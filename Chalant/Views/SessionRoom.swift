import AppKit
import SwiftUI

/// Every agent on this Mac, and the one you picked open beside them.
///
/// The island's focused destination for sessions, and the surface the
/// app's one unusual claim rests on. Two panes because four jobs have to
/// be true at once and none of them may be behind a tap: spot what is
/// blocked on you, read and answer without leaving, see everything at
/// once, and catch up on what ended while you were away.
///
/// What it replaced was a strip in a 480pt box: two rows at the top and
/// roughly 340pt of black under them, which reads as a fault rather than
/// as room to grow into. The room is not taller so much as filled.
struct SessionRoom: View {
    @ObservedObject var sessions: SessionStore
    @ObservedObject var model: NotchViewModel
    /// Computed by the caller from this display's own chrome
    /// (`Theme.Panel.room`), never a constant: every input to it is a
    /// user dial.
    let height: CGFloat

    /// A sidebar does not grow when its window does. Everything past
    /// this lands in the conversation, which is the part that benefits.
    private static let railWidth: CGFloat = 280

    /// Whether the rail is taking arrow keys. Set on appear, given up
    /// the moment the composer wants them.
    @FocusState private var railFocused: Bool

    private var bands: [(group: SessionStore.Group, live: [SessionStore.Session], ended: [SessionStore.Finished])] {
        sessions.groups()
    }

    /// Every row in the rail, in the order the eye reads them, so an
    /// arrow key crosses a band boundary the way it looks like it should
    /// rather than stopping at one.
    private var order: [String] {
        bands.flatMap { $0.live.map(\.id) + $0.ended.map(\.id) }
    }

    private func move(_ step: Int) {
        let rows = order
        guard !rows.isEmpty else { return }
        let current = model.selectedSessionID.flatMap { rows.firstIndex(of: $0) } ?? 0
        let next = min(max(current + step, 0), rows.count - 1)
        model.selectedSessionID = rows[next]
    }

    var body: some View {
        Group {
            if bands.isEmpty {
                // Deliberately not the two-pane frame with nothing in
                // it. A fixed height around an empty room reproduces
                // exactly the void this whole surface exists to fix.
                SessionRoomEmpty(model: model)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    SessionRail(sessions: sessions, model: model, bands: bands)
                        .frame(width: Self.railWidth)
                        // Its own material, not a hairline and a void.
                        //
                        // A rail holding two rows in a 600pt room leaves
                        // most of itself empty, which is normal for a
                        // sidebar and looks like a fault on a near-black
                        // backdrop: the first build of this read as the
                        // same hole the room was built to close, just
                        // moved to the left. A surface behind it says
                        // "this column has room" instead of "something
                        // failed to draw here".
                        .padding(.vertical, Theme.Space.m)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                .fill(Theme.surface)
                        )
                    detail
                }
                .frame(height: height)
            }
        }
        // Every one of these has a visible control that does the same
        // thing, which is this app's standing rule: the arrows are the
        // rail, return is the field, escape is the back chevron. They
        // are here because a room you can only drive with a mouse is not
        // one you can drive quickly.
        .focusable()
        .focused($railFocused)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        // No return-key handler, and that is a decision rather than an
        // omission.
        //
        // The plan called for return to focus the composer. It was
        // built, and it shut the island instead: the panel this room
        // lives in is an `NSPanel`, which has its own idea about that
        // key, and returning `.handled` from `onKeyPress` did not stop
        // it. Two attempts, one with and one without giving up the
        // rail's focus first, both collapsed on the spot (observed in
        // pixels, 2026-08-03). A key that closes the surface you are
        // working in is worse than a key that does nothing, so it is
        // not here. The field takes a click, which is how it would be
        // reached anyway.
        //
        // Escape went with it, untested and next to the same landmine.
        .onAppear {
            landOnSomething()
            railFocused = true
        }
        // The store re-sorts and re-bands constantly. Selection follows
        // only when what it pointed at has actually gone.
        .onChange(of: sessions.sessions.map(\.id)) { _, _ in landOnSomething() }
        .onChange(of: sessions.finished.map(\.id)) { _, _ in landOnSomething() }
    }

    @ViewBuilder
    private var detail: some View {
        if let live = selectedLive {
            SessionDetail(session: live, sessions: sessions, model: model)
        } else if let ended = selectedEnded {
            FinishedDetail(record: ended)
        } else {
            EmptyPaneHint(message: "Pick a session.")
        }
    }

    private var selectedLive: SessionStore.Session? {
        guard let id = model.selectedSessionID else { return nil }
        return bands.flatMap(\.live).first { $0.id == id }
    }

    private var selectedEnded: SessionStore.Finished? {
        guard let id = model.selectedSessionID else { return nil }
        return bands.flatMap(\.ended).first { $0.id == id }
    }

    /// Keep something open.
    ///
    /// Only ever moves selection when the selected id has left the rail
    /// entirely. A row arriving in Needs you is not permission to move
    /// somebody off the session they were typing into: a countdown
    /// running elsewhere is what the notification is for.
    ///
    /// Falls to the first row of the highest band rather than to
    /// nothing, because an empty detail pane beside a full rail is the
    /// void bug again in miniature.
    private func landOnSomething() {
        if selectedLive != nil || selectedEnded != nil { return }
        model.selectedSessionID = bands.first.flatMap { $0.live.first?.id ?? $0.ended.first?.id }
    }
}

