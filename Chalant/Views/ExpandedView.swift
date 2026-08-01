import SwiftUI

/// The island's open form: one state, voice-first. There is no text bar
/// and no More/Less, you speak (the mic, or hold the notch), and the
/// island shows only the blocks you keep on, sizing itself to fit.
struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var stopwatch: StopwatchController
    @ObservedObject var focus: FocusController
    @ObservedObject var ambience: AmbienceController
    @ObservedObject var activities: ActivityStore

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
    @AppStorage("chatFull") private var chatFull = false

    init(model: NotchViewModel) {
        self.model = model
        self.music = model.music
        self.timer = model.timer
        self.stopwatch = model.stopwatch
        self.focus = model.focus
        self.ambience = model.ambience
        self.activities = model.activities
    }

    private var todayEnabled: Bool { showCalendar || showReminders }

    /// Chat costs nothing by default: compact mode keeps the island
    /// at its everyday 520 and renders the site single-column. Full
    /// mode (the expand glyph in the pane) grows to 680, where 0.8
    /// zoom crosses the desktop breakpoint and the sidebar returns.
    private var islandWidth: CGFloat {
        model.tab == .chat && model.pane == .none && chatFull ? 680 : 520
    }

    private var enabledTools: [NotchViewModel.Tab] {
        var tools: [NotchViewModel.Tab] = []
        if toolGo { tools.append(.links) }
        if toolClips { tools.append(.clipboard) }
        if toolShelf { tools.append(.shelf) }
        if toolNotes { tools.append(.notes) }
        if toolFocus { tools.append(.focus) }
        if toolChat { tools.append(.chat) }
        return tools
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // Rows come from the layout rather than being written here,
            // so rearranging one is data rather than a code change.
            // Ordering, hiding and pairing all live in IslandLayout.
            ForEach(layoutRows) { row in
                if row.elements.count == 1 {
                    element(row.elements[0])
                } else {
                    HStack(alignment: .top, spacing: Theme.Space.l) {
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
            if model.isDropTargeted {
                Color.clear.frame(height: 150)
            }
        }
        .padding(.horizontal, model.islandContentPadding)
        .padding(.top, model.contentTopReserve + Theme.Space.m)
        // The same inset as the sides, so the island reads as one box
        // rather than three different margins. It was 10 against the
        // sides' 16, which left the input crowded against the bottom
        // curve — and the belly sags below this, taking some of it back.
        .padding(.bottom, model.islandContentPadding)
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
                        // island's `.animation(_:value: model.state)`
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
                            model.expandedSize = size
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
                            model.expandedSize = size
                        }
                    }
            }
        )
        // A drag over the island chalantrs the body with one large,
        // unmistakable target, so drops aim here, well below the
        // browser's tab strip, instead of at the little pill.
        .overlay {
            if model.isDropTargeted {
                dropTarget
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.hover, value: model.isDropTargeted)
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
            topRow
        case .activities:
            if !activities.activities.isEmpty {
                ActivitiesStrip(activities: activities)
                    .transition(.opacity)
            }
        case .sessions:
            AgentSessionsStrip(sessions: model.sessions)
                .transition(.opacity)
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

    /// Media (if on and something's playing) with the persistent mic,
    /// the voice affordance is always reachable even when media is off.
    private var topRow: some View {
        HStack(spacing: Theme.Space.l) {
            if showMedia, music.nowPlaying != nil {
                MusicRow(music: music)
            } else {
                // The chip only appears once a player has earned it:
                // running now, or seen playing before. Guessing a
                // brand for a fresh Mac presumed too much.
                if showMedia, music.preferredApp != nil {
                    MusicLaunchChip(music: music)
                }
                Spacer(minLength: 0)
            }
            MicButton { model.toggleListening() }
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
                    showReminders: showReminders
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
    @Environment(\.chalantAccent) private var accent

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
                    IconActionButton(symbol: "xmark", dim: true) {
                        activities.clear(id: activity.id)
                    }
                }
                .rowInsets()
                .chalantCard(radius: Theme.Radius.row)
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
        // Only rendered when a preferred app exists (see topRow).
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

/// The voice affordance: tap to talk, tap again to run, or hold the
/// notch. Always present, whatever else the island is showing.
private struct MicButton: View {
    let action: () -> Void
    @State private var hovered = false

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
        .help("Speak, or hold the notch")
        .animation(Theme.Motion.hover, value: hovered)
    }
}

/// Your day, shown only when turned on. Calendar and reminders are
/// independent blocks; reminders tick off in place. Live from EventKit.
struct TodayView: View {
    @ObservedObject var events: EventKitService
    let showCalendar: Bool
    let showReminders: Bool
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
        let denials = deniedLines
        let rowCount = (hasEvents ? events.events.count : 0)
            + (hasReminders ? events.reminders.count : 0)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            ForEach(denials, id: \.self) { line in
                Text(line)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
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
            if !hasEvents, !hasReminders, denials.isEmpty {
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

    private var deniedLines: [String] {
        var lines: [String] = []
        if showCalendar, events.calendarDenied {
            lines.append("Calendar access is off. System Settings, Privacy, Calendars.")
        }
        if showReminders, events.remindersDenied {
            lines.append("Reminders access is off. System Settings, Privacy, Reminders.")
        }
        return lines
    }

    /// The empty moment, in the island's own voice.
    private var clearDay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Clear water.")
                .font(Theme.Fonts.reading)
                .foregroundStyle(Theme.textSecondary)
            Text("Nothing scheduled, nothing due. The day is yours.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textHint)
        }
        .padding(.vertical, Theme.Space.s)
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
