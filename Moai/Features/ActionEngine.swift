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

    func handle(_ raw: String) async -> String? {
        // Speech hands over sentences with trailing punctuation and
        // doubled spaces; a period kills every exact-match verb. It
        // also hands over manners ("hey can you add a reminder for
        // walking"), which must never defeat the verb underneath.
        let text = Self.strippedOfPleasantries(Self.sanitized(raw))
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // A staged message answers before anything else. The contract
        // read back to the user is "say send, or anything else to
        // drop it", and the gate holds it literally: an utterance
        // whose words include "send" without a negation fires it
        // ("send", "yes send it", "okay send that"); everything else
        // drops it. Bare "yes" is NOT consent for an outward message;
        // it once was, and that was a sent-unconfirmed bug waiting.
        if model.courier.pending != nil {
            let words = Set(lower.split(separator: " ").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: ",."))
            })
            let negated = ["don't", "dont", "not", "never", "no"]
                .contains(where: words.contains)
            if words.contains("send"), !negated {
                model.isWorking = true
                let outcome = await model.courier.confirmSend()
                model.isWorking = false
                return outcome
            }
            model.courier.drop()
            if ["cancel", "don't send", "dont send", "do not send", "no",
                "drop it", "never mind", "nevermind"].contains(lower) {
                return "Dropped."
            }
            // Any other command drops it silently on the way through.
        } else if ["send", "send it"].contains(lower) {
            return "Nothing staged to send."
        } else if ["cancel", "never mind", "nevermind"].contains(lower) {
            // Bare "cancel" reaches for whatever is running before it
            // admits there is nothing; it used to say "Nothing to
            // cancel." over a live timer.
            if model.timer.isActive {
                model.timer.stop()
                return "Timer off."
            }
            if model.focus.isActive {
                model.focus.stop()
                return "Focus off."
            }
            if model.stopwatch.isActive {
                model.stopwatch.reset()
                return "Stopwatch cleared."
            }
            if model.ambience.active != nil {
                model.ambience.stop()
                return "Quiet."
            }
            return "Nothing to cancel."
        }

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

        // The cheat sheet, for anyone who forgets the words.
        if ["help", "commands", "what can you do", "what can i say",
            "what do you do"].contains(lower) {
            return Self.cheatSheet
        }

        // The trail: what was heard, what happened. Turns every
        // "it did nothing" into something readable.
        if ["voice log", "what did you hear", "voice history"].contains(lower) {
            return model.voiceLogRendered
        }

        // The screen, read into context: one shot of the front
        // window, on-device OCR, and the words ride the same attach
        // pipeline as a dropped file. One-shot forms ("summarize my
        // screen", "translate my screen to hindi") attach and return
        // nil so the normal fallback streams the answer in the same
        // breath. Deliberate on purpose: a leading intent verb AND a
        // screen mention that is either a suffix or the possessive
        // "my screen" mid-utterance; "the screen recording" and
        // screenplays never fire a capture (review-caught). One
        // capture total: the old shape ran capture and OCR twice on
        // any wordless window.
        let screenMention = lower.hasSuffix(" my screen")
            || lower.hasSuffix(" the screen")
            || lower.contains(" my screen ")
        let screenOneShot = screenMention &&
            ["summarize ", "explain ", "translate ", "describe ", "tldr "]
                .contains(where: lower.hasPrefix)
        let screenRead = ["read my screen", "read the screen", "read screen",
                          "what's on my screen", "whats on my screen",
                          "what's on the screen", "whats on the screen",
                          "look at my screen", "ask about my screen"].contains(lower)
        if screenOneShot || screenRead {
            // The words are only ever consumed by the on-device
            // model; capturing without it wasted seconds and then
            // promised "ask away" into a dead end (review-caught).
            guard AIService.localModelAvailable else {
                return "Reading the screen needs Apple Intelligence, System Settings, Apple Intelligence and Siri. The Chat tab carries your own Claude, ChatGPT, or Gemini meanwhile."
            }
            guard ScreenReader.preflight() else {
                ScreenReader.requestGrant()
                return "macOS is asking about Screen Recording. Allow it (a relaunch may be needed), then say it again. The reading stays on this Mac."
            }
            model.isWorking = true
            let outcome = await ScreenReader.readFrontWindow()
            model.isWorking = false
            switch outcome {
            case .text(let app, let words):
                model.pendingContext = (
                    name: "\(app)'s window",
                    text: String(words.prefix(6000))
                )
                if screenOneShot {
                    // The trail must say the capture happened; "no
                    // verb matched" over a matched verb was a lie
                    // (review-caught).
                    model.logVoice(text, outcome: "read \(app)'s window into context")
                    return nil
                }
                let count = words.split(separator: "\n").count
                return "Read \(count) lines from \(app). Ask away; the words stay on this Mac."
            case .empty(let app):
                return "\(app)'s window came back wordless. Text-light windows read as pictures."
            case .noWindow:
                return "No readable window up front."
            case .failed:
                return "The capture didn't land. Say it again."
            case .denied, .needsGrant:
                return "Screen Recording isn't allowed yet. System Settings, Privacy and Security, Screen Recording, then relaunch Moai."
            }
        }

        // One word into the meeting: the Today row chip's spoken twin.
        if ["join", "join meeting", "join the meeting", "join my meeting",
            "join call", "join the call", "join my call"].contains(lower) {
            guard let event = await model.events.joinableEvent(),
                  let url = event.joinURL else {
                return "Nothing on the calendar to join. A meeting needs a link I recognize."
            }
            NSWorkspace.shared.open(url)
            return "Joining \(event.title)."
        }

        // The island's own changelog, read from the latest release.
        if ["what's new", "whats new", "what is new", "changelog",
            "what changed", "release notes"].contains(lower) {
            model.isWorking = true
            let notes = await model.updates.latestNotes()
            model.isWorking = false
            return notes ?? "Couldn't reach the release notes. Check the network, then ask again."
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
        // Dictation and plain typing both write "stop watch" as two
        // words; join them so the watch's verbs never wander to the
        // model as strangers.
        let watch = lower.replacingOccurrences(of: "stop watch", with: "stopwatch")
        if ["stop stopwatch", "stop the stopwatch", "stopwatch stop",
            "pause stopwatch", "pause the stopwatch"].contains(watch) {
            guard model.stopwatch.isActive else { return "No stopwatch running." }
            guard model.stopwatch.isRunning else {
                return "Holding at \(model.stopwatch.display). Say stopwatch to roll on, reset stopwatch to clear."
            }
            return "Stopped at \(model.stopwatch.pause()). It holds; say stopwatch to roll on, reset stopwatch to clear."
        }
        if ["reset stopwatch", "reset the stopwatch", "clear stopwatch",
            "clear the stopwatch", "stopwatch reset"].contains(watch) {
            guard model.stopwatch.isActive else { return "Nothing on the watch." }
            model.stopwatch.reset()
            return "Cleared."
        }
        if ["stopwatch", "start stopwatch", "start the stopwatch",
            "start a stopwatch", "resume stopwatch"].contains(watch) {
            if model.stopwatch.isRunning {
                return "Running, \(model.stopwatch.display). Say stop stopwatch to hold it."
            }
            let resuming = model.stopwatch.isActive
            model.stopwatch.start()
            return resuming
                ? "Rolling again from \(model.stopwatch.display)."
                : "Stopwatch running. Say stop stopwatch to hold it."
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
        // The inversion: "add walking to my reminders (at 8)" puts
        // the thing before the word reminder, and prefix matching
        // never sees it. Longest tails first, so "reminders list"
        // is not half-eaten by "reminders". The recognizer writes
        // "add" as at, and, ad, or had (seen live); with the
        // reminders tail present the intent is unambiguous, so the
        // mishears are welcome too.
        let inversionLeads = [
            "add ", "put ", "set ", "create ", "make ", "save ",
            "at ", "and ", "ad ", "had ",
        ]
        let inversionTails = [
            "to my reminders list", "to my reminder list",
            "on my reminders list", "in my reminders app",
            "to my reminders app", "to my reminders",
            "to my reminder", "on my reminders", "in my reminders",
            "to the reminders", "to reminders", "in reminders",
        ]
        if let lead = inversionLeads.first(where: { lower.hasPrefix($0) }),
           let tailRange = inversionTails
               .compactMap({ text.range(of: $0, options: .caseInsensitive) })
               .first {
            let afterLead = text.index(text.startIndex, offsetBy: lead.count)
            if afterLead <= tailRange.lowerBound {
                let thing = String(text[afterLead..<tailRange.lowerBound])
                let trailing = String(text[tailRange.upperBound...])
                var rest = (thing + " " + trailing)
                    .trimmingCharacters(in: .whitespaces)
                var due: Date?
                if let (date, range) = Self.extractDate(rest) {
                    due = date
                    rest = Self.removing(range, from: rest)
                }
                if !rest.isEmpty {
                    return await model.events.addReminder(rest, due: due)
                }
            }
        }

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

        // "run <name>" hands the name to the user's own Shortcuts.app
        // library; every automation they ever built becomes a verb.
        // Launch is optimistic, a missing name speaks via the glance.
        if lower.hasPrefix("run ") {
            var name = String(text.dropFirst("run ".count))
                .trimmingCharacters(in: .whitespaces)
            for lead in ["shortcut ", "the ", "my "] where
                name.lowercased().hasPrefix(lead) {
                name = String(name.dropFirst(lead.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty else { return "Run which shortcut?" }
            model.shortcuts.runAppleShortcut(name)
            return "Running \(name)."
        }

        // Texting: the one verb whose words leave the Mac, so it
        // stages and reads back instead of firing; the send happens
        // when the next thing said is "send". The body is sliced
        // from the RAW input, not the sanitized copy: sanitize
        // strips trailing punctuation and pleasantries, and a
        // message that promises word-for-word must keep its "?",
        // its comma, and its "thank you" (review-caught: "text mom:
        // thank you" used to lose its entire body).
        for prefix in ["text ", "imessage ", "i message ", "message ",
                       "send a message to ", "send a text to ",
                       "send an imessage to ", "send a text message to "]
        where lower.hasPrefix(prefix) {
            let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let rest: String
            if let range = rawTrimmed.range(of: prefix, options: .caseInsensitive) {
                rest = String(rawTrimmed[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                rest = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !rest.isEmpty else { return "Text who?" }
            model.isWorking = true
            let outcome = await model.courier.stage(freeform: rest)
            model.isWorking = false
            return outcome
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
        if ["screen record", "record screen", "screen recording",
            "record my screen", "start screen recording"].contains(lower) {
            SystemAction.screenRecord.run()
            return "Recorder's up. Pick a window or an area, then hit Record."
        }
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

        // The net, last of all verbs: a sentence that says remind and
        // matched nothing above still becomes a reminder, unless it
        // reads like a question. The transcript is a lossy channel
        // (Bluetooth mics, mishears, dropped opening words); remind
        // is the intent, the rest is scaffolding to strip. A rough
        // title beats a silent miss every time.
        let asksAQuestion = ["what", "show", "list", "which", "read",
                             "how", "do i ", "did ", "any "]
            .contains { lower.hasPrefix($0) }
        if lower.contains("remind"), !asksAQuestion {
            var rest = text
            var due: Date?
            if let (date, range) = Self.extractDate(rest) {
                due = date
                rest = Self.removing(range, from: rest)
            }
            let scaffolding = [
                "to my reminders list", "to my reminder list",
                "on my reminders list", "to my reminders app",
                "in my reminders app", "to my reminders",
                "on my reminders", "in my reminders", "to reminders",
                "in reminders", "my reminders", "remind me to",
                "remind me", "a reminder", "the reminder",
                "reminders", "reminder", "remind",
            ]
            for phrase in scaffolding {
                while let range = rest.range(of: phrase, options: .caseInsensitive) {
                    rest.removeSubrange(range)
                }
            }
            rest = Self.strippedOfPleasantries(Self.sanitized(rest))
            var trimming = true
            while trimming {
                trimming = false
                for connector in ["to ", "for ", "about ", "that ", "of ",
                                  "add ", "put ", "set ", "saying ",
                                  "says ", "said ", "say "]
                where rest.lowercased().hasPrefix(connector) {
                    rest = String(rest.dropFirst(connector.count))
                        .trimmingCharacters(in: .whitespaces)
                    trimming = true
                }
            }
            if !rest.isEmpty {
                return await model.events.addReminder(rest, due: due)
            }
            return "Remind you to what? Say the thing and a time."
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

    /// Everything the island answers to, in one breath. Also the
    /// vocabulary the intent bridge translates loose phrasings into.
    static let cheatSheet = """
    remind me to call amma at 6 · schedule lunch friday at 1
    what's next · agenda · what's due · done with the thing · join
    cancel my 3pm · move standup to 4 · undo
    focus 25 · timer 10 · stopwatch · stop focus · rain · fire · cafe · quiet
    play · pause · next · open figma · quit slack
    text amma: on my way, then say send to send it
    left half · right half · fill · center
    note: an idea · notes · find parcel · read my screen
    screenshot · screen record · lock screen · dark mode · voice log
    what's new reads the latest release notes
    Anything else is a question; the model answers it.
    """

    // MARK: - Parsing helpers

    /// Politeness is welcome and ignored: leading fillers peel off
    /// until a verb can lead, and a trailing "please" or "for me"
    /// stays out of reminder titles.
    static func strippedOfPleasantries(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        let leaders = [
            "hey moai ", "hey ", "hi ", "ok ", "okay ", "so ",
            "please ", "can you ", "could you ", "would you ",
            "will you ", "moai ",
        ]
        var peeled = true
        while peeled {
            peeled = false
            for leader in leaders where text.lowercased().hasPrefix(leader) {
                text = String(text.dropFirst(leader.count))
                    .trimmingCharacters(in: .whitespaces)
                peeled = true
            }
        }
        for trailer in [" please", " for me", " thanks", " thank you"]
        where text.lowercased().hasSuffix(trailer) {
            text = String(text.dropLast(trailer.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Trailing punctuation gone, runs of spaces collapsed. Dictation
    /// writes "What's next." and exact matches must still hit.
    static func sanitized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "6 p.m." loses its meaningful final dot to the trailing-
        // punctuation strip below and the date detector goes blind;
        // normalize meridiem dots away first.
        for meridiem in ["p.m.", "p.m", "a.m.", "a.m"] {
            text = text.replacingOccurrences(
                of: meridiem,
                with: meridiem.hasPrefix("p") ? "pm" : "am",
                options: .caseInsensitive
            )
        }
        while let last = text.last, ".!?,;".contains(last) {
            text.removeLast()
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text
    }

    /// Spoken numbers arrive as words as often as digits.
    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    ]

    private static func numberValue(_ token: String) -> Int? {
        Int(token) ?? numberWords[token.lowercased()]
    }

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

    /// Spoken relative times, "in 20 minutes", "in an hour", "in one
    /// hour", which NSDataDetector handles unreliably. Speech writes
    /// number words as often as digits.
    private static func relativeTime(_ text: String) -> (Date, NSRange)? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\bin (\\d{1,3}|[a-z]+) ?(minutes|minute|mins|min|hours|hour|hrs|hr)\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ) else { return nil }
        let amountText = nsText.substring(with: match.range(at: 1)).lowercased()
        guard let amount = numberValue(amountText) else { return nil }
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        let seconds = unit.hasPrefix("h") ? amount * 3600 : amount * 60
        guard seconds > 0 else { return nil }
        return (Date().addingTimeInterval(TimeInterval(seconds)), match.range)
    }

    /// NSDataDetector misses bare hours ("at 6", spoken "at nine").
    /// Resolve them to the next future occurrence, trying both AM and
    /// PM when unspecified.
    private static func bareHourTime(_ text: String) -> (Date, NSRange)? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\bat (\\d{1,2}|[a-z]+)(?::(\\d{2}))?\\s*(am|pm|a\\.m|p\\.m)?\\b",
            options: [.caseInsensitive]
        ) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(
            in: text, range: NSRange(location: 0, length: nsText.length)
        ), let hour = numberValue(nsText.substring(with: match.range(at: 1))),
           (1...23).contains(hour) else { return nil }
        let minute = match.range(at: 2).location == NSNotFound
            ? 0 : Int(nsText.substring(with: match.range(at: 2))) ?? 0
        var meridiem: String?
        if match.range(at: 3).location != NSNotFound {
            meridiem = nsText.substring(with: match.range(at: 3)).lowercased()
                .replacingOccurrences(of: ".", with: "")
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
