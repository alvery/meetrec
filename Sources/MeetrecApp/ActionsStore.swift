import Foundation

/// Действие над транскриптом (как actions в Shadow): промпт → Markdown-файл в папке встречи.
/// Выполняет их scripts/run_actions.py сразу после транскрипции.
struct MeetingAction: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var output: String
    var prompt: String

    init(id: String, name: String, enabled: Bool, output: String, prompt: String) {
        (self.id, self.name, self.enabled, self.output, self.prompt) = (id, name, enabled, output, prompt)
    }

    /// Терпимо к файлу, написанному руками: id/enabled/output необязательны (как и для run_actions.py).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Действие"
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}

private struct ActionsFile: Codable {
    var version: Int? = 1
    var actions: [MeetingAction]
}

/// ~/.config/meetrec/actions.json — общий для приложения и process.sh.
/// Нет файла — стандартные действия из репозитория (prompts/actions.default.json).
@MainActor
final class ActionsStore: ObservableObject {
    static let shared = ActionsStore()
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/meetrec/actions.json")

    @Published var actions: [MeetingAction] = [] {
        didSet { if !loading { scheduleSave() } }
    }
    @Published private(set) var saveError: String?
    /// actions.json есть, но не читается — приложение его не перезаписывает (иначе потеря действий).
    @Published private(set) var loadError: String?
    private var loading = false
    private var saveTask: Task<Void, Never>?

    private init() {
        loading = true
        if FileManager.default.fileExists(atPath: Self.url.path) {
            do {
                actions = try Self.decode(Self.url)
            } catch {
                loadError = "Не читается \(Self.url.path): \(error.localizedDescription). Исправь файл или удали его — изменения здесь не сохраняются."
                actions = Self.defaults()
            }
        } else {
            actions = Self.defaults()
        }
        loading = false
    }

    /// Сохранение с задержкой: не писать файл на каждую букву в редакторе промпта.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    func binding(for id: String) -> MeetingAction? { actions.first { $0.id == id } }

    func update(_ action: MeetingAction) {
        if let i = actions.firstIndex(where: { $0.id == action.id }) { actions[i] = action }
    }

    /// Файлы результатов в порядке действий (для «открыть главное» и списка в меню).
    var outputs: [String] { actions.map(\.output) }

    func add() -> String {
        var n = 1
        while outputs.contains("result-\(n).md") { n += 1 }
        let action = MeetingAction(id: UUID().uuidString, name: "Новое действие", enabled: true,
                                   output: "result-\(n).md", prompt: "")
        actions.append(action)
        return action.id
    }

    func remove(_ id: String) {
        actions.removeAll { $0.id == id }
    }

    func resetToDefaults() {
        actions = Self.defaults()
    }

    private func save() {
        guard loadError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(ActionsFile(actions: actions)).write(to: Self.url, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Не удалось сохранить действия: \(error.localizedDescription)"
        }
    }

    private static func decode(_ url: URL) throws -> [MeetingAction] {
        try JSONDecoder().decode(ActionsFile.self, from: Data(contentsOf: url)).actions
    }

    private static func defaults() -> [MeetingAction] {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "MeetrecRepoRoot") as? String else { return [] }
        return (try? decode(URL(fileURLWithPath: root).appendingPathComponent("prompts/actions.default.json"))) ?? []
    }
}
