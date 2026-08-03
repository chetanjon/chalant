import AppKit
import SwiftUI

/// Claude Code sessions running on this Mac, discovered from the
/// metadata files Claude Code already writes. Only sessions that are
/// actually going appear: a developer's machine carries months of
/// history, and listing all of it would push a wall of finished work
/// into a surface whose whole premise is calm.
///
/// Its own tab rather than a row in the island body (B1, founder
/// 2026-08-02: "add a tab to see a list of all the sessions running
/// instead of making it exist in the view directly"). `HuggingList`
/// hugs the few and scrolls the many, so the tab shows every live
/// session rather than three plus a count.
///
/// Named for agents rather than sessions because "session" is already
/// taken here by the focus/timer strip (`SessionStrip`); the store keeps
/// Claude Code's own vocabulary, the surface uses the island's.
struct AgentSessionsStrip: View {
    @ObservedObject var sessions: SessionStore
    /// Only reached for `composingSessionID` and the voice pipeline;
    /// see that property's doc for why it lives on the model rather
    /// than as this view's own `@State`.
    @ObservedObject var model: NotchViewModel
    /// Given the island's whole panel rather than a slice of it. The
    /// rows are the same; what changes is that there is room for all of
    /// them and for a composer under one, at once, without the list
    /// collapsing to two lines and a scrollbar.
    var focused = false
    @Environment(\.chalantAccent) private var accent

    /// Working, waiting, or idle — anything actually alive. `stale` is
    /// honest about what discovery can know from a file alone — "last
    /// seen", not "running" — and a last-seen row is history, not
    /// attention. `idle` is different from `stale`: the registry has
    /// confirmed the process is still there, sitting at its prompt, and
    /// that is exactly the session someone would most want to message
    /// (notch-messaging-plan-2026-08-01.md, finding 3).
    private var live: [SessionStore.Session] {
        sessions.sessions.filter {
            $0.state == .working || $0.state == .needsInput || $0.state == .idle
        }
    }

    var body: some View {
        let live = live
        // Hoisted and explicitly typed: inlined into the `.animation`
        // below, the map sent the type checker into an expression it
        // could not solve in reasonable time and the build hung.
        let liveIDs: [String] = live.map(\.id)
        Group {
            if live.isEmpty {
                EmptyPaneHint(message: "Nothing running. Start Claude Code in any terminal and it shows up here.")
            } else if focused {
                // Top-aligned rather than hugging: a list given the
                // whole panel must not centre two rows in the middle of
                // it, which reads as a layout mistake rather than as
                // room to grow into.
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(live) { session in
                            row(session)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                HuggingList {
                    ForEach(live) { session in
                        row(session)
                    }
                }
            }
        }
        // Same rule as ActivitiesStrip: the id list, not the rows.
        // Discovery rewrites `updatedAt` on every rescan, and animating
        // the sessions themselves re-ran the strip's animation each
        // time for no visible change.
        .animation(Theme.Motion.content, value: liveIDs)
    }

    private func row(_ session: SessionStore.Session) -> some View {
        // Tighter than the standard row gap: a card that reads as
        // belonging to the row above needs to sit close under it, not
        // float at the same distance a wholly separate row would.
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            rowLine(session)
            // Answering happens here rather than in the terminal the
            // question came from, which is the whole point: the island
            // already told you a session wants something.
            //
            // `isFullyAnswered`, never just the first question's answer:
            // a bundle two of three questions answered is still a
            // session that wants you, and the old single-question check
            // would have hidden the card the moment question one landed.
            if let ask = session.ask, !ask.isFullyAnswered {
                AskCard(ask: ask, answer: { choices in
                    sessions.answer(sessionID: session.id, with: choices)
                }, answerQuestion: { index, choices in
                    sessions.answerQuestion(sessionID: session.id, questionIndex: index, with: choices)
                }, queue: { label in
                    sessions.queue(message: label, for: session.id)
                })
            }
            // The composer goes in the slot AskCard occupies, under the
            // row it belongs to: no second element, no stored layout
            // migration for a surface that already has a home
            // (notch-messaging-plan-2026-08-01.md, W-C rationale).
            if model.composingSessionID == session.id {
                ComposeCard(session: session, sessions: sessions, model: model)
            } else if focused {
                // What it said, on the row, once there is room for it.
                //
                // In the glance this lives inside the composer, because
                // a strip four rows tall cannot afford it and a name
                // alone is enough to pick from. Given the whole panel
                // the trade reverses: a list of names in a room this
                // size is a room with nothing in it, and the reason to
                // open a session is almost always what it just said.
                //
                // Only when the composer is closed. Open, the composer
                // shows the same words directly above its own field,
                // and twice is worse than once.
                lastWord(session)
            }
        }
    }

