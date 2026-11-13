import Foundation

/// Шлюз агента — OpenAI-совместимый API (/v1/models, /v1/chat/completions), через который идут действия.
/// Наш meetrec-gateway на сервере (за ним claude -p) доступен через SSH-туннель, который поднимается
/// сам; но подойдёт любой совместимый: Ollama, LM Studio, LiteLLM, OpenRouter…
/// Настройки — в ~/.config/meetrec/gateway.env (права 600): их же читает process.sh / run_actions.py.
@MainActor
final class GatewayStore: ObservableObject {
    static let shared = GatewayStore()
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/meetrec/gateway.env")

    @Published var ssh = "" { didSet { changed() } }        // user@server — поднимать туннель; пусто — без туннеля
    @Published var port = "8787" { didSet { changed() } }   // порт шлюза на сервере и локально
    @Published var address = "" { didSet { changed() } }   // свой адрес; пусто — http://127.0.0.1:<port>/v1
    @Published var token = "" { didSet { changed() } }
    @Published var model = "" { didSet { changed() } }     // модель по умолчанию; пусто — решает шлюз

    @Published private(set) var models: [String] = []
    @Published private(set) var steps: [Step] = []
    @Published private(set) var checking = false
    @Published private(set) var saveError: String?

    struct Step: Identifiable {
        enum State { case running, ok, failed }
        let id: Int
        let title: String
        var state: State
        var detail: String
    }

    private var loading = false
    private var saveTask: Task<Void, Never>?

    /// Адрес API, по которому ходят действия; пусто — шлюз не настроен (действия идут через claude -p).
    var effectiveURL: String {
        let a = address.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty { return a.hasSuffix("/") ? String(a.dropLast()) : a }
        return ssh.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "http://127.0.0.1:\(port)/v1"
    }

    var isConfigured: Bool { !effectiveURL.isEmpty }

    private init() {
        loading = true
        load()
        loading = false
    }

    // MARK: - Файл настроек

    private static let keys = ["MEETREC_GATEWAY_SSH", "MEETREC_GATEWAY_PORT", "MEETREC_GATEWAY_URL",
                               "MEETREC_GATEWAY_TOKEN", "MEETREC_GATEWAY_MODEL"]

