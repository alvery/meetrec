import EventKit
import Foundation

/// Встреча из календаря macOS (туда же синхронизируется Google Calendar через «Учётные записи интернета»).
struct MeetingEvent: Identifiable, Equatable {
    let id: String          // eventIdentifier + время начала (повторяющиеся встречи различаются)
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?
    let attendees: [String]

    func isInProgress(at now: Date = Date()) -> Bool { start <= now && now < end }
}

@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private(set) var authorized = false

    func requestAccess() async -> Bool {
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
        return authorized
    }

    /// Перепроверить доступ (пользователь мог включить его в Системных настройках без перезапуска).
    func refreshAuthorization() -> Bool {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        return authorized
    }

    /// Главная встреча (идущая или ближайшая) и следующая за ней.
    func upcoming(now: Date = Date()) -> (main: MeetingEvent?, following: MeetingEvent?) {
        guard let main = currentOrNext(now: now) else { return (nil, nil) }
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let following = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declinedByMe($0) && $0.startDate > max(now, main.start) }
            .map(Self.makeEvent)
            .filter { $0.id != main.id }
            .min { $0.start < $1.start }
        return (main, following)
    }

    /// Текущая (уже идущая) или ближайшая встреча в ближайшие 24 часа.
    /// Без весь-день-событий, отменённых и тех, от которых я отказался.
    /// Из идущих — со ссылкой на созвон, затем начавшаяся позже всех: длинный блок
    /// «Focus 13–17» не должен закрывать созвон в 14:00.
    func currentOrNext(now: Date = Date()) -> MeetingEvent? {
        guard authorized else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !Self.declinedByMe($0) }
            .map(Self.makeEvent)
        let current = events.filter { $0.isInProgress(at: now) }
            .sorted { a, b in
                if (a.joinURL != nil) != (b.joinURL != nil) { return a.joinURL != nil }
                return a.start > b.start
            }
        if let best = current.first { return best }
        return events.filter { $0.start > now }.min { $0.start < $1.start }
    }

    private static func declinedByMe(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    private static func makeEvent(_ e: EKEvent) -> MeetingEvent {
        let attendees = (e.attendees ?? []).compactMap { p -> String? in
            if let name = p.name, !name.isEmpty { return name }
            let s = p.url.absoluteString
            return s.hasPrefix("mailto:") ? String(s.dropFirst(7)) : nil
        }
        return MeetingEvent(
            id: "\(e.eventIdentifier ?? e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))",
            title: e.title?.isEmpty == false ? e.title! : "Встреча",
            start: e.startDate, end: e.endDate,
            joinURL: joinLink([e.url?.absoluteString, e.location, e.notes]),
            attendees: attendees)
    }

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"https://(?:[\w-]+\.)*(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com)/[^\s<>"')\]]+"#,
        options: [.caseInsensitive])

    /// Ссылка Zoom / Meet / Teams из URL, места или описания события.
    static func joinLink(_ sources: [String?]) -> URL? {
        for case let text? in sources {
            let range = NSRange(text.startIndex..., in: text)
            if let m = linkRegex.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }
}
