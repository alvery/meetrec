import AVFoundation
import CoreAudio
import Foundation

/// Одна запись встречи: обе дорожки, лог, разрешения. Общий фасад для CLI и приложения.
@available(macOS 14.2, *)
public final class Recording {
    public let dir: URL
    let mic: MicRecorder
    let system: SystemAudioRecorder
    private var stopped = false

    /// Файлы, по которым видно, что в папке уже есть запись: дописывать в неё нельзя —
    /// сегменты разных встреч перемешались бы.
    static let markers = ["mic.segments", "system.segments", "mic.caf", "mic.m4a", "system.caf", "system.m4a"]

    /// Создаёт папку и лог. Бросает ошибку, если в папке уже есть запись.
    public init(dir: URL) throws {
        let fm = FileManager.default
        let existing = Self.markers.filter { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard existing.isEmpty else {
            throw RecError("в \(dir.path) уже есть запись (\(existing.joined(separator: ", "))) — выбери другую папку")
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        Log.shared.open(dir.appendingPathComponent("rec.log"))
        log("▶︎ start, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", echo: false)
        mic = MicRecorder(dir: dir)
        system = SystemAudioRecorder(dir: dir)
    }

    public func start() throws {
        recordingT0 = ProcessInfo.processInfo.systemUptime
        do {
            // Микрофон — первым: если это AirPods/гарнитура, они переключатся в HFP сразу.
            try mic.start()
            try system.start()
        } catch {
            system.stop()
            mic.stop()
            log("❌ \(error)", echo: false)
            throw error
        }
    }

    /// Останавливает обе дорожки и пишет итог в лог. Повторный вызов ничего не делает.
    public func stop(reason: String) {
        guard !stopped else { return }
        stopped = true
        mic.stop()
        system.stop()
        let e = elapsed
        log("■ stop (\(reason)), длительность \(Int(e)) с", echo: false)
        log(describe("mic", mic.track, elapsed: e), echo: false)
        log(describe("system", system.track, elapsed: e), echo: false)
    }

    public var elapsed: TimeInterval { sinceStart() }

    /// Пиковые уровни (0…1) с прошлого вызова.
    public func takeLevels() -> (me: Float, them: Float) {
        (mic.track.takeLevel(), system.track.takeLevel())
    }

    /// Системная дорожка теряет данные (неожиданная раскладка буферов и т.п.).
    public var systemDropping: Bool { system.track.snapshot().dropped > 0 }

    /// Периодическая строка в лог: пики за интервал и счётчики дорожек.
    public func logPeriodic(peakMe: Float, peakThem: Float) {
        let t = elapsed
        log("t=\(Int(t))s пик: я \(String(format: "%.3f", peakMe)), они \(String(format: "%.3f", peakThem))", echo: false)
        log(describe("mic", mic.track, elapsed: t), echo: false)
        log(describe("system", system.track, elapsed: t), echo: false)
    }

    // MARK: - Разрешения (блокирующие вызовы — в GUI вызывать не на главном потоке)

    public static func requestMicAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
            sem.wait()
            return granted
        default: return false
        }
    }

    /// Статус разрешения на системный звук без запроса: "authorized" | "denied" | "unknown" | nil.
    public static func audioCapturePermissionStatus() -> String? { AudioCapturePermission.status() }

    /// Проверяет (и при необходимости запрашивает) разрешение на системный звук.
    /// Возвращает текст предупреждения, если разрешения нет, иначе nil.
    public static func ensureAudioCapturePermission() -> String? {
        let app = AudioCapturePermission.responsibleApp()
        var permission = AudioCapturePermission.status()
        log("🔐 системный звук: разрешение \(permission ?? "не проверить"), запущено из: \(app)", echo: false)
        if permission == "unknown" {
            let granted = AudioCapturePermission.request()
            log("🔐 запрос разрешения: \(granted.map { $0 ? "выдано" : "отказано" } ?? "не удалось"), " +
                "preflight теперь \(AudioCapturePermission.status() ?? "?")", echo: false)
            switch granted {
            case true?: permission = "authorized" // ответ пользователя важнее запоздалого кэша TCC
            case false?: permission = "denied"
            case nil: permission = nil            // спросить не удалось — не утверждаем, что доступа нет
            }
        }
        guard permission == "denied" || permission == "unknown" else { return nil }
        return """
        Нет разрешения на запись системного звука — дорожка «они» будет тишиной.
        Разрешение нужно приложению: \(app)
        Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука →
        «Только запись системного звука» → включи это приложение (или добавь через +), затем перезапусти его.
        """
    }
}

/// Строка счётчиков дорожки для лога. Записанные секунды vs реальное время выявляют
/// проблемы со скоростью/частотой и пропуски.
func describe(_ name: String, _ track: Track, elapsed: TimeInterval) -> String {
    let s = track.snapshot()
    var line = "\(name): записано \(String(format: "%.1f", s.seconds)) с из \(String(format: "%.1f", elapsed)) с, " +
        "сегментов \(s.segments), сейчас \(Int(track.sampleRate)) Hz, " +
        "ошибок записи \(s.writeErrors), пропущено \(s.dropped)"
    if s.observedStreams >= 0 { line += ", буферов в callback'е \(s.observedStreams)" }
    if let e = s.lastError { line += ", последняя ошибка: \(e)" }
    return line
}

/// Микрофон по умолчанию сейчас кем-то используется (Zoom/Meet/…) — признак идущего созвона.
public func defaultInputInUse() -> Bool {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = Devices.address(kAudioHardwarePropertyDefaultInputDevice)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
    else { return false }
    var running = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    addr = Devices.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr else { return false }
    return running != 0
}
