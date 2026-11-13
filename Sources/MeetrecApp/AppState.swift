import AVFoundation
import AppKit
import EventKit
import Foundation
import RecorderKit
import ServiceManagement
import UserNotifications

// MARK: - Встречи на диске

enum MeetingStatus: Equatable {
    case recording
    case processing(stage: String?)
    case done
    case partial // результаты есть, но последний прогон с ошибкой (часть действий / повтор упали)
    case failed
    case pending // записано, но не обработано

    var isProcessing: Bool { if case .processing = self { return true } else { return false } }
    var isBusy: Bool { self == .recording || isProcessing }
}

/// Встреча на диске: папка в ~/Meetings.
struct MeetingFolder: Identifiable, Equatable {
    let url: URL
    let title: String
    let date: Date
    let status: MeetingStatus
    /// Готовые результаты действий (notes.md, action-items.md, …) в порядке действий.
    let results: [URL]
    /// Причина ошибки последнего прогона (строка «❌ …» из process.log) — для .failed / .partial.
    let error: String?
    var id: URL { url }
    var transcript: URL { url.appendingPathComponent("transcript.md") }
    var log: URL { url.appendingPathComponent("process.log") }
    /// Главный результат: первое действие, иначе транскрипт.
    var primaryResult: URL { results.first ?? transcript }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcript.path) }
}

// MARK: - Уровни звука

/// Уровни во время записи — отдельный объект: 4 обновления в секунду перерисовывают
/// только полоски, а не всё окно (минимум нагрузки во время созвона).
@MainActor
final class Meter: ObservableObject {
    static let shared = Meter()
    @Published private(set) var me: Float = 0
    @Published private(set) var them: Float = 0
    /// Сколько секунд подряд молчит дорожка «Они».
    @Published private(set) var themSilentSeconds: Double = 0
    /// «Они» звучали с начала записи — тогда долгая тишина (свой монолог, демонстрация) — норма.
    @Published private(set) var themHeard = false

    /// Предупреждать: ни разу не звучали за 30 с, или пропали на 5 минут посреди созвона (сменился выход звука).
    var themSilenceAlarm: Bool { themSilentSeconds >= (themHeard ? 300 : 30) }

    func update(me peakMe: Float, them peakThem: Float, dt: Double) {
        me = Self.normalized(peakMe)
        them = Self.normalized(peakThem)
        let loud = peakThem >= 0.001 // > −60 dBFS
        if loud, !themHeard { themHeard = true }
        themSilentSeconds = loud ? 0 : themSilentSeconds + dt
    }

    func reset() { me = 0; them = 0; themSilentSeconds = 0; themHeard = false }

    /// Пик → 0…1 по шкале −50…0 dBFS: тихая речь собеседника (пик 0.02–0.1) видна, а не «пустая».
    static func normalized(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(peak) + 50) / 50))
    }
}

/// Фаза мигания точки «Записать?» — отдельный объект: его слушает только иконка,
/// а не всё окно (мигание идёт во время созвона).
@MainActor
final class Blinker: ObservableObject {
    static let shared = Blinker()
    @Published var on = true
}

// MARK: - Разрешения

enum Permission: String, Identifiable, CaseIterable {
    case microphone, systemAudio, calendar, notifications
    var id: String { rawValue }

    var text: String {
        switch self {
        case .microphone: return "Нет доступа к микрофону — дорожка «Я» не запишется"
        case .systemAudio: return "Нет доступа к системному звуку — дорожка «Они» будет тишиной"
        case .calendar: return "Нет доступа к календарю — встречи не видны"
        case .notifications: return "Уведомления выключены — не узнаешь, что заметки готовы"
        }
    }

    /// Ещё не спрашивали — кнопка «Разрешить» (системный запрос), а не «Открыть настройки».
    var canRequest: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .systemAudio: return Recording.audioCapturePermissionStatus() == "unknown"
        case .calendar, .notifications: return false
        }
    }

    var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference."
        switch self {
        case .microphone: return URL(string: base + "security?Privacy_Microphone")!
        case .systemAudio: return URL(string: base + "security?Privacy_ScreenCapture")!
        case .calendar: return URL(string: base + "security?Privacy_Calendars")!
        case .notifications: return URL(string: base + "notifications")!
        }
    }
}

// MARK: - Состояние приложения

