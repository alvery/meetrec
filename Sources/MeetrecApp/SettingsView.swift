import AppKit
import SwiftUI

/// Окно настроек (⌘,): основные и действия над транскриптом.
struct SettingsView: View {
    static let tabKey = "settingsTab"
    @AppStorage(SettingsView.tabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("Основные", systemImage: "gearshape") }.tag("general")
            ActionsSettings()
                .tabItem { Label("Действия", systemImage: "sparkles") }.tag("actions")
            GatewaySettings()
                .tabItem { Label("Агент", systemImage: "network") }.tag("agent")
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
    @ObservedObject private var hotkey = Hotkey.shared

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
                if hotkeyMode.modifier != nil && !hotkey.trusted {
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
            Text(listening ? "Нажми сочетание с ⌃ или ⌥… (⎋ — отмена)" : (display.isEmpty ? "Не задано" : display))
                .font(.system(.body, design: .rounded).weight(listening ? .regular : .semibold))
                .foregroundStyle(listening ? Color.accentColor : (display.isEmpty ? .secondary : .primary))
            Button(listening ? "Отмена" : "Задать…") { listening ? stop() : start() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        Hotkey.shared.suspend() // иначе текущее сочетание сработает вместо записи нового
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // ⎋
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // Нужен ⌃ или ⌥: сочетания только с ⌘ (⌘C, ⌘V, ⌘Q…) заняты системой и приложениями,
            // а глобальная регистрация отобрала бы их у всех.
            guard !mods.intersection([.option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            let d = UserDefaults.standard
            d.set(Int(e.keyCode), forKey: Hotkey.keyCodeKey)
            d.set(Int(mods.rawValue), forKey: Hotkey.modifiersKey)
            display = Hotkey.display(keyCode: e.keyCode, modifiers: mods, characters: e.charactersIgnoringModifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        let wasListening = listening
        listening = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if wasListening { Hotkey.shared.apply() } // вернуть (новое или прежнее) сочетание
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
    @ObservedObject private var gateway = GatewayStore.shared

    /// Модели шлюза + текущая модель действия (если её нет в списке — не теряем).
    private var modelChoices: [String] {
        var list = gateway.models
        if let m = action.model, !list.contains(m) { list.append(m) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("Название", text: $action.name)
                TextField("Файл результата", text: $action.output)
                Picker("Модель", selection: Binding(get: { action.model ?? "" },
                                                     set: { action.model = $0.isEmpty ? nil : $0 })) {
                    Text(gateway.model.isEmpty ? "По умолчанию" : "По умолчанию (\(gateway.model))").tag("")
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!gateway.isConfigured)
                .help(gateway.isConfigured ? "Модель шлюза для этого действия"
                                           : "Выбор модели — через шлюз (вкладка «Агент»)")
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
            Text("К промпту автоматически добавляются: кто есть «Я» и «Они», meta.md (название, время, участники) и транскрипт. Результат пишется на языке встречи. Действия выполняются параллельно — через шлюз агента (вкладка «Агент») или claude -p по SSH.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}

// MARK: - Агент (шлюз)

private struct GatewaySettings: View {
    @ObservedObject private var gw = GatewayStore.shared
    @State private var showToken = false

    var body: some View {
        Form {
            Section {
                TextField("SSH-туннель к", text: $gw.ssh, prompt: Text("user@server"))
                TextField("Порт шлюза", text: $gw.port)
                TextField("Свой адрес API", text: $gw.address, prompt: Text(gw.ssh.isEmpty ? "https://host:port/v1" : "http://127.0.0.1:\(gw.port)/v1"))
                LabeledContent("Токен") {
                    HStack {
                        if showToken { TextField("", text: $gw.token).labelsHidden() }
                        else { SecureField("", text: $gw.token).labelsHidden() }
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless).accessibilityLabel(showToken ? "Скрыть токен" : "Показать токен")
                        Button("С сервера") { Task { await gw.fetchToken() } }
                            .disabled(gw.ssh.isEmpty)
                            .help("Забрать токен meetrec-gateway по SSH")
                    }
                }
                Picker("Модель по умолчанию", selection: $gw.model) {
                    Text("Решает шлюз").tag("")
                    ForEach(gw.models + (gw.model.isEmpty || gw.models.contains(gw.model) ? [] : [gw.model]), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            } header: {
                Text("Шлюз агента")
            } footer: {
                Text("Любой OpenAI-совместимый API (/v1/models, /v1/chat/completions): meetrec-gateway на сервере (за ним claude -p по подписке), Ollama, LM Studio, LiteLLM, OpenRouter… С «SSH-туннелем» meetrec сам поднимает туннель тем же ключом, что и для отчётов, — на сервере наружу ничего не открыто. Пусто — действия идут через claude -p по SSH, как раньше.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button {
                        Task { await gw.check() }
                    } label: {
                        Label(gw.checking ? "Проверяю…" : "Проверить", systemImage: "checkmark.seal")
                    }
                    .disabled(gw.checking)
                    if gw.isConfigured {
                        Text(gw.effectiveURL).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                ForEach(gw.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        switch step.state {
                        case .running: ProgressView().controlSize(.small)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let err = gw.saveError { Text(err).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Проверка")
            } footer: {
                Text("Три шага: туннель поднят → шлюз принимает токен и отдаёт модели → модель отвечает на короткий запрос.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
