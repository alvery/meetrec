// rec — записывает созвон в две дорожки:
//   mic.caf    (+ mic.N.caf)    — твой микрофон («Я»)
//   system.caf (+ system.N.caf) — системный звук, т.е. собеседники («Они»), через Core Audio process tap
//   mic.segments / system.segments — манифест: сегмент + момент его начала (для синхронной склейки)
//   rec.log — технический лог (устройства, форматы, счётчики) для scripts/report.sh
// Новый сегмент открывается, когда меняется формат/устройство (AirPods ушли в HFP, сменился выход).
// Формат — Float32 PCM CAF (без клиппинга громких пиков); process.sh потом сжимает его в m4a.
// Остановка: Ctrl+C (а также SIGTERM / SIGHUP — закрытие вкладки).
// Требуется macOS 14.2+ (Core Audio taps).

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

/// Общая точка отсчёта для манифестов обеих дорожек (монотонные часы — не зависят от
/// подстройки системного времени). Задаётся один раз до старта записи.
var recordingT0 = ProcessInfo.processInfo.systemUptime
func sinceStart() -> TimeInterval { ProcessInfo.processInfo.systemUptime - recordingT0 }

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
    var seconds: Double = 0  // записано секунд (сумма по сегментам с разной частотой)
    var segments = 0
    var writeErrors = 0
    var dropped = 0          // буферы, которые не удалось записать / не нашлись в callback'е
    var lastError: String?
    var observedStreams = -1 // сколько буферов реально пришло в первом callback'е (только system)
}

/// Дорожка: сегменты-файлы + уровень + счётчики. Пишется из аудиопотока, читается и
/// переключается из других потоков. Каждый открытый сегмент дописывается в манифест
/// `<name>.segments` строкой «файл<TAB>секунды от recordingT0» — process.sh по нему
/// склеивает сегменты, заполняя паузы тишиной, чтобы дорожки оставались синхронными.
final class Track {
    let dir: URL
    let name: String
    private let lock = NSLock()      // уровень и счётчики — быстро, берёт и главный поток
    private let fileLock = NSLock()  // файл и сегменты — медленный I/O
    private var file: AVAudioFile?
    private var segment = -1
    private var manifestPending: String? // сегмент открыт, но ещё не получил ни одного буфера
    private var level: Float = 0
    private var stats = TrackStats()
    private var _sampleRate: Double = 0
    var sampleRate: Double { lock.withLock { _sampleRate } }

    init(dir: URL, name: String) { self.dir = dir; self.name = name }

    /// Открывает следующий сегмент в заданном формате. Если файл создать не удалось —
    /// бросает ошибку, а текущий сегмент остаётся открытым (номер не пропускается).
    @discardableResult
    func openSegment(_ format: AVAudioFormat) throws -> String {
        try fileLock.withLock {
            let index = segment + 1
            let fileName = index == 0 ? "\(name).caf" : "\(name).\(index).caf"
            let newFile = try makeTrackFile(dir.appendingPathComponent(fileName), format: format)
            segment = index
            file = newFile // предыдущий сегмент закрывается при освобождении
            // В манифест — по первому реально записанному буферу: так момент начала учитывает
            // задержку старта устройства, а пустые сегменты (неудачный старт) не попадают вовсе.
            manifestPending = fileName
            lock.withLock { _sampleRate = format.sampleRate; stats.segments = index + 1 }
            return fileName
        }
    }