/// Подсказка «Остановить запись?»: созвон закончился / началась следующая встреча.
struct StopSuggestion: Equatable {
    let key: String       // причина; закрытую ✕ больше не показываем в этой записи
    let text: String
    let next: MeetingEvent? // началась следующая встреча — можно сразу подключиться
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Запись
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var recordingTitle: String?
    @Published private(set) var recordingDir: URL?
    @Published var errorText: String?

    // Календарь
    @Published private(set) var event: MeetingEvent?
    @Published private(set) var followingEvent: MeetingEvent?
    @Published private(set) var promptEvent: MeetingEvent?
    /// Встреча, для которой показана плашка «Через минуту — Подключиться».
    @Published private(set) var joinPanelEvent: MeetingEvent?
    /// Во время записи: похоже, пора остановить.
    @Published private(set) var stopSuggestion: StopSuggestion?
    /// Микрофон занят созвоном (Zoom/Meet/…) — значит, уже подключился.
    @Published private(set) var callActive = false
    /// Меняется раз в минуту — чтобы обратный отсчёт в метке и окне не застывал.
    @Published private(set) var minuteTick = 0

    // Разрешения и встречи
    @Published private(set) var missingPermissions: [Permission] = []
    @Published private(set) var meetings: [MeetingFolder] = []
    /// Обработка упала, а окно с тех пор не открывали — «!» в иконке.
    @Published private(set) var unseenFailure = false
    /// Заметки готовы, а окно/заметки с тех пор не открывали — «✓» в иконке (гаснет и сам через 15 мин).
    @Published private(set) var unseenNotes = false
    private var unseenNotesSince: Date?
    private var blinkTimer: Timer?

    /// Папка встреч (настраивается в окне настроек), по умолчанию ~/Meetings.
    @Published private(set) var meetingsRoot: URL = {
        if let path = UserDefaults.standard.string(forKey: "meetingsRoot"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
    }()

    func setMeetingsRoot(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "meetingsRoot")
        meetingsRoot = url
        refreshMeetings()
    }
    private let calendar = CalendarService()
    private var recording: Recording?
    private var tickTimer: Timer?
    private var levelTimer: Timer?
    private var prompted: Set<String> = []
    private var joinReminded: Set<String> = []
    private var promptShownAt: Date?
    private var started: Set<URL> = [] // обработки, запущенные приложением (до появления замка на диске)
    private var audioPermissionWarned = false
    // Для подсказки «Остановить?»
    private var recordingEvent: MeetingEvent?
    private var recordingStartedAt: Date?
    private var callSeenWhileRecording = false
    private var callIdleSince: Date?
    private var stopDismissed: Set<String> = []
    private var permissionRequestInFlight = false
    /// Системный звук уже запрашивали в этом запуске: preflight TCC отстаёт от ответа пользователя,
    /// так что «unknown» после запроса — не повод показывать «нет доступа».
    private var audioRequested = false
    private var peakMe: Float = 0, peakThem: Float = 0
    private var levelTicks = 0

    var processingMeeting: MeetingFolder? { meetings.first { $0.status.isProcessing } }

