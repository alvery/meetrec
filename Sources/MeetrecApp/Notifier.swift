import AppKit
import UserNotifications

/// Системные уведомления — только итог обработки («Записать?» и «Подключиться» — плашкой,
/// см. FloatingPanel: у уведомлений с двумя действиями кнопки прячутся в «Параметры»). Заголовок — название встречи; содержимое заметок в баннер не выводим
/// (его увидят все на демонстрации экрана). Во время созвона — без звука: звук попал бы в запись.
enum Notifier {
    enum Category {
        static let notes = "NOTES"     // заметки готовы
        static let failed = "FAILED"   // обработка упала
    }
    enum Action {
        static let openLog = "OPEN_LOG"
        static let retry = "RETRY"
    }

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in AppState.shared.refreshPermissions() }
        }
        func action(_ id: String, _ title: String, _ symbol: String) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: [],
                                 icon: UNNotificationActionIcon(systemImageName: symbol))
        }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.notes, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Category.failed,
                                   actions: [action(Action.openLog, "Открыть лог", "doc.text.magnifyingglass"),
                                             action(Action.retry, "Повторить", "arrow.clockwise")],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Клик открывает главный результат (первое действие); в тексте — что получилось.
    static func notesReady(title: String, results: [URL], quiet: Bool) {
        let names = results.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")
        post(title: title, body: "Готово: \(names)", category: Category.notes,
             info: ["path": results.first?.path ?? ""], sound: !quiet)
    }

    static func failed(title: String, dir: URL, partial: Bool, quiet: Bool) {
        post(title: title, body: partial ? "Часть действий не выполнилась" : "Не удалось сделать заметки",
             category: Category.failed,
             info: ["dir": dir.path, "title": title], sound: !quiet)
    }

    private static func post(title: String, body: String, category: String, info: [String: String], sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.setUp(delegate: self)
        MainActor.assumeIsolated { Hotkey.shared.apply() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppState.shared.stopRecording(reason: "выход из приложения") }
        return .terminateNow
    }

    // Показывать уведомления и когда приложение активно.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let info = content.userInfo
        let action = response.actionIdentifier
        let isDefault = action == UNNotificationDefaultActionIdentifier
        Task { @MainActor in
            let state = AppState.shared
            switch content.categoryIdentifier {
            case Notifier.Category.notes where isDefault:
                if let path = info["path"] as? String { state.open(URL(fileURLWithPath: path)) }
                state.notesSeen()
            case Notifier.Category.failed:
                guard let path = info["dir"] as? String else { break }
                let dir = URL(fileURLWithPath: path)
                if action == Notifier.Action.retry {
                    state.process(dir, title: info["title"] as? String ?? AppState.title(of: dir))
                } else if action == Notifier.Action.openLog || isDefault {
                    state.open(dir.appendingPathComponent("process.log"))
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
