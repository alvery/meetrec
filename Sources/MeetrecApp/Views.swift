import AppKit
import SwiftUI

@main
struct MeetrecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(state)
        }
    }
}

// MARK: - Метка в строке меню

/// Что показывать в строке меню рядом с иконкой. По умолчанию — только иконка: на MacBook с вырезом
/// macOS молча прячет иконки, которые не влезли слева от него, и длинная метка пропадает целиком.
enum LabelMode: String, CaseIterable, Identifiable {
    case icon, time, titleAndTime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: return "Только иконка (кольцо-отсчёт)"
        case .time: return "Время до встречи"
        case .titleAndTime: return "Название и время"
        }
    }
    static let storageKey = "menuBarLabelMode"
}

struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject private var blinker = Blinker.shared
    @AppStorage(LabelMode.storageKey) private var mode: LabelMode = .icon

    var body: some View {
        let c = content
        HStack(spacing: 3) {
            Image(nsImage: MenuIcon.image(c.icon)).renderingMode(.template)
            if mode != .icon, let text = c.text { Text(text).monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("meetrec, " + c.a11y)
    }

    /// Иконка по фазе, приоритет сверху вниз: запись → «Записать?» → обработка → ошибка →
    /// встреча идёт / скоро → ✓ → простой. Текст — только в режимах «время» / «название и время».
    private var content: (icon: IconState, text: String?, a11y: String) {
        _ = state.minuteTick // перерисовка раз в минуту
        let now = Date()
        if state.isRecording {
            let t = Format.timer(state.elapsedSeconds)
            return (.recording, t, "идёт запись \(t)")
        }
        if state.promptEvent != nil { return (.prompt(blink: blinker.on), "Записать?", "встреча идёт, записать?") }
        if let p = state.processingMeeting { return (.processing, nil, "делаю заметки: \(p.title)") }
        if state.unseenFailure { return (.failed, nil, "не удалось сделать заметки") }
        if let e = state.event {
            let prefix = mode == .titleAndTime ? "\(Format.short(e.title)) · " : ""
            if e.isInProgress(at: now) {
                let left = e.end.timeIntervalSince(now)
                let duration = max(60, e.end.timeIntervalSince(e.start))
                let step = Int((left / duration * Double(IconState.steps)).rounded(.up))
                return (.now(step: min(IconState.steps, max(1, step))), "\(prefix)ещё \(Format.compact(left))",
                        "\(e.title) идёт, ещё \(Format.minutes(left))")
            }
            let until = e.start.timeIntervalSince(now)
            if until <= 3600 {
                let step = Int(((1 - until / 3600) * Double(IconState.steps)).rounded(.up)) // за ≤ 2,5 мин — полное кольцо
                return (.soon(step: min(IconState.steps, max(1, step))), "\(prefix)\(Format.compact(until))",
                        "\(e.title) через \(Format.minutes(until))")
            }
        }
        if state.unseenNotes { return (.done, nil, "заметки готовы") }
        return (.idle, nil, "нет встреч в ближайший час")
    }
}

// MARK: - Окно

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionRows()
            if state.isRecording { RecordingHero() } else { EventHero() }
            if let err = state.errorText { ErrorRow(text: err) }
            if let p = state.processingMeeting, !state.isRecording { ProcessingRow(meeting: p) }
            Divider()
            RecentSection()
            Divider()
            FooterSection()
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { state.popoverOpened() }
        // MenuBarExtra не пересоздаёт содержимое между открытиями — onAppear бывает только первый раз.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            state.popoverOpened()
        }
    }
}

// MARK: - Разрешения и ошибки

struct PermissionRows: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ForEach(state.missingPermissions) { p in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(p.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Открыть настройки") { state.open(p.settingsURL) }.controlSize(.small)
            }
        }
    }
}

struct ErrorRow: View {
    @EnvironmentObject var state: AppState
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { state.errorText = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("Скрыть ошибку")
        }
    }
}

// MARK: - Главный блок: встреча

