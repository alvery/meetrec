import AppKit
import Foundation
import RecorderKit
import ServiceManagement

/// Встреча на диске: папка в ~/Meetings.
struct MeetingFolder: Identifiable, Equatable {
    let url: URL
    let title: String
    let date: Date
    let hasNotes: Bool
    var id: URL { url }
    var notes: URL { url.appendingPathComponent("notes.md") }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Запись
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levelMe: Float = 0
    @Published private(set) var levelThem: Float = 0
    @Published private(set) var recordingTitle: String?
    @Published var errorText: String?
    @Published var warningText: String?

    // Календарь
    @Published private(set) var event: MeetingEvent?
    @Published private(set) var calendarAuthorized = true
    @Published private(set) var promptEvent: MeetingEvent?

    // Встречи на диске
    @Published private(set) var meetings: [MeetingFolder] = []
    @Published private(set) var processing: Set<URL> = []

    let meetingsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
    private let calendar = CalendarService()
    private var recording: Recording?
    private var tickTimer: Timer?
    private var levelTimer: Timer?
    private var prompted: Set<String> = []
    private var peakMe: Float = 0, peakThem: Float = 0
    private var levelTicks = 0

    private init() {
        refreshMeetings()
        Task {
            calendarAuthorized = await calendar.requestAccess()
            tick()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppState.shared.tick() }
        }
    }

    // MARK: - Календарь и подсказка о записи

    /// Раз в 5 секунд: обновить встречу; если она идёт, а микрофон занят Zoom/Meet — предложить запись.
    func tick() {
        let now = Date()
        event = calendar.currentOrNext(now: now)
        if let e = promptEvent, now >= e.end { promptEvent = nil }
        guard !isRecording, !isStarting, let e = event,
              e.start.addingTimeInterval(-60) <= now, now < e.end,
              !prompted.contains(e.id), defaultInputInUse()
        else { return }
        prompted.insert(e.id)
        promptEvent = e
        Notifier.meetingStarted(e)
    }

    func join(_ event: MeetingEvent) {
        if let url = event.joinURL { NSWorkspace.shared.open(url) }
    }

    func openCalendarPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    // MARK: - Запись

    /// Начать запись; если встреча известна — папка и meta.md по ней.
    func startRecording(for event: MeetingEvent?) {
        guard !isRecording, !isStarting else { return }
        let ev = event ?? self.event.flatMap { $0.isInProgress() ? $0 : nil }
        let dir = meetingsRoot.appendingPathComponent(Self.folderName(for: ev))
        isStarting = true
        errorText = nil
        warningText = nil
        promptEvent = nil
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
        guard micOK else {
            errorText = "Нет доступа к микрофону: Системные настройки → Конфиденциальность → Микрофон → meetrec."
            return
        }
        warningText = audioWarning
        do {
            let rec = try Recording(dir: dir)
            if let event { Self.writeMeta(event, to: dir) }
            try rec.start()
            recording = rec
            recordingTitle = event?.title
            isRecording = true
            elapsed = 0
            peakMe = 0; peakThem = 0; levelTicks = 0
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                Task { @MainActor in AppState.shared.updateLevels() }
            }
            refreshMeetings()
        } catch {
            errorText = "Не удалось начать запись: \(error)"
        }
    }

    private func updateLevels() {
        guard let rec = recording else { return }
        let (me, them) = rec.takeLevels()
        levelMe = me
        levelThem = them
        elapsed = rec.elapsed
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
        isRecording = false
        levelMe = 0; levelThem = 0
        let title = recordingTitle ?? rec.dir.lastPathComponent
        recordingTitle = nil
        process(rec.dir, title: title)
    }

    // MARK: - Обработка (scripts/process.sh из репозитория)

    func process(_ dir: URL, title: String) {
        guard !processing.contains(dir) else { return }
        guard let root = Bundle.main.object(forInfoDictionaryKey: "MeetrecRepoRoot") as? String else {
            Notifier.failed(title: "Обработка не запущена", body: "В Info.plist нет MeetrecRepoRoot — пересобери build-app.sh")
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
                state.processing.remove(dir)
                state.refreshMeetings()
                if ok {
                    Notifier.notesReady(title: title, notes: dir.appendingPathComponent("notes.md"))
                } else {
                    Notifier.failed(title: "Обработка не удалась: \(title)",
                                    body: "Код \(proc.terminationStatus). Подробности — process.log в папке встречи.")
                }
            }
        }
        do {
            try p.run()
            processing.insert(dir)
        } catch {
            Notifier.failed(title: "Обработка не запущена", body: "\(error)")
        }
    }

    // MARK: - Встречи на диске

    func refreshMeetings() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        meetings = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { dir -> MeetingFolder in
                let date = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return MeetingFolder(url: dir, title: Self.title(of: dir), date: date,
                                     hasNotes: fm.fileExists(atPath: dir.appendingPathComponent("notes.md").path))
            }
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map { $0 }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    // MARK: - Настройки

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
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/meetrec/env")
        NSWorkspace.shared.open(url)
    }

    func quit() {
        stopRecording(reason: "выход из приложения")
        NSApp.terminate(nil)
    }

    // MARK: - Вспомогательное

    /// 2026-11-12-1400-sync-s-komandoy (или 2026-11-12-140312 без встречи).
    static func folderName(for event: MeetingEvent?) -> String {
        let f = DateFormatter()
        f.dateFormat = event == nil ? "yyyy-MM-dd-HHmmss" : "yyyy-MM-dd-HHmm"
        let stamp = f.string(from: Date())
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
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var text = "# \(event.title)\n\n- Время: \(f.string(from: event.start)) – \(f.string(from: event.end))\n"
        if !event.attendees.isEmpty { text += "- Участники: \(event.attendees.joined(separator: ", "))\n" }
        try? text.write(to: dir.appendingPathComponent("meta.md"), atomically: true, encoding: .utf8)
    }

    /// Название встречи: первая строка meta.md («# …»), иначе имя папки.
    static func title(of dir: URL) -> String {
        if let meta = try? String(contentsOf: dir.appendingPathComponent("meta.md"), encoding: .utf8),
           let first = meta.split(separator: "\n").first, first.hasPrefix("# ") {
            return String(first.dropFirst(2))
        }
        return dir.lastPathComponent
    }
}
