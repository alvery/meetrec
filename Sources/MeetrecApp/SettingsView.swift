import AppKit
import SwiftUI

/// Окно настроек (⌘,): основные и действия над транскриптом.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }
            ActionsSettings()
                .tabItem { Label("Действия", systemImage: "sparkles") }
        }
        .frame(width: 760, height: 520)
        // Приложение без Dock-иконки: окно настроек (в т.ч. по ⌘,) должно выйти поверх остальных.
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - Основные

private struct GeneralSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(LabelMode.storageKey) private var labelMode: LabelMode = .icon
    @AppStorage(Hotkey.modeKey) private var hotkeyMode: HotkeyMode = .off
    @State private var axTrusted = Hotkey.accessibilityTrusted
    private let axCheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Папка встреч") {
                    HStack {
                        Text(state.meetingsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Выбрать…") { chooseFolder() }
                            .disabled(state.isRecording || state.processingMeeting != nil)
                            .help(state.isRecording || state.processingMeeting != nil
                                  ? "Нельзя менять папку, пока идёт запись или обработка" : "")
                        Button("Открыть") { state.open(state.meetingsRoot) }
                    }
                }
            } footer: {
                Text("Для каждой встречи — своя папка: запись, transcript.md сразу после транскрипции, затем результаты действий.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Старт / стоп записи", selection: $hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { Text($0.title).tag($0) }
                }
                if hotkeyMode == .combo {
                    LabeledContent("Сочетание") { ShortcutRecorder() }
                }
                if hotkeyMode.modifier != nil && !axTrusted {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Нужен «Универсальный доступ» для meetrec — иначе двойное нажатие не сработает.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Разрешить…") {
                            Hotkey.requestAccessibility()
                            state.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            } header: {
                Text("Горячая клавиша")
            } footer: {
                Text("Работает из любого приложения: первое нажатие начинает запись (с привязкой к идущей встрече), второе — останавливает и запускает обработку. Сочетание клавиш не требует разрешений; двойное нажатие — требует «Универсальный доступ»: без него macOS не даёт видеть нажатия в других приложениях.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: hotkeyMode) { Hotkey.shared.apply() }
            .onReceive(axCheck) { _ in
                let trusted = Hotkey.accessibilityTrusted
                if trusted != axTrusted {
                    axTrusted = trusted
                    Hotkey.shared.apply() // монитор нажатий заработает только после выдачи доступа
                }
            }
            Section {
                Picker("В строке меню", selection: $labelMode) {
                    ForEach(LabelMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Запускать при входе", isOn: Binding(get: { state.launchAtLogin },
                                                            set: { state.launchAtLogin = $0 }))
            }
            Section {
                LabeledContent("Прочие настройки") {
                    Button("Открыть ~/.config/meetrec/env") { state.openConfig() }
                }
            } footer: {
                Text("Сервер для заметок и отчётов, язык и модель whisper — в env-файле.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.meetingsRoot
        panel.prompt = "Выбрать"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { state.setMeetingsRoot(url) }
    }
}

/// Запись сочетания: «Задать…» → нажать сочетание с ⌘/⌥/⌃ (⎋ — отмена).
private struct ShortcutRecorder: View {
    @AppStorage(Hotkey.displayKey) private var display = ""
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(listening ? "Нажми сочетание… (⎋ — отмена)" : (display.isEmpty ? "Не задано" : display))
                .font(.system(.body, design: .rounded).weight(listening ? .regular : .semibold))
                .foregroundStyle(listening ? Color.accentColor : (display.isEmpty ? .secondary : .primary))
            Button(listening ? "Отмена" : "Задать…") { listening ? stop() : start() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // ⎋
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep() // без ⌘/⌥/⌃ сочетание будет мешать обычному набору текста
                return nil
            }
            let d = UserDefaults.standard
            d.set(Int(e.keyCode), forKey: Hotkey.keyCodeKey)
            d.set(Int(mods.rawValue), forKey: Hotkey.modifiersKey)
            display = Hotkey.display(keyCode: e.keyCode, modifiers: mods, characters: e.charactersIgnoringModifiers)
            stop()
            Hotkey.shared.apply()
            return nil
        }
    }

    private func stop() {
        listening = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: - Действия

private struct ActionsSettings: View {
    @ObservedObject private var store = ActionsStore.shared
    @State private var selection: String?
    @State private var confirmReset = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($store.actions) { $action in
                        HStack {
                            Toggle("", isOn: $action.enabled).labelsHidden().toggleStyle(.checkbox)
                                .help(action.enabled ? "Выполняется после транскрипции" : "Выключено")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(action.name).lineLimit(1)
                                Text(action.output).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(action.id)
                    }
                    .onMove { store.actions.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset)
                Divider()
                HStack(spacing: 4) {
                    Button { selection = store.add() } label: { Image(systemName: "plus") }
                        .help("Добавить действие").accessibilityLabel("Добавить действие")
                    Button {
                        if let id = selection { store.remove(id); selection = store.actions.first?.id }
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help("Удалить действие").accessibilityLabel("Удалить действие")
                    Spacer()
                    Button("Стандартные…") { confirmReset = true }
                        .help("Вернуть три стандартных действия")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 240)
            Divider()
            Group {
                // Привязка по id, а не по индексу: удаление/«Стандартные…» не роняют редактор.
                if let id = selection, let current = store.binding(for: id) {
                    ActionEditor(action: Binding(get: { store.binding(for: id) ?? current },
                                                 set: { store.update($0) }))
                        .id(id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Выбери действие слева или добавь новое").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selection == nil { selection = store.actions.first?.id } }
        .confirmationDialog("Заменить все действия тремя стандартными?", isPresented: $confirmReset) {
            Button("Заменить", role: .destructive) { store.resetToDefaults(); selection = store.actions.first?.id }
        }
        .overlay(alignment: .bottom) {
            if let err = store.loadError ?? store.saveError {
                Text(err).font(.caption).foregroundStyle(.red).padding(6)
            }
        }
    }
}

private struct ActionEditor: View {
    @Binding var action: MeetingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("Название", text: $action.name)
                TextField("Файл результата", text: $action.output)
                Toggle("Выполнять после транскрипции", isOn: $action.enabled)
            }
            .formStyle(.columns)
            Text("Промпт").font(.headline)
            TextEditor(text: $action.prompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            Text("К промпту автоматически добавляются: кто есть «Я» и «Они», meta.md (название, время, участники) и транскрипт. Результат пишется на языке встречи. Действия выполняются параллельно через claude -p на сервере.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}
