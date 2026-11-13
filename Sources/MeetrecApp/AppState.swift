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
    case failed
    case pending // записано, но не обработано

    var isProcessing: Bool { if case .processing = self { return true } else { return false } }
}

/// Встреча на диске: папка в ~/Meetings.
struct MeetingFolder: Identifiable, Equatable {
    let url: URL
    let title: String
    let date: Date
    let status: MeetingStatus
    var id: URL { url }
    var notes: URL { url.appendingPathComponent("notes.md") }
    var log: URL { url.appendingPathComponent("process.log") }
}

// MARK: - Уровни звука

/// Уровни во время записи — отдельный объект: 4 обновления в секунду перерисовывают
/// только полоски, а не всё окно (минимум нагрузки во время созвона).
@MainActor
final class Meter: ObservableObject {
    static let shared = Meter()
    @Published private(set) var me: Float = 0
    @Published private(set) var them: Float = 0
    @Published private(set) var themSilentSeconds: Double = 0

    func update(me peakMe: Float, them peakThem: Float, dt: Double) {
        me = Self.normalized(peakMe)
        them = Self.normalized(peakThem)
        themSilentSeconds = peakThem < 0.001 ? themSilentSeconds + dt : 0 // < −60 dBFS
    }

    func reset() { me = 0; them = 0; themSilentSeconds = 0 }

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

    let meetingsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
    private let calendar = CalendarService()
    private var recording: Recording?
    private var tickTimer: Timer?
    private var levelTimer: Timer?
    private var prompted: Set<String> = []
    private var joinReminded: Set<String> = []
    private var promptShownAt: Date?
    private var started: Set<URL> = [] // обработки, запущенные приложением (до появления замка на диске)
    private var audioPermissionWarned = false
    private var peakMe: Float = 0, peakThem: Float = 0
    private var levelTicks = 0

    var processingMeeting: MeetingFolder? { meetings.first { $0.status.isProcessing } }

    private init() {
        refreshMeetings()
        Task {
            _ = await calendar.requestAccess()
            tick()
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

        // Встреча идёт и Zoom/Meet занял микрофон — предложить запись (один раз на встречу).
        if !isRecording, !isStarting, let e = main,
           e.start.addingTimeInterval(-60) <= now, now < e.end,
           !prompted.contains(e.id), defaultInputInUse() {
            prompted.insert(e.id)
            promptEvent = e
            promptShownAt = now
            // Микрофон занят этой же встречей — значит, уже подключился; напоминание о другой встрече не трогаем.
            if joinPanelEvent?.id == e.id { joinPanelEvent = nil }
        }
        updatePanel()

        if unseenNotes, let since = unseenNotesSince, now.timeIntervalSince(since) > 900 { unseenNotes = false }

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
    }

    func refreshPermissions() {
        var missing: [Permission] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { missing.append(.microphone) }
        let audio = Recording.audioCapturePermissionStatus()
        if audio == "authorized" { audioPermissionWarned = false } // выдали в Настройках — предупреждение снять
        if audio == "denied" || audioPermissionWarned { missing.append(.systemAudio) }
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
        if let e = promptEvent, !isRecording, !isStarting {
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
        refreshPermissions()
        do {
            let rec = try Recording(dir: dir)
            if let event { Self.writeMeta(event, to: dir) }
            try rec.start()
            recording = rec
            recordingTitle = event?.title
            recordingDir = dir
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
        updatePanel()
        process(rec.dir, title: title)
    }

    // MARK: - Обработка (scripts/process.sh из репозитория)

    func process(_ dir: URL, title: String) {
        guard !started.contains(dir), dir != recordingDir,
              !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".processing").path)
        else { return }
        guard let root = Bundle.main.object(forInfoDictionaryKey: "MeetrecRepoRoot") as? String else {
            errorText = "Обработка не запущена: в Info.plist нет MeetrecRepoRoot — пересобери build-app.sh"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["\(root)/scripts/process.sh", dir.path]
        var env = ProcessInfo.processInfo.environment
        // GUI-приложения не видят PATH из shell — добавляем Homebrew (whisper-cli) явно.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice // process.sh сам пишет process.log
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                let state = AppState.shared
                state.started.remove(dir)
                state.refreshMeetings()
                if ok {
                    state.unseenFailure = false
                    if !state.windowVisible { state.unseenNotes = true; state.unseenNotesSince = Date() }
                    Notifier.notesReady(title: title, notes: dir.appendingPathComponent("notes.md"), quiet: state.isRecording)
                } else {
                    state.unseenNotes = false
                    if !state.windowVisible { state.unseenFailure = true }
                    Notifier.failed(title: title, dir: dir, quiet: state.isRecording)
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
            .map { dir, date in MeetingFolder(url: dir, title: Self.title(of: dir), date: date, status: status(of: dir)) }
        assign(\.meetings, list)
    }

    private func status(of dir: URL) -> MeetingStatus {
        let fm = FileManager.default
        if dir == recordingDir { return .recording }
        let log = Self.logInfo(dir)
        if started.contains(dir) || fm.fileExists(atPath: dir.appendingPathComponent(".processing").path) {
            return .processing(stage: log.stage)
        }
        // Есть заметки — встреча «готова», даже если последний повтор обработки упал.
        if fm.fileExists(atPath: dir.appendingPathComponent("notes.md").path) { return .done }
        if let code = log.exitCode, code != 0 { return .failed }
        return .pending
    }

    /// Последний код выхода и текущая стадия обработки — из хвоста process.log.
    static func logInfo(_ dir: URL) -> (exitCode: Int32?, stage: String?) {
        guard let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent("process.log")) else { return (nil, nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var exitCode: Int32?
        var stage: String?
        for line in tail.split(separator: "\n") {
            if line.hasPrefix("=== exit ") { exitCode = Int32(line.dropFirst(9).trimmingCharacters(in: .whitespaces)) }
            if line.hasPrefix("=== process.sh") { exitCode = nil; stage = nil } // начался новый прогон
            if line.hasPrefix("→ ") { stage = String(line.dropFirst(2)) }
        }
        return (exitCode, stage)
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
