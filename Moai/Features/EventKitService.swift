import EventKit
import Foundation

/// A calendar event, flattened for the glance.
struct DayEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// A recognized video-call link found in the event, if any.
    let joinURL: URL?

    init(ek: EKEvent) {
        id = ek.eventIdentifier ?? UUID().uuidString
        title = ek.title ?? "Untitled"
        start = ek.startDate
        end = ek.endDate ?? ek.startDate.addingTimeInterval(3600)
        isAllDay = ek.isAllDay
        joinURL = DayEvent.meetingURL(in: ek)
    }

    var time: String {
        if isAllDay { return "all day" }
        return DayEvent.timeFormatter.string(from: start)
    }

    /// Minutes until start, as glance copy: "12m", then "now".
    func countdown(from now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "now" : "\(minutes)m"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// First link pointing at a known meeting host, searched in the
    /// event's URL, location, then notes. NSDataDetector keeps it
    /// deterministic and offline, same as date parsing elsewhere.
    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com",
        "webex.com", "facetime.apple.com", "meet.jit.si",
    ]

    static func meetingURL(in event: EKEvent) -> URL? {
        var haystacks: [String] = []
        if let url = event.url?.absoluteString { haystacks.append(url) }
        if let location = event.location { haystacks.append(location) }
        if let notes = event.notes { haystacks.append(notes) }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        for text in haystacks {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url, let host = url.host else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                    return url
                }
            }
        }
        return nil
    }
}

/// An open reminder, flattened for the glance.
struct OpenReminder: Identifiable {
    let id: String
    let title: String
    let due: Date?
}

private extension String {
    /// Strip any of these leading phrases, then trim.
    func removingPrefixes(_ prefixes: [String]) -> String {
        var result = self
        for prefix in prefixes where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
final class EventKitService: ObservableObject {
    private let store = EKEventStore()
    private var remindersGranted = false
    private var eventsGranted = false

    /// Live data for the Today glance. Empty until `refresh()` runs.
    @Published private(set) var events: [DayEvent] = []
    @Published private(set) var reminders: [OpenReminder] = []

    /// The event about to start (within half an hour, until shortly
    /// after it begins), for the collapsed glance. Only set while the
    /// Calendar block is on and access is already granted; the glance
    /// itself never triggers a permission prompt.
    @Published private(set) var nextEvent: DayEvent?

    private var glanceTimer: Timer?

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
            .map { DayEvent(ek: $0) }
        recomputeNext()
    }

    // MARK: - Upcoming-event glance

    /// The meeting "join" should reach for. One about to begin wins
    /// over one running long (at 10:58 with the 11:00 on the glance,
    /// "join" means the 11:00, not the standup's tail); otherwise a
    /// running meeting wins (a late join is the verb's whole use);
    /// otherwise today's next linked one. EventKit returns events
    /// unsorted, so sort before any first-wins pick (review-caught).
    /// Fetches on its own, like agenda: saying "join" IS the ask, so
    /// the Today block's privacy gate (which governs the ambient
    /// glance cache) does not apply here.
    func joinableEvent(at now: Date = Date()) async -> DayEvent? {
        guard await ensureEvents() else { return nil }
        let calendar = Calendar.current
        guard let dayEnd = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ) else { return nil }
        let predicate = store.predicateForEvents(
            withStart: now, end: dayEnd, calendars: nil
        )
        let linked = store.events(matching: predicate)
            .map(DayEvent.init(ek:))
            .filter { $0.joinURL != nil && !$0.isAllDay && $0.end > now }
            .sorted { $0.start < $1.start }
        if let imminent = linked.first(where: {
            $0.start > now && $0.start.timeIntervalSince(now) <= 300
        }) {
            return imminent
        }
        if let running = linked.first(where: { $0.start <= now }) {
            return running
        }
        return linked.first { $0.start > now }
    }