    private func appendManifest(_ fileName: String, offset: TimeInterval) {
        let url = dir.appendingPathComponent("\(name).segments")
        let line = String(format: "%@\t%.3f\n", fileName, max(0, offset))
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            log("\n❌ не могу дописать манифест \(url.lastPathComponent) — сегмент \(fileName) не попадёт в склейку")
            return
        }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let p = peak(buffer)
        var writeError: Error?
        let written: Bool = fileLock.withLock {
            guard let file else { return false }
            do {
                try file.write(from: buffer)
                if let pending = manifestPending { // первый буфер сегмента: начало = сейчас − длина буфера
                    manifestPending = nil
                    appendManifest(pending, offset: sinceStart() - Double(buffer.frameLength) / buffer.format.sampleRate)
                }
                return true
            } catch { writeError = error; return false }
        }
        lock.withLock {
            level = max(level, p)
            if written {
                stats.seconds += Double(buffer.frameLength) / buffer.format.sampleRate
            } else if let writeError {
                stats.writeErrors += 1
                stats.lastError = "\(writeError)"
            } else {
                stats.dropped += 1 // нет открытого сегмента
            }
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

/// Повторяет `action` раз в секунду, пока он не перестанет бросать ошибку (до `attempts` раз).
/// Устройства во время переключения (AirPods → HFP) какое-то время бывают недоступны.
func retry(_ what: String, attempt: Int = 1, attempts: Int = 10,
           while active: @escaping () -> Bool, _ action: @escaping () throws -> Void) {
    guard active() else { return }
    do {
        try action()
        if attempt > 1 { log("ℹ️  \(what): получилось с попытки \(attempt)") }
    } catch {
        guard attempt < attempts else {
            log("\n❌ \(what): не удалось после \(attempts) попыток (\(error)) — дорожка прервана")
            return
        }
        log("\n⚠️  \(what): попытка \(attempt) не удалась (\(error)), повторю через 1 с")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            retry(what, attempt: attempt + 1, attempts: attempts, while: active, action)
        }
    }
}

// MARK: - Микрофон

final class MicRecorder {
    private let engine = AVAudioEngine()
    let track: Track
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var generation = 0 // каждое уведомление отменяет повторные попытки предыдущего

    init(dir: URL) { track = Track(dir: dir, name: "mic") }

    func start() throws {
        // Подписка ДО старта: смена маршрута (AirPods ушли в HFP, подключили гарнитуру)
        // останавливает AVAudioEngine — перезапускаем его в новый сегмент.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.stopped else { return }
            log("\n⚠️  mic: конфигурация аудио изменилась — перезапускаю запись в новый сегмент")
            self.generation += 1
            let gen = self.generation
            retry("mic: перезапуск", while: { [weak self] in
                guard let self else { return false }
                return !self.stopped && self.generation == gen
            }) { [weak self] in
                try self?.restartEngine()
            }
        }
        try startEngine()
    }