    private init() {
        refreshMeetings()
        Task {
            _ = await calendar.requestAccess()
            tick()
            // Микрофон и системный звук — сразу при первом запуске, а не посреди первого созвона.
            requestRecordingPermissions()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppState.shared.tick() }
        }
    }

    /// Присвоить, только если значение изменилось: @Published шлёт обновление даже при равенстве.
    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: - Периодическая проверка (раз в 5 с)

    func tick() {
        let now = Date()
        assign(\.minuteTick, Int(now.timeIntervalSince1970 / 60))
        let (main, following) = calendar.upcoming(now: now)
        assign(\.event, main)
        assign(\.followingEvent, following)

        // Подсказка «Записать?» гаснет через 5 минут или с концом встречи.
        if let e = promptEvent, now >= e.end || now.timeIntervalSince(promptShownAt ?? now) > 300 {
            promptEvent = nil
        }

        // За минуту до встречи — плашка «Подключиться». Смотрим и следующую:
        // при встречах подряд main — ещё идущая встреча. Плашка гаснет через 3 мин после начала.
        for e in [main, following].compactMap({ $0 })
        where e.joinURL != nil && e.start > now && e.start.timeIntervalSince(now) <= 60 && !joinReminded.contains(e.id) {
            joinReminded.insert(e.id)
            joinPanelEvent = e
        }
        if let j = joinPanelEvent, now > j.start.addingTimeInterval(180) { joinPanelEvent = nil }

        // Созвон = кто-то, кроме нас, пишет микрофон (любой, не только системный по умолчанию).
        // Запасной признак вне записи — занятость микрофона по умолчанию.
        let call = otherProcessUsingInput() || (!isRecording && defaultInputInUse())
        assign(\.callActive, call)
        if isRecording { updateStopSuggestion(now: now, main: main, call: call) }

        // Встреча идёт и Zoom/Meet занял микрофон — предложить запись (один раз на встречу).
        if !isRecording, !isStarting, let e = main,
           e.start.addingTimeInterval(-60) <= now, now < e.end,
           !prompted.contains(e.id), call {
            prompted.insert(e.id)
            promptEvent = e
            promptShownAt = now
            // Микрофон занят этой же встречей — значит, уже подключился; напоминание о другой встрече не трогаем.
            if joinPanelEvent?.id == e.id { joinPanelEvent = nil }
        }
        updatePanel()

        if unseenNotes, let since = unseenNotesSince, now.timeIntervalSince(since) > 900 { unseenNotes = false }
        Hotkey.shared.refreshTrust() // «Универсальный доступ» могли выдать при закрытых настройках

        // Диск читаем часто, только пока что-то пишется или обрабатывается; иначе — при открытии окна.
        if isRecording || !started.isEmpty || processingMeeting != nil { refreshMeetings() }
    }

    /// Окно открыли: всё актуализировать (диск, разрешения), «!» в метке погасить.
    func popoverOpened() {
        unseenFailure = false
        unseenNotes = false
        tick()
        refreshMeetings()
        refreshPermissions()
        Hotkey.shared.refreshTrust()
    }

    /// Подсказка «Остановить запись?»: созвон ушёл с микрофона на минуту (только если он был
    /// во время записи — очная встреча без Zoom так не сработает), запись пережила встречу на 2 мин
    /// без созвона, или началась следующая встреча.
    private func updateStopSuggestion(now: Date, main: MeetingEvent?, call: Bool) {
        if call { callSeenWhileRecording = true; callIdleSince = nil } else if callIdleSince == nil { callIdleSince = now }
        var s: StopSuggestion?
        if let m = main, m.id != recordingEvent?.id, m.isInProgress(at: now), m.start > (recordingStartedAt ?? now) {
            s = StopSuggestion(key: "next-\(m.id)", text: "Началась «\(m.title)»", next: m)
        } else if callSeenWhileRecording, let idle = callIdleSince, now.timeIntervalSince(idle) >= 60 {
            s = StopSuggestion(key: "idle", text: "Созвон, похоже, закончился — микрофон свободен", next: nil)
        } else if let r = recordingEvent, now >= r.end.addingTimeInterval(call ? 600 : 120) {
            // Микрофон кем-то занят (диктовка, фоновый helper) — всё равно спросить, но позже.
            s = StopSuggestion(key: "ended", text: "Встреча закончилась в \(Format.time.string(from: r.end))", next: nil)
        }
        if let k = s?.key, stopDismissed.contains(k) { s = nil }
        assign(\.stopSuggestion, s)
    }

    func dismissStop() {
        if let k = stopSuggestion?.key { stopDismissed.insert(k) }
        stopSuggestion = nil
        updatePanel()
    }

    /// Запросить микрофон и системный звук (если ещё не спрашивали). Запросы блокируют поток — не на главном.
    func requestRecordingPermissions() {
        guard !permissionRequestInFlight, Permission.microphone.canRequest || Permission.systemAudio.canRequest else { return }
        permissionRequestInFlight = true
        Task.detached {
            let micOK = Recording.requestMicAccess()
            let audioWarning = micOK ? Recording.ensureAudioCapturePermission() : nil
            await MainActor.run {
                let state = AppState.shared
                state.permissionRequestInFlight = false
                if micOK { state.audioRequested = true; state.audioPermissionWarned = audioWarning != nil }
                state.refreshPermissions()
            }
        }
    }

    func refreshPermissions() {
        var missing: [Permission] = []
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .denied || mic == .notDetermined { missing.append(.microphone) }
        let audio = Recording.audioCapturePermissionStatus()
        if audio == "authorized" { audioPermissionWarned = false } // выдали в Настройках — предупреждение снять
        if audio == "denied" || (audio == "unknown" && !audioRequested) || audioPermissionWarned { missing.append(.systemAudio) }
        if !calendar.refreshAuthorization(), EKEventStore.authorizationStatus(for: .event) != .notDetermined {
            missing.append(.calendar)
        }
        let current = missing
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in
                AppState.shared.assign(\.missingPermissions, current + (denied ? [.notifications] : []))
            }
        }
    }

    // MARK: - Действия со встречей

    func join(_ event: MeetingEvent) {
        if let url = event.joinURL { NSWorkspace.shared.open(url) }
        joinPanelEvent = nil
        updatePanel()
    }

    func dismissPrompt() {
        promptEvent = nil
        updatePanel()
    }

    /// Мигаем точкой в иконке, пока висит «Записать?»; в остальное время таймера нет.
    private func updateBlink() {
        let needed = promptEvent != nil && !isRecording && !isStarting
        if needed, blinkTimer == nil {
            let t = Timer(timeInterval: 0.7, repeats: true) { _ in
                Task { @MainActor in Blinker.shared.on.toggle() }
            }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common) // мигать и при открытом меню
            blinkTimer = t
        } else if !needed, let t = blinkTimer {
            t.invalidate()
            blinkTimer = nil
            Blinker.shared.on = true
        }
    }

    /// Пользователь сам открыл заметки (из уведомления) — «✓» больше не нужен.
    func notesSeen() { unseenNotes = false }

    /// Окно meetrec сейчас перед глазами — тогда «✓ / !» в иконке не нужны.
    private var windowVisible: Bool {
        NSApp.windows.contains { $0.isKeyWindow && $0.isVisible && !($0 is NSPanel) }
    }

    func dismissJoin() {
        joinPanelEvent = nil
        updatePanel()
    }

    /// Плашка: «Записать?» важнее «Подключиться». Во время записи «Записать?» не нужна,
    /// а «Подключиться» к следующей встрече (встречи подряд) — нужна.
    func updatePanel() {
        updateBlink()
        // «Остановить?» без следующей встречи не перекрывает «Подключиться» к следующей.
        if isRecording, let s = stopSuggestion, s.next != nil || joinPanelEvent == nil {
            FloatingPanel.shared.show(.stop(s))
        } else if let e = promptEvent, !isRecording, !isStarting {
            FloatingPanel.shared.show(.prompt(e))
        } else if let e = joinPanelEvent {
            FloatingPanel.shared.show(.join(e))
        } else {
            FloatingPanel.shared.hide()
        }
    }

    // MARK: - Запись

    /// Начать запись; если встреча известна — папка и meta.md по ней.
    func startRecording(for event: MeetingEvent?) {
        guard !isRecording, !isStarting else { return }
        let ev = event ?? self.event.flatMap { $0.isInProgress() ? $0 : nil }
        let dir = meetingsRoot.appendingPathComponent(Self.folderName(for: ev))
        isStarting = true
        errorText = nil
        promptEvent = nil
        joinPanelEvent = nil
        updatePanel()
        // Запросы разрешений блокируют поток до ответа пользователя — не на главном.
        Task.detached {
            let micOK = Recording.requestMicAccess()
            let audioWarning = micOK ? Recording.ensureAudioCapturePermission() : nil
            await MainActor.run {
                AppState.shared.finishStart(dir: dir, event: ev, micOK: micOK, audioWarning: audioWarning)
            }
        }
    }

    private func finishStart(dir: URL, event: MeetingEvent?, micOK: Bool, audioWarning: String?) {
        isStarting = false
        defer { updatePanel() }
        guard micOK else {
            refreshPermissions()
            errorText = "Запись не началась: нет доступа к микрофону."
            return
        }
        audioPermissionWarned = audioWarning != nil
        audioRequested = true
        refreshPermissions()
        do {
            let rec = try Recording(dir: dir)
            if let event { Self.writeMeta(event, to: dir) }
            try rec.start()
            recording = rec
            recordingTitle = event?.title
            recordingDir = dir
            recordingEvent = event
            recordingStartedAt = Date()
            callSeenWhileRecording = false
            callIdleSince = nil
            stopDismissed = []
            stopSuggestion = nil
            isRecording = true
            elapsedSeconds = 0
            Meter.shared.reset()
            peakMe = 0; peakThem = 0; levelTicks = 0
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                Task { @MainActor in AppState.shared.updateLevels() }
            }
            refreshMeetings()
        } catch {
            errorText = "Запись не началась: \(error)"
        }
    }

    private func updateLevels() {
        guard let rec = recording else { return }
        let (me, them) = rec.takeLevels()
        Meter.shared.update(me: me, them: them, dt: 0.25)
        assign(\.elapsedSeconds, Int(rec.elapsed))
        peakMe = max(peakMe, me)
        peakThem = max(peakThem, them)
        levelTicks += 1
        if levelTicks % 120 == 0 { // ~30 с
            rec.logPeriodic(peakMe: peakMe, peakThem: peakThem)
            peakMe = 0; peakThem = 0
        }
    }

    /// Горячая клавиша: старт (с привязкой к идущей встрече) или стоп.
    func toggleRecording() {
        if isRecording {
            stopRecording(reason: "горячая клавиша")
        } else {
            startRecording(for: promptEvent)
        }
    }

    /// Остановить запись и сразу запустить обработку.
    func stopRecording(reason: String = "кнопка Стоп") {
        guard let rec = recording else { return }
        levelTimer?.invalidate()
        levelTimer = nil
        rec.stop(reason: reason)
        recording = nil
        recordingDir = nil
        isRecording = false
        Meter.shared.reset()
        let title = recordingTitle ?? Self.title(of: rec.dir)
        recordingTitle = nil
        recordingEvent = nil
        stopSuggestion = nil
        updatePanel()
        process(rec.dir, title: title)
    }

    // MARK: - Обработка (scripts/process.sh из репозитория)

    /// Повтор: транскрипт уже есть — только действия (ошибка шлюза не стоит минут повторной расшифровки).
    func retry(_ dir: URL, title: String) {
        let hasTranscript = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path)
        process(dir, title: title, actionsOnly: hasTranscript)
    }

    func process(_ dir: URL, title: String, actionsOnly: Bool = false) {
        guard !started.contains(dir), dir != recordingDir,
              !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".processing").path)
        else { return }
        guard let root = Bundle.main.object(forInfoDictionaryKey: "MeetrecRepoRoot") as? String else {
            errorText = "Обработка не запущена: в Info.plist нет MeetrecRepoRoot — пересобери build-app.sh"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["\(root)/scripts/process.sh"] + (actionsOnly ? ["--actions-only"] : []) + [dir.path]
        var env = ProcessInfo.processInfo.environment
        // GUI-приложения не видят PATH из shell — добавляем Homebrew (whisper-cli) явно.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice // process.sh сам пишет process.log
        p.standardError = FileHandle.nullDevice
        let runStarted = Date()
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                let state = AppState.shared
                state.started.remove(dir)
                state.refreshMeetings()
                let m = Self.manifest(in: dir)
                let error = Self.logInfo(dir).error
                // Часть действий выполнилась в этом прогоне — это «готово с оговоркой», а не ошибка:
                // клик открывает заметки, в тексте — что не выполнилось.
                let partial = !ok && !m.ok.isEmpty && Self.manifestNewer(than: runStarted, in: dir)
                if ok || partial {
                    state.unseenFailure = false
                    if !state.windowVisible { state.unseenNotes = true; state.unseenNotesSince = Date() }
                    Notifier.notesReady(title: title, dir: dir,
                                        results: m.ok.isEmpty ? [dir.appendingPathComponent("transcript.md")] : m.ok,
                                        failed: partial ? m.failed : [], quiet: state.isRecording)
                } else {
                    state.unseenNotes = false
                    if !state.windowVisible { state.unseenFailure = true }
                    Notifier.failed(title: title, dir: dir, reason: error, quiet: state.isRecording)
                }
            }
        }
        do {
            try p.run()
            started.insert(dir)
            refreshMeetings()
        } catch {
            errorText = "Обработка не запущена: \(error.localizedDescription)"
        }
    }

    // MARK: - Встречи на диске

    func refreshMeetings() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let list = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { dir -> (URL, Date) in (dir, (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { dir, date in
                let results = Self.results(in: dir)
                let log = Self.logInfo(dir)
                let status = status(of: dir, results: results, log: log)
                return MeetingFolder(url: dir, title: Self.title(of: dir), date: date, status: status, results: results,
                                     error: status == .failed || status == .partial ? log.error : nil)
            }
        assign(\.meetings, list)
    }

    private func status(of dir: URL, results: [URL], log: LogInfo) -> MeetingStatus {
        let fm = FileManager.default
        if dir == recordingDir { return .recording }
        if started.contains(dir) || fm.fileExists(atPath: dir.appendingPathComponent(".processing").path) {
            return .processing(stage: log.stage)
        }
        // Есть результаты — «готово»; последний прогон упал: часть действий в нём выполнилась — «с оговоркой»,
        // ни одно (туннель, whisper) — «ошибка», хотя заметки прошлого прогона остались.
        if !results.isEmpty, (log.exitCode ?? 0) == 0 { return .done }
        if !results.isEmpty, log.actionsSucceeded { return .partial }
        if let code = log.exitCode, code != 0 { return .failed }
        // Действия выключены — готово, когда есть транскрипт и обработка завершилась успешно.
        if log.exitCode == 0, fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path) { return .done }
        return .pending
    }

    /// Результаты действий из results.json, который пишет run_actions.py (имена файлов — уже
    /// нормализованные скриптом). Встречи, обработанные до действий, — notes.md.
    static func results(in dir: URL) -> [URL] { manifest(in: dir).ok }

    /// results.json: готовые файлы и названия невыполненных действий.
    static func manifest(in dir: URL) -> (ok: [URL], failed: [String]) {
        let fm = FileManager.default
        struct Manifest: Decodable {
            struct Item: Decodable { let name: String?; let file: String; let ok: Bool }
            let results: [Item]
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("results.json")),
           let m = try? JSONDecoder().decode(Manifest.self, from: data) {
            let ok = m.results.filter(\.ok)
                .map { dir.appendingPathComponent($0.file) }
                .filter { fm.fileExists(atPath: $0.path) }
            return (ok, m.results.filter { !$0.ok }.map { $0.name ?? $0.file })
        }
        let legacy = dir.appendingPathComponent("notes.md")
        return (fm.fileExists(atPath: legacy.path) ? [legacy] : [], [])
    }

    /// results.json записан этим прогоном (позже его старта) — значит, действия дошли до конца.
    static func manifestNewer(than date: Date, in dir: URL) -> Bool {
        let m = try? dir.appendingPathComponent("results.json").resourceValues(forKeys: [.contentModificationDateKey])
        return (m?.contentModificationDate ?? .distantPast) > date
    }

    /// Последний код выхода, текущая стадия и последняя ошибка («❌ …») — из хвоста process.log.
    struct LogInfo { var exitCode: Int32?; var stage: String?; var error: String?; var actionsSucceeded = false }

    static func logInfo(_ dir: URL) -> LogInfo {
        guard let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent("process.log")) else { return LogInfo() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 16384 ? size - 16384 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var info = LogInfo()
        for line in tail.split(separator: "\n") {
            if line.hasPrefix("=== exit ") { info.exitCode = Int32(line.dropFirst(9).trimmingCharacters(in: .whitespaces)) }
            if line.hasPrefix("=== process.sh") { info = LogInfo() } // начался новый прогон
            if line.hasPrefix("→ ") { info.stage = String(line.dropFirst(2)) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("❌") { info.error = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if trimmed.hasPrefix("✅ «") { info.actionsSucceeded = true } // строка run_actions.py об успешном действии
        }
        return info
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    // MARK: - Настройки и выход

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorText = "Автозапуск: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    func openConfig() {
        open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/meetrec/env"))
    }

    /// «Выйти» во время записи = «Остановить и выйти»: запись корректно закрывается и уходит в обработку.
    func quit() {
        stopRecording(reason: "выход из приложения")
        NSApp.terminate(nil)
    }

    // MARK: - Вспомогательное

    /// 2026-11-12-140312-sync-s-komandoy (или 2026-11-12-140312 без встречи). С секундами —
    /// чтобы повторный старт той же встречи (случайный «Стоп») не упёрся в занятую папку.
    static func folderName(for event: MeetingEvent?) -> String {
        let stamp = Format.folderStamp.string(from: Date())
        guard let event else { return stamp }
        let latin = event.title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? event.title
        let slug = latin.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? stamp : "\(stamp)-\(String(slug.prefix(40)))"
    }

    static func writeMeta(_ event: MeetingEvent, to dir: URL) {
        let f = Format.metaTime
        var text = "# \(event.title)\n\n- Время: \(f.string(from: event.start)) – \(f.string(from: event.end))\n"
        if !event.attendees.isEmpty { text += "- Участники: \(event.attendees.joined(separator: ", "))\n" }
        try? text.write(to: dir.appendingPathComponent("meta.md"), atomically: true, encoding: .utf8)
    }

    /// Название встречи: первая строка meta.md («# …»), иначе «Запись без встречи».
    static func title(of dir: URL) -> String {
        if let meta = try? String(contentsOf: dir.appendingPathComponent("meta.md"), encoding: .utf8),
           let first = meta.split(separator: "\n").first, first.hasPrefix("# ") {
            return String(first.dropFirst(2))
        }
        return "Запись без встречи"
    }
}