    /// Keep `nextEvent` current: a slow timer for the passage of time,
    /// plus the store's change notification for edits made elsewhere.
    func startGlanceTicker() {
        recomputeNext()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeNext() }
        }
        timer.tolerance = 5
        glanceTimer = timer
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputeNext() }
        }
    }

    private func recomputeNext() {
        // Status is read without asking: the collapsed island must never
        // be the thing that pops a permission dialog.
        guard UserDefaults.standard.bool(forKey: "showCalendar"),
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            if nextEvent != nil { nextEvent = nil }
            return
        }
        let now = Date()
        let calendar = Calendar.current
        guard let dayEnd = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ) else { return }
        // Two minutes of grace after start, so "now" lingers a beat
        // instead of vanishing the second the meeting begins.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-120), end: dayEnd, calendars: nil
        )
        let upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate.timeIntervalSince(now) > -120 }
            .sorted { $0.startDate < $1.startDate }
            .first
        let next: DayEvent? = upcoming.flatMap { ek in
            guard ek.startDate.timeIntervalSince(now) <= 30 * 60 else { return nil }
            return DayEvent(ek: ek)
        }
        // Publish only real changes; every set re-renders the island.
        if next != nextEvent { nextEvent = next }
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

    /// Settings key holding the chosen destination list's identifier.
    /// Empty means automatic (the system default list).
    static let reminderListKey = "reminderListID"

    /// Writable reminder lists for the settings picker, labeled with
    /// their account so two lists named "Reminders" stay tellable
    /// apart. Empty until access has been granted; enumerating must
    /// never be the thing that pops the permission dialog.
    func availableReminderLists() -> [(title: String, id: String)] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return []
        }
        return store.calendars(for: .reminder)
            .filter { $0.allowsContentModifications }
            .map { ("\($0.title) · \($0.source.title)", $0.calendarIdentifier) }
    }

    func addReminder(_ title: String, due: Date?) async -> String {
        guard await ensureReminders() else {
            return "Reminders access is off. System Settings, Privacy, Reminders."
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        // The user's chosen list wins; automatic falls to the system
        // default. No default list is a real configuration on Macs
        // without iCloud Reminders, fall back to any writable list.
        let chosenID = UserDefaults.standard.string(forKey: Self.reminderListKey) ?? ""
        let chosen = chosenID.isEmpty ? nil : store.calendars(for: .reminder)
            .first { $0.calendarIdentifier == chosenID && $0.allowsContentModifications }
        guard let calendar = chosen
            ?? store.defaultCalendarForNewReminders()
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
        // Name the list: a reminder that lands in an unexpected list,
        // or an undated one hiding from the Today smart list, reads
        // as "it never saved" without this one word of truth.
        if let due {
            return "Set. \(Self.formatter.string(from: due))."
                + " In \(calendar.title) (\(calendar.source.title))."
        }
        return "Set in \(calendar.title) (\(calendar.source.title)),"
            + " no time attached, it won't ring. Add one like \"at 6\" next time."
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

    // MARK: - Voice edits (cancel, move, undo)

    /// The most recent voice edit, held so "undo" can reverse it.
    private enum LastEdit {
        case cancelled(title: String, start: Date, end: Date, location: String?, notes: String?)
        case moved(id: String, title: String, from: Date, fromEnd: Date)
    }

    private var lastEdit: LastEdit?

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Today's events, fetched fresh for matching.
    private func todaysEKEvents() -> [EKEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    /// The week ahead, for the edit verbs: "cancel dentist" said the
    /// moment after scheduling tomorrow's dentist must find it
    /// (dogfood-caught; create spans any day, cancel searched today).
    private func weekEKEvents() -> [EKEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    /// Resolve spoken words to an event this week, soonest first.
    /// "Next meeting" takes the nearest one ahead; a title matches
    /// loosely in either direction; a bare time ("the 3pm") matches
    /// by start hour. Upcoming events win over finished ones on ties.
    private func resolveEvent(_ raw: String) -> EKEvent? {
        let query = raw.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .removingPrefixes(["my ", "the "])
        let events = weekEKEvents()
        let now = Date()
        let upcoming = events.filter { $0.startDate.timeIntervalSince(now) > -120 }

        if ["next", "next meeting", "next event", "next one"].contains(query) {
            return upcoming.first { !$0.isAllDay } ?? upcoming.first
        }
        let titleMatch: (EKEvent) -> Bool = { event in
            let title = (event.title ?? "").lowercased()
            return !title.isEmpty && (title.contains(query) || query.contains(title))
        }
        if let hit = upcoming.first(where: titleMatch) ?? events.first(where: titleMatch) {
            return hit
        }
        // "the 3pm": a bare hour, matched against start times.
        let bare = query.removingPrefixes(["at "])
        if let hour = Self.spokenHour(bare) {
            return upcoming.first { Calendar.current.component(.hour, from: $0.startDate) % 12 == hour % 12 }
                ?? events.first { Calendar.current.component(.hour, from: $0.startDate) % 12 == hour % 12 }
        }
        return nil
    }

    /// "3", "3pm", "3 o'clock" as an hour, nil for anything wordier.
    private static func spokenHour(_ text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "o'clock", with: "")
            .replacingOccurrences(of: "oclock", with: "")
            .replacingOccurrences(of: "pm", with: "")
            .replacingOccurrences(of: "am", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let hour = Int(cleaned), (1...23).contains(hour) else { return nil }
        return hour
    }

    /// Cancel one of today's events by voice. Only ever this one
    /// occurrence, never a whole series.
    func cancelEvent(_ query: String) async -> String {
        guard await ensureEvents() else {
            return "Calendar access is off. System Settings, Privacy, Calendars."
        }
        guard let event = resolveEvent(query) else {
            return "No event this week matching \"\(query)\"."
        }
        let title = event.title ?? "Untitled"
        lastEdit = .cancelled(
            title: title,
            start: event.startDate,
            end: event.endDate ?? event.startDate.addingTimeInterval(3600),
            location: event.location,
            notes: event.notes
        )
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            lastEdit = nil
            return "Couldn't cancel that. \(error.localizedDescription)"
        }
        await reloadEvents()
        let clock = Self.formatter.string(from: event.startDate)
        return "Cancelled \(title), \(clock). Say undo if that was wrong."
    }

    /// Move one of today's events to a new start, keeping its length.
    func moveEvent(_ query: String, to newStart: Date) async -> String {
        guard await ensureEvents() else {
            return "Calendar access is off. System Settings, Privacy, Calendars."
        }
        guard let event = resolveEvent(query) else {
            return "No event this week matching \"\(query)\"."
        }
        let title = event.title ?? "Untitled"
        guard let oldStart = event.startDate else {
            return "No event this week matching \"\(query)\"."
        }
        let oldEnd = event.endDate ?? oldStart.addingTimeInterval(3600)
        let duration = oldEnd.timeIntervalSince(oldStart)
        event.startDate = newStart
        event.endDate = newStart.addingTimeInterval(duration)
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return "Couldn't move that. \(error.localizedDescription)"
        }
        lastEdit = .moved(
            id: event.eventIdentifier ?? "",
            title: title, from: oldStart, fromEnd: oldEnd
        )
        await reloadEvents()
        return "Moved \(title) to \(Self.formatter.string(from: newStart))."
    }

    /// Nudge one of today's events by a delta ("push it by 30 minutes").
    func moveEvent(_ query: String, by delta: TimeInterval) async -> String {
        guard await ensureEvents() else {
            return "Calendar access is off. System Settings, Privacy, Calendars."
        }
        guard let event = resolveEvent(query), let start = event.startDate else {
            return "No event this week matching \"\(query)\"."
        }
        return await moveEvent(query, to: start.addingTimeInterval(delta))
    }

    /// Reverse the most recent voice edit, one step only.
    func undoLastEdit() async -> String {
        guard await ensureEvents() else {
            return "Calendar access is off. System Settings, Privacy, Calendars."
        }
        guard let edit = lastEdit else { return "Nothing to undo." }
        lastEdit = nil
        switch edit {
        case .cancelled(let title, let start, let end, let location, let notes):
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.location = location
            event.notes = notes
            guard let calendar = store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications })
            else { return "No calendar to put it back into." }
            event.calendar = calendar
            do {
                try store.save(event, span: .thisEvent)
            } catch {
                return "Couldn't bring it back. \(error.localizedDescription)"
            }
            await reloadEvents()
            return "Back on. \(title), \(Self.clockFormatter.string(from: start))."
        case .moved(let id, let title, let from, let fromEnd):
            guard let event = store.event(withIdentifier: id) else {
                return "That event is gone; nothing to move back."
            }
            event.startDate = from
            event.endDate = fromEnd
            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                return "Couldn't move it back. \(error.localizedDescription)"
            }
            await reloadEvents()
            return "Moved \(title) back to \(Self.clockFormatter.string(from: from))."
        }
    }

    /// Spoken answer for "what's next": the nearest event still ahead
    /// of you today, whether or not it is close enough for the glance.
    func nextSummary() async -> String {
        guard await ensureEvents() else {
            return "Calendar access is off. System Settings, Privacy, Calendars."
        }
        let now = Date()
        let calendar = Calendar.current
        guard let dayEnd = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ) else { return "Nothing else today. Clear water." }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-120), end: dayEnd, calendars: nil
        )
        guard let ek = store.events(matching: predicate)
            .filter({ !$0.isAllDay && $0.startDate.timeIntervalSince(now) > -120 })
            .sorted(by: { $0.startDate < $1.startDate })
            .first
        else { return "Nothing else today. Clear water." }
        let event = DayEvent(ek: ek)
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let clock = timeFormatter.string(from: event.start)
        if minutes <= 0 {
            return "\(event.title), on now."
        }
        if minutes < 60 {
            return "\(event.title) in \(minutes) minute\(minutes == 1 ? "" : "s"), at \(clock)."
        }
        return "\(event.title) at \(clock)."
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

    /// True when spoken words resolve to one of today's events, used
    /// to route "push X to 4" between calendar and reminders. Never
    /// prompts: without access the store just matches nothing.
    func matchesEvent(_ query: String) -> Bool {
        resolveEvent(query) != nil
    }

    /// Move an open reminder to a new due time, alarm included.
    func rescheduleReminder(_ raw: String, to due: Date) async -> String {
        guard await ensureReminders() else {
            return "Reminders access is off. System Settings, Privacy, Reminders."
        }
        await reloadReminders()
        let query = raw.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .removingPrefixes(["my ", "the "])
            .replacingOccurrences(of: " reminder", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Move which reminder?" }
        guard let match = reminders.first(where: {
            let title = $0.title.lowercased()
            return title.contains(query) || query.contains(title)
        }) else {
            return "No open reminder matching \"\(raw)\"."
        }
        guard let ek = store.calendarItem(withIdentifier: match.id) as? EKReminder else {
            return "That reminder slipped away; open Reminders once and retry."
        }
        ek.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due
        )
        ek.alarms?.forEach { ek.removeAlarm($0) }
        ek.addAlarm(EKAlarm(absoluteDate: due))
        do {
            try store.save(ek, commit: true)
        } catch {
            return "Couldn't move that. \(error.localizedDescription)"
        }
        await reloadReminders()
        return "Moved \(match.title). \(Self.formatter.string(from: due))."
    }

    /// Complete the open reminder whose title best matches spoken text.
    func completeByVoice(_ query: String) async -> String {
        await reloadReminders()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return "Complete which one?" }
        // Best match, not first match: exact title, then the closest
        // containment. "done with cooking dinner" must never tick off
        // a sibling called "cook" (it did, live).
        let candidates = reminders.filter {
            let title = $0.title.lowercased()
            return title == q || title.contains(q) || q.contains(title)
        }
        let match = candidates.first { $0.title.lowercased() == q }
            ?? candidates.min { lhs, rhs in
                abs(lhs.title.count - q.count) < abs(rhs.title.count - q.count)
            }
        guard let match else {
            return "No open reminder matching \"\(query)\"."
        }
        await complete(match)
        return "Done, \(match.title)."
    }
}
