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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            rowLine(session)
            // Answering happens here rather than in the terminal the
            // question came from, which is the whole point: the island
            // already told you a session wants something.
            if let ask = session.ask, ask.answer == nil {
                AskCard(ask: ask) { choices in
                    sessions.answer(sessionID: session.id, with: choices)
                }
            }
            // The composer goes in the slot AskCard occupies, under the
            // row it belongs to: no second element, no stored layout
            // migration for a surface that already has a home
            // (notch-messaging-plan-2026-08-01.md, W-C rationale).
            if model.composingSessionID == session.id {
                ComposeCard(session: session, sessions: sessions, model: model)
            }
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
    /// Four lines, because this is a glance surface and an agent can
    /// write an essay. The whole thing is one tap away in the terminal,
    /// which the row itself already reaches.
    @ViewBuilder
    private var lastWord: some View {
        if let said = session.lastMessage, !said.isEmpty {
            Text(said)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("It said: \(said)")
        }
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
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queued.text)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(index == 0 ? "Next" : "Queued")
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Button {
                            sessions.cancelMessage(id: queued.id, for: session.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(Theme.Fonts.icon(.s))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Cancel this message")
                        .accessibilityLabel("Cancel this message")
                    }
                }
            }
        }
    }
}

/// A question an agent is waiting on, answerable in place.
///
/// Options are buttons rather than a menu: there are at most six, and a
/// menu would hide the choice behind a click on a surface whose whole
/// job is to have already told you.
private struct AskCard: View {
    let ask: SessionStore.Ask
    let answer: ([String]) -> Void

    /// Only used when several may be picked. A single-choice question
    /// answers on the tap and never reads this.
    @State private var picked: Set<String> = []

    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(ask.question)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: Theme.Space.s) {
                ForEach(ask.options, id: \.self) { option in
                    optionChip(option)
                }
            }
            if ask.multiSelect {
                Button("Send") { answer(Array(picked)) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
                    // Nothing chosen is not an answer, and sending one
                    // would tell the agent the user decided when they
                    // did not.
                    .disabled(picked.isEmpty)
            }
        }
        .rowInsets()
        .chalantCard(radius: Theme.Radius.row)
    }

    private func optionChip(_ option: String) -> some View {
        let on = picked.contains(option)
        return Button {
            guard ask.multiSelect else {
                answer([option])
                return
            }
            if on { picked.remove(option) } else { picked.insert(option) }
        } label: {
            Text(option)
                .font(Theme.Fonts.caption)
                .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(on ? accent.opacity(0.18) : Theme.surface)
                )
                .overlay(
                    Capsule().strokeBorder(on ? accent.opacity(0.4) : .clear, lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}
