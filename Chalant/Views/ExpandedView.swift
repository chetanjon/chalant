import SwiftUI

/// The island's open form: one state, voice-first. There is no text bar
/// and no More/Less, you speak (the mic, or hold the notch), and the
/// island shows only the blocks you keep on, sizing itself to fit.
struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var face: IslandFace
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var stopwatch: StopwatchController
    @ObservedObject var focus: FocusController
    @ObservedObject var ambience: AmbienceController
    @ObservedObject var activities: ActivityStore
    /// Observed in its own right for the same reason `Switcher` does
    /// (see TabRow.swift): a nested `ObservableObject` does not
    /// republish through `model`, and `enabledTools` below reads
    /// `stats.battery` to decide whether the tab even exists.
    @ObservedObject var stats: SystemStatsController

    // Modular blocks, each shows only if the user keeps it on. Media,
    // ambience and the tools are on out of the box; your day (calendar,
    // reminders) is opt-in, so a fresh island stays quiet and private.
    @AppStorage("showMedia") private var showMedia = true
    @AppStorage("showAmbience") private var showAmbience = true
    @AppStorage("showCalendar") private var showCalendar = false
    @AppStorage("showReminders") private var showReminders = false
    @AppStorage("toolGo") private var toolGo = true
    @AppStorage("toolClips") private var toolClips = true
    @AppStorage("toolShelf") private var toolShelf = true
    @AppStorage("toolNotes") private var toolNotes = true
    @AppStorage("toolFocus") private var toolFocus = true
    @AppStorage("toolChat") private var toolChat = true
    @AppStorage("toolSessions") private var toolSessions = true
    @AppStorage("toolBattery") private var toolBattery = true
    @AppStorage("chatFull") private var chatFull = false

    init(model: NotchViewModel, face: IslandFace) {
        self.model = model
        self.face = face
        self.music = model.music
        self.timer = model.timer
        self.stopwatch = model.stopwatch
        self.focus = model.focus
        self.ambience = model.ambience
        self.activities = model.activities
        self.stats = model.stats
    }

    private var todayEnabled: Bool { showCalendar || showReminders }

    /// The user's own width dial by default (`face.expandedWidth`,
    /// W-F). Full-mode chat (the expand glyph in the pane) is the one
    /// exception: 680 is where 0.8 zoom crosses the chat site's
    /// desktop breakpoint and the sidebar returns, so it survives as a
    /// floor under the dial there, never a ceiling on it.
    private var islandWidth: CGFloat {
        NotchViewModel.expandedWidth(
            configWidth: face.expandedWidth, tab: model.tab, pane: model.pane,
            chatFull: chatFull, focused: model.focusedTab != nil)
    }

    private var enabledTools: [NotchViewModel.Tab] {
        var tools: [NotchViewModel.Tab] = []
        if toolGo { tools.append(.links) }
        if toolClips { tools.append(.clipboard) }
        if toolShelf { tools.append(.shelf) }
        if toolNotes { tools.append(.notes) }
        if toolFocus { tools.append(.focus) }
        if toolChat { tools.append(.chat) }
        if toolSessions { tools.append(.sessions) }
        // Hidden outright on a Mac with no battery (a Mac mini, a
        // desktop docked in clamshell) rather than switched off by
        // default: there is nothing this tool toggle should even be
        // asked to remember on hardware that can never grow a
        // battery, and a tab that opens onto nothing is worse than
        // one that was never offered.
        if toolBattery, stats.battery != nil { tools.append(.battery) }
        return tools
    }

    /// The island you get by reaching for it: everything at once, small,
    /// and gone the moment you look away.
    private var glanceContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // Rows come from the layout rather than being written here,
            // so rearranging one is data rather than a code change.
            // Ordering, hiding and pairing all live in IslandLayout.
            ForEach(layoutRows) { row in
                if row.elements.count == 1 {
                    element(row.elements[0])
                } else {
                    // Tighter than the gap between rows (below), so a
                    // two-up row's pair reads as one group and the rows
                    // themselves read as separate ones (EC-15).
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(row.elements) { each in
                            element(each)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            // While a drag hovers, the body reaches further down the
            // screen, so the release happens nowhere near the top
            // edge and its Mission Control hot zone.
            if face.isDropTargeted {
                Color.clear.frame(height: 150)
            }
        }
    }

    /// The island you get by asking for it: one destination, the whole
    /// panel, and it stays until you leave.
    ///
    /// Everything the glance carries is gone here on purpose. Music,
    /// soundscapes and the switcher are what you look at when you have
    /// not decided what you came for; once you have, they are furniture
    /// between you and it.
    private func focusedContent(_ destination: NotchViewModel.Tab) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                HoverGlyphButton(
                    symbol: "chevron.left", label: "Back", scale: .m, tint: Theme.textSecondary
                ) {
                    withAnimation(Theme.Motion.content) { model.unfocus() }
                }
                Text(Switcher.label(destination))
                    .font(Theme.Fonts.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                HoverGlyphButton(
                    symbol: "gearshape", label: "Settings", scale: .m, tint: Theme.textTertiary
                ) {
                    model.collapse()
                    model.openDashboard?(nil)
                }
            }
            focusedPanel(destination)
                // Sized from this display's own chrome rather than from
                // a constant. `contentTopReserve` and `contentPadding`
                // are both user dials, so the room they leave is a
                // different number on every Mac, and the old flat 480
                // was wrong on all of them: too short here, and it would
                // have overflowed the panel had it been set for here.
                .frame(height: Theme.Panel.room(
                    topReserve: face.contentTopReserve, padding: face.contentPadding))
        }
    }

    @ViewBuilder
    private func focusedPanel(_ destination: NotchViewModel.Tab) -> some View {
        switch destination {
        case .sessions:
            AgentSessionsStrip(sessions: model.sessions, model: model, focused: true)
        default:
            // Nothing else claims `canFocus` yet, so nothing else can
            // reach here. An empty panel beats a crash if one ever does.
            EmptyPaneHint(message: "Nothing to show here yet.")
        }
    }

    var body: some View {
        Group {
            if let focused = model.focusedTab {
                focusedContent(focused)
            } else {
                glanceContent
            }
        }
        .padding(.horizontal, face.contentPadding)
        .padding(.top, face.contentTopReserve + Theme.Space.notchClearance)
        // The same inset as the sides, so the island reads as one box
        // rather than three different margins. It was 10 against the
        // sides' 16, which left the input crowded against the bottom
        // curve — and the belly sags below this, taking some of it back.
        .padding(.bottom, face.contentPadding)
        .foregroundStyle(.white)
        .frame(width: islandWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            // The island hugs its content, driven straight from geometry
            // (a `.preference`/`.onPreferenceChange` pair silently failed
            // in this hierarchy, freezing the island at its default size).
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size, initial: true) { _, size in
                        guard size.height > 0 else { return }
                        // Animated, with the shell's own spring, and that
                        // is the whole reason the island expands at all.
                        //
                        // This lands one layout pass after the state
                        // flip, so the shell is already mid-morph toward
                        // whatever size was measured last time. The
                        // island's `.animation(_:value: face.state)`
                        // does not cover this change — state did not
                        // change — so unanimated it SNAPPED the frame to
                        // full size on the very first frame, cancelling
                        // the morph. All that was left to see was the
                        // content's opacity fade: the border never grew,
                        // an already-open panel just faded in.
                        //
                        // The same spring retargets the motion already
                        // running rather than restarting it, so a stale
                        // first target curves into the real one as one
                        // continuous expansion.
                        withAnimation(Theme.Motion.island) {
                            model.expandedSize = CGSize(
                                width: size.width,
                                height: NotchViewModel.expandedHeight(
                                    measured: size.height, floor: face.expandedMinHeight))
                        }
                    }
                    // A tab switch can slip past the size observer and
                    // leave the shell wearing the previous tab's
                    // height (seen live: a void under the notes list);
                    // re-anchor after the new panel settles.
                    .onChange(of: model.tab) { _, _ in
                        DispatchQueue.main.async {
                            let size = geo.size
                            guard size.height > 0 else { return }
                            model.expandedSize = CGSize(
                                width: size.width,
                                height: NotchViewModel.expandedHeight(
                                    measured: size.height, floor: face.expandedMinHeight))
                        }
                    }
            }
        )
        // A drag over the island chalantrs the body with one large,
        // unmistakable target, so drops aim here, well below the
        // browser's tab strip, instead of at the little pill.
        .overlay {
            if face.isDropTargeted {
                dropTarget
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.hover, value: face.isDropTargeted)
        .animation(Theme.Motion.content, value: model.tab)
        .animation(Theme.Motion.content, value: chatFull)
        .animation(Theme.Motion.content, value: model.pane)
        .animation(Theme.Motion.content, value: music.nowPlaying != nil)
        .animation(Theme.Motion.content, value: ambience.active)
        .animation(Theme.Motion.content, value: model.pendingContext != nil)
        .animation(Theme.Motion.content, value: model.answer.isEmpty)
        .onExitCommand {
            withAnimation(Theme.Motion.content) {
                if model.pane != .none {
                    model.pane = .none
                } else {
                    model.collapse()
                }
            }
        }
    }

    /// The whole body as one drop zone while a drag hovers.
    private var dropTarget: some View {
        DropStashCard()
            .padding(Theme.Space.m)
            .allowsHitTesting(false)
    }

    /// The rows to draw. The welcome tour takes the island's chrome —
    /// the switcher and the panel — and leaves the content rows above
    /// it alone, which is how the tour has always behaved.
    private var layoutRows: [IslandRow] {
        let rows = model.layout.layout.rows
        guard model.pane == .welcome else { return rows }
        return rows.filter { row in !row.elements.contains { $0.isRequired } }
            + [IslandRow([.input])]
    }

    /// One placeable element, drawn.
    ///
    /// Each case keeps the condition that used to sit around it in the
    /// hard-coded stack: an element the user has placed still shows
    /// nothing when it has nothing to say.
    @ViewBuilder
    private func element(_ element: IslandElement) -> some View {
        switch element {
        case .timers:
            if focus.isActive || timer.isActive || stopwatch.isActive {
                SessionStrip(
                    kind: focus.isActive ? .focus : timer.isActive ? .timer : .stopwatch,
                    focus: focus, timer: timer, stopwatch: stopwatch
                ) {
                    withAnimation(Theme.Motion.content) { model.tab = .focus }
                }
                .transition(.opacity)
            }
            // A stopwatch running BESIDE a focus or timer session gets
            // its own strip; it used to run invisibly behind their
            // precedence with no control anywhere (review-caught).
            if stopwatch.isActive, focus.isActive || timer.isActive {
                SessionStrip(
                    kind: .stopwatch, focus: focus, timer: timer, stopwatch: stopwatch
                ) {
                    withAnimation(Theme.Motion.content) { model.tab = .focus }
                }
                .transition(.opacity)
            }
        case .media:
            // The row itself vanishes once it has nothing to show: the
            // mic that used to sit here regardless (H1, founder
            // 2026-08-02: "for microphone 2 remove it not needed near
            // the spotify") kept this row non-empty even with media off
            // and nothing playing. Voice is still always reachable, via
            // the `.talk` hotkey and the collapsed long-press; neither
            // goes through this view.
            if showMedia, music.nowPlaying != nil {
                MusicRow(music: music)
            } else if showMedia, music.preferredApp != nil {
                // The chip only appears once a player has earned it:
                // running now, or seen playing before. Guessing a
                // brand for a fresh Mac presumed too much.
                MusicLaunchChip(music: music)
            }
        case .activities:
            if !activities.activities.isEmpty {
                ActivitiesStrip(activities: activities) { sessionID in
                    // A pill can outlive the session that pushed it, so
                    // check before opening a composer that would have
                    // nothing to attach to. Saying so beats a click that
                    // does nothing, which is the bug this is fixing.
                    guard model.sessions.sessions.contains(where: { $0.id == sessionID }) else {
                        model.flashGlance("That session is no longer running")
                        return
                    }
                    model.composingSessionID =
                        model.composingSessionID == sessionID ? nil : sessionID
                }
                    .transition(.opacity)
            }
        case .sessions:
            // Moved into its own tab (B1); this row case is kept only
            // so a layout saved before that still decodes. `repaired()`
            // never places it, so this is never actually reached.
            EmptyView()
        case .ambience:
            if showAmbience {
                AmbienceRow(ambience: ambience)
                    .transition(.opacity)
            }
        case .switcher:
            // Every band used to sit the same distance from its
            // neighbour, so five rows read as five equal claims on the
            // eye. What is playing and what is sounding belong
            // together; the switcher and its panel are a different
            // thing, and the gap says so before the rule does.
            Rectangle()
                .fill(Theme.hairlineFaint)
                .frame(height: 1)
                .padding(.top, Theme.Space.xs)
            Switcher(model: model, updates: model.updates,
                     todayEnabled: todayEnabled, tools: enabledTools)
        case .input:
            if model.pane == .welcome {
                WelcomeView(model: model)
                    .transition(.opacity)
            } else {
                // Identity per tab, so SwiftUI sees a swap to transition
                // rather than one view quietly changing its contents.
                // Without it the panels simply popped: the switch above
                // returned a different body and nothing animated, which
                // is what `tabSlideDirection` was declared for and never
                // wired to.
                panel
                    .id(model.tab)
                    .transition(.asymmetric(
                        insertion: .move(edge: model.tabSlideDirection >= 0 ? .trailing : .leading)
                            .combined(with: .opacity),
                        // The outgoing panel fades where it stands. Two
                        // panels travelling at once reads as the whole
                        // island sliding, and the island is not moving.
                        removal: .opacity
                    ))
            }
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch model.tab {
        case .today:
            if todayEnabled {
                TodayView(
                    events: model.events,
                    showCalendar: showCalendar,
                    showReminders: showReminders,
                    onLeaveForSettings: { model.collapse() }
                )
            } else {
                AnswerView(model: model)
            }
        case .ask:
            AnswerView(model: model)
        case .links:
            ShortcutsView(model: model).frame(height: Theme.Panel.list)
        case .clipboard:
            ClipboardView(model: model)
                .frame(maxHeight: Theme.Panel.list, alignment: .top)
        case .shelf:
            ShelfView(model: model)
                .frame(maxHeight: Theme.Panel.list, alignment: .top)
        case .notes:
            NotesView(model: model)
                .frame(maxHeight: Theme.Panel.list, alignment: .top)
        case .focus:
            FocusPanel(
                focus: focus,
                timer: timer,
                stopwatch: stopwatch,
                stats: model.focusStats
            )
                .frame(height: Theme.Panel.focus)
        case .chat:
            ChatPane(chat: model.chat)
                .frame(height: chatFull ? Theme.Panel.chatFull : Theme.Panel.chat)
        case .sessions:
            AgentSessionsStrip(sessions: model.sessions, model: model)
                .frame(maxHeight: Theme.Panel.list, alignment: .top)
        case .battery:
            // `enabledTools` never offers this tab without a battery,
            // and `NotchViewModel.isAvailable` guards the one other
            // way a tab is reached (a restored last-open tab), so the
            // `if let` here is a second, cheap guarantee rather than
            // the only one: reachable with nothing to show is a
            // blank pane, never a crash.
            if let battery = stats.battery {
                BatteryPanel(battery: battery, stats: stats)
                    .frame(height: Theme.Panel.battery)
            }
        }
    }

}