    private func restartEngine() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try startEngine()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecError("не найдено устройство ввода (микрофон)") }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw RecError("неожиданный формат микрофона: \(format)")
        }
        let fileName = try track.openSegment(format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [track = self.track] buffer, _ in
            track.write(buffer)
        }
        try engine.start()
        let name = AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"
        log("🎙  mic:    \(name), \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved) → \(fileName)")
    }

    func stop() {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
    let track: Track
    private var stopped = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var generation = 0 // каждое уведомление о смене выхода отменяет попытки предыдущего

    // Состояние ниже меняется только на `queue` (IO-callback и слушатель частоты идут на ней).
    private var activeAggregate = AudioObjectID(kAudioObjectUnknown)
    private var format: AVAudioFormat!
    private var buffer: AVAudioPCMBuffer?
    private var tapChannels: AVAudioChannelCount = 2
    private var tapInterleaved = true
    private var rateListener: AudioObjectPropertyListenerBlock?

    init(dir: URL) { track = Track(dir: dir, name: "system") }

    func start() throws {
        try setUp()
        watchDefaultOutput()
    }

    func stop() {
        stopped = true
        if let outputListener {
            var addr = Devices.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, outputListener)
            self.outputListener = nil
        }
        tearDown()
        track.close()
    }

    /// Сменилось основное устройство вывода (отключили AirPods, выбрали другой выход):
    /// старый aggregate тактируется пропавшим устройством — пересоздаём tap в новый сегмент.
    private func watchDefaultOutput() {
        var addr = Devices.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            log("\n⚠️  system: устройство вывода сменилось — пересоздаю захват в новый сегмент")
            self.generation += 1
            let gen = self.generation
            retry("system: пересоздание захвата", while: { [weak self] in
                guard let self else { return false }
                return !self.stopped && self.generation == gen
            }) { [weak self] in
                guard let self else { return }
                do { try self.setUp() } catch { self.tearDown(); throw error }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        if status == noErr { outputListener = listener }
        else { log("⚠️  не удалось подписаться на смену устройства вывода: OSStatus \(status)") }
    }

    /// Создаёт захват; если предыдущий ещё жив — сначала освобождает его (идемпотентно).
    private func setUp() throws {
        tearDown()
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
        // иначе запись будет с неправильной скоростью. Если частота сменится позже —
        // слушатель откроет новый сегмент (см. watchSampleRate).
        let aggregate = aggregateID
        let sampleRate = Self.rate(of: aggregate) ?? tapFormat.sampleRate
        let fileName = try queue.sync { () throws -> String in
            self.tapChannels = tapFormat.channelCount
            self.tapInterleaved = tapFormat.isInterleaved
            self.activeAggregate = aggregate
            return try self.openSegment(rate: sampleRate)
        }

        // 4. Раскладка буферов в callback'е: сначала входные потоки устройства вывода
        //    (микрофон AirPods / USB-гарнитуры), за ними — потоки tap'а (их и берём).
        let deviceInputs = Devices.streamCount(output.id, scope: kAudioObjectPropertyScopeInput)
        let tapBuffers = tapFormat.isInterleaved ? 1 : Int(tapFormat.channelCount)
        let channelsPerBuffer = tapFormat.isInterleaved ? tapFormat.channelCount : 1
        let bytesPerFrame = Int(asbd.mBytesPerFrame) // не зависит от частоты
        log("🔈 вывод:  \(output.name) [\(output.uid)], входных потоков у него: \(deviceInputs)")
        log("🔊 system: tap \(Int(tapFormat.sampleRate)) Hz / aggregate \(Int(sampleRate)) Hz, " +
            "\(tapFormat.channelCount) ch, interleaved=\(tapFormat.isInterleaved) → \(fileName)")

        // Буфер (self.buffer) переиспользуется между callback'ами: на аудиопути нет аллокаций,
        // кроме редкого роста буфера и смены сегмента.
        var firstCallback = true
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [unowned self] _, inInputData, _, _, _ in
            let track = self.track
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            if firstCallback { firstCallback = false; track.noteStreams(list.count) }
            // Потоки tap'а — последние в списке, сколько бы потоков устройства HAL ни оставил перед ними.
            let base = list.count - tapBuffers
            guard base >= 0 else { track.noteDropped(); return }
            guard list[base].mNumberChannels == channelsPerBuffer else { track.noteDropped(); return }

            let frames = Int(list[base].mDataByteSize) / bytesPerFrame
            guard frames > 0 else { return }
            if self.buffer == nil || self.buffer!.frameCapacity < AVAudioFrameCount(frames) {
                self.buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(frames))
            }
            guard let buffer = self.buffer else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for i in 0..<tapBuffers {
                guard let s = list[base + i].mData, let d = dst[i].mData else { track.noteDropped(); return }
                memcpy(d, s, min(Int(list[base + i].mDataByteSize), Int(dst[i].mDataByteSize)))
            }
            track.write(buffer)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        // 5. Не включать микрофон устройства вывода: если AirPods — только выход (микрофон
        //    встроенный), иначе они ушли бы в режим гарнитуры (HFP) из-за нас.
        disableDeviceInputStreams(deviceInputs)
        watchSampleRate(aggregate)
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        // Частота могла смениться между чтением и подпиской (AirPods переключаются асинхронно).
        queue.async { self.rotateIfRateChanged(aggregate) }
    }

    /// Освобождает tap/aggregate (можно вызывать повторно и после частичного setUp).
    private func tearDown() {
        queue.sync { activeAggregate = AudioObjectID(kAudioObjectUnknown) } // гасит запоздалые события частоты
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let rateListener {
                var addr = Devices.address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, queue, rateListener)
                self.rateListener = nil
            }
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                self.procID = nil
            }
            queue.sync {} // дождаться последнего callback'а
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func rate(of device: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = Devices.address(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    /// Только на `queue`. Формат меняется только если сегмент действительно открылся.
    private func openSegment(rate: Double) throws -> String {
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                    channels: tapChannels, interleaved: tapInterleaved)
        else { throw RecError("не удалось создать формат \(rate) Hz") }
        let fileName = try track.openSegment(f)
        format = f
        buffer = nil
        return fileName
    }

    /// Только на `queue`: если частота aggregate изменилась — продолжаем в новый сегмент
    /// с правильной частотой, чтобы дорожка «они» не исказилась по скорости.
    private func rotateIfRateChanged(_ aggregate: AudioObjectID) {
        guard aggregate == activeAggregate, // событие от уже освобождённого захвата — игнорируем
              let rate = Self.rate(of: aggregate), let old = format, rate != old.sampleRate else { return }
        do {
            let fileName = try openSegment(rate: rate)
            log("\n⚠️  system: частота устройства вывода \(Int(old.sampleRate)) → \(Int(rate)) Hz, новый сегмент \(fileName)")
        } catch {
            log("\n❌ system: не удалось открыть новый сегмент (\(error)) — пишу в прежний, возможны искажения скорости")
        }
    }

    private func watchSampleRate(_ aggregate: AudioObjectID) {
        var addr = Devices.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [unowned self] _, _ in self.rotateIfRateChanged(aggregate) }
        let status = AudioObjectAddPropertyListenerBlock(aggregateID, &addr, queue, listener)
        if status == noErr { rateListener = listener }
        else { log("⚠️  не удалось подписаться на смену частоты: OSStatus \(status)") }
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
    var line = "\(name): записано \(String(format: "%.1f", s.seconds)) с из \(String(format: "%.1f", elapsed)) с, " +
        "сегментов \(s.segments), сейчас \(Int(track.sampleRate)) Hz, " +
        "ошибок записи \(s.writeErrors), пропущено \(s.dropped)"
    if s.observedStreams >= 0 { line += ", буферов в callback'е \(s.observedStreams)" }
    if let e = s.lastError { line += ", последняя ошибка: \(e)" }
    return line
}

