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

    var symbol: String? {
        switch self {
        case .doubleCommand: return "⌘"
        case .doubleOption: return "⌥"
        case .doubleControl: return "⌃"
        case .doubleShift: return "⇧"
        case .off, .combo: return nil
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
        default: return mode.symbol.map { $0 + $0 }
        }
    }
}

@MainActor
final class Hotkey: ObservableObject {
    static let shared = Hotkey()
    /// «Универсальный доступ» выдан (перепроверяется в AppState.tick, раз в 5 с).
    @Published private(set) var trusted = AXIsProcessTrusted()
    static let modeKey = "hotkeyMode"
    static let keyCodeKey = "hotkeyKeyCode"
    static let modifiersKey = "hotkeyModifiers"
    static let displayKey = "hotkeyDisplay"

    private var monitors: [Any] = []
    private var hotKeyRef: EventHotKeyRef?
    private var markRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef? // ставится один раз и живёт всё время работы приложения

    /// ★ Метка важного момента — ⌃⌥M, только пока идёт запись (в остальное время сочетание свободно).
    static let markDisplay = "⌃⌥M"
    private static let markID: UInt32 = 2
    static var markCollidesWithMain: Bool {
        let d = UserDefaults.standard
        return d.string(forKey: modeKey) == HotkeyMode.combo.rawValue && d.object(forKey: keyCodeKey) != nil
            && d.integer(forKey: keyCodeKey) == kVK_ANSI_M
            && NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: modifiersKey)))
                .intersection([.command, .option, .control, .shift]) == [.control, .option]
    }

    // Состояние распознавания двойного нажатия.
    private var target: NSEvent.ModifierFlags = []
    private var isDown = false
    private var downAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = 0
    private var interrupted = false
    private var tapApp: pid_t = 0 // приложение в момент первого нажатия

    /// Для двойного нажатия: есть ли «Универсальный доступ».
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Доступ выдали/отозвали — переустановить мониторы (они работают только с доступом).
    func refreshTrust() {
        let now = AXIsProcessTrusted()
        if now != trusted {
            trusted = now
            apply()
        }
    }

    /// Пока в настройках записывается новое сочетание — старое не должно срабатывать.
    func suspend() { uninstall() }

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
        // Клики и прокрутка с зажатым модификатором (⌘-клик, ⇧-клик) — тоже «не нажатие».
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown,
                                           .otherMouseDown, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(m) }
    }

    /// Нажатие = модификатор нажат из «ничего не зажато», отпущен быстро (< 0,25 с), между — ни клавиш,
    /// ни кликов, ни других модификаторов. Два таких подряд за 0,4 с в одном и том же приложении
    /// (⌘Tab ⌘Tab меняет приложение — это не наше нажатие).
    private func handle(_ e: NSEvent) {
        guard e.type == .flagsChanged else { // клавиша / клик / прокрутка — это не «двойное нажатие»
            interrupted = true
            lastTapAt = 0
            return
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == target, !isDown, !interrupted {
            isDown = true
            downAt = e.timestamp
        } else if flags.isEmpty {
            defer { isDown = false; interrupted = false } // всё отпущено — следующее нажатие с чистого листа
            guard isDown, !interrupted, e.timestamp - downAt < 0.25 else { lastTapAt = 0; return }
            let app = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            if lastTapAt > 0, e.timestamp - lastTapAt < 0.4, app == tapApp {
                lastTapAt = 0
                fire()
            } else {
                lastTapAt = e.timestamp
                tapApp = app
            }
        } else { // другой модификатор (вместе с нашим или вместо) — до полного отпускания не считаем
            interrupted = true
            lastTapAt = 0
        }
    }

    // MARK: - Сочетание клавиш (Carbon)

    /// Один обработчик Carbon на все сочетания; какое нажато — по id.
    private func ensureHandler() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if id == Hotkey.markID { AppState.shared.addMark() } else { Hotkey.shared.fire() }
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if installed != noErr { AppState.shared.errorText = "Горячая клавиша не установилась (код \(installed))." }
        return installed == noErr
    }

    /// Включить ⌃⌥M на время записи. false — сочетание занято другим приложением.
    @discardableResult
    func registerMark() -> Bool {
        guard markRef == nil else { return true }
        // ⌃⌥M уже основная клавиша старт/стоп — метку не вешаем (иначе «метка» остановила бы запись).
        if Self.markCollidesWithMain { return false }
        guard ensureHandler() else { return false }
        let id = EventHotKeyID(signature: OSType(0x4D54_5243), id: Self.markID)
        return RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id,
                                   GetApplicationEventTarget(), 0, &markRef) == noErr
    }

    func unregisterMark() {
        if let ref = markRef { UnregisterEventHotKey(ref); markRef = nil }
    }

    private func installCombo(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        guard ensureHandler() else { return }
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
        // Подпись по физической клавише (US-раскладка), как регистрирует Carbon: на русской
        // раскладке ⌃⌥R не превратится в «⌃⌥К», ⇧1 — в «!».
        let keys: [UInt16: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K",
            37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
            9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            49: "Пробел", 36: "↩", 53: "⎋", 51: "⌫", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return s + (keys[keyCode] ?? (characters ?? "?").uppercased())
    }
}