/// The dashed "Drop to stash" card: over the island body while a drag
/// hovers it, and inside the mid-screen drop bubble that meets rising
/// drags away from the screen's top edge.
struct DropStashCard: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.black.opacity(0.86))
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    Theme.textTertiary,
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                )
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(Theme.Fonts.icon(.l))
                    .foregroundStyle(Theme.textSecondary)
                Text("Drop to stash")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                Text("Files and links to the shelf, images and text to clips.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
            }
        }
    }
}

/// A recognized call link on a calendar row: one tap and you're in the
/// room, no hunting through the invite.
private struct JoinChip: View {
    let url: URL
    @Environment(\.chalantAccent) private var accent
    @State private var hovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "video.fill")
                    .font(Theme.Fonts.icon(.xs))
                Text("Join")
                    .font(Theme.Fonts.caption)
            }
            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: 22)
            .background(Capsule().fill(accent.opacity(hovered ? 0.26 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help("Join the call")
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}

/// Live status pushed from outside: agents, deploys, renders, any
/// local process that curled the island. Needs-input leads and wears
/// the accent; finished rows fade out on their own timer.
private struct ActivitiesStrip: View {
    @ObservedObject var activities: ActivityStore
    /// Opens the session a row belongs to, when it belongs to one.
    /// Rows pushed by the Claude Code hook carry the session's own id
    /// behind a `claude-` prefix, and the pill saying an agent wants
    /// you did nothing at all when clicked, which is the one row on
    /// this strip somebody would certainly click (founder,
    /// 2026-08-02).
    var onOpenSession: ((String) -> Void)?
    @Environment(\.chalantAccent) private var accent

    /// The session id behind an activity id, when the row came from a
    /// session at all. `scripts/chalant-hook` posts `claude-<id>`.
    private static func sessionID(of activityID: String) -> String? {
        let prefix = "claude-"
        guard activityID.hasPrefix(prefix) else { return nil }
        let id = String(activityID.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    var body: some View {
        // Explicitly typed and hoisted, for the same reason as
        // AgentSessionsStrip: inlined in the `.animation` at the bottom
        // this map is enough to stall the type checker.
        let rowIDs: [String] = activities.activities.map(\.id)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(activities.activities) { activity in
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: activity.state.symbol)
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(tint(for: activity.state))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.title)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = activity.detail, !detail.isEmpty {
                            Text(detail)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(RelativeAge.short(activity.updatedAt))
                        .font(Theme.Fonts.microMono)
                        .foregroundStyle(Theme.textGhost)
                    IconActionButton(symbol: "xmark", label: "Dismiss this row", dim: true) {
                        activities.clear(id: activity.id)
                    }
                }
                .rowInsets()
                .chalantCard(radius: Theme.Radius.row)
                .modifier(OpensSession(
                    sessionID: Self.sessionID(of: activity.id),
                    onOpen: onOpenSession
                ))
            }
        }
        // Animate on which rows are here, not on their contents.
        // `Activity` carries `updatedAt`, which every push rewrites, so
        // animating the array itself restarted a 0.34s animation of the
        // whole strip on each one — eight agents pushing at 1Hz meant
        // eight full animations a second on a surface whose whole
        // premise is calm. Inserts, removals and reorders all change
        // the id list; a title changing in place needs no animation.
        .animation(Theme.Motion.content, value: rowIDs)
    }

    private func tint(for state: ActivityStore.State) -> Color {
        switch state {
        case .needsInput: return accent
        case .working: return Theme.textSecondary
        case .done: return Theme.textTertiary
        case .failed: return Theme.textSecondary
        }
    }
}

/// Nothing playing: one quiet chip that opens your player, so music
/// is a click away instead of a dock hunt.
private struct MusicLaunchChip: View {
    @ObservedObject var music: MusicController
    @State private var hovered = false

    private var label: String {
        // Only rendered when a preferred app exists (see the `.media`
        // case in `element(_:)`).
        music.preferredApp.map { "Open \($0.rawValue)" } ?? "Open music"
    }

    var body: some View {
        Button {
            music.openMusicApp()
        } label: {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "music.note")
                    .font(Theme.Fonts.icon(.xs))
                Text(label)
                    .font(Theme.Fonts.caption)
            }
            .foregroundStyle(hovered ? Theme.textSecondary : Theme.textTertiary)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: 22)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}

