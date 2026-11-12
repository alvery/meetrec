// rec — CLI-запись созвона в две дорожки (см. RecorderKit). Остановка: Ctrl+C / SIGTERM / SIGHUP.

import Foundation
import RecorderKit

setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String) -> Never {
    log("❌ " + message, echo: false)
    FileHandle.standardError.write(Data(("❌ " + message + "\n").utf8))
    exit(1)
}

func bar(_ level: Float) -> String {
    let n = min(8, Int((level * 8).rounded(.up)))
    return String(repeating: "▮", count: n) + String(repeating: "·", count: 8 - n)
}

let outDir: URL
if CommandLine.arguments.count > 1 {
    outDir = URL(fileURLWithPath: CommandLine.arguments[1])
} else {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings/\(f.string(from: Date()))")
}

let recording: Recording
do { recording = try Recording(dir: outDir) } catch {
    FileHandle.standardError.write(Data("❌ \(error)\n".utf8))
    exit(1)
}

guard Recording.requestMicAccess() else {
    fail("нет доступа к микрофону. Системные настройки → Конфиденциальность → Микрофон → включи свой терминал.")
}
if let warning = Recording.ensureAudioCapturePermission() {
    print("⚠️  " + warning.replacingOccurrences(of: "\n", with: "\n    ") + "\n")
}

let timer = DispatchSource.makeTimerSource(queue: .main)

// Сигналы перехватываем ДО старта: файлы корректно закроются на Ctrl+C, kill и закрытии
// вкладки терминала, даже если сигнал пришёл во время запуска (обработчик выполнится на
// main queue после него). Все источники на serial main queue, обработчик завершает процесс.
let signalSources = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        timer.cancel()
        recording.stop(reason: "signal \(sig)")
        print("\n■ Остановлено. Файлы: \(outDir.path)")
        print("  Дальше: ./scripts/process.sh \"\(outDir.path)\"")
        exit(0)
    }
    source.resume()
    return source
}

do { try recording.start() } catch { fail("\(error)") }
print("📁 \(outDir.path)")
print("● Запись идёт. Ctrl+C — остановить.\n")

var systemSilentSeconds = 0
var droppedWarned = false
var peakMe: Float = 0, peakThem: Float = 0
var ticks = 0
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    let t = Int(recording.elapsed)
    let (me, them) = recording.takeLevels()
    peakMe = max(peakMe, me)
    peakThem = max(peakThem, them)
    if them == 0 { systemSilentSeconds += 1 } else { systemSilentSeconds = 0 }
    let hint = systemSilentSeconds >= 15 ? "  (системный звук = тишина: нет звука или нет разрешения?)" : ""
    if !droppedWarned && recording.systemDropping {
        droppedWarned = true
        log("\n⚠️  системный звук: часть данных пропускается (подробности в rec.log)")
    }
    print(String(format: "\r● %02d:%02d  я %@  они %@%@", t / 60, t % 60, bar(me), bar(them), hint), terminator: "")
    ticks += 1
    if ticks % 30 == 0 { // раз в 30 тиков (~30 с) — пики и счётчики в лог
        recording.logPeriodic(peakMe: peakMe, peakThem: peakThem)
        peakMe = 0
        peakThem = 0
    }
}
timer.resume()

withExtendedLifetime((timer, signalSources)) { dispatchMain() }
