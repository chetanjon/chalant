import AppKit
import SwiftUI

/// Claude Code sessions running on this Mac, discovered from the
/// metadata files Claude Code already writes. Only sessions that are
/// actually going appear: a developer's machine carries months of
/// history, and listing all of it would push a wall of finished work
/// into a surface whose whole premise is calm. Nothing running, nothing
/// rendered — the strip costs an idle island zero pixels.
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

    /// Three rows sit beside media, ambience and the switcher without
    /// the island outgrowing its panel. Beyond that the count carries
    /// the news, which is all a fourth row would have said anyway.
    private static let visibleLimit = 3

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
        if !live.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(live.prefix(Self.visibleLimit)) { session in
                    row(session)
                }
                if live.count > Self.visibleLimit {
                    // The count is the whole point of this line, so it
                    // reads at the tier for guidance rather than the one
                    // reserved for marks that say nothing.
                    Text("\(live.count - Self.visibleLimit) more running")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                        .padding(.horizontal, Theme.Space.l)
                }
            }
            // Same rule as ActivitiesStrip: the id list, not the rows.
            // Discovery rewrites `updatedAt` on every rescan, and
            // animating the sessions themselves re-ran the strip's
            // animation each time for no visible change.
            .animation(Theme.Motion.content, value: liveIDs)
        }
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
            AgentMark(agent: session.agent, size: 11, working: session.state == .working)
                .foregroundStyle(Theme.textTertiary)
            // Glyph as well as tint: a row that only changed colour
            // would say nothing to anyone reading it in greyscale. A
            // hollow ring for idle, distinct from working's dashed
            // circle — this is a session sitting still, not one going.
            Image(systemName: session.state == .needsInput ? "exclamationmark.circle.fill"
                  : session.state == .idle ? "circle" : "circle.dashed")
                .font(Theme.Fonts.icon(.s))
                .foregroundStyle(session.state == .needsInput ? accent : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // What it is doing wins the subtitle while it is doing
                // something: where a session lives changes rarely, what
                // it is up to changes constantly, and the second is the
                // reason to glance at all.
                Text(session.activity.map { "\($0) · \(Self.place(session))" }
                    ?? Self.place(session))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
              ? "Write to this session — \(session.cwd)"
              : session.cwd)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.agent.label): \(session.title), \(Self.place(session)), "
            + (session.state == .needsInput ? "waiting for you"
               : session.state == .idle ? "waiting for input" : "working")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the app running this session")
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
                tint: composing ? accent : Theme.textSecondary
            ) {
                model.composingSessionID = composing ? nil : session.id
            }
            .help(label)
            .accessibilityLabel(label)
        } else if session.agent == .cursor {
            // The affordance itself is absent: Cursor keeps no hook
            // contract with this app, so nothing queued here would ever
            // be collected (EC-17). The reason still needs somewhere to
            // live for anyone who goes looking for it.
            Image(systemName: "text.bubble")
                .font(Theme.Fonts.icon(.s))
                .foregroundStyle(Theme.textGhost)
                .help("Cursor keeps no hook here yet, so this session can't be messaged.")
                .accessibilityLabel("Cursor sessions cannot receive messages")
        }
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
        let folder = session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
        guard let branch = session.branch, !branch.isEmpty else { return folder }
        return "\(folder) · \(branch)"
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
                HoverGlyphButton(symbol: "arrow.up.circle.fill", scale: .m, tint: accent, action: send)
                    .accessibilityLabel("Send")
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
                Text(session.state == .idle
                     ? "Waiting for input. This arrives the next time it takes a turn."
                     : "Arrives when this turn ends.")
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
                Text("\(session.title) ended before reading this.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                Text(outbox.text)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.m) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(outbox.text, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
                    Button("Dismiss") { sessions.clearMessage(sessionID: session.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } else if outbox.deliveredAt != nil {
            Text("Delivered.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .task(id: outbox.deliveredAt) {
                    // Seen, then gone: a delivered card left standing
                    // would be a finished pill with no expiry of its own.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    sessions.clearMessage(sessionID: session.id)
                    if model.composingSessionID == session.id {
                        model.composingSessionID = nil
                    }
                }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // The whole pending text, not just a count: a second
                // message queued before the first is collected must
                // never hide the first (EC-10).
                Text(outbox.text)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.m) {
                    Text("Queued.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                    Button("Cancel") { sessions.clearMessage(sessionID: session.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
