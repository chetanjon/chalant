import Foundation

/// The one line a session row says about itself.
///
/// The rail used to print a folder name and a clock. It told you where
/// an agent lived and when it started, never what it was doing or what
/// it wanted, and the app covered that hole with mood words: Working,
/// Needs you, At its prompt. The founder's verdict on those (2026-08-06)
/// was "vague ones that pretend", and they were right: not one of them
/// is checkable against anything.
///
/// This is the replacement. It walks a ranked ladder and stops at the
/// first rung holding a fact, so every line on screen is something read
/// off disk in the agent's own words. The order is the design: what an
/// agent is *asking* for always outranks what it happens to be *doing*,
/// because only one of those is waiting on a person.
///
/// Pure, and deliberately so. Everything it reads is already on the
/// `Session`, which means the ladder tests without a filesystem, a clock
/// or a running agent, and the question of *when* to gather those inputs
/// stays with the readers that gather them.
enum SessionActivity {

    /// Where a line came from, so the room can style a question
    /// differently from a file being edited without re-deriving which is
    /// which from the text.
    enum Source: Equatable {
        case heldCall
        case terminalPrompt
        case question
        case needs
        case doing
        case plan
        case result
        case said
        case started
    }

    struct Line: Equatable {
        var text: String
        var source: Source
    }

    /// The truest thing this session can say about itself right now.
    static func line(for session: SessionStore.Session) -> Line {
        // 1. A call held at the door. The strongest proof of life there
        //    is, and the only thing on this ladder that is costing the
        //    agent time while you do not look at it. Verbatim: the
        //    approval card's own rule is that a summary of a command you
        //    are being asked to authorise is a summary of the wrong
        //    thing, and a row that softens it is the same lie earlier.
        if let approval = session.approval, approval.decision == nil {
            return Line(text: flattened(approval.detail), source: .heldCall)
        }

        // 2. Claude Code standing at its own permission prompt. The
        //    agent is frozen mid tool call and the terminal is unusable
        //    until somebody answers, which makes it the most stuck a
        //    session gets. Below a held call only because that one can
        //    be resolved from here and this one cannot.
        //
        //    Worth more than it looks: it needs nothing switched on. The
        //    `Notification` hook that reports it is already installed on
        //    the founder's machine, and it fires for a session inside VS
        //    Code's terminal exactly as it does anywhere else, which is
        //    the one place none of this app's other verbs reach.
        if let prompt = session.pendingPrompt, !prompt.isStale {
            return Line(text: flattened(prompt.detail.isEmpty ? prompt.tool : prompt.detail),
                        source: .terminalPrompt)
        }

        // 3. A question nobody has answered. A bundle asks two to four
        //    things at once and gets answered one at a time, so the line
        //    is the first one still outstanding, not the first one asked.
        if let ask = session.ask, !ask.isFullyAnswered,
           let waiting = ask.questions.first(where: { $0.answer == nil }) {
            return Line(text: flattened(waiting.question), source: .question)
        }

        // 3. A background agent that stopped for you. `needs` is written
        //    in the first person by the agent itself; `detail` is the
        //    note it left about where it got to. Only `blocked` counts:
        //    a `needs` line left behind by a working agent is a question
        //    somebody already answered, and it must not outrank live work.
        if let job = session.job, job.state == .blocked,
           let asking = job.needs ?? job.detail, !asking.isEmpty {
            return Line(text: flattened(asking), source: .needs)
        }

        // 4. A step in flight, from the transcript. Gated on the session
        //    being live, because the last tool a finished session reached
        //    for is history, and a row claiming "Editing X" about a
        //    process that has exited is exactly the pretending this
        //    ladder exists to end.
        if session.state.isLive, let activity = session.activity, !activity.isEmpty {
            return Line(text: flattened(activity), source: .doing)
        }

        // 5. A step in the agent's own plan. Ranked under the transcript
        //    on purpose: a to-do list says what an agent means to do, a
        //    live tool call says what it is doing.
        if session.state.isLive, let plan = session.plan, let step = plan.step {
            return Line(text: "\(flattened(step)) · \(plan.done + 1) of \(plan.total)",
                        source: .plan)
        }

        // 6. What it came back with. A background agent writes its own
        //    one-line result when it finishes, which is better than
        //    anything this app could summarise from the transcript.
        if let result = session.job?.result, !result.isEmpty {
            return Line(text: flattened(result), source: .result)
        }

        // 7. Its last words. First line only, unlike every rung above:
        //    those are single sentences somebody wrote as one thought,
        //    while an assistant message is prose whose first line is the
        //    headline and whose rest is the detail a row has no room for.
        if let said = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           let headline = said.split(separator: "\n").first.map(String.init),
           !headline.isEmpty {
            return Line(text: flattened(headline), source: .said)
        }

        // 8. The floor, and it is still a fact. "Started 18:46" can be
        //    checked against a clock. "Working" cannot be checked
        //    against anything, which is why it is not here.
        return Line(text: "Started \(SessionRoomFormat.clock(session.startedAt))",
                    source: .started)
    }

