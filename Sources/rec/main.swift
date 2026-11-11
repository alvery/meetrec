// rec — записывает созвон в две дорожки:
//   mic.caf    — твой микрофон («Я»)
//   system.caf — системный звук, т.е. собеседники («Они»), через Core Audio process tap
//   rec.log    — технический лог (устройства, форматы, счётчики) для scripts/report.sh
// Формат — Float32 PCM CAF (без клиппинга громких пиков); process.sh потом сжимает его в m4a.
// Остановка: Ctrl+C (а также SIGTERM / SIGHUP — закрытие вкладки).
// Требуется macOS 14.2+ (Core Audio taps).

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

struct RecError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw RecError("\(what) failed: OSStatus \(status)") }
}

// MARK: - Лог

/// Пишет в консоль и в rec.log с отметкой времени. Только технические данные — никакого аудио/текста.
final class Log {
    static let shared = Log()
    private let lock = NSLock()
    private var handle: FileHandle?
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func open(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ message: String, echo: Bool) {
        lock.withLock {
            if echo { print(message) }
            handle?.write(Data("\(stamp.string(from: Date())) \(message)\n".utf8))
        }
    }
}

func log(_ message: String, echo: Bool = true) { Log.shared.write(message, echo: echo) }

func fail(_ message: String) -> Never {
    Log.shared.write("❌ " + message, echo: false)
    FileHandle.standardError.write(Data(("❌ " + message + "\n").utf8))
    exit(1)
}

// MARK: - Дорожка

/// Пиковый уровень буфера (0…1) — для индикатора, чтобы видеть, что звук реально пишется.
func peak(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    let channels = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
    let n = Int(buffer.frameLength) * channels
    var m: Float = 0
    for i in 0..<n { m = max(m, abs(data[0][i])) }
    return m
}

/// Float32 PCM CAF. Берём настройки из формата источника (сохраняет channel layout для
/// многоканальных входов) и фиксируем только кодировку.
func makeTrackFile(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
    var settings = format.settings
    settings[AVFormatIDKey] = kAudioFormatLinearPCM
    settings[AVLinearPCMBitDepthKey] = 32
    settings[AVLinearPCMIsFloatKey] = true
    settings[AVLinearPCMIsBigEndianKey] = false
    settings[AVLinearPCMIsNonInterleaved] = false
    return try AVAudioFile(forWriting: url, settings: settings,
                           commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
}

struct TrackStats {
    var frames: Int64 = 0
    var writeErrors = 0
    var dropped = 0          // callback'и, где не нашлось ожидаемых буферов
    var lastError: String?
    var observedStreams = -1 // сколько буферов реально пришло в первом callback'е (только system)
}

/// Файл дорожки + уровень + счётчики под замком: пишутся из аудиопотока,
/// читаются/закрываются из главного.
final class Track {
    private let lock = NSLock()      // уровень и счётчики — быстро, берёт и главный поток
    private let fileLock = NSLock()  // файл — медленный I/O, только аудиопоток и close()
    private var file: AVAudioFile?
    private var level: Float = 0
    private var stats = TrackStats()
    private var _sampleRate: Double = 0
    var sampleRate: Double { lock.withLock { _sampleRate } }

    func open(_ file: AVAudioFile, sampleRate: Double) {
        fileLock.withLock { self.file = file }
        lock.withLock { _sampleRate = sampleRate }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let p = peak(buffer)
        var writeError: Error?
        let written: Bool = fileLock.withLock {
            guard let file else { return false }
            do { try file.write(from: buffer); return true } catch { writeError = error; return false }
        }
        lock.withLock {
            level = max(level, p)
            if written { stats.frames += Int64(buffer.frameLength) }
            if let writeError { stats.writeErrors += 1; stats.lastError = "\(writeError)" }
        }
    }

    func noteDropped() { lock.withLock { stats.dropped += 1 } }
    func noteStreams(_ n: Int) { lock.withLock { if stats.observedStreams < 0 { stats.observedStreams = n } } }

    /// Пиковый уровень с прошлого вызова (сбрасывает его).
    func takeLevel() -> Float { lock.withLock { defer { level = 0 }; return level } }
    func snapshot() -> TrackStats { lock.withLock { stats } }
    func close() { fileLock.withLock { file = nil } } // освобождение AVAudioFile закрывает файл
}

// MARK: - Устройства

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum Devices {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "read string property \(selector)")
        guard let value else { throw RecError("пустое свойство \(selector)") }
        return value.takeRetainedValue() as String
    }

    /// Основное устройство вывода — туда играют Zoom/Meet
    /// (не DefaultSystemOutputDevice — это устройство для системных звуков).
    static func defaultOutput() throws -> AudioDevice {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id),
                  "read default output device")
        return AudioDevice(id: id,
                           uid: try string(id, kAudioDevicePropertyDeviceUID),
                           name: (try? string(id, kAudioObjectPropertyName)) ?? "?")
    }

    /// Число потоков устройства в заданной области (у AirPods/гарнитур на входе — микрофон).
    static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