/// Nothing has ever run here.
///
/// The one place in the app with room to say what the hook is for
/// without nagging: this is a surface somebody deliberately opened,
/// looking for agents, and finding none is the moment the setup step is
/// worth mentioning.
private struct SessionRoomEmpty: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            EmptyPaneHint(
                message: "No agents running.\nStart one here and you can drive it from the island."
            ) {
                NewSessionButton(compact: false)
            }
            if HookInstall.status() != .installed {
                VStack(spacing: Theme.Space.s) {
                    Text("Chalant can also carry their questions, hold risky commands, "
                         + "and take your replies. That part needs one hook.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set it up") { model.openDashboard?(.sessions) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(accent)
                }
                .frame(maxWidth: 380)
            }
        }
        .padding(.vertical, Theme.Space.xxl)
    }
}

// MARK: - The rail

private struct SessionRail: View {
    @ObservedObject var sessions: SessionStore
    @ObservedObject var model: NotchViewModel
    let bands: [(group: SessionStore.Group, live: [SessionStore.Session], ended: [SessionStore.Finished])]

    @AppStorage(SessionRoomSettings.densityKey) private var density = SessionRoomSettings.defaultDensity

    private var dense: Bool { density == "compact" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(bands, id: \.group) { band in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        header(band.group, count: band.live.count + band.ended.count)
                        ForEach(band.live) { session in
                            SessionRailRow(
                                title: AgentSessionsStrip.title(session),
                                subtitle: SessionActivity.railLine(
                                    for: session,
                                    disambiguating: collidingTitles
                                        .contains(AgentSessionsStrip.title(session))),
                                agent: session.agent,
                                state: session.state,
                                group: band.group,
                                trailing: RelativeAge.short(session.stateSince),
                                selected: model.selectedSessionID == session.id,
                                dense: dense
                            ) { model.selectedSessionID = session.id }
                        }
                        ForEach(band.ended) { record in
                            SessionRailRow(
                                title: record.title,
                                subtitle: SessionActivity.line(for: record).text,
                                agent: record.agent,
                                state: nil,
                                group: band.group,
                                trailing: SessionRoomFormat.clock(record.finishedAt),
                                selected: model.selectedSessionID == record.id,
                                dense: dense
                            ) { model.selectedSessionID = record.id }
                        }
                    }
                }
            }
            .padding(.trailing, Theme.Space.xs)
        }
        .scrollIndicators(.never)
    }

    private func header(_ group: SessionStore.Group, count: Int) -> some View {
        HStack(spacing: Theme.Space.s) {
            SectionHeader(title: group.title)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textGhost)
        }
        .padding(.horizontal, Theme.Space.s)
    }

    /// Titles that appear on more than one row right now.
    ///
    /// Claude Code names a session from its work, so two sessions in the
    /// same repo doing the same job get the same name: three live rows
    /// on this machine read "Push changes to PR and pull", in the same
    /// folder, on the same branch, and nothing on any of them told them
    /// apart (observed 2026-08-03). The spec called this ambiguous and
    /// left it; it turns out to be the ordinary case for anyone running
    /// two agents in one repo.
    private var collidingTitles: Set<String> {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for title in bands.flatMap({ $0.live.map(AgentSessionsStrip.title) + $0.ended.map(\.title) }) {
            if !seen.insert(title).inserted { repeated.insert(title) }
        }
        return repeated
    }

    // Where a session lives used to be this line. It moved to the
    // detail pane's own header, which already carried it, because a
    // folder name is looked up once and read never: it is the same on
    // every row for anyone working in one repo. The line is spent on
    // what the agent is doing instead. See `SessionActivity`.
}