struct EventHero: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 6) {
            if let e = state.event {
                let inProgress = e.isInProgress(at: now)
                // Главное действие по фазе: до начала — «Подключиться», когда идёт — «Записать».
                let recordIsPrimary = inProgress || state.promptEvent != nil || e.joinURL == nil
                Text(inProgress ? "СЕЙЧАС · ещё \(Format.minutes(e.end.timeIntervalSince(now)))"
                                : "ДАЛЕЕ · \(Format.startsIn(e.start, now: now))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(e.title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(Format.details(e)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    if e.joinURL != nil {
                        Button { state.join(e) } label: { Label("Подключиться", systemImage: "video") }
                            .prominent(!recordIsPrimary)
                            .keyboardShortcut("j", modifiers: .command)
                    }
                    RecordButton(event: inProgress ? e : nil).prominent(recordIsPrimary)
                }
                .padding(.top, 2)
                if state.promptEvent != nil {
                    HStack(spacing: 4) {
                        Text("Микрофон занят — похоже, созвон уже идёт.").font(.caption).foregroundStyle(.secondary)
                        Button("Не записывать") { state.dismissPrompt() }.buttonStyle(.link).font(.caption)
                    }
                }
                if let f = state.followingEvent {
                    Text("Далее: \(f.title) · \(Format.time.string(from: f.start))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Встреч в ближайшие сутки нет").foregroundStyle(.secondary)
                RecordButton(event: nil).prominent(true)
            }
        }
    }
}

struct RecordButton: View {
    @EnvironmentObject var state: AppState
    // Подписка на настройки клавиши — чтобы подсказка обновлялась сразу.
    @AppStorage(Hotkey.modeKey) private var hotkeyMode = ""
    @AppStorage(Hotkey.displayKey) private var hotkeyDisplay = ""
    let event: MeetingEvent?

    var body: some View {
        Button { state.startRecording(for: event) } label: {
            Label(state.isStarting ? "Запуск…" : "Записать", systemImage: "record.circle")
        }
        .disabled(state.isStarting)
        .keyboardShortcut("r", modifiers: .command)
        .help("Записать (⌘R" + (HotkeyMode.currentHint().map { "; из любого приложения — \($0)" } ?? "") + ")")
    }
}

// MARK: - Главный блок: запись

struct RecordingHero: View {
    @EnvironmentObject var state: AppState
    @AppStorage(Hotkey.modeKey) private var hotkeyMode = ""
    @AppStorage(Hotkey.displayKey) private var hotkeyDisplay = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("ЗАПИСЬ").font(.caption.weight(.semibold)).foregroundStyle(.red)
                Text(Format.timer(state.elapsedSeconds)).font(.caption.weight(.semibold)).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Text(state.recordingTitle ?? "Запись без встречи").font(.title3.weight(.semibold)).lineLimit(2)
            LevelsView()
            Button { state.stopRecording() } label: {
                Label("Остановить и сделать заметки", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(".", modifiers: .command)
            .help("Остановить (⌘." + (HotkeyMode.currentHint().map { "; из любого приложения — \($0)" } ?? "") + ")")
            .padding(.top, 2)
        }
    }
}

/// Уровни «Я» / «Они» и предупреждение о тишине. Подписан только на Meter —
/// 4 обновления в секунду не трогают остальное окно.
struct LevelsView: View {
    @ObservedObject private var meter = Meter.shared
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LevelRow(label: "Я", level: meter.me)
            LevelRow(label: "Они", level: meter.them)
            if meter.themSilentSeconds >= 30 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("«Они» молчат \(Int(meter.themSilentSeconds)) с — нет звука или нет разрешения на системный звук?")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Настройки") { state.open(Permission.systemAudio.settingsURL) }.controlSize(.small)
                }
            }
        }
    }
}

struct LevelRow: View {
    let label: String
    let level: Float
    private let bars = 14

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 30, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Float(i) < level * Float(bars) ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 9, height: 6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(level < 0.05 ? "тишина" : "уровень \(Int(level * 100)) процентов")
    }
}

// MARK: - Обработка

struct ProcessingRow: View {
    let meeting: MeetingFolder

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Заметки «\(meeting.title)»").lineLimit(1)
                if case .processing(let stage?) = meeting.status {
                    Text(stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Недавние встречи

struct RecentSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Недавние").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if state.meetings.isEmpty {
                Text("Пока нет записей").foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(state.meetings) { m in
                RecentRow(meeting: m)
            }
        }
    }
}

/// Клик по строке — главное действие (заметки / лог ошибки / обработать); остальное — в контекстном меню.
struct RecentRow: View {
    @EnvironmentObject var state: AppState
    let meeting: MeetingFolder
    @State private var hovered = false

