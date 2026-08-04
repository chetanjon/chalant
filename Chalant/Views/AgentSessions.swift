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
///
/// The glance, and only the glance. Clicking through opens `SessionRoom`,
/// which is where the record of what has finished, the conversation and
/// the verbs live. This one stayed deliberately small: it is what a hover
/// gets, and a hover is somebody asking "is anything happening", not
/// "let me work in here". The law in the first paragraph is this view's
/// alone for the same reason; the room is allowed a bounded record
/// because opening it was a decision.
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
        // Tighter than the standard row gap: a card that reads as
        // belonging to the row above needs to sit close under it, not
        // float at the same distance a wholly separate row would.
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            rowLine(session)
            // Answering happens here rather than in the terminal the
            // question came from, which is the whole point: the island
            // already told you a session wants something.
            //
            // Above the question card, because it outranks one: a
            // question can wait, a held tool call is an agent standing
            // still until it is answered.
            if let approval = session.approval, approval.decision == nil {
                ApprovalCard(approval: approval) { decision in
                    sessions.decide(approvalID: approval.id, as: decision)
                }
            }
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
            // `stateSince`, not `updatedAt`. Discovery rewrites
            // `updatedAt` on every sweep, so this column said "now" on
            // every live row forever: it was reporting how recently this
            // app looked rather than anything about the session. It now
            // says what the row's own state measures, so a session that
            // has been mid-turn for four minutes says so.
            //
            // No state dot here, unlike the room's rail. The room needs
            // one because it draws four bands and has to say which; this
            // strip is live-only and already carries the one mark worth
            // carrying. A pair of rings said the state a second time
            // here once and were deleted for it (founder, 2026-08-02),
            // and a dot would be the same mistake in a smaller shape.
            Text(RelativeAge.short(session.stateSince))
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

    /// What to call this session, which the store decides: the record
    /// stores the same answer, and two places computing it separately is
    /// how the same session ended up with two different names in one
    /// rail. Kept as a forwarder rather than replaced at every call site
    /// because "the strip's title" is what those call sites mean.
    static func title(_ session: SessionStore.Session) -> String {
        SessionStore.displayTitle(for: session)
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