private struct SessionRailRow: View {
    let title: String
    let subtitle: String
    let agent: SessionStore.Agent
    /// Nil for a row in the record: it has no state any more, only an
    /// outcome, and the drained dot says that on its own.
    let state: SessionStore.State?
    let group: SessionStore.Group
    let trailing: String
    let selected: Bool
    let dense: Bool
    let select: () -> Void

    @Environment(\.chalantAccent) private var accent

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                StateDot(group: group, state: state)
                    // Nudged onto the title's own line rather than the
                    // top of the row: a 6pt mark aligned to a 14pt
                    // line's box reads as floating above it.
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Theme.Space.s) {
                        AgentMark(agent: agent, size: 10, state: state)
                        Text(title)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // Compact drops it. Where it lives changes rarely
                    // and the title is what anybody picks by, so this is
                    // the line worth spending when rows are short.
                    if !dense {
                        Text("\(subtitle) · \(trailing)")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textGhost)
                            .lineLimit(1)
                            // Tail, not middle. This line used to be
                            // "folder · branch", where both ends carried
                            // meaning and the middle was the part to
                            // spend. It is now a sentence about what the
                            // agent is doing, and a sentence is read from
                            // the front: middle truncation turned
                            // "Decline the prompt and run from a neutral
                            // path" into "Decline the promp…neutral path"
                            // on this machine, which reads as two
                            // half-thoughts glued together.
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if dense {
                    Text(trailing)
                        .font(Theme.Fonts.microMono)
                        .foregroundStyle(Theme.textGhost)
                }
            }
            .rowInsets()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(selected ? accent.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.40) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(radius: Theme.Radius.row)
        .accessibilityLabel("\(title), \(group.title), \(subtitle)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// What a session is doing, in one 6pt mark that survives a still frame.
///
/// The `AgentMark` was carrying this alone through its rotation, which
/// says nothing in a screenshot and very little at 11pt in motion. Now
/// the mark answers "whose session" and this answers "doing what", and
/// neither restates the other.
private struct StateDot: View {
    let group: SessionStore.Group
    let state: SessionStore.State?

    @Environment(\.chalantAccent) private var accent

    private static let size: CGFloat = 6

    var body: some View {
        Group {
            switch group {
            case .needsYou:
                Circle().fill(accent)
            case .working:
                // The one that moves, because it is the one that is
                // still changing. Breath rather than a spinner: this is
                // a rail somebody reads down, not a progress bar.
                if Theme.Feel.current.ambient {
                    TimelineView(.animation(minimumInterval: 1 / 12)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                        Circle()
                            .fill(Theme.textPrimary)
                            .opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(phase * 2)))
                    }
                } else {
                    Circle().fill(Theme.textPrimary)
                }
            case .atPrompt:
                Circle().strokeBorder(Theme.textSecondary, lineWidth: 1.5)
            case .finished:
                Circle().strokeBorder(Theme.textGhost, lineWidth: 1)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

// MARK: - The detail pane

private struct SessionDetail: View {
    let session: SessionStore.Session
    @ObservedObject var sessions: SessionStore
    @ObservedObject var model: NotchViewModel

    @StateObject private var reader = TranscriptReader()
    @AppStorage(SessionRoomSettings.toolActivityKey) private var showsToolActivity = true
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            headline
            Divider().overlay(Theme.hairlineFaint)
            // Directly under the headline, above the transcript, because
            // the top of this pane is the only part guaranteed to be on
            // screen.
            //
            // These three were below the conversation, which reads
            // correctly (what it said, then what it is asking) and drew
            // them where nobody could see them. The conversation claims
            // `maxHeight: .infinity`, so anything after it lands at the
            // bottom of whatever height the room was given, and the
            // island does not always wear that height: measured
            // 2026-08-09 on the shipped 1.8.0, the room laid out at 686
            // while the island drew 326, putting a held call's Allow and
            // Deny at y=448, which is 122pt past the island's own edge.
            // The card the release exists for was built, positioned, and
            // invisible.
            //
            // The sizing bug behind that was fixed straight after
            // (a second writer re-anchoring from a frozen
            // `GeometryProxy`), so this is no longer load-bearing. It
            // stays because it is the better order anyway: an agent
            // frozen at a question is the most stuck a session gets, and
            // the thing blocking you belongs above the record of what
            // already happened.
            if let approval = session.approval, approval.decision == nil {
                ApprovalCard(approval: approval, decide: { decision in
                    sessions.decide(approvalID: approval.id, as: decision)
                }, repo: session.cwd, grant: { pattern, repo, duration in
                    model.policy.grant(pattern: pattern, repo: repo, for: duration)
                })
            }
            // Under the held call, for the same reason it sits there on
            // the ladder: this is the only card that appears without
            // anything being armed.
            if let prompt = session.pendingPrompt, !prompt.isStale {
                TerminalPromptCard(prompt: prompt, session: session) {
                    AgentSessionsStrip.go(to: session)
                }
            }
            if let ask = session.ask, !ask.isFullyAnswered {
                AskCard(ask: ask, answerQuestion: { index, choices in
                    sessions.answerQuestion(sessionID: session.id, questionIndex: index, with: choices)
                }, declined: {
                    model.activityServer.decline(askID: ask.id)
                    sessions.clearAsk(askID: ask.id)
                })
            }
            Conversation(
                turns: showsToolActivity ? reader.turns : reader.turns.filter { !$0.isTool },
                agentLabel: session.agent.label,
                empty: reader.loaded
                    ? "Nothing readable in this session's transcript yet."
                    : "Reading this session\u{2026}"
            )
            .frame(maxHeight: .infinity)
            if session.canReceiveMessages {
                // The same card the glance uses, minus the quoted last
                // message: the conversation above already carries it,
                // and twice is worse than once. Reused rather than
                // rewritten because the queue it manages (expired heads,
                // undelivered messages, collected receipts) is the
                // fiddliest thing in this feature and must not exist in
                // two versions.
                ComposeCard(session: session, sessions: sessions, model: model, showsLastWord: false)
            } else {
                unreachableNote
            }
            SessionActions(session: session)
        }
        .task(id: pollKey) { await poll() }
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            AgentMark(agent: session.agent, size: 13, state: session.state)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentSessionsStrip.title(session))
                    .font(Theme.Fonts.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    /// Where it lives, then what it is doing and for how long. The
    /// duration says what its state actually measures rather than how
    /// recently this app looked at it.
    private var subtitle: String {
        let folder = session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
        var parts = [folder]
        if let branch = session.branch, !branch.isEmpty { parts.append(branch) }
        let age = RelativeAge.short(session.stateSince)
        let elapsed = age == "now" ? "" : " \(age)"
        switch session.state {
        case .working: parts.append("running\(elapsed)")
        case .needsInput: parts.append("waiting on you\(elapsed)")
        case .idle: parts.append("at its prompt\(elapsed)")
        default: parts.append("last seen\(elapsed.isEmpty ? " just now" : elapsed)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var unreachableNote: some View {
        if let reason = AgentSessionsStrip.unreachableReason(session) {
            Text("Nothing can be sent to this session: \(reason).")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Following a live transcript

    /// Restarts the poll whenever either input to its cadence changes.
    private var pollKey: String { "\(session.id)|\(session.state.rawValue)" }

    /// Two seconds while it is mid-turn, ten while it sits at its
    /// prompt, and every one of those gated on the file's `mtime` having
    /// moved. Never at all while the room is closed, because this whole
    /// task is torn down with the view.
    private func poll() async {
        let cadence: UInt64 = session.state == .working ? 2 : 10
        while !Task.isCancelled {
            await reader.refresh(path: session.transcriptPath)
            try? await Task.sleep(nanoseconds: cadence * 1_000_000_000)
        }
    }
}

/// A row in the record, opened.
///
/// Read-only and says so. The composer is replaced rather than disabled:
/// a live-looking field that silently goes nowhere is the thing this app
/// keeps deciding not to do.
private struct FinishedDetail: View {
    let record: SessionStore.Finished

    @StateObject private var reader = TranscriptReader()
    @AppStorage(SessionRoomSettings.toolActivityKey) private var showsToolActivity = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                AgentMark(agent: record.agent, size: 13, state: .stale)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title)
                        .font(Theme.Fonts.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(Theme.hairlineFaint)
            if reader.loaded, reader.turns.isEmpty, let said = record.lastMessage {
                // The transcript has been rotated away. What the record
                // kept is all there is, and saying so beats an empty
                // column that looks like a failure to load.
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("This session's transcript is gone. The last thing it said:")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                    // Unfolded: this is the only thing left of the
                    // session, so there is nothing for it to crowd out.
                    QuotedBlock(text: said, foldable: false)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Conversation(
                    turns: showsToolActivity ? reader.turns : reader.turns.filter { !$0.isTool },
                    agentLabel: record.agent.label,
                    empty: reader.loaded ? "Nothing readable in this transcript." : "Reading\u{2026}"
                )
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: Theme.Space.m) {
                Text(endedNote)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button("Open folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: record.cwd))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .task(id: record.id) { await reader.refresh(path: record.transcriptPath) }
    }

    private var subtitle: String {
        let folder = record.cwd.split(separator: "/").last.map(String.init) ?? record.cwd
        var parts = [folder]
        if let branch = record.branch, !branch.isEmpty { parts.append(branch) }
        parts.append(SessionRoomFormat.clock(record.finishedAt))
        return parts.joined(separator: " · ")
    }

    /// `.lost` never claims the session finished. The registry stopped
    /// seeing the process, which is all this app can honestly say.
    private var endedNote: String {
        switch record.outcome {
        case .done: return "This session finished."
        case .failed: return "This session ended in a failure."
        case .lost: return "This session's process went away. Chalant can't say how it ended."
        }
    }
}

// MARK: - The conversation

private struct Conversation: View {
    let turns: [SessionDiscovery.Turn]
    let agentLabel: String
    let empty: String

    var body: some View {
        if turns.isEmpty {
            EmptyPaneHint(message: empty)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(turns) { turn in
                        TurnRow(turn: turn, agentLabel: agentLabel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Theme.Space.s)
            }
            .scrollIndicators(.never)
            // Grows up off the composer, the way every conversation does.
            //
            // Tried the other way round, top-aligned, on the theory that
            // a half-empty pane should fill from the top like a list.
            // In pixels it was worse: the gap lands *between* the last
            // thing the agent said and the box you answer it in, which
            // is the one adjacency on this pane that carries meaning.
            // Empty room above a short conversation reads as "this only
            // just started"; empty room below it reads as a layout
            // fault.
            .defaultScrollAnchor(.bottom)
        }
    }
}

private struct TurnRow: View {
    let turn: SessionDiscovery.Turn
    let agentLabel: String

    @Environment(\.chalantAccent) private var accent

    var body: some View {
        switch turn.kind {
        case let .said(who, text):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("\(who == .you ? "you" : agentLabel) · \(RelativeAge.short(turn.at))")
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(Theme.textGhost)
                QuotedBlock(text: text, tint: who == .you ? accent.opacity(0.45) : Theme.textGhost)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .did(tool, detail, _, finishedAt):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Circle()
                    .fill(finishedAt == nil ? Color.clear : Theme.textGhost)
                    .overlay(
                        Circle().strokeBorder(
                            finishedAt == nil ? accent : Color.clear, lineWidth: 1.5)
                    )
                    .frame(width: 5, height: 5)
                Text(SessionDiscovery.turnVerb(forTool: tool, live: finishedAt == nil))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Fonts.captionMono)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if finishedAt == nil {
                    Text(RelativeAge.short(turn.at))
                        .font(Theme.Fonts.microMono)
                        .foregroundStyle(Theme.textGhost)
                }
            }
            .padding(.leading, 2)
        }
    }
}

/// The rule-and-text treatment for anything somebody said.
///
/// The same shape `ComposeCard`'s quoted last message uses, pulled out
/// so a conversation of twenty of them cannot drift from the one under
/// the composer.
struct QuotedBlock: View {
    let text: String
    var tint: Color = Theme.textGhost
    /// Long turns start folded. A conversation is twenty of these
    /// stacked, and an agent's turn routinely runs to pages: unfolded,
    /// one of them fills the pane and everything around it becomes
    /// scrollback. The founder's word for the result was that it was not
    /// readable (2026-08-03).
    ///
    /// Folded, never truncated. The toggle is always there when there is
    /// more, which is the rule `ComposeCard` already settled: text cut
    /// off with no way through is its own bug.
    var foldable = true

    @State private var open = false
    @Environment(\.chalantAccent) private var accent

    private static let foldedLines = 6

    private var long: Bool { ComposeCard.mayBeClipped(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: 2)
                Text(ComposeCard.rendered(text))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .lineLimit(foldable && long && !open ? Self.foldedLines : nil)
                    .fixedSize(horizontal: false, vertical: !(foldable && long && !open))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if foldable, long {
                Button(open ? "Show less" : "Show everything") {
                    withAnimation(Theme.Motion.content) { open.toggle() }
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(accent)
                .padding(.leading, Theme.Space.m + 2)
            }
        }
    }
}

/// Start an agent somewhere Chalant can actually reach.
///
/// The gap this closes: an agent started in an editor's built-in
/// terminal cannot be typed into from outside, and nobody knows that
/// before they choose where to work. A session begun here lands in
/// Terminal or iTerm, which means it is remote controllable from the
/// moment it exists, and the choice is made for the user rather than
/// explained to them.
struct NewSessionButton: View {
    var compact = true
    @State private var note: String?
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        Group {
            if compact {
                HoverGlyphButton(
                    symbol: "plus", label: "Start a session Chalant can reach",
                    scale: .m, tint: Theme.textTertiary
                ) { pick() }
            } else {
                Button("Start a session") { pick() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
            }
        }
        .help(note ?? "Opens a terminal here and runs Claude Code in it")
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start here"
        panel.message = "Pick the folder to run the agent in."
        // A background app's panel opens behind everything otherwise,
        // and reads as the button having done nothing.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            if case .cannot(let why) = await SessionRemote.newSession(in: folder) {
                note = why
            }
        }
    }
}

// MARK: - Verbs

private struct SessionActions: View {
    let session: SessionStore.Session

    @State private var copied = false

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            // Says what it will actually do. `hasTerminal == false` is
            // the kernel saying, positively, that this process holds no
            // controlling terminal, so there is no window to raise and
            // promising one would be a lie.
            Button(session.hasTerminal == false ? "Open folder" : "Open terminal") {
                AgentSessionsStrip.go(to: session)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // Only where it is true. A bridged session is one the Claude
            // app can drive, so this hands over the door rather than
            // this app building a second one. A session with no bridge
            // gets no button, because there would be nothing behind it.
            if let phone = SessionStore.Session.phoneURL(bridgeID: session.bridgeID) {
                Button("Open on your phone") { NSWorkspace.shared.open(phone) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("This session is bridged to claude.ai/code, so the Claude app "
                          + "on your phone can see it and type into it.")
            }
            Button(copied ? "Copied" : "Copy id") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
                copied = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        // There is no Stop here, and it is not an oversight.
        //
        // The design specified one: SIGINT to the pid, two-step, on the
        // theory that SIGINT is what Ctrl-C sends and Ctrl-C interrupts
        // a turn without ending the session. It was gated on proving
        // that against a real session before being wired to a button,
        // and the proof came back the other way (2026-08-03, two
        // throwaway sessions under a pty): SIGINT kills the Claude Code
        // process outright, sent to the pid and sent to the process
        // group alike.
        //
        // The reason is that Ctrl-C in Claude Code's own terminal is
        // never a signal at all. The TUI holds the tty in raw mode and
        // reads it as a keystroke, so the interrupt everybody has in
        // mind has no out-of-band equivalent to reach for. A button here
        // would not have stopped a turn, it would have destroyed
        // whatever the agent had not yet written down.
        //
        // The thing that does stop an agent from outside is already in
        // this app and already works: a `PreToolUse` rule holds the call
        // at the door and Deny refuses it. That is the honest verb, it
        // lives on the approval card, and it is where anyone looking for
        // "stop" should be pointed.
        .animation(Theme.Motion.hover, value: copied)
        .onChange(of: session.id) { _, _ in copied = false }
    }
}

// MARK: - Reading a live transcript

/// Holds one session's conversation and re-reads it only when the file
/// has actually moved.
///
/// The `mtime` gate lives here rather than inside
/// `SessionDiscovery.turns(atTranscript:)` so that reader stays a pure
/// function of a path: a test can call it without faking a clock, and
/// the policy about how often to look belongs to the surface that is
/// looking.
@MainActor
final class TranscriptReader: ObservableObject {
    @Published private(set) var turns: [SessionDiscovery.Turn] = []
    /// Whether a read has completed, so an empty conversation can tell
    /// "nothing in this transcript" from "not read yet". Without it the
    /// pane says "nothing here" for the first beat of every session it
    /// opens, which reads as a bug.
    @Published private(set) var loaded = false

    private var path: String?
    private var mtime: Date?

    func refresh(path next: String?) async {
        guard let next else {
            turns = []
            loaded = true
            return
        }
        if next != path {
            path = next
            mtime = nil
            turns = []
            loaded = false
        }
        let moment = (try? FileManager.default
            .attributesOfItem(atPath: next)[.modificationDate]) as? Date
        // A stat is free; re-reading and re-parsing 256KB because a
        // timer fired is not.
        guard moment != mtime else { return }
        mtime = moment
        // Off the main actor: this is a quarter of a megabyte of JSONL
        // per read, and the island is a surface whose whole promise is
        // that it never stutters.
        let read = await Task.detached(priority: .utility) {
            SessionDiscovery.turns(atTranscript: next)
        }.value
        guard path == next else { return }  // selection moved mid-read
        if let read { turns = read }
        loaded = true
    }
}

// MARK: - Settings keys

/// The room's own user choices.
///
/// Keys and defaults in one place so the store, the room and the
/// settings pane cannot drift on a string. The bands' own visibility
/// keys live on `SessionStore.Group`, beside the code that reads them.
enum SessionRoomSettings {
    static let densityKey = "sessionRowDensity"
    static let defaultDensity = "comfortable"
    static let toolActivityKey = "sessionShowsToolActivity"
}

enum SessionRoomFormat {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
}

extension SessionDiscovery.Turn {
    /// Whether this is the agent doing something rather than saying
    /// something, which is the half the user can switch off.
    var isTool: Bool {
        if case .did = kind { return true }
        return false
    }
}
