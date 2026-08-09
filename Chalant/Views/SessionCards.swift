import AppKit
import SwiftUI

/// The three cards a session row can carry: a tool call held at the
/// door, a question waiting on an answer, and the box you write back in.
///
/// Their own file because both surfaces use them and neither owns them.
/// They were `private` to `AgentSessions.swift` when the glance was the
/// only place a session could be acted on; the room needs the same three
/// and would otherwise have grown its own, which is how two versions of
/// an approval dialog end up disagreeing about what "allow" means.

/// A message to a running session: typed or spoken, sent on return or
/// on the mic's release. No confirmation step: the words are already
/// visible in the field, and an agent is not a person, so the "say
/// send to confirm" staging a spoken text message to a human gets does
/// not apply here (Open Question 1, notch-messaging-plan-2026-08-01.md).
///
/// One line of field, one line of status, never more. The island is a
/// glance surface, and this composer is the row most likely to try to
/// grow past that.
struct ComposeCard: View {
    let session: SessionStore.Session
    @ObservedObject var sessions: SessionStore
    @ObservedObject var model: NotchViewModel
    /// The room turns this off: it draws the whole conversation above
    /// the composer, so quoting the last message here would be the same
    /// words twice, six points apart. The glance keeps it, because there
    /// the composer is the only place those words appear at all.
    var showsLastWord = true

    @State private var draft = ""
    /// What became of the last send, when it went somewhere other than
    /// the outbox or failed to. Cleared on the next ordinary send.
    @State private var remoteNote: String?
    /// Whether the agent's last message is showing in full. Collapsed
    /// is the resting state; the toggle below it is the way through.
    @State private var showingFullMessage = false
    @Environment(\.chalantAccent) private var accent