// MARK: - Микрофон

final class MicRecorder {
    private let engine = AVAudioEngine()
    let track = Track()

    func start(to url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecError("не найдено устройство ввода (микрофон)") }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw RecError("неожиданный формат микрофона: \(format)")
        }
        track.open(try makeTrackFile(url, format: format), sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [track = self.track] buffer, _ in
            track.write(buffer)
        }
        try engine.start()
        let name = AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"
        log("🎙  mic:    \(name), \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved) → \(url.lastPathComponent)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        track.close() // под замком: дожидается текущей записи, если она идёт
    }
}

// MARK: - Системный звук (Core Audio process tap)

@available(macOS 14.2, *)
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "meetrec.system-tap", qos: .userInitiated)
    let track = Track()

    func start(to url: URL) throws {
        // 1. Глобальный tap: весь системный звук (Zoom, браузер с Meet и т.д.), сведённый в стерео.
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "meetrec"
        tap.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "AudioHardwareCreateProcessTap")

        // 2. Приватное aggregate-устройство: основной выход (задаёт часы) + наш tap.
        let output = try Devices.defaultOutput()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meetrec-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        // 3. Формат tap'а.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = Devices.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read tap format")
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd),
              tapFormat.commonFormat == .pcmFormatFloat32, asbd.mBytesPerFrame > 0
        else { throw RecError("неподдерживаемый формат tap'а: \(asbd)") }

        // Aggregate тактируется устройством вывода. У AirPods в режиме гарнитуры (HFP)
        // это 16/24 kHz, а tap сообщает 48 kHz — в файл пишем реальную частоту aggregate,
        // иначе запись будет с неправильной скоростью.
        var deviceRate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        addr = Devices.address(kAudioDevicePropertyNominalSampleRate)
        try check(AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &deviceRate), "read aggregate sample rate")
        let sampleRate = deviceRate > 0 ? deviceRate : tapFormat.sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: tapFormat.channelCount, interleaved: tapFormat.isInterleaved)
        else { throw RecError("не удалось создать формат \(sampleRate) Hz") }
        track.open(try makeTrackFile(url, format: format), sampleRate: sampleRate)

        // 4. Раскладка буферов в callback'е: сначала входные потоки устройства вывода
        //    (микрофон AirPods / USB-гарнитуры), за ними — потоки tap'а (их и берём).
        let deviceInputs = Devices.streamCount(output.id, scope: kAudioObjectPropertyScopeInput)
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        log("🔈 вывод:  \(output.name) [\(output.uid)], входных потоков у него: \(deviceInputs)")
        log("🔊 system: tap \(Int(tapFormat.sampleRate)) Hz / aggregate \(Int(sampleRate)) Hz, " +
            "\(format.channelCount) ch, interleaved=\(format.isInterleaved) → \(url.lastPathComponent)")

        // Буфер переиспользуется между callback'ами (они идут последовательно на `queue`):
        // на аудиопути нет аллокаций, кроме редкого роста буфера.
        var buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
        var firstCallback = true
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [track = self.track] _, inInputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            if firstCallback { firstCallback = false; track.noteStreams(list.count) }
            // Потоки tap'а — последние в списке, сколько бы потоков устройства HAL ни оставил перед ними.
            let base = list.count - tapBuffers
            guard base >= 0 else { track.noteDropped(); return }
            guard list[base].mNumberChannels == channelsPerBuffer else { track.noteDropped(); return }

            let frames = Int(list[base].mDataByteSize) / bytesPerFrame
            guard frames > 0 else { return }
            if buffer == nil || buffer!.frameCapacity < AVAudioFrameCount(frames) {
                buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            }
            guard let buffer else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for i in 0..<tapBuffers {
                guard let s = list[base + i].mData, let d = dst[i].mData else { track.noteDropped(); return }
                memcpy(d, s, min(Int(list[base + i].mDataByteSize), Int(dst[i].mDataByteSize)))
            }
            track.write(buffer)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        // 5. Не включать микрофон устройства вывода: иначе AirPods уходят в режим
        //    гарнитуры (HFP) и звук созвона портится на всю встречу.
        disableDeviceInputStreams(deviceInputs)
        watchSampleRate(initial: sampleRate)
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    /// Если частота устройства вывода сменилась посреди записи (например, Zoom открыл микрофон
    /// AirPods и они ушли в HFP), файл остаётся с прежней частотой и дорожка «они» будет с
    /// неправильной скоростью. Пока только фиксируем это в логе — для диагностики.
    private func watchSampleRate(initial: Double) {
        var addr = Devices.address(kAudioDevicePropertyNominalSampleRate)
        let id = aggregateID
        let status = AudioObjectAddPropertyListenerBlock(id, &addr, queue) { _, _ in
            var rate = Float64(0)
            var size = UInt32(MemoryLayout<Float64>.size)
            var a = Devices.address(kAudioDevicePropertyNominalSampleRate)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &rate) == noErr, rate != initial else { return }
            log("\n⚠️  частота устройства вывода сменилась: \(Int(initial)) → \(Int(rate)) Hz — дорожка «они» может быть искажена")
        }
        if status != noErr { log("⚠️  не удалось подписаться на смену частоты: OSStatus \(status)") }
    }

    /// kAudioDevicePropertyIOProcStreamUsage: говорим HAL, что входные потоки устройства
    /// вывода нашему IOProc не нужны (используем только потоки tap'а).
    private func disableDeviceInputStreams(_ count: Int) {
        guard count > 0, let procID else { return }
        var addr = Devices.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr, size > 0 else {
            log("⚠️  IOProcStreamUsage недоступен — входные потоки устройства вывода остаются включены")
            return
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        var status = AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw)
        guard status == noErr else { log("⚠️  чтение IOProcStreamUsage: OSStatus \(status)"); return }

        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let total = Int(raw.load(fromByteOffset: countOffset, as: UInt32.self))
        let off = min(count, total)
        for i in 0..<off {
            raw.storeBytes(of: UInt32(0), toByteOffset: flagsOffset + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, size, raw)
        log(status == noErr
            ? "ℹ️  отключено входных потоков устройства вывода: \(off) из \(total)"
            : "⚠️  не удалось отключить входные потоки: OSStatus \(status)")
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            queue.sync {} // дождаться последнего callback'а
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        track.close()
    }
}

