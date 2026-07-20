import EventKit
import Foundation

/// A calendar event, flattened for the glance.
struct DayEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let isAllDay: Bool

    var time: String {
        if isAllDay { return "all day" }
        return DayEvent.timeFormatter.string(from: start)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}

/// An open reminder, flattened for the glance.
struct OpenReminder: Identifiable {
    let id: String
    let title: String
    let due: Date?
}

@MainActor
final class EventKitService: ObservableObject {
    private let store = EKEventStore()
    private var remindersGranted = false
    private var eventsGranted = false

    /// Live data for the Today glance. Empty until `refresh()` runs.
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var reminders: [OpenReminder] = []

    /// Access was asked for and refused; the glance says so instead
    /// of showing an empty day.
    @Published private(set) var calendarDenied = false
    @Published private(set) var remindersDenied = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter
    }()

    private func ensureReminders() async -> Bool {
        if remindersGranted { return true }
        remindersGranted = (try? await store.requestFullAccessToReminders()) ?? false
        return remindersGranted
    }

    private func ensureEvents() async -> Bool {
        if eventsGranted { return true }
        eventsGranted = (try? await store.requestFullAccessToEvents()) ?? false
        return eventsGranted
    }

    // MARK: - Live glance data

    /// Reload both feeds. The Today view calls this when it appears and
    /// after any change, so the glance always matches reality.
    func refresh() async {
        await reloadEvents()
        await reloadReminders()
    }

    private func reloadEvents() async {
        let granted = await ensureEvents()
        calendarDenied = !granted
        guard granted else { events = []; return }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                DayEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    isAllDay: $0.isAllDay
                )
            }
    }

    private func reloadReminders() async {
        let granted = await ensureReminders()
        remindersDenied = !granted
        guard granted else { reminders = []; return }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        let calendar = Calendar.current
        let endOfToday = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())
        )!
        func dueDate(_ reminder: EKReminder) -> Date? {
            reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
        }
        reminders = fetched
            // Due today or overdue, plus anything undated, the glance is
            // "what's open now", not the whole backlog.
            .filter { reminder in
                guard let due = dueDate(reminder) else { return true }
                return due < endOfToday
            }
            .sorted {
                (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture)
            }
            .prefix(6)
            .map {
                OpenReminder(
                    id: $0.calendarItemIdentifier,
                    title: $0.title ?? "Untitled",
                    due: dueDate($0)
                )
            }
    }

    /// Tick a reminder off from the glance.
    func complete(_ reminder: OpenReminder) async {
        guard await ensureReminders() else { return }
        if let ek = store.calendarItem(withIdentifier: reminder.id) as? EKReminder {
            ek.isCompleted = true
            try? store.save(ek, commit: true)
        }
        await reloadReminders()
    }

    // MARK: - Writes

    func addReminder(_ title: String, due: Date?) async -> String {
        guard await ensureReminders() else {
            return "Reminders access is off. System Settings, Privacy, Reminders."
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        // No default list is a real configuration on Macs without
        // iCloud Reminders, fall back to any writable list.
        guard let calendar = store.defaultCalendarForNewReminders()
            ?? store.calendars(for: .reminder).first(where: { $0.allowsContentModifications })
        else {
            return "No Reminders list to save into. Open the Reminders app once, then retry."
        }
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return "Couldn't save that. \(error.localizedDescription)"
        }
        await reloadReminders()
        if let due {
            return "Set. \(Self.formatter.string(from: due))."
        }
        return "Set, no time attached, it won't ring. Add one like \"at 6\" next time."
    }

    func addEvent(_ title: String, start: Date) async -> String {
        guard await ensureEvents() else {
            return "Calendar access is off. System Settings, Privacy, Calendars."
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        guard let calendar = store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications })
        else {
            return "No calendar to save into. Open the Calendar app once, then retry."
        }
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            return "Couldn't save that. \(error.localizedDescription)"
        }
        await reloadEvents()
        return "On the calendar. \(Self.formatter.string(from: start))."
    }

    // MARK: - Voice summaries

    func agendaToday() async -> String { await agenda(dayOffset: 0) }

    /// Spoken agenda for today (0) or tomorrow (1).
    func agenda(dayOffset: Int) async -> String {
        guard await ensureEvents() else {
            return "Calendar access is off. System Settings, Privacy, Calendars."
        }
        let calendar = Calendar.current
        let day = calendar.date(
            byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: Date())
        )!
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else {
            return "Nothing."
        }
        let predicate = store.predicateForEvents(withStart: day, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
        let label = dayOffset == 0 ? "today" : dayOffset == 1 ? "tomorrow" : "then"
        guard !events.isEmpty else { return "Nothing \(label). Clear water." }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        return events
            .map { "\(timeFormatter.string(from: $0.startDate))  \($0.title ?? "Untitled")" }
            .joined(separator: "\n")
    }

    /// Spoken list of what's open right now.
    func remindersSummary() async -> String {
        await reloadReminders()
        guard !reminders.isEmpty else { return "No open reminders. Clear water." }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        return reminders.map { reminder in
            if let due = reminder.due {
                return "☐ \(reminder.title), \(timeFormatter.string(from: due))"
            }
            return "☐ \(reminder.title)"
        }.joined(separator: "\n")
    }

    /// Complete the open reminder whose title best matches spoken text.
    func completeByVoice(_ query: String) async -> String {
        await reloadReminders()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return "Complete which one?" }
        guard let match = reminders.first(where: {
            let title = $0.title.lowercased()
            return title.contains(q) || q.contains(title)
        }) else {
            return "No open reminder matching \"\(query)\"."
        }
        await complete(match)
        return "Done, \(match.title)."
    }
}