    var body: some View {
        Button(action: primary) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).lineLimit(1)
                    Text(Format.day(meeting.date)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusIcon
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(hint)
        .contextMenu {
            ForEach(meeting.results, id: \.self) { file in
                Button("Открыть \(file.lastPathComponent)") { state.open(file) }
            }
            Button("Открыть транскрипт") { state.open(meeting.transcript) }
                .disabled(!FileManager.default.fileExists(atPath: meeting.transcript.path))
            Divider()
            Button("Открыть папку") { state.open(meeting.url) }
            Button("Открыть лог обработки") { state.open(meeting.log) }
            Divider()
            Button("Обработать заново") { state.process(meeting.url, title: meeting.title) }
                .disabled(meeting.status == .recording || meeting.status.isProcessing)
        }
        .accessibilityLabel("\(meeting.title), \(Format.day(meeting.date)), \(statusText)")
        .accessibilityHint(hint)
    }

    @ViewBuilder private var statusIcon: some View {
        switch meeting.status {
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .processing: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch meeting.status {
        case .recording: return "идёт запись"
        case .processing: return "обрабатывается"
        case .done: return "готово"
        case .failed: return "ошибка обработки"
        case .pending: return "не обработана"
        }
    }

    private var hint: String {
        switch meeting.status {
        case .done: return "Открыть \(meeting.primaryResult.lastPathComponent)"
        case .failed: return "Открыть лог ошибки"
        case .pending: return "Сделать заметки"
        case .recording, .processing: return "Открыть папку"
        }
    }

    private func primary() {
        switch meeting.status {
        case .done: state.open(meeting.primaryResult)
        case .failed: state.open(meeting.log)
        case .pending: state.process(meeting.url, title: meeting.title)
        case .recording, .processing: state.open(meeting.url)
        }
    }
}

// MARK: - Низ окна

struct FooterSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            // Окно настроек; приложение без Dock-иконки — активируем, чтобы окно вышло поверх.
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                .help("Настройки (⌘,)").accessibilityLabel("Настройки")
            Button { state.open(state.meetingsRoot) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Открыть папку встреч").accessibilityLabel("Открыть папку встреч")
            Spacer()
            Button(state.isRecording ? "Остановить и выйти" : "Выйти") { state.quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Вспомогательное

extension View {
    /// Главная кнопка фазы — заметная; остальные — обычные.
    @ViewBuilder func prominent(_ on: Bool) -> some View {
        if on { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

enum Format {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static let folderStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f }()
    static let metaTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func timer(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                  : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Минуты с округлением вверх: за 59 секунд до начала — «1 мин», а не «0».
    static func minutes(_ t: TimeInterval) -> String {
        let m = max(0, Int((t / 60).rounded(.up)))
        return m >= 60 ? "\(m / 60) ч \(m % 60) мин" : "\(m) мин"
    }

    static func startsIn(_ start: Date, now: Date) -> String {
        let t = start.timeIntervalSince(now)
        return t <= 3600 ? "через \(minutes(t))" : "в \(time.string(from: start)), через \(minutes(t))"
    }

    /// «14:00–14:30 · Zoom · Петя, Аня +2»
    static func details(_ e: MeetingEvent) -> String {
        var parts = ["\(time.string(from: e.start))–\(time.string(from: e.end))"]
        if let host = e.joinURL?.host?.lowercased() {
            parts.append(host.contains("zoom") ? "Zoom" : host.contains("meet.google") ? "Meet" : "Teams")
        }
        if !e.attendees.isEmpty {
            let names = e.attendees.prefix(2).joined(separator: ", ")
            parts.append(e.attendees.count > 2 ? "\(names) +\(e.attendees.count - 2)" : names)
        }
        return parts.joined(separator: " · ")
    }

    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }

    /// Название для строки меню: она общая с другими иконками, длинное — обрезаем.
    /// Для строки меню: «23 мин», «1ч23».
    static func compact(_ t: TimeInterval) -> String {
        let m = max(0, Int((t / 60).rounded(.up)))
        return m >= 60 ? "\(m / 60)ч\(String(format: "%02d", m % 60))" : "\(m) мин"
    }

    static func short(_ title: String, max: Int = 14) -> String {
        title.count > max ? String(title.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : title
    }
}
