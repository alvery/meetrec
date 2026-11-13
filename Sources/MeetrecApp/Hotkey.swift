import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Глобальная горячая клавиша «старт / стоп записи».
/// - двойное нажатие модификатора (⌘⌘, ⌥⌥, ⌃⌃, ⇧⇧) — глобальный монитор событий, нужен «Универсальный доступ»;
/// - сочетание клавиш (⌃⌥R…) — Carbon RegisterEventHotKey, без дополнительных разрешений.
enum HotkeyMode: String, CaseIterable, Identifiable {
    case off, doubleCommand, doubleOption, doubleControl, doubleShift, combo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Выключена"
        case .doubleCommand: return "Двойное нажатие ⌘"
        case .doubleOption: return "Двойное нажатие ⌥"
        case .doubleControl: return "Двойное нажатие ⌃"
        case .doubleShift: return "Двойное нажатие ⇧"
        case .combo: return "Сочетание клавиш"
        }
    }

    var modifier: NSEvent.ModifierFlags? {
        switch self {
        case .doubleCommand: return .command
        case .doubleOption: return .option
        case .doubleControl: return .control
        case .doubleShift: return .shift
        case .off, .combo: return nil
        }
    }

    /// Короткая подпись для подсказок: «⌥⌥», «⌃⌥R».
    static func currentHint(_ defaults: UserDefaults = .standard) -> String? {
        let mode = HotkeyMode(rawValue: defaults.string(forKey: Hotkey.modeKey) ?? "") ?? .off
        switch mode {
        case .off: return nil
        case .combo: return defaults.string(forKey: Hotkey.displayKey)
        default:
            let s = mode.title.components(separatedBy: " ").last ?? ""
            return s + s
        }
    }
}

@MainActor
final class Hotkey {
    static let shared = Hotkey()
    static let modeKey = "hotkeyMode"
    static let keyCodeKey = "hotkeyKeyCode"
    static let modifiersKey = "hotkeyModifiers"
    static let displayKey = "hotkeyDisplay"

    private var monitors: [Any] = []
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // Состояние распознавания двойного нажатия.
    private var target: NSEvent.ModifierFlags = []
    private var isDown = false
    private var downAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = 0
    private var interrupted = false

    /// Для двойного нажатия: есть ли «Универсальный доступ».
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// (Пере)установить по текущим настройкам. Вызывать при запуске и после изменения настроек.
    func apply() {
        uninstall()
        let d = UserDefaults.standard
        let mode = HotkeyMode(rawValue: d.string(forKey: Self.modeKey) ?? "") ?? .off
        if let flag = mode.modifier {
            installDoubleTap(flag)
        } else if mode == .combo, d.object(forKey: Self.keyCodeKey) != nil {
            installCombo(keyCode: UInt32(d.integer(forKey: Self.keyCodeKey)),
                         modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: Self.modifiersKey))))
        }
    }

    private func fire() {
        AppState.shared.toggleRecording()
    }

    // MARK: - Двойное нажатие модификатора

    private func installDoubleTap(_ flag: NSEvent.ModifierFlags) {
        target = flag
        isDown = false
        lastTapAt = 0
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(m) }
    }

    /// Нажатие = модификатор нажат один и отпущен быстро, без других клавиш между; два таких подряд за 0,4 с.
    private func handle(_ e: NSEvent) {
        if e.type == .keyDown { // печатают с модификатором — это не «двойное нажатие»
            interrupted = true
            lastTapAt = 0
            return
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == target {
            isDown = true
            interrupted = false
            downAt = e.timestamp
        } else if flags.isEmpty, isDown {
            isDown = false
            guard !interrupted, e.timestamp - downAt < 0.3 else { lastTapAt = 0; return }
            if e.timestamp - lastTapAt < 0.4 {
                lastTapAt = 0
                fire()
            } else {
                lastTapAt = e.timestamp
            }
        } else { // зажали другой модификатор вместе с нашим
            isDown = false
            interrupted = true
            lastTapAt = 0
        }
    }

    // MARK: - Сочетание клавиш (Carbon)

    private func installCombo(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.shared.fire() } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4D54_5243), id: 1) // 'MTRC'
        let status = RegisterEventHotKey(keyCode, Self.carbonModifiers(modifiers), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            AppState.shared.errorText = "Горячая клавиша занята другим приложением (код \(status)) — выбери другое сочетание."
        }
    }

    private func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// «⌃⌥⌘R» — в порядке, принятом в macOS.
    static func display(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [49: "Пробел", 36: "↩", 53: "⎋", 51: "⌫", 48: "⇥",
                                         123: "←", 124: "→", 125: "↓", 126: "↑"]
        return s + (special[keyCode] ?? (characters ?? "?").uppercased())
    }
}
