import Foundation

/// Действие над транскриптом (как actions в Shadow): промпт → Markdown-файл в папке встречи.
/// Выполняет их scripts/run_actions.py сразу после транскрипции.
struct MeetingAction: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var enabled: Bool
    var output: String
    var prompt: String
}

private struct ActionsFile: Codable {
    var version = 1
    var actions: [MeetingAction]
}

/// ~/.config/meetrec/actions.json — общий для приложения и process.sh.
/// Нет файла — стандартные действия из репозитория (prompts/actions.default.json).
@MainActor
final class ActionsStore: ObservableObject {
    static let shared = ActionsStore()
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/meetrec/actions.json")

    @Published var actions: [MeetingAction] = [] {
        didSet { if !loading { save() } }
    }
    @Published private(set) var saveError: String?
    private var loading = false

    private init() {
        loading = true
        actions = Self.read(Self.url) ?? Self.defaults()
        loading = false
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

    private static func read(_ url: URL) -> [MeetingAction]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(ActionsFile.self, from: data))?.actions
    }

    private static func defaults() -> [MeetingAction] {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "MeetrecRepoRoot") as? String else { return [] }
        return read(URL(fileURLWithPath: root).appendingPathComponent("prompts/actions.default.json")) ?? []
    }
}