/// The voice affordance for messaging a session by speaking instead of
/// typing: lives in a session's compose card (`AgentSessions.swift`).
///
/// The media row used to carry its own copy of this button for
/// `.chalant` (talk to the app itself), removed per H1 (founder,
/// 2026-08-02: "not needed near the spotify"). That voice path did not
/// go away with it: the `.talk` global hotkey and the collapsed
/// island's long-press both call `beginListening()`/`toggleListening()`
/// directly and never went through this view. `destination` keeps its
/// full type rather than narrowing to `.session` alone, since
/// `VoiceDestination` is still a two-case enum shared with those other
/// callers and a switch here has to stay exhaustive over it regardless.
struct MicButton: View {
    let destination: NotchViewModel.VoiceDestination
    let action: () -> Void
    @State private var hovered = false

    private var helpText: String {
        switch destination {
        case .chalant: return "Speak, or hold the notch"
        case .session(_, let title): return "Speak to \(title)"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "mic.fill")
                .font(Theme.Fonts.icon(.m))
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.08 : 0.04)))
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .animation(Theme.Motion.hover, value: hovered)
    }
}

/// Your day, shown only when turned on. Calendar and reminders are
/// independent blocks; reminders tick off in place. Live from EventKit.
struct TodayView: View {
    @ObservedObject var events: EventKitService
    let showCalendar: Bool
    let showReminders: Bool
    /// System Settings is about to take focus, so the island gets out of
    /// the way first rather than sitting lit over the window it sent you
    /// to. Same move the gear makes.
    var onLeaveForSettings: () -> Void = {}
    @Environment(\.chalantAccent) private var accent

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    var body: some View {
        // Empty sections vanish instead of announcing their
        // emptiness; a fully clear day gets one graceful line.
        let hasEvents = showCalendar && !events.calendarDenied && !events.events.isEmpty
        let hasReminders = showReminders && !events.remindersDenied && !events.reminders.isEmpty
        let denials = denials
        let rowCount = (hasEvents ? events.events.count : 0)
            + (hasReminders ? events.reminders.count : 0)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            ForEach(denials) { denial in
                HStack(spacing: Theme.Space.s) {
                    Text(denial.text)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // Says what it does, not what you want: it opens the
                    // pane, macOS still asks you to flip the switch.
                    Button("Open Settings") {
                        onLeaveForSettings()
                        denial.open()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
                }
            }
            // A short day sits inline; a crowded one scrolls inside a
            // fixed box instead of pushing the island past the panel
            // window, which sliced the last rows flat.
            if rowCount > 8 {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        dayRows(hasEvents: hasEvents, hasReminders: hasReminders)
                    }
                }
                .frame(height: Theme.Panel.list)
            } else {
                dayRows(hasEvents: hasEvents, hasReminders: hasReminders)
            }
            // Speaks for the sources that can actually see. It used to
            // fall silent the moment anything was denied, so a granted
            // reminders list with nothing due said nothing at all and
            // the whole panel was one denial line. With every source
            // denied there is still nothing to report: "the day is
            // yours" over a permission wall is a guess dressed as a
            // fact, and the denial above is the whole story.
            if !hasEvents, !hasReminders, canSeeAnything {
                clearDay
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await events.refresh() }
    }

    @ViewBuilder
    private func dayRows(hasEvents: Bool, hasReminders: Bool) -> some View {
        if hasEvents { eventRows }
        if hasReminders {
            reminderRows
                .padding(.top, hasEvents ? Theme.Space.xs : 0)
        }
    }

    /// One header for the whole day, anchored by the date.
    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            SectionHeader(title: "Today")
            Rectangle()
                .fill(Theme.hairlineFaint)
                .frame(height: 1)
            Text(Self.dateFormatter.string(from: Date()))
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textGhost)
        }
    }

    /// A denial with the way out attached.
    ///
    /// This used to be a sentence naming three places to click, on the
    /// tab the island opens onto, which made a set of directions the
    /// most-read screen in the app. The directions were even correct.
    /// They were still directions.
    struct Denial: Identifiable {
        let id: String
        let text: String
        let open: () -> Void
    }

    private var denials: [Denial] {
        var out: [Denial] = []
        if showCalendar, events.calendarDenied {
            out.append(Denial(
                id: "calendar",
                text: "Calendar access is off, so today's events stay hidden.",
                open: EventKitService.openCalendarPrivacySettings))
        }
        if showReminders, events.remindersDenied {
            out.append(Denial(
                id: "reminders",
                text: "Reminders access is off, so nothing due shows here.",
                open: EventKitService.openRemindersPrivacySettings))
        }
        return out
    }

    private var seesCalendar: Bool { showCalendar && !events.calendarDenied }
    private var seesReminders: Bool { showReminders && !events.remindersDenied }
    private var canSeeAnything: Bool { seesCalendar || seesReminders }

    /// The empty moment, in the island's own voice.
    ///
    /// Claims only what it looked at. Half a view of the day cannot say
    /// the day is yours, and saying it anyway beside a line admitting
    /// the calendar is hidden is the app contradicting itself in two
    /// consecutive sentences.
    private var clearDay: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Clear water.")
                .font(Theme.Fonts.reading)
                .foregroundStyle(Theme.textSecondary)
            Text(Self.clearDayDetail(seesCalendar: seesCalendar, seesReminders: seesReminders))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textHint)
        }
        .padding(.vertical, Theme.Space.s)
    }

    static func clearDayDetail(seesCalendar: Bool, seesReminders: Bool) -> String {
        switch (seesCalendar, seesReminders) {
        case (true, true): return "Nothing scheduled, nothing due. The day is yours."
        case (true, false): return "Nothing scheduled."
        case (false, true): return "Nothing due."
        case (false, false): return ""
        }
    }

    private var eventRows: some View {
        let now = Date()
        return ForEach(events.events) { event in
            let past = !event.isAllDay && event.end < now
            HStack(spacing: Theme.Space.m) {
                Text(event.time)
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 58, alignment: .leading)
                Text(event.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                // The one about to start carries its countdown.
                if event.id == events.nextEvent?.id {
                    let closing = event.countdown(from: now)
                    Text(closing == "now" ? "now" : "in \(closing)")
                        .font(Theme.Fonts.captionMono)
                        .foregroundStyle(accent)
                }
                Spacer(minLength: 0)
                if let url = event.joinURL, !past {
                    JoinChip(url: url)
                }
            }
            .rowInsets()
            .chalantCard(radius: Theme.Radius.row)
            .hoverHighlight(radius: Theme.Radius.row)
            // The day so far settles back; what's ahead stays lit.
            .opacity(past ? 0.4 : 1)
        }
    }

    private var reminderRows: some View {
        ForEach(events.reminders) { reminder in
            ReminderRow(reminder: reminder, events: events)
        }
    }

}

/// One open reminder: a tick circle that fills on hover, the title,
/// and the due time when it has one. The whole row completes it.
private struct ReminderRow: View {
    let reminder: OpenReminder
    let events: EventKitService

    @State private var hovered = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    var body: some View {
        Button {
            Task { await events.complete(reminder) }
        } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: hovered ? "checkmark.circle" : "circle")
                    .font(Theme.Fonts.icon(.s))
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.textTertiary)
                Text(reminder.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let due = reminder.due {
                    Text(Self.timeFormatter.string(from: due))
                        .font(Theme.Fonts.captionMono)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .rowInsets()
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .chalantCard(radius: Theme.Radius.row)
        .hoverHighlight(radius: Theme.Radius.row)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        .help("Mark done")
    }
}


/// Makes an activity row reach its session, and leaves rows that have
/// no session completely alone: a hover highlight on something that
/// does nothing when clicked is a worse lie than no highlight.
private struct OpensSession: ViewModifier {
    let sessionID: String?
    let onOpen: ((String) -> Void)?

    func body(content: Content) -> some View {
        if let sessionID, let onOpen {
            content
                .hoverHighlight(radius: Theme.Radius.row)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(sessionID) }
                .help("Write to this session")
        } else {
            content
        }
    }
}
