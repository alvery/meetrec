// rec — записывает созвон в две дорожки:
//   mic.caf    — твой микрофон («Я»)
//   system.caf — системный звук, т.е. собеседники («Они»), через Core Audio process tap
// Остановка: Ctrl+C. Требуется macOS 14.2+ (Core Audio taps).

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

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("❌ " + msg + "\n").utf8))
    exit(1)
}

/// Пиковый уровень буфера (0…1) — для индикатора, чтобы видеть, что звук реально пишется.
func peak(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData else { return 0 }
    let channels = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
    let n = Int(buffer.frameLength) * channels
    var m: Float = 0
    for i in 0..<n { m = max(m, abs(data[0][i])) }
    return m
}

// MARK: - Микрофон

final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    var level: Float = 0

    func start(to url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecError("не найдено устройство ввода (микрофон)") }
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.level = max(self.level, peak(buffer))
            do { try self.file?.write(from: buffer) } catch { print("\nmic write error: \(error)") }
        }
        try engine.start()
        print("🎙  mic:    \(Int(format.sampleRate)) Hz, \(format.channelCount) ch → \(url.lastPathComponent)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // закрывает файл
    }
}

// MARK: - Системный звук (Core Audio process tap)

@available(macOS 14.2, *)
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "meetrec.system-tap", qos: .userInitiated)
    var level: Float = 0

    func start(to url: URL) throws {
        // 1. Глобальный tap: весь системный звук (Zoom, браузер с Meet и т.д.), сведённый в стерео.
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.name = "meetrec"
        tap.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "AudioHardwareCreateProcessTap")

        // 2. Приватное aggregate-устройство: текущий выход + наш tap.
        let outputUID = try Self.defaultOutputDeviceUID()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meetrec-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        // 3. Формат tap'а → файл.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "read tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecError("неподдерживаемый формат tap'а")
        }
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)

        // 4. IO-callback: пишем всё, что приходит, в файл.
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
            else { return }
            self.level = max(self.level, peak(buffer))
            do { try file.write(from: buffer) } catch { print("\nsystem write error: \(error)") }
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        print("🔊 system: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch → \(url.lastPathComponent)")
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
        file = nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID),
                  "read default output device")

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid), "read output device UID")
        guard let uid else { throw RecError("пустой UID устройства вывода") }
        return uid.takeRetainedValue() as String
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
    } catch { fail("не могу создать \(outDir.path): \(error)") }

    guard requestMicAccess() else {
        fail("нет доступа к микрофону. Системные настройки → Конфиденциальность → Микрофон → включи свой терминал.")
    }

    let mic = MicRecorder()
    let system = SystemAudioRecorder()
    let started = Date()
    do {
        try system.start(to: outDir.appendingPathComponent("system.caf"))
        try mic.start(to: outDir.appendingPathComponent("mic.caf"))
    } catch {
        system.stop(); mic.stop()
        fail("\(error)")
    }
    print("📁 \(outDir.path)")
    print("● Запись идёт. Ctrl+C — остановить.\n")

    var systemSilentSeconds = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let t = Int(Date().timeIntervalSince(started))
        if system.level == 0 { systemSilentSeconds += 1 } else { systemSilentSeconds = 0 }
        let hint = systemSilentSeconds >= 15 ? "  (системный звук = тишина: нет звука или нет разрешения?)" : ""
        print(String(format: "\r● %02d:%02d  я %@  они %@%@", t / 60, t % 60, bar(mic.level), bar(system.level), hint),
              terminator: "")
        mic.level = 0
        system.level = 0
    }
    timer.resume()

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        timer.cancel()
        mic.stop()
        system.stop()
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = [
            "started": iso.string(from: started),
            "ended": iso.string(from: Date()),
            "tracks": ["me": "mic.caf", "them": "system.caf"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outDir.appendingPathComponent("meta.json"))
        }
        print("\n■ Остановлено. Файлы: \(outDir.path)")
        print("  Дальше: ./scripts/process.sh \"\(outDir.path)\"")
        exit(0)
    }
    sigint.resume()

    withExtendedLifetime((timer, sigint)) { dispatchMain() }
}

if #available(macOS 14.2, *) {
    run()
} else {
    fail("нужна macOS 14.2 или новее (Core Audio process taps)")
}