    /// What a row in the rail says under its title.
    ///
    /// `disambiguating` is for the case Claude Code creates by naming a
    /// session after its work: two agents in one repo doing the same job
    /// get the same name, and three such rows were on the founder's
    /// machine at once. The line usually tells them apart on its own
    /// now, since they are rarely on the same step at the same second,
    /// and the start time is only spent when the titles genuinely
    /// collide. Never appended to a line that is already the start time.
    static func railLine(for session: SessionStore.Session, disambiguating: Bool) -> String {
        let line = self.line(for: session)
        guard disambiguating, line.source != .started else { return line.text }
        return "\(line.text) · from \(SessionRoomFormat.clock(session.startedAt))"
    }

    /// What a row in the record says.
    ///
    /// A finished session has no state left, only an outcome, so the
    /// ladder collapses to two rungs: what it said last, or what became
    /// of it. `markGone` refuses to call a lost session finished, and
    /// this refuses to let one read as though it had.
    static func line(for finished: SessionStore.Finished) -> Line {
        if let said = finished.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           let headline = said.split(separator: "\n").first.map(String.init),
           !headline.isEmpty {
            return Line(text: flattened(headline), source: .said)
        }
        switch finished.outcome {
        case .done: return Line(text: "Finished", source: .result)
        case .failed: return Line(text: "Stopped on an error", source: .result)
        case .lost: return Line(text: "Stopped without finishing", source: .result)
        }
    }

    /// One line out of however many the agent wrote.
    ///
    /// A `needs` string routinely arrives wrapped, and a row that keeps
    /// the newline renders the first fragment and drops the rest with no
    /// sign, which reads as the agent having said something clipped.
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension SessionStore {
    /// What a background agent published about itself, read from
    /// `~/.claude/jobs/<id>/state.json`.
    ///
    /// Claude Code writes this file for every background agent and
    /// nothing has ever read it here, which is how the founder's own
    /// August 3 agent sat blocked for three days behind a sentence
    /// ("say the word and I'll bump to 1.6.1 and do the proper release")
    /// the island was never able to show.
    struct JobState: Equatable {
        /// The agent's own word for what it is doing. Deliberately its
        /// vocabulary, not this app's `State`: the two answer different
        /// questions and collapsing them would put this app back in the
        /// business of guessing.
        enum Phase: String, Equatable {
            case working
            case blocked
            case done
            case failed
        }

        /// Optional on purpose. `SessionRegistry.parse` once treated an
        /// unrecognised enum value as grounds to discard the whole
        /// entry, and one unexpected spelling disowned every background
        /// agent on the machine. An unknown state costs the state.
        var state: Phase?
        /// What it wants from you, in the first person.
        var needs: String?
        /// Where it got to, in its own words.
        var detail: String?
        /// Its one-line outcome, once there is one.
        var result: String?
        /// The answer Claude Code expects to the `needs` line, written
        /// by the agent itself. A button, not a sentence: the founder's
        /// own blocked agent published "bump to 1.6.1 and do the proper
        /// release" while the island offered nothing to tap.
        var suggestedReply: String?
        /// Context spent, for the detail pane. Never for a decision.
        var tokens: Int?

        // Identity, carried because a background agent has no registry
        // file to carry it: this file is the only place its name, folder
        // and start time are written down.
        var name: String?
        var cwd: String?
        var startedAt: Date?
    }

    /// A permission prompt Claude Code is showing in its own terminal
    /// right now.
    ///
    /// Not the same thing as an `Approval`, and deliberately a separate
    /// type so the difference cannot be blurred: an approval is held by
    /// this app and a tap resolves it, while this is Claude Code asking
    /// somebody in a window, which no button here can answer. Proven
    /// 2026-08-06: a hook returning a decision on `PermissionRequest` is
    /// ignored, and typing an answer into the prompt from outside picked
    /// the wrong option and wrote a permission rule nobody agreed to.
    ///
    /// So the island's job here is to say what is stuck and where, and
    /// to hand over a door: the terminal, or the phone if that session
    /// is bridged.
    struct PendingPrompt: Equatable {
        var tool: String
        /// The command, path or query, read from the transcript's last
        /// unfinished tool call by the hook that reports the prompt.
        var detail: String
        var since: Date

        /// Past believing. The prompt is normally cleared by the turn
        /// ending or the next tool call; this is the backstop for a turn
        /// that never ends, because a row still claiming an hour-old
        /// prompt is describing the past.
        var isStale: Bool {
            -since.timeIntervalSinceNow >= SessionStore.pendingPromptExpiry
        }
    }

    /// The agent's live to-do list, from `~/.claude/tasks/<id>/`.
    ///
    /// Present for roughly one session in five (measured on this machine,
    /// 4 of 22), because it only exists once an agent reaches for the
    /// task tool. A bonus rung, never a foundation.
    struct PlanProgress: Equatable {
        /// The step in progress, in the present tense the agent wrote it
        /// in ("Running the test suite"). Nil when every step is done or
        /// none has started.
        var step: String?
        /// Steps completed before this one.
        var done: Int
        var total: Int
    }
}