    /// Read fresh on every render rather than cached, same as the
    /// Sessions pane's own card: the file is never written by this app,
    /// so there is nothing here worth a cache invalidating.
    private var hookInstalled: Bool { HookInstall.status() == .installed }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            lastWord
            if let outbox = session.outbox {
                outboxStatus(outbox)
            } else {
                field
                statusLine
            }
        }
        .rowInsets()
        .chalantCard(radius: Theme.Radius.row)
        .task(id: session.id) {
            while !Task.isCancelled {
                await measureReach()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// What the agent last said, above the box you answer in.
    ///
    /// Being told a session wants you and not being told what it wants
    /// is half a notification: the founder asked, plainly, whether
    /// there was a way to see the message before replying, and there
    /// was not (2026-08-02). Read from the transcript rather than the
    /// hook, so it is there whether or not the hook is installed and
    /// for sessions that were already running.
    ///
    /// Four lines at rest, all of it on request.
    ///
    /// A glance surface cannot open with an essay in it, but truncating
    /// with no way through is its own fault: the founder hit a message
    /// cut at "matched it against the Dockerfil..." with nowhere to go
    /// (2026-08-03). Shortened is a starting state now, not a ceiling.
    @ViewBuilder
    private var lastWord: some View {
        if showsLastWord, let said = session.lastMessage, !said.isEmpty {
            let rendered = Self.rendered(said)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // What it said is quoted, not just placed: a wall of
                // grey text running to both edges with the reply box
                // under it read as one undifferentiated block, and it is
                // two different things (founder, 2026-08-03). A rule
                // down the leading edge says where the agent's words
                // start and stop without drawing a second card inside a
                // card.
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Capsule(style: .continuous)
                        .fill(Theme.textGhost)
                        .frame(width: 2)
                    if showingFullMessage {
                        // Scrolls rather than growing without limit: an
                        // agent's last turn can run to pages, and an
                        // island that stretched to hold one would push
                        // its own controls off the screen.
                        ScrollView {
                            messageText(rendered, clamped: false)
                                .padding(.trailing, Theme.Space.xs)
                        }
                        .frame(maxHeight: Theme.Panel.list)
                        .scrollIndicators(.never)
                    } else {
                        messageText(rendered, clamped: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showingFullMessage || Self.mayBeClipped(said) {
                    Button(showingFullMessage ? "Show less" : "Show everything") {
                        withAnimation(Theme.Motion.content) { showingFullMessage.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(accent)
                    .padding(.leading, Theme.Space.m + 2)
                }
                // The agent's words end here and yours begin below. A
                // hairline is cheaper than a second card and says the
                // same thing.
                Divider().overlay(Theme.hairline)
            }
            .accessibilityLabel("It said: \(said)")
        }
    }

    /// One place decides how the agent's words are set, so the clamped
    /// and the full versions cannot drift apart in font or colour.
    private func messageText(_ rendered: AttributedString, clamped: Bool) -> some View {
        Text(rendered)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(2)
            .lineLimit(clamped ? 4 : nil)
            .fixedSize(horizontal: false, vertical: clamped)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether four lines might not be all of it.
    ///
    /// A length alone was the wrong test: a short message with four
    /// line breaks in it is clipped and offered nothing, while a long
    /// unbroken one is offered a toggle it may not need. Counting the
    /// breaks the agent actually wrote catches the first, and the
    /// length still catches the second. Erring towards offering it is
    /// the right way to be wrong here: a toggle that opens the same
    /// text is a small waste, and text with no way to reach it is the
    /// thing that was reported (founder, 2026-08-03).
    static func mayBeClipped(_ text: String) -> Bool {
        text.count > 180 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 4
    }

    /// Agents write markdown, so the island renders it rather than
    /// showing the punctuation. Bold, italics, inline code and links
    /// arrive constantly; before this, a message came through wearing
    /// its asterisks and backticks (founder, 2026-08-03).
    ///
    /// `inlineOnlyPreservingWhitespace` on purpose: it keeps the line
    /// breaks an agent wrote, which the full interpretation throws away
    /// by reflowing into paragraphs, and this is a surface where a list
    /// losing its lines would read as one run-on sentence. Fenced code
    /// blocks are beyond it either way, and their fences are left
    /// visible rather than silently swallowed, which at least says
    /// plainly that something was code.
    ///
    /// Falls back to the raw text: malformed markdown is still a
    /// message, and showing it unstyled beats showing nothing.
    static func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    // MARK: Composing, nothing queued yet

    private var field: some View {
        HStack(spacing: Theme.Space.s) {
            TextField("Message this session", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .onSubmit(send)
            MicButton(destination: .session(id: session.id, title: session.title)) {
                model.toggleListening(to: .session(id: session.id, title: session.title))
            }
            if !draft.isEmpty {
                HoverGlyphButton(
                    symbol: "arrow.up.circle.fill", label: "Send", scale: .m, tint: accent, action: send
                )
                .transition(.opacity)
            }
        }
        .padding(Theme.Space.m)
        .chalantField()
        // Sending here is pointless before the hook exists to collect
        // it, and a live field that quietly does nothing reads as
        // broken rather than as "not set up yet" (EC-18).
        //
        // Unless the words are going straight into the terminal, which
        // needs no hook at all: that path is the keyboard, and the
        // keyboard was never waiting on a Stop event.
        //
        // And closed outright when there is nowhere for the words to go
        // at all, which is the state that let a message be queued for a
        // session that had ended half an hour earlier.
        .disabled({ if case .nowhere = reach { return true }; return false }())
        .animation(Theme.Motion.hover, value: draft.isEmpty)
    }

    /// Straight into the running session where that is possible and the
    /// user has asked for it, and into the outbox otherwise.
    ///
    /// The fallback is never silent. A message that quietly became a
    /// note-for-later when the person meant "say this now" is the same
    /// class of failure as a button that does nothing, so every path
    /// that cannot type says why, in `remoteNote`, right under the
    /// field.
    private func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !typed.isEmpty else { return }
        // The field is already closed in this state; this is the second
        // lock, for the return key.
        if case .nowhere = reach { return }
        Task {
            // Re-asked at the moment of sending rather than trusting the
            // measurement from up to three seconds ago: a window can be
            // closed between reading the line under the field and
            // pressing return, and that gap is where a message goes
            // missing.
            guard SessionRemote.sendsStraightToTerminal(),
                  let target = await SessionRemote.target(for: session),
                  SessionRemote.canType(into: target)
            else {
                remoteNote = nil
                sessions.queue(message: typed, for: session.id)
                return
            }
            switch await SessionRemote.type(typed, into: target) {
            case .typed(let app):
                remoteNote = "Typed into \(app)."
            case .cannot(let reason):
                remoteNote = reason
                sessions.queue(message: typed, for: session.id)
            }
        }
    }

    /// Where this session's next message would actually go.
    ///
    /// Three answers, and the third one is why this type exists: a
    /// message was once queued for a session whose transcript had been
    /// cold for half an hour, and it sat there forever because nothing
    /// was left to collect it. The composer looked like it had worked.
    enum Reach: Equatable {
        /// Straight into a real terminal, now.
        case types(app: String)
        /// The outbox, collected at this session's next turn. Only
        /// offered when a process is actually there to have one.
        case queues
        /// Nowhere, and this is why. The field is closed in this state.
        case nowhere(String)
    }

    /// Held rather than computed per render: answering it walks the
    /// process table, and SwiftUI redraws far more often than a process
    /// starts or stops. Refreshed by the task below.
    @State private var reach: Reach = .queues

    /// Recomputed on open and every few seconds after, because both
    /// halves of the answer go stale on their own: a terminal window can
    /// be closed, and a session can end, without anything telling this
    /// card.
    private func measureReach() async {
        if SessionRemote.sendsStraightToTerminal(),
           let target = await SessionRemote.target(for: session),
           SessionRemote.canType(into: target) {
            reach = .types(app: target.appName)
            return
        }
        guard SessionRemote.isRunning(session) else {
            reach = .nowhere(
                "This session isn't running any more, so there's nothing left to read a message. "
                + "Anything sent now would wait forever.")
            return
        }
        guard hookInstalled else {
            reach = .nowhere("Claude Code isn't set up to collect these yet.")
            return
        }
        // Alive, but sitting at its prompt with no turn to end.
        //
        // The outbox is collected by the Stop hook, which fires when a
        // turn finishes. An idle session has no turn, so a message left
        // here waits until somebody types into that window themselves,
        // which is the errand this whole surface exists to save. Saying
        // "arrives next time it runs" was true and useless; this says
        // the part that changes what you do next.
        if session.state == .idle {
            reach = .nowhere(
                "This session is idle, and Chalant can only type into Terminal or iTerm. "
                + "Yours is somewhere else, so a message left here would wait until you go and "
                + "type in that window yourself.")
            return
        }
        reach = .queues
    }

    private var remoteTarget: String? {
        if case .types(let app) = reach { return app }
        return nil
    }

    @ViewBuilder
    private var statusLine: some View {
        if let note = remoteNote {
            // What actually happened to the last one, which outranks
            // any general statement about what usually happens.
            Text(note)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let app = remoteTarget {
            Text("Goes straight into \(app), the way typing does.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
        } else if case .nowhere(let why) = reach {
            Text(why)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        } else if !hookInstalled {
            HStack(spacing: Theme.Space.s) {
                Text("Claude Code is not set up to receive these yet.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                Button("Open settings") { model.openDashboard?(.sessions) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                // Said before the send, not after, and differently for
                // the two shapes delivery actually takes (EC-2): a busy
                // session gets this at its next turn boundary, an idle
                // one only when something starts a turn at all.
                // "Turn" is the precise word and the wrong one out
                // here: it is the vocabulary of the thing being talked
                // to, not of the person doing the talking.
                Text(session.state == .idle
                     ? "Waiting for input. This arrives the next time it runs."
                     : "Arrives when it finishes what it's doing.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                if session.state == .idle {
                    Button("Open session") { AgentSessionsStrip.go(to: session) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(accent)
                }
            }
        }
    }

    // MARK: A message already in the outbox

    @ViewBuilder
    private func outboxStatus(_ outbox: SessionStore.Outbox) -> some View {
        if outbox.undelivered {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("\(session.title) ended before reading "
                     + (outbox.pending.count == 1 ? "this." : "these."))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(outbox.pending) { queued in
                    Text(queued.text)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Theme.Space.m) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            outbox.pending.map(\.text).joined(separator: "\n\n"), forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
                    Button("Dismiss") { sessions.clearMessage(sessionID: session.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } else if outbox.pending.isEmpty, let collectedAt = outbox.deliveredAt {
            // "Collected", never "delivered": `deliveredAt` is stamped
            // the moment a Stop hook comes and picks the message up,
            // which is the last thing this app can observe. Whether the
            // agent then acts on it is invisible from here, so the copy
            // stops exactly where the knowledge does (H3, founder
            // 2026-08-02: "how do I know if the request is being sent
            // or not is it actually working"). This used to say
            // "Delivered." for 2.5 seconds and take the whole card down
            // with it when the timer fired, easy to miss entirely; now
            // it holds, like the undelivered case above, until the user
            // dismisses it themselves.
            let ago = RelativeAge.short(collectedAt)
            HStack(spacing: Theme.Space.s) {
                Text("Collected \(ago == "now" ? "just now" : "\(ago) ago"). "
                     + "What it does with it next isn't something Chalant can see.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Dismiss") {
                    sessions.clearMessage(sessionID: session.id)
                    if model.composingSessionID == session.id {
                        model.composingSessionID = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            // Every queued message, stacked and cancellable on its own,
            // the way Claude Code's terminal shows a queue. One goes at
            // each turn boundary, so the first in the list is the one
            // leaving next and the rest are honestly behind it.
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(outbox.pending.enumerated()), id: \.element.id) { index, queued in
                    let expiredHead = index == 0 && queued.isExpired
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queued.text)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(statusLabel(index: index, queued: queued))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(expiredHead ? Theme.textSecondary : Theme.textTertiary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        // Only the head can ever be collected, so only
                        // the head gets a reason and a second chance.
                        // An aged-out message further back is still just
                        // "queued" until it is the one being asked for.
                        if expiredHead {
                            Button("Send now") {
                                sessions.resendMessage(id: queued.id, for: session.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(accent)
                        }
                        Button {
                            sessions.cancelMessage(id: queued.id, for: session.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(Theme.Fonts.icon(.s))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textTertiary)
                        .help(expiredHead ? "Drop this message" : "Cancel this message")
                        .accessibilityLabel(expiredHead ? "Drop this message" : "Cancel this message")
                    }
                }
            }
        }
    }

    /// "Next" or "Queued" as before, plus how long it has actually been
    /// waiting: a message that rode out a relaunch is not the same as
    /// one just typed, and the card must not pretend otherwise. The head
    /// of a queue that aged out says so outright instead of "Next":
    /// handing it to the agent silently is exactly the failure
    /// persisting the outbox at all is meant to avoid.
    private func statusLabel(index: Int, queued: SessionStore.QueuedMessage) -> String {
        guard !(index == 0 && queued.isExpired) else {
            return "Expired, waited too long to send safely"
        }
        let ago = RelativeAge.short(queued.queuedAt)
        return "\(index == 0 ? "Next" : "Queued") · \(ago == "now" ? "just now" : "\(ago) ago")"
    }
}

/// A question — or several, bundled into one `AskUserQuestion` call — an
/// agent is waiting on, answerable in place.
///
/// A leading accent rule and the header sitting right above the question
/// tie this to the row it hangs off, rather than reading as a second,
/// unrelated box floating below it (founder, 2026-08-03: "the UI to show
/// the question sucks"). Options are full-width rows with a real
/// selection glyph rather than capsule chips: a chip crushes a real
/// `AskUserQuestion` option, which is routinely a full sentence, into a
/// pill built for a word.
///
/// A bundle is shown one question at a time with a progress line, never
/// all at once: a real bundle runs three or four questions deep, each
/// with several sentence-length options (native-questions-evidence-
/// 2026-08-03.md — logo direction, then the microphone, then drag scope,
/// each unrelated to the last), and stacking all of it would make the
/// card the entire reason to look at the island rather than a glance off
/// it. One question keeps this exactly the size it already was for a
/// single question; only the progress line is new.
struct AskCard: View {
    let ask: SessionStore.Ask
    let answer: ([String]) -> Void
    /// Records one question's answer inside a bundle, independent of the
    /// rest — `SessionStore.answerQuestion`, keyed by index into
    /// `ask.questions`. Kept separate from `answer` above because that
    /// one still means "answer the whole (single-question) ask" for the
    /// scripted `chalant ask` path, and must go on meaning exactly that.
    let answerQuestion: (Int, [String]) -> Void
    /// Native asks only: queues a label through the session's outbox
    /// instead of answering. There is no supported way to resolve
    /// Claude Code's own `AskUserQuestion` from outside the process, so
    /// this is the honest alternative rather than a button that looks
    /// like it answers and silently does nothing. Returns whether the
    /// queue actually took it, so a session that cannot receive
    /// messages right now can be told rather than left looking answered.
    let queue: (String) -> Bool
    /// Elicitation only: says "not answering" to the server that asked.
    var declined: (() -> Void)?

    /// Only used when several may be picked. A single-choice question
    /// answers (or advances) on the tap and never reads this.
    @State private var picked: Set<String> = []
    /// The free-text answer, and whether its field is open. Kept apart
    /// from `picked` because "something else" is not one of the
    /// options: it replaces them.
    @State private var writingOther = false
    @State private var otherText = ""
    /// Set once a native ask's last question has been queued, replacing
    /// the options with what actually happened. Never cleared back: the
    /// tap already happened, and offering the buttons again would invite
    /// a second, different pick queued behind the one Claude Code is
    /// still waiting on in its terminal.
    @State private var queuedOutcome: String?

    @Environment(\.chalantAccent) private var accent

    /// The first question in the bundle without an answer yet, straight
    /// off the store rather than tracked separately here: `ask` is
    /// rebuilt from `SessionStore` on every answer, so this is always
    /// exactly where answering left off, even if this view is recreated
    /// mid-bundle.
    private var currentIndex: Int {
        ask.questions.firstIndex(where: { $0.answer == nil }) ?? max(ask.questions.count - 1, 0)
    }

    private var currentQuestion: SessionStore.Ask.Question {
        ask.questions[currentIndex]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule()
                .fill(accent.opacity(0.5))
                .frame(width: 2)
            content
                .padding(.leading, Theme.Space.m)
        }
        .rowInsets()
        .chalantCard(radius: Theme.Radius.row)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: currentQuestion.header.isEmpty ? "Question" : currentQuestion.header, tint: accent)
            if ask.questions.count > 1, queuedOutcome == nil {
                Text("Question \(currentIndex + 1) of \(ask.questions.count)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(currentQuestion.question)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if ask.elicitation, !ask.server.isEmpty, queuedOutcome == nil {
                Text("\(ask.server) is waiting on this, inside the call it is making now.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ask.native, queuedOutcome == nil {
                Text("Claude Code asked this itself, in its own terminal. Chalant can't answer it "
                     + "there directly: tapping a choice queues it as a message for this "
                     + "session's next turn instead.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let queuedOutcome {
                Text(queuedOutcome)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(currentQuestion.options, id: \.self) { option in
                        optionRow(option)
                    }
                    otherRow
                }
                if ask.elicitation {
                    HStack(spacing: Theme.Space.m) {
                        Spacer(minLength: 0)
                        Button("Not answering") { decline() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Tells "
                                  + (ask.server.isEmpty ? "the server that asked" : ask.server)
                                  + " you are not answering, rather than leaving it waiting.")
                    }
                }
                if currentQuestion.multiSelect {
                    // Hoisted rather than inlined into the Button call:
                    // a ternary inline in a SwiftUI modifier chain is
                    // exactly the shape that has hung this project's
                    // type-checker before.
                    let isLastQuestion = currentIndex == ask.questions.count - 1
                    Button(isLastQuestion ? "Send" : "Next") {
                        respond(with: Array(picked), label: picked.sorted().joined(separator: ", "))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
                    // Nothing chosen is not an answer, and sending one
                    // would tell the agent the user decided when they
                    // did not.
                    .disabled(picked.isEmpty)
                }
            }
        }
    }

    /// The answer that is not on the list.
    ///
    /// Claude Code's own picker always offers one, and a question in
    /// the notch that only offered the options would quietly be a
    /// narrower question than the one being asked (founder,
    /// 2026-08-03). A scripted `chalant ask` is answered with whatever
    /// text is chosen, so free text was always allowed on the wire;
    /// only the surface lacked a way to type it.
    @ViewBuilder
    private var otherRow: some View {
        if writingOther || currentQuestion.options.isEmpty {
            HStack(spacing: Theme.Space.s) {
                TextField(currentQuestion.options.isEmpty ? "Your answer" : "Something else",
                          text: $otherText)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.body)
                    .onSubmit(sendOther)
                HoverGlyphButton(
                    symbol: "arrow.up.circle.fill", label: "Send this answer",
                    scale: .m, tint: accent
                ) {
                    sendOther()
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Theme.field)
            )
        } else {
            Button { writingOther = true } label: {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: "square.and.pencil")
                        .font(Theme.Fonts.icon(.m))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Something else")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Answer with your own words")
        }
    }

    /// Turned down, which only an elicitation can be. The agent is told
    /// so and carries on, instead of standing there until its hook runs
    /// out of patience.
    private func decline() {
        declined?()
    }

    private func sendOther() {
        let text = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        respond(with: [text], label: text)
        otherText = ""
        writingOther = false
    }

    /// One real row per option: a selection glyph, the full label
    /// wrapping rather than truncating, a hover lift and a press sink,
    /// exactly what "obviously tappable" asks for.
    private func optionRow(_ option: String) -> some View {
        let on = picked.contains(option)
        return Button {
            guard currentQuestion.multiSelect else {
                respond(with: [option], label: option)
                return
            }
            if on { picked.remove(option) } else { picked.insert(option) }
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: currentQuestion.multiSelect ? (on ? "checkmark.square.fill" : "square") : "circle")
                    .font(Theme.Fonts.icon(.m))
                    .foregroundStyle(on ? accent : Theme.textTertiary)
                Text(option)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(on ? accent.opacity(0.14) : Theme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(on ? accent.opacity(0.45) : Theme.hairlineFaint, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(radius: Theme.Radius.row)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }

    /// Where a tap actually goes: a real answer for the scripted
    /// `chalant ask` — always exactly one question, so answering it is
    /// answering the whole ask, unchanged from before bundles existed —
    /// or, for one Claude Code asked on its own, this question's answer
    /// recorded on its own (see `ask.native`), and only once every
    /// question in the bundle has one, a single queued message carrying
    /// all of them together. There is no supported way to resolve the
    /// real `AskUserQuestion` prompt from outside the process, so a
    /// native bundle is never "answered" here, only ever queued.
    private func respond(with choices: [String], label: String) {
        guard ask.native else {
            answer(choices)
            return
        }
        let index = currentIndex
        answerQuestion(index, choices)
        picked = []
        writingOther = false
        otherText = ""
        // Not the last question: the next render picks up wherever
        // `currentIndex` now points, straight off the store.
        guard index == ask.questions.count - 1 else { return }
        // Every earlier answer already lives on `ask.questions` — set by
        // this same function, on an earlier render — except this last
        // one, which `ask` will not reflect until the next render.
        let summary = ask.questions.count == 1 ? label
            : ask.questions.enumerated().map { i, question -> String in
                let header = question.header.isEmpty ? "Q\(i + 1)" : question.header
                let text = i == index ? label : (question.answer?.joined(separator: ", ") ?? "")
                return "\(header): \(text)"
            }.joined(separator: "\n")
        let delivered = ask.questions.count == 1
            ? "Queued \u{201C}\(summary)\u{201D}. Arrives when this session next takes a turn. "
                + "The terminal prompt still needs its own answer to move past it now."
            : "Queued all \(ask.questions.count) answers together. Arrives when this session "
                + "next takes a turn. The terminal prompt still needs its own answer to move "
                + "past it now."
        queuedOutcome = queue(summary) ? delivered : "Could not queue that; this session can't take a message right now."
    }
}

/// A tool call held at the door.
///
/// The only card in this app whose buttons change what a running agent
/// does. Everything else here reports, or leaves something for an agent
/// to collect on its own schedule; this one has an agent standing still
/// on the other side of it.
///
/// So it shows the call verbatim and never summarises: a paraphrase of
/// a command you are being asked to authorise is a paraphrase of the
/// wrong thing. And it says out loud that not answering is an option
/// with a known outcome, because a dialog that looks like it might trap
/// an agent forever is one people learn to avoid rather than use.
/// Claude Code asking, in its own terminal, with the island watching.
///
/// Deliberately not styled as a decision. Nothing here can answer this
/// prompt: a hook returning a decision on the event is ignored, and
/// typing the answer in from outside selected the wrong option and
/// wrote a permission rule nobody agreed to (both measured 2026-08-06).
/// So this card names what is stuck and hands over a door, and says so
/// rather than implying a button might work.
struct TerminalPromptCard: View {
    let prompt: SessionStore.PendingPrompt
    let session: SessionStore.Session
    let openTerminal: () -> Void

    @Environment(\.chalantAccent) private var accent
    /// Read once when the card appears rather than on every redraw: it
    /// reads a file, and this card can be on screen for minutes.
    @State private var armed = HookInstall.answersPrompts()
    @State private var outcome: HookInstall.ArmOutcome?

    /// The offer, made at the only moment it means anything.
    ///
    /// The button that turns this app's approval gate on has lived at
    /// the bottom of the Sessions settings page since 1.5.0, under two
    /// hook status cards, three code snippets, a session list and a rule
    /// editor. It was never pressed once, by the person who asked for
    /// the feature, across two releases. That is not forgetfulness, it
    /// is a button nobody was ever looking at.
    ///
    /// Here it is attached to the exact frustration it answers: you are
    /// staring at a question you cannot answer from here, and this is
    /// the thing that would have let you. It appears only while the gate
    /// is off, and it says what it changes and when, because arming
    /// writes somebody's Claude config and takes effect for sessions
    /// they have not started yet.
    @ViewBuilder
    private var offerToHold: some View {
        if let outcome {
            switch outcome {
            case .armed, .alreadyArmed:
                Text("Done. The next prompt arrives here with Allow and Deny on it, for "
                     + "sessions you start after this one. This one still belongs to its "
                     + "terminal.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .refused(let why):
                Text(why)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !armed {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Text("Chalant can take these instead, so the next one arrives here with Allow "
                     + "and Deny on it. One hook added to ~/.claude/settings.json, your old "
                     + "file copied aside first. It holds prompts only, so nothing that "
                     + "was not already being asked about gets interrupted.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Let me answer these here") {
                    outcome = HookInstall.armPrompts()
                    armed = HookInstall.answersPrompts()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule().fill(accent.opacity(0.5)).frame(width: 2)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(title: "Asking you, in its terminal", tint: accent)
                if !prompt.detail.isEmpty {
                    Text(prompt.detail)
                        .font(Theme.Fonts.captionMono)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Not "Chalant can't answer permission prompts", which
                // is what this said for two releases and is not true: it
                // can, and does, whenever the prompt reaches it. What is
                // true is narrower and about this one prompt. A session
                // reads its hooks when it starts, so anything already
                // running when the door opened never learned to knock.
                Text(armed
                     ? "This one came from a session that started before Chalant was set up to "
                       + "take prompts, so its terminal still owns it."
                     : "Chalant can't answer this one: nothing told it the prompt existed until "
                       + "it was already on screen. Its terminal, or the Claude app, can "
                       + "settle it.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                offerToHold
                HStack(spacing: Theme.Space.m) {
                    Button(session.hasTerminal == false ? "Open folder" : "Open terminal",
                           action: openTerminal)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(accent)
                    if let phone = SessionStore.Session.phoneURL(bridgeID: session.bridgeID) {
                        Button("Open on your phone") { NSWorkspace.shared.open(phone) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, Theme.Space.m)
        }
        .rowInsets()
        .chalantCard(radius: Theme.Radius.row)
    }
}

struct ApprovalCard: View {
    let approval: SessionStore.Approval
    let decide: (SessionStore.Approval.Decision) -> Void
    /// The folder this call is being made in, which is the only place a
    /// grant made here will ever apply. Empty means nowhere to scope
    /// one to, and the offer is withdrawn rather than widened.
    var repo: String = ""
    var grant: ((String, TimeInterval) -> Void)?
    @Environment(\.chalantAccent) private var accent

    /// Whatever the hook holding this one will actually wait, which is
    /// 25 seconds for the polling shim and its own `timeout` for an HTTP
    /// hook. Shown rather than hidden: the countdown is the promise that
    /// this ends, and a promise made with the wrong number is worse than
    /// none.
    private var patience: TimeInterval { approval.patience }

    /// A minute is a countdown. Ten minutes is a fact about the shape of
    /// the wait, and ticking it down second by second only makes a card
    /// look frantic about something that is not urgent yet.
    private func remaining(at now: Date) -> String {
        Self.remaining(
            patience: patience, askedAt: approval.askedAt, now: now,
            alsoInTerminal: approval.alsoInTerminal)
    }

    static func remaining(
        patience: TimeInterval, askedAt: Date, now: Date, alsoInTerminal: Bool
    ) -> String {
        let left = patience - now.timeIntervalSince(askedAt)
        guard left > 0 else {
            return alsoInTerminal ? "only the terminal can answer now" : "back to the terminal"
        }
        let tail = alsoInTerminal ? "then only the terminal can answer"
                                  : "then it asks the terminal"
        if left >= 90 { return "\(Int((left / 60).rounded(.up)))m, \(tail)" }
        return "\(Int(left.rounded(.down)))s, \(tail)"
    }

    /// The rule "always allow" would write, and the words on the button.
    private var exception: String {
        SessionStore.suggestedException(tool: approval.tool, detail: approval.detail)
    }

    /// The rule without its tool wrapper, so the button reads
    /// "Always allow git *" rather than "Always allow Bash(git *)".
    private var exceptionLabel: String {
        guard let open = exception.firstIndex(of: "("), exception.hasSuffix(")") else {
            return exception
        }
        return String(exception[exception.index(after: open)..<exception.index(before: exception.endIndex)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Wants to run \(approval.tool)")
                .font(Theme.Fonts.bodyEmphasis)
                .foregroundStyle(Theme.textPrimary)
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Said out loud because it is measured and it is surprising:
            // Claude Code paints its own prompt whatever a hook returns,
            // and it did so even when the answer came back four
            // milliseconds later. So this card is a second door onto one
            // question, not a replacement for the first, and somebody
            // who answers in the terminal instead has not done anything
            // wrong.
            if approval.alsoInTerminal {
                Text("Also on screen in its own terminal. Answering here settles it in both "
                     + "places.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.m) {
                Button("Allow") { decide(.allow) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
                Button("Deny") { decide(.deny) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                // The second option Claude Code's own prompt has always
                // had, and this card never did. Without it, holding
                // every command means answering the same question about
                // the same `git status` forever, which is how a person
                // stops reading the ones that matter. Says the exact
                // rule it will write, because a button that promises
                // something wider than it says is not consent.
                // Narrowed from what this used to be. It wrote a rule
                // with no folder and no end date, which is a strange
                // thing to be handed for pressing a button once while
                // looking at one command in one repo. Now it says the
                // pattern, the folder and how long, and every one of
                // those is a limit on what is being agreed to.
                if let grant, !repo.isEmpty {
                    Menu("Allow \(exceptionLabel) here for…") {
                        ForEach(Grant.expiries(), id: \.label) { choice in
                            Button(choice.label) {
                                grant(exception, choice.seconds)
                                decide(.allow)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Allows \(exception) in \((repo as NSString).lastPathComponent) "
                          + "and nowhere else, until it runs out. "
                          + "Undo it in Dashboard, Sessions.")
                } else {
                    Button("Always allow \(exceptionLabel)") {
                        SessionStore.addException(exception)
                        decide(.allow)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Adds \(exception) to the calls Chalant never holds. "
                          + "Undo it in Dashboard, Sessions.")
                }
                Spacer(minLength: 0)
                TimelineView(.periodic(from: approval.askedAt, by: 1)) { context in
                    Text(remaining(at: context.date))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .rowInsets()
        .chalantCard(radius: Theme.Radius.row)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(approval.tool) is waiting for your approval: \(approval.detail)")
    }
}
