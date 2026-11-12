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

final class CalendarService {
    private let store = EKEventStore()
    private(set) var authorized = false

    func requestAccess() async -> Bool {
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
        return authorized
    }

    /// Текущая (уже идущая) или ближайшая встреча в ближайшие 24 часа.
    /// Без весь-день-событий, отменённых и тех, от которых я отказался.
    func currentOrNext(now: Date = Date()) -> MeetingEvent? {
        guard authorized else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(24 * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !Self.declinedByMe($0) }
            .sorted { $0.startDate < $1.startDate }
            .first
            .map(Self.makeEvent)
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