    private func load() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            var v = parts[1].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = v
        }
        ssh = values["MEETREC_GATEWAY_SSH"] ?? ""
        port = values["MEETREC_GATEWAY_PORT"].flatMap { $0.isEmpty ? nil : $0 } ?? "8787"
        address = values["MEETREC_GATEWAY_URL"] ?? ""
        token = values["MEETREC_GATEWAY_TOKEN"] ?? ""
        model = values["MEETREC_GATEWAY_MODEL"] ?? ""
    }

    private func changed() {
        guard !loading else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    private func save() {
        let values = [ssh, port, address, token, model].map { $0.replacingOccurrences(of: "\"", with: "") }
        let text = "# Пишет meetrec (Настройки → Агент). Читают process.sh / run_actions.py.\n" +
            zip(Self.keys, values).map { "\($0)=\"\($1)\"" }.joined(separator: "\n") + "\n"
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path) // там токен
            saveError = nil
        } catch {
            saveError = "Не удалось сохранить настройки шлюза: \(error.localizedDescription)"
        }
    }

    // MARK: - Проверка: туннель → модели → ответ

    func check() async {
        guard !checking else { return }
        saveTask?.cancel()
        save()
        checking = true
        defer { checking = false }
        steps = []
        guard isConfigured else {
            steps = [Step(id: 0, title: "Шлюз", state: .failed, detail: "Не задан ни SSH-туннель, ни адрес")]
            return
        }

        // 1. Туннель (если нужен).
        if !ssh.isEmpty {
            begin(1, "SSH-туннель к \(ssh)")
            let (code, out) = await Self.runScript("tunnel.sh", env: ["MEETREC_GATEWAY_SSH": ssh, "MEETREC_GATEWAY_PORT": port])
            guard code == 0 else {
                finish(1, .failed, out.isEmpty ? "ssh завершился с кодом \(code)" : out)
                return
            }
            finish(1, .ok, "127.0.0.1:\(port) → \(ssh)")
        }

        // 2. Авторизация и список моделей.
        begin(2, "Авторизация и модели")
        do {
            let data = try await request("models", body: nil, timeout: 20)
            struct List: Decodable { struct M: Decodable { let id: String }; let data: [M] }
            models = try JSONDecoder().decode(List.self, from: data).data.map(\.id)
            finish(2, .ok, models.isEmpty ? "моделей нет" : models.joined(separator: ", "))
        } catch {
            finish(2, .failed, Self.describe(error))
            return
        }

        // 3. Модель отвечает.
        let m = model.isEmpty ? "default" : model
        begin(3, "Ответ модели \(m)")
        let started = Date()
        do {
            let body: [String: Any] = ["model": m, "messages": [
                ["role": "system", "content": "Ответь ровно одним словом."],
                ["role": "user", "content": "Скажи: ok"],
            ]]
            let data = try await request("chat/completions", body: body, timeout: 120)
            struct Reply: Decodable {
                struct C: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }
                let model: String?
                let choices: [C]
            }
            let r = try JSONDecoder().decode(Reply.self, from: data)
            let text = r.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            finish(3, .ok, "«\(text.prefix(40))» от \(r.model ?? m) за \(String(format: "%.1f", Date().timeIntervalSince(started))) с")
        } catch {
            finish(3, .failed, Self.describe(error))
        }
    }

    /// Забрать токен meetrec-gateway с сервера по SSH (тот же ключ, что и для туннеля).
    func fetchToken() async {
        guard !ssh.isEmpty else { return }
        begin(0, "Токен с сервера")
        let (code, out) = await Self.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", ssh,
                                                          "cat ~/.config/meetrec/gateway-token"])
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == 0, !t.isEmpty, !t.contains(" ") {
            token = t
            finish(0, .ok, "получен")
        } else {
            finish(0, .failed, out.isEmpty ? "ssh: код \(code)" : String(out.prefix(300)))
        }
    }

    private func begin(_ id: Int, _ title: String) {
        steps.removeAll { $0.id == id }
        steps.append(Step(id: id, title: title, state: .running, detail: ""))
        steps.sort { $0.id < $1.id }
    }

    private func finish(_ id: Int, _ state: Step.State, _ detail: String) {
        if let i = steps.firstIndex(where: { $0.id == id }) {
            steps[i].state = state
            steps[i].detail = detail
        }
    }

    private struct GatewayError: LocalizedError {
        let errorDescription: String?
    }

    private func request(_ path: String, body: [String: Any]?, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: effectiveURL + "/" + path) else { throw GatewayError(errorDescription: "неверный адрес") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct E: Decodable { struct I: Decodable { let message: String? }; let error: I? }
            let msg = (try? JSONDecoder().decode(E.self, from: data))?.error?.message
            let hint = status == 401 ? " — неверный токен" : status == 404 ? " — это не OpenAI-совместимый шлюз?" : ""
            throw GatewayError(errorDescription: "HTTP \(status)\(hint)" + (msg.map { ": \($0)" } ?? ""))
        }
        return data
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .networkConnectionLost: return "не отвечает по этому адресу (шлюз не запущен?)"
            case .timedOut: return "нет ответа — таймаут"
            case .cannotFindHost: return "адрес не найден"
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Запуск процессов

    static func runScript(_ name: String, env: [String: String]) async -> (Int32, String) {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "MeetrecRepoRoot") as? String else {
            return (-1, "в Info.plist нет MeetrecRepoRoot — пересобери build-app.sh")
        }
        return await run("/bin/bash", ["\(root)/scripts/\(name)"], env: env)
    }

    static func run(_ executable: String, _ args: [String], env: [String: String] = [:]) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            var e = ProcessInfo.processInfo.environment
            e.merge(env) { $1 }
            e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = e
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