// MARK: - main

func requestMicAccess() -> Bool {
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

func bar(_ level: Float) -> String {
    let n = min(8, Int((level * 8).rounded(.up)))
    return String(repeating: "▮", count: n) + String(repeating: "·", count: 8 - n)
}

/// Строка счётчиков дорожки для лога. Записанные секунды vs реальное время выявляют
/// проблемы со скоростью/частотой и пропуски.
func describe(_ name: String, _ track: Track, elapsed: TimeInterval) -> String {
    let s = track.snapshot()
    let seconds = track.sampleRate > 0 ? Double(s.frames) / track.sampleRate : 0
    var line = "\(name): записано \(String(format: "%.1f", seconds)) с из \(String(format: "%.1f", elapsed)) с, " +
        "ошибок записи \(s.writeErrors), пропущено callback'ов \(s.dropped)"
    if s.observedStreams >= 0 { line += ", буферов в callback'е \(s.observedStreams)" }
    if let e = s.lastError { line += ", последняя ошибка: \(e)" }
    return line
}

@available(macOS 14.2, *)
func run() -> Never {
    let outDir: URL
    if CommandLine.arguments.count > 1 {
        outDir = URL(fileURLWithPath: CommandLine.arguments[1])
    } else {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        outDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings/\(f.string(from: Date()))")
    }
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("❌ не могу создать \(outDir.path): \(error)\n".utf8))
        exit(1)
    }
    Log.shared.open(outDir.appendingPathComponent("rec.log"))
    log("▶︎ start, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", echo: false)

    guard requestMicAccess() else {
        fail("нет доступа к микрофону. Системные настройки → Конфиденциальность → Микрофон → включи свой терминал.")
    }

    let mic = MicRecorder()
    let system = SystemAudioRecorder()
    var started = Date()
    let timer = DispatchSource.makeTimerSource(queue: .main)

    // Сигналы перехватываем ДО старта: файлы корректно закроются на Ctrl+C, kill и закрытии
    // вкладки терминала, даже если сигнал пришёл во время запуска (обработчик выполнится на
    // main queue после него). Все источники на serial main queue, обработчик завершает процесс.
    let signalSources = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            timer.cancel()
            mic.stop()
            system.stop()
            let elapsed = Date().timeIntervalSince(started)
            print("")
            log("■ stop (signal \(sig)), длительность \(Int(elapsed)) с", echo: false)
            log(describe("mic", mic.track, elapsed: elapsed), echo: false)
            log(describe("system", system.track, elapsed: elapsed), echo: false)
            print("■ Остановлено. Файлы: \(outDir.path)")
            print("  Дальше: ./scripts/process.sh \"\(outDir.path)\"")
            exit(0)
        }
        source.resume()
        return source
    }

    // Микрофон — первым: если это AirPods/гарнитура, они переключатся в HFP сейчас,
    // и system прочитает уже итоговую частоту устройства вывода.
    do {
        try mic.start(to: outDir.appendingPathComponent("mic.caf"))
        try system.start(to: outDir.appendingPathComponent("system.caf"))
    } catch {
        system.stop(); mic.stop()
        fail("\(error)")
    }
    started = Date()
    print("📁 \(outDir.path)")
    print("● Запись идёт. Ctrl+C — остановить.\n")

    var systemSilentSeconds = 0
    var droppedWarned = false
    var micPeak: Float = 0, sysPeak: Float = 0
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let t = Int(Date().timeIntervalSince(started))
        let micLevel = mic.track.takeLevel()
        let sysLevel = system.track.takeLevel()
        micPeak = max(micPeak, micLevel)
        sysPeak = max(sysPeak, sysLevel)
        if sysLevel == 0 { systemSilentSeconds += 1 } else { systemSilentSeconds = 0 }
        let hint = systemSilentSeconds >= 15 ? "  (системный звук = тишина: нет звука или нет разрешения?)" : ""
        if !droppedWarned && system.track.snapshot().dropped > 0 {
            droppedWarned = true
            log("\n⚠️  системный звук: неожиданная раскладка буферов, часть данных пропускается (подробности в rec.log)")
        }
        print(String(format: "\r● %02d:%02d  я %@  они %@%@", t / 60, t % 60, bar(micLevel), bar(sysLevel), hint),
              terminator: "")
        if t > 0 && t % 30 == 0 { // раз в 30 с — пики и счётчики в лог
            log("t=\(t)s пик: я \(String(format: "%.3f", micPeak)), они \(String(format: "%.3f", sysPeak))", echo: false)
            log(describe("mic", mic.track, elapsed: Double(t)), echo: false)
            log(describe("system", system.track, elapsed: Double(t)), echo: false)
            micPeak = 0; sysPeak = 0
        }
    }
    timer.resume()

    withExtendedLifetime((timer, signalSources)) { dispatchMain() }
}

if #available(macOS 14.2, *) {
    run()
} else {
    FileHandle.standardError.write(Data("❌ нужна macOS 14.2 или новее (Core Audio process taps)\n".utf8))
    exit(1)
}