@available(macOS 14.2, *)
func run() -> Never {
    let fm = FileManager.default
    let outDir: URL
    if CommandLine.arguments.count > 1 {
        outDir = URL(fileURLWithPath: CommandLine.arguments[1])
    } else {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        outDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Meetings/\(f.string(from: Date()))")
    }
    // Не дописывать в папку с прошлой записью: сегменты разных встреч перемешались бы.
    let existing = ["mic.segments", "system.segments", "mic.caf", "mic.m4a", "system.caf", "system.m4a"]
        .filter { fm.fileExists(atPath: outDir.appendingPathComponent($0).path) }
    if !existing.isEmpty {
        FileHandle.standardError.write(Data("❌ в \(outDir.path) уже есть запись (\(existing.joined(separator: ", "))) — выбери другую папку\n".utf8))
        exit(1)
    }
    do {
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("❌ не могу создать \(outDir.path): \(error)\n".utf8))
        exit(1)
    }
    Log.shared.open(outDir.appendingPathComponent("rec.log"))
    log("▶︎ start, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", echo: false)

    guard requestMicAccess() else {
        fail("нет доступа к микрофону. Системные настройки → Конфиденциальность → Микрофон → включи свой терминал.")
    }

    let mic = MicRecorder(dir: outDir)
    let system = SystemAudioRecorder(dir: outDir)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    recordingT0 = ProcessInfo.processInfo.systemUptime

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
            let elapsed = sinceStart()
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

    // Микрофон — первым: если это AirPods/гарнитура, они переключатся в HFP сразу.
    // Переключение асинхронное — если формат сменится позже, обе дорожки продолжат
    // запись в новый сегмент с правильной частотой.
    do {
        try mic.start()
        try system.start()
    } catch {
        system.stop(); mic.stop()
        fail("\(error)")
    }
    print("📁 \(outDir.path)")
    print("● Запись идёт. Ctrl+C — остановить.\n")

    var systemSilentSeconds = 0
    var droppedWarned = false
    var micPeak: Float = 0, sysPeak: Float = 0
    var ticks = 0
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let t = Int(sinceStart())
        let micLevel = mic.track.takeLevel()
        let sysLevel = system.track.takeLevel()
        micPeak = max(micPeak, micLevel)
        sysPeak = max(sysPeak, sysLevel)
        if sysLevel == 0 { systemSilentSeconds += 1 } else { systemSilentSeconds = 0 }
        let hint = systemSilentSeconds >= 15 ? "  (системный звук = тишина: нет звука или нет разрешения?)" : ""
        if !droppedWarned && system.track.snapshot().dropped > 0 {
            droppedWarned = true
            log("\n⚠️  системный звук: часть данных пропускается (подробности в rec.log)")
        }
        print(String(format: "\r● %02d:%02d  я %@  они %@%@", t / 60, t % 60, bar(micLevel), bar(sysLevel), hint),
              terminator: "")
        ticks += 1
        if ticks % 30 == 0 { // раз в 30 тиков (~30 с) — пики и счётчики в лог
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
