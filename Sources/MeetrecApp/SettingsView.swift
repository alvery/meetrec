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
    }
}

// MARK: - Основные

private struct GeneralSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(LabelMode.storageKey) private var labelMode: LabelMode = .icon

    var body: some View {
        Form {
            Section {
                LabeledContent("Папка встреч") {
                    HStack {
                        Text(state.meetingsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Выбрать…") { chooseFolder() }
                        Button("Открыть") { state.open(state.meetingsRoot) }
                    }
                }
            } footer: {
                Text("Для каждой встречи — своя папка: запись, transcript.md сразу после транскрипции, затем результаты действий.")
                    .font(.caption).foregroundStyle(.secondary)
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
                if let i = store.actions.firstIndex(where: { $0.id == selection }) {
                    ActionEditor(action: $store.actions[i])
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
            if let err = store.saveError {
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
