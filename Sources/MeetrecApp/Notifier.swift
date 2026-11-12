import AppKit
import UserNotifications

/// Системные уведомления: «Начинается встреча — записать?» и «Заметки готовы».
enum Notifier {
    static let meetingCategory = "MEETING"
    static let notesCategory = "NOTES"
    static let recordAction = "RECORD"

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let record = UNNotificationAction(identifier: recordAction, title: "Записать", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: meetingCategory, actions: [record], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: notesCategory, actions: [], intentIdentifiers: [], options: []),
        ])
    }

    static func meetingStarted(_ event: MeetingEvent) {
        post(title: "Начинается: \(event.title)", body: "Записать встречу?", category: meetingCategory,
             info: ["eventID": event.id])
    }

    static func notesReady(title: String, notes: URL) {
        post(title: "Заметки готовы", body: title, category: notesCategory, info: ["path": notes.path])
    }

    static func failed(title: String, body: String) {
        post(title: title, body: body, category: notesCategory, info: [:])
    }

    private static func post(title: String, body: String, category: String, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.setUp(delegate: self)
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
        let action = response.actionIdentifier
        Task { @MainActor in
            switch content.categoryIdentifier {
            case Notifier.meetingCategory where action == Notifier.recordAction || action == UNNotificationDefaultActionIdentifier:
                AppState.shared.startRecording(for: AppState.shared.promptEvent)
            case Notifier.notesCategory where action == UNNotificationDefaultActionIdentifier:
                if let path = content.userInfo["path"] as? String {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            default:
                break
            }
            completionHandler()
        }
    }
}