    /// The agent's last words, trimmed to a glance's worth.
    ///
    /// Three lines, not the composer's four: this one repeats down a
    /// list, so its job is to let you recognise a session rather than
    /// to read it. Opening the composer is where reading happens.
    @ViewBuilder
    private func lastWord(_ session: SessionStore.Session) -> some View {
        if let said = session.lastMessage, !said.isEmpty {
            Text(said)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.xs)
                .accessibilityLabel("It said: \(said)")
        }
    }

    private func rowLine(_ session: SessionStore.Session) -> some View {
        HStack(spacing: Theme.Space.m) {
            // Whose session it is, then what it wants. Two rows from
            // two different agents are otherwise identical at a glance.
            // The mark carries the state itself: turning while the
            // session works, still and coloured while it waits, drained
            // of colour once it is gone. The dashed and hollow rings
            // that used to sit beside it said the same thing a second
            // time and were dropped (founder, 2026-08-02).
            AgentMark(agent: session.agent, size: 11, state: session.state)
                // A row you cannot reach is still worth seeing, and
                // still not the row you came here for.
                .opacity(Self.unreachableReason(session) == nil ? 1 : 0.55)
            // The one mark that survived, because it is the only one
            // that was not a restatement: a session asking for an
            // answer is the whole reason to look at this list, and
            // "coloured and still" already means idle.
            if session.state == .needsInput {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(Theme.Fonts.icon(.s))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(session))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // What it is doing wins the subtitle while it is doing
                // something: where a session lives changes rarely, what
                // it is up to changes constantly, and the second is the
                // reason to glance at all. Absent when it would only
                // repeat the line above it.
                if let subtitle = Self.subtitle(session) {
                    Text(subtitle)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Text(RelativeAge.short(session.updatedAt))
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textGhost)
            composeAffordance(session)
        }
        .rowInsets()
        .chalantCard(radius: Theme.Radius.row)
        .hoverHighlight(radius: Theme.Radius.row)
        .contentShape(Rectangle())
        // Opens the composer rather than going anywhere. Clicking a
        // row used to try to raise the terminal it came from and, when
        // it could not find one, fall back to opening the folder in
        // Finder, so the common outcome of clicking a session was a
        // Finder window (founder, 2026-08-02). Reaching the terminal
        // stays available on its own button inside the composer, where
        // it is labelled and cannot surprise anyone.
        .onTapGesture {
            guard session.canReceiveMessages else { return }
            model.composingSessionID = model.composingSessionID == session.id ? nil : session.id
        }
        .help(session.canReceiveMessages
              ? "Write to this session. \(session.cwd)"
              : session.cwd)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.agent.label): \(Self.title(session)), \(Self.place(session)), "
            + (session.state == .needsInput ? "waiting for you"
               : session.state == .idle ? "waiting for input" : "working")
            + (Self.unreachableReason(session).map { ", \($0)" } ?? "")
        )
        .accessibilityAddTraits(.isButton)
        // The tap opens the composer. It used to reach for the terminal
        // and the hint was never updated when that moved onto its own
        // labelled button inside the composer.
        .accessibilityHint(session.canReceiveMessages
                           ? "Opens a box to write to this session"
                           : "This session cannot be written to")
    }

    /// The row's own tap keeps meaning "go to this session"; this is a
    /// second, narrower tap target for a second meaning, exactly the
    /// way `ShelfView`'s trailing clear button sits inside a tappable
    /// row without stealing its tap.
    @ViewBuilder
    private func composeAffordance(_ session: SessionStore.Session) -> some View {
        if session.canReceiveMessages {
            let composing = model.composingSessionID == session.id
            let label = composing ? "Close the composer" : "Message this session"
            IconActionButton(
                symbol: composing ? "text.bubble.fill" : "text.bubble",
                label: label,
                tint: composing ? accent : Theme.textSecondary
            ) {
                model.composingSessionID = composing ? nil : session.id
            }
        }
        // Nothing otherwise. A greyed bubble used to sit here carrying
        // the reason in a tooltip, which is a place nobody looks before
        // deciding a feature is broken. The reason moved into the
        // subtitle, where it is read without being hunted for, and the
        // icon went with it rather than saying it twice.
    }

    /// Bring up whatever is running this session.
    ///
    /// The folder is the fallback rather than the answer: a session
    /// whose process has since exited still has somewhere to go, and a
    /// row that did nothing when clicked would read as broken.
    static func go(to session: SessionStore.Session) {
        guard !SessionLocator.reveal(cwd: session.cwd) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
    }

    /// Folder, then branch when the folder is a repo. The last path
    /// component alone is what the eye actually matches against the
    /// terminal it came from; the full path lives in the tooltip.
    private static func place(_ session: SessionStore.Session) -> String {
        guard let branch = session.branch, !branch.isEmpty else { return folder(session) }
        return "\(folder(session)) · \(branch)"
    }

    private static func folder(_ session: SessionStore.Session) -> String {
        session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
    }

    /// Why a message left on this row would never be read, or nil when
    /// it would. Both answers are things the row itself now says.
    static func unreachableReason(_ session: SessionStore.Session) -> String? {
        if session.hasTerminal == false { return "no terminal" }
        // Cursor keeps no hook contract with this app, so nothing
        // queued here would ever be collected (EC-17).
        if session.agent == .cursor { return "no hook yet" }
        return nil
    }

    /// A session that never earned a title from its transcript falls
    /// back to its folder name, and for a headless process that folder
    /// is an implementation detail of whatever spawned it. Naming it
    /// for what it is beats naming it after a directory the person has
    /// never opened.
    ///
    /// Only the fallback is replaced. A headless session that does have
    /// a real title keeps it, because that title is the one thing on
    /// the row that was worth reading.
    static func title(_ session: SessionStore.Session) -> String {
        guard session.hasTerminal == false, session.title == folder(session)
        else { return session.title }
        return "Background task"
    }

    /// What it is doing, where it lives, and why you cannot write to it,
    /// in that order, dropping whichever of the three does not apply.
    ///
    /// Nil when the whole line would only repeat the title above it,
    /// which is what a row with no activity, no branch and a
    /// folder-name title used to do: the same word, twice, in two
    /// sizes.
    static func subtitle(_ session: SessionStore.Session) -> String? {
        var parts: [String] = []
        if let activity = session.activity { parts.append(activity) }
        parts.append(place(session))
        if let reason = unreachableReason(session) { parts.append(reason) }
        let line = parts.joined(separator: " · ")
        return line == title(session) ? nil : line
    }
}

/// A message to a running session: typed or spoken, sent on return or
/// on the mic's release. No confirmation step: the words are already
/// visible in the field, and an agent is not a person, so the "say
/// send to confirm" staging a spoken text message to a human gets does
/// not apply here (Open Question 1, notch-messaging-plan-2026-08-01.md).
///
/// One line of field, one line of status, never more. The island is a
/// glance surface, and this composer is the row most likely to try to
/// grow past that.
private struct ComposeCard: View {
    let session: SessionStore.Session
    @ObservedObject var sessions: SessionStore
    @ObservedObject var model: NotchViewModel

    @State private var draft = ""
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
        if let said = session.lastMessage, !said.isEmpty {
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
        .disabled(!hookInstalled)
        .animation(Theme.Motion.hover, value: draft.isEmpty)
    }

    private func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !typed.isEmpty else { return }
        sessions.queue(message: typed, for: session.id)
    }

    @ViewBuilder
    private var statusLine: some View {
        if !hookInstalled {
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
private struct AskCard: View {
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
        if writingOther {
            HStack(spacing: Theme.Space.s) {
                TextField("Something else", text: $otherText)
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
