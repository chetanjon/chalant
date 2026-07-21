import AppKit
import Foundation

/// Turns plain sentences into done actions. Deterministic first:
/// verbs by prefix, dates by NSDataDetector, zero network, zero model.
/// Returns nil when a sentence is beyond local verbs, so the caller
/// can fall through to the optional key.
@MainActor
final class ActionEngine {
    private unowned let model: NotchViewModel

    init(model: NotchViewModel) {
        self.model = model
    }

    func handle(_ text: String) async -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Notes, fully local
        if lower.hasPrefix("note:") || lower.hasPrefix("note ") {
            let body = String(text.dropFirst(5))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return "Note what?" }
            model.notes.add(body)
            return "Noted."
        }
        if ["notes", "my notes", "show notes", "show my notes"].contains(lower) {
            return model.notes.rendered
        }
        if lower == "clear notes" {
            model.notes.clear()
            return "Notes cleared."
        }

        // Stops
        if ["stop focus", "end focus"].contains(lower) {
            model.focus.stop()
            return "Focus off."
        }
        if ["stop timer", "cancel timer"].contains(lower) {
            model.timer.stop()
            return "Timer off."
        }
        if ["stop noise", "quiet"].contains(lower) {
            model.ambience.stop()
            return "Quiet."
        }

        // Reminders you already have: list them, or tick one off. Run
        // before the create-reminder prefixes so "complete X" and
        // "my reminders" aren't mistaken for new reminders.
        if ["reminders", "my reminders", "what are my reminders",
            "show reminders", "show my reminders", "what's due", "whats due"].contains(lower) {
            return await model.events.remindersSummary()
        }
        for prefix in ["done with ", "complete ", "completed ", "finish ",
                       "finished ", "check off ", "tick off "]
        where lower.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return await model.events.completeByVoice(rest)
        }
        if lower.hasPrefix("mark ") {
            var rest = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            for suffix in [" as done", " as complete", " done", " complete", " off"]
            where rest.lowercased().hasSuffix(suffix) {
                rest = String(rest.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                return await model.events.completeByVoice(rest)
            }
        }

        // Reminders. Prefix verbs are unambiguous, so they run before
        // the fuzzy contains() branches below can hijack them. Spoken
        // phrasing varies, "set a reminder for X" must work as well as
        // "remind me to X".
        let reminderPrefixes = [
            "remind me to ", "remind me ", "remind ",
            "set a reminder ", "set reminder ",
            "add a reminder ", "add reminder ",
            "create a reminder ", "make a reminder ",
            "new reminder ", "reminder ",
        ]
        for prefix in reminderPrefixes where lower.hasPrefix(prefix) {
            var rest = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            var due: Date?
            if let (date, range) = Self.extractDate(rest) {
                due = date
                rest = Self.removing(range, from: rest)
            }
            for connector in ["to ", "for ", "about ", "that "]
            where rest.lowercased().hasPrefix(connector) {
                rest = String(rest.dropFirst(connector.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
            guard !rest.isEmpty else { return "Remind you to what?" }
            return await model.events.addReminder(rest, due: due)
        }

        // Calendar edits: cancel, move, undo. Exact stops ("cancel
        // timer") already matched above, so "cancel " here means an
        // event. Parses that don't pan out fall through to the model.
        if ["undo", "undo that", "bring it back", "put it back"].contains(lower) {
            return await model.events.undoLastEdit()
        }
        if lower.hasPrefix("cancel ") {
            let rest = String(text.dropFirst("cancel ".count))
                .trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                return await model.events.cancelEvent(rest)
            }
        }
        for prefix in ["move ", "push ", "reschedule ", "shift "]
        where lower.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            // "move design sync to 4pm": split on the last " to ",
            // parse the tail as a time ("at 4" handles the bare hour).
            if let range = rest.range(of: " to ", options: [.backwards, .caseInsensitive]) {
                let title = String(rest[..<range.lowerBound])
                let timePart = String(rest[range.upperBound...])
                if let (date, _) = Self.extractDate(timePart)
                    ?? Self.extractDate("at \(timePart)") {
                    // Saying "reminder" targets reminders; otherwise
                    // today's events get first claim, reminders catch
                    // the rest ("push dentist to tomorrow").
                    if title.lowercased().contains("reminder") {
                        return await model.events.rescheduleReminder(title, to: date)
                    }
                    if model.events.matchesEvent(title) {
                        return await model.events.moveEvent(title, to: date)
                    }
                    return await model.events.rescheduleReminder(title, to: date)
                }
                return "Move it to when? Try: move \(title.isEmpty ? "the meeting" : title) to 4pm."
            }
            // "push standup by 30 minutes"
            if let range = rest.range(of: " by ", options: [.backwards, .caseInsensitive]) {
                let title = String(rest[..<range.lowerBound])
                let tail = String(rest[range.upperBound...]).lowercased()
                if let amount = Self.firstNumber(in: tail) {
                    let seconds = tail.contains("hour") || tail.contains("hr")
                        ? amount * 3600 : amount * 60
                    return await model.events.moveEvent(title, by: TimeInterval(seconds))
                }
            }
        }

        // Calendar events: needs an explicit verb and a real date
        for prefix in ["schedule ", "put "] where lower.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard let (date, range) = Self.extractDate(rest) else { break }
            let title = Self.removing(range, from: rest)
            guard !title.isEmpty else { return "Schedule what?" }
            return await model.events.addEvent(title, start: date)
        }

        // Shortcuts: prefix verb, so it can't be hijacked by the fuzzy
        // branches below. "open github" hits a saved shortcut by name;
        // "open stripe.com" resolves cold.
        for prefix in ["open ", "go to ", "launch "] where lower.hasPrefix(prefix) {
            let name = String(lower.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return "Open what?" }
            if let shortcut = model.shortcuts.match(name) {
                model.shortcuts.open(shortcut)
                return "Opening \(shortcut.title)."
            }
            // An installed app by name: the summon key plus "open
            // slack" is a launcher with no setup at all.
            if let app = AppIndex.shared.lookup(name) {
                NSWorkspace.shared.openApplication(
                    at: app, configuration: .init(), completionHandler: nil
                )
                return "Opening \(app.deletingPathExtension().lastPathComponent)."
            }
            if let folder = Self.knownFolder(name) {
                NSWorkspace.shared.open(folder)
                return "Opening \(name.capitalized)."
            }
            if let url = ShortcutStore.resolvedURL(for: name) {
                NSWorkspace.shared.open(url)
                return "Opening."
            }
            return "Nothing called \"\(name)\", app or shortcut. Add it in the Go tab."
        }

        // Quit a running app by name. Never Moai itself.
        for prefix in ["quit ", "kill "] where lower.hasPrefix(prefix) {
            let name = String(lower.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return "Quit what?" }
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            let match = running.first { ($0.localizedName ?? "").lowercased() == name }
                ?? running.first { ($0.localizedName ?? "").lowercased().hasPrefix(name) }
                ?? running.first { ($0.localizedName ?? "").lowercased().contains(name) }
            guard let match else { return "Nothing called \"\(name)\" is running." }
            let title = match.localizedName ?? name
            match.terminate()
            return "Quit \(title)."
        }

        // System actions, spoken: the same four the Go grid offers.
        if ["screenshot", "take a screenshot", "grab a screenshot"].contains(lower) {
            SystemAction.screenshot.run()
            return "Crosshairs up. It lands on the clipboard."
        }
        if ["lock screen", "lock the screen", "lock my screen"].contains(lower) {
            SystemAction.lockScreen.run()
            return "Locked."
        }
        if ["dark mode", "light mode", "toggle dark mode", "switch appearance"].contains(lower) {
            SystemAction.darkMode.run()
            return "Appearance flipped."
        }
        if ["empty trash", "empty the trash", "take out the trash"].contains(lower) {
            SystemAction.emptyTrash.run()
            return "Trash emptied."
        }

        // Recall: one query across everything the island holds. This
        // is the thesis made literal, whatever you put here can be
        // found here.
        for prefix in ["find ", "where's ", "wheres ", "where is ", "look for "]
        where lower.hasPrefix(prefix) {
            let query = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return "Find what?" }
            return recall(query)
        }

        // Window snapping: the frontmost app answers. With the summon
        // key this is a window manager with no chrome at all.
        if ["left", "left half", "snap left", "window left"].contains(lower) {
            return WindowSnapper.snap(.left)
        }
        if ["right", "right half", "snap right", "window right"].contains(lower) {
            return WindowSnapper.snap(.right)
        }
        if ["maximize", "fill", "full screen", "fullscreen", "fill screen"].contains(lower) {
            return WindowSnapper.snap(.full)
        }
        if ["center", "center window", "middle"].contains(lower) {
            return WindowSnapper.snap(.center)
        }

        // Focus sessions
        if lower.contains("pomodoro") || lower.hasPrefix("focus") {
            let minutes = Self.firstNumber(in: lower) ?? 25
            model.focus.start(work: minutes)
            return "Focus on. \(minutes) minutes, brown noise. Say stop focus to end."
        }

        // Plain timers
        if lower.contains("timer") {
            let minutes = Self.firstNumber(in: lower) ?? 5
            model.timer.start(minutes: minutes)
            return "Timer on. \(minutes) minutes, counting in the notch."
        }

        // Standalone ambience. Token match for rain/cafe so "training"
        // or "cafeteria" can't trigger it.
        let words = Set(lower.split(separator: " ").map(String.init))
        if lower.contains("noise") || words.contains("rain")
            || words.contains("fire") || words.contains("fireplace")
            || words.contains("cafe") || lower.contains("coffee shop") {
            let color: NoiseEngine.NoiseColor =
                words.contains("rain") ? .rain :
                (words.contains("fire") || words.contains("fireplace")) ? .fire :
                (words.contains("cafe") || lower.contains("coffee")) ? .cafe :
                lower.contains("pink") ? .pink : .brown
            model.ambience.play(color)
            switch color {
            case .rain: return "Rain on. Say stop noise when done."
            case .fire: return "Fire on. Say stop noise when done."
            case .cafe: return "Cafe hum on. Say stop noise when done."
            default: return "\(color.rawValue.capitalized) noise on. Say stop noise when done."
            }
        }

        // Music transport, explicit verbs
        if ["play", "play music", "resume"].contains(lower) {
            model.music.play()
            return "Playing."
        }
        if ["pause", "pause music"].contains(lower) {
            model.music.pause()
            return "Paused."
        }
        if ["skip", "next", "next song"].contains(lower) {
            model.music.next()
            return "Skipped."
        }
        if ["previous", "back", "previous song"].contains(lower) {
            model.music.previous()
            return "Back one."
        }

        // The nearest event still ahead. Bare "next" stays music's.
        if ["what's next", "whats next", "what is next", "next up",
            "next meeting", "next event"].contains(lower) {
            return await model.events.nextSummary()
        }

        // Agenda, today or tomorrow
        let agendaish = ["agenda", "today", "tomorrow"].contains(lower)
            || lower.contains("calendar")
            || lower.contains("what's on") || lower.contains("whats on")
            || lower.contains("my agenda") || lower.contains("my schedule")
            || lower.contains("what's my day") || lower.contains("whats my day")
        if agendaish {
            return await model.events.agenda(dayOffset: lower.contains("tomorrow") ? 1 : 0)
        }

        // Reminder recovery: speech sometimes garbles the opening verb
        // ("said a reminder...") but keeps "remind(er)" intact somewhere.
        // Runs last so explicit verbs always win.
        let afterVerb: (rest: String, bare: Bool)? = {
            if let range = text.range(of: "reminder", options: .caseInsensitive) {
                let tail = String(text[range.upperBound...])
                // "reminders" is the plural noun ("show my reminders"),
                // not a save command.
                guard !tail.lowercased().hasPrefix("s") else { return nil }
                return (tail, false)
            }
            if let range = text.range(of: "remind", options: .caseInsensitive) {
                return (String(text[range.upperBound...]), true)
            }
            return nil
        }()
        if let (tail, bare) = afterVerb {
            var rest = tail.trimmingCharacters(in: .whitespaces)
            if bare, rest.lowercased().hasPrefix("me ") {
                rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            var due: Date?
            if let (date, range) = Self.extractDate(rest) {
                due = date
                rest = Self.removing(range, from: rest)
            }
            for connector in ["to ", "for ", "about ", "that "]
            where rest.lowercased().hasPrefix(connector) {
                rest = String(rest.dropFirst(connector.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
            guard !rest.isEmpty else { return "Remind you to what?" }
            return await model.events.addReminder(rest, due: due)
        }

        return nil
    }

    /// Search notes, clips, shelf, shortcuts, and the cached day for
    /// one query; answer with grouped hits. All local, all instant.
    /// Calendar and reminders search their cache only, so recall
    /// never raises a permission prompt.
    private func recall(_ query: String) -> String {
        let q = query.lowercased()
        var lines: [String] = []

        func clip(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            return flat.count > 64 ? String(flat.prefix(64)) + "…" : flat
        }

        for note in model.notes.notes
        where note.text.lowercased().contains(q) {
            lines.append("note · \(clip(note.text))")
        }
        for item in model.clipboard.clips
        where (item.text ?? "").lowercased().contains(q) {
            lines.append("clip · \(clip(item.text ?? ""))")
        }
        for item in model.shelf.items
        where item.name.lowercased().contains(q) {
            lines.append("file · \(item.name)")
        }
        for shortcut in model.shortcuts.shortcuts
        where shortcut.title.lowercased().contains(q) {
            lines.append("go · \(shortcut.title)")
        }
        for event in model.events.events
        where event.title.lowercased().contains(q) {
            lines.append("today · \(event.title), \(event.time)")
        }
        for reminder in model.events.reminders
        where reminder.title.lowercased().contains(q) {
            lines.append("reminder · \(reminder.title)")
        }

        guard !lines.isEmpty else {
            return "Nothing on the island matching \"\(query)\"."
        }
        return lines.prefix(8).joined(separator: "\n")
    }

    /// The home folders people ask for by name. Apps win first, so
    /// "open music" is the app and "open downloads" is the folder.
    private static func knownFolder(_ name: String) -> URL? {
        let fm = FileManager.default
        func standard(_ directory: FileManager.SearchPathDirectory) -> URL? {
            fm.urls(for: directory, in: .userDomainMask).first
        }
        switch name {
        case "downloads": return standard(.downloadsDirectory)
        case "documents": return standard(.documentDirectory)
        case "desktop": return standard(.desktopDirectory)
        case "pictures": return standard(.picturesDirectory)
        case "movies": return standard(.moviesDirectory)
        case "home", "home folder": return fm.homeDirectoryForCurrentUser
        case "applications": return URL(fileURLWithPath: "/Applications")
        default: return nil
        }
    }

    // MARK: - Parsing helpers

    private static func firstNumber(in text: String) -> Int? {
        let digits = text.split(whereSeparator: { !$0.isNumber })
        return digits.first.flatMap { Int($0) }
    }

    private static func extractDate(_ text: String) -> (Date, NSRange)? {
        if let relative = relativeTime(text) {
            return relative
        }
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = detector.matches(in: text, range: range).first,
               let date = match.date {
                return (rollForwardIfPast(date), match.range)
            }
        }
        return bareHourTime(text)
    }

    /// Spoken relative times, "in 20 minutes", "in an hour", which
    /// NSDataDetector handles unreliably.
    private static func relativeTime(_ text: String) -> (Date, NSRange)? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\bin (\\d{1,3}|a|an) ?(minutes|minute|mins|min|hours|hour|hrs|hr)\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ) else { return nil }
        let amountText = nsText.substring(with: match.range(at: 1)).lowercased()
        let amount = Int(amountText) ?? 1
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        let seconds = unit.hasPrefix("h") ? amount * 3600 : amount * 60
        guard seconds > 0 else { return nil }
        return (Date().addingTimeInterval(TimeInterval(seconds)), match.range)
    }

    /// NSDataDetector misses bare hours ("at 6"). Resolve them to the
    /// next future occurrence, trying both AM and PM when unspecified.
    private static func bareHourTime(_ text: String) -> (Date, NSRange)? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\bat (\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ), let hour = Int(nsText.substring(with: match.range(at: 1))),
           (1...23).contains(hour) else { return nil }
        let minute = match.range(at: 2).location == NSNotFound
            ? 0 : Int(nsText.substring(with: match.range(at: 2))) ?? 0
        var meridiem: String?
        if match.range(at: 3).location != NSNotFound {
            meridiem = nsText.substring(with: match.range(at: 3)).lowercased()
        }

        var hours: [Int]
        if let meridiem {
            hours = [meridiem == "pm" ? hour % 12 + 12 : hour % 12]
        } else if hour > 12 {
            hours = [hour]
        } else {
            hours = [hour % 12, hour % 12 + 12]
        }

        let calendar = Calendar.current
        let now = Date()
        let candidates: [Date] = hours.compactMap { h in
            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            comps.hour = h
            comps.minute = minute
            guard let date = calendar.date(from: comps) else { return nil }
            return date > now
                ? date
                : calendar.date(byAdding: .day, value: 1, to: date)
        }
        guard let date = candidates.min() else { return nil }
        return (date, match.range)
    }

    /// A same-day time that already passed makes a dead alarm.
    /// Push it to tomorrow.
    private static func rollForwardIfPast(_ date: Date) -> Date {
        guard date <= Date() else { return date }
        return Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
    }

    /// Drop the matched date words plus dangling connectors ("at", "on").
    private static func removing(_ range: NSRange, from text: String) -> String {
        let nsText = text as NSString
        var result = nsText.replacingCharacters(in: range, with: "")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        for connector in ["at", "on", "for", "by"] {
            if result.lowercased().hasSuffix(" \(connector)") {
                result = String(result.dropLast(connector.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}
