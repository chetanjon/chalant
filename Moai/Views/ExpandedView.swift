import SwiftUI

/// The island's open form: one state, voice-first. There is no text bar
/// and no More/Less, you speak (the mic, or hold the notch), and the
/// island shows only the blocks you keep on, sizing itself to fit.
struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var focus: FocusController
    @ObservedObject var ambience: AmbienceController

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

    init(model: NotchViewModel) {
        self.model = model
        self.music = model.music
        self.timer = model.timer
        self.focus = model.focus
        self.ambience = model.ambience
    }

    private var todayEnabled: Bool { showCalendar || showReminders }

    private var enabledTools: [NotchViewModel.Tab] {
        var tools: [NotchViewModel.Tab] = []
        if toolGo { tools.append(.links) }
        if toolClips { tools.append(.clipboard) }
        if toolShelf { tools.append(.shelf) }
        if toolNotes { tools.append(.notes) }
        if toolFocus { tools.append(.focus) }
        return tools
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if focus.isActive || timer.isActive {
                SessionStrip(
                    kind: focus.isActive ? .focus : .timer,
                    focus: focus,
                    timer: timer
                ) {
                    withAnimation(Theme.Motion.content) { model.tab = .focus }
                }
                .transition(.opacity)
            }

            topRow

            if showAmbience {
                AmbienceRow(ambience: ambience)
                    .transition(.opacity)
            }

            Rectangle()
                .fill(Theme.hairlineFaint)
                .frame(height: 1)

            if model.pane == .settings {
                settingsSection
            } else {
                Switcher(model: model, todayEnabled: todayEnabled, tools: enabledTools)
                panel
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, model.notchSize.height + Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
        .foregroundStyle(.white)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            // The island hugs its content, driven straight from geometry
            // (a `.preference`/`.onPreferenceChange` pair silently failed
            // in this hierarchy, freezing the island at its default size).
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size, initial: true) { _, size in
                        guard size.height > 0 else { return }
                        model.expandedSize = size
                    }
            }
        )
        .animation(Theme.Motion.content, value: model.tab)
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

    /// Media (if on and something's playing) with the persistent mic,
    /// the voice affordance is always reachable even when media is off.
    private var topRow: some View {
        HStack(spacing: Theme.Space.l) {
            if showMedia, music.nowPlaying != nil {
                MusicRow(music: music)
            } else {
                if showMedia {
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
            ClipboardView(model: model).frame(height: Theme.Panel.list)
        case .shelf:
            ShelfView(model: model).frame(height: Theme.Panel.list)
        case .notes:
            NotesView(model: model).frame(height: Theme.Panel.list)
        case .focus:
            FocusPanel(focus: focus, timer: timer, stats: model.focusStats)
                .frame(height: Theme.Panel.focus)
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        HStack(spacing: Theme.Space.xs) {
            HoverGlyphButton(symbol: "chevron.left", tint: Theme.textSecondary) {
                withAnimation(Theme.Motion.content) { model.pane = .none }
            }
            Text("Settings")
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        SettingsPane(music: music)
            .frame(height: Theme.Panel.settings)
    }
}

/// Nothing playing: one quiet chip that opens your player, so music
/// is a click away instead of a dock hunt.
private struct MusicLaunchChip: View {
    @ObservedObject var music: MusicController
    @State private var hovered = false

    private var label: String {
        music.preferredApp.map { "Open \($0.rawValue)" } ?? "Open YouTube Music"
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
    @Environment(\.moaiAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if showCalendar { calendarBlock }
            if showReminders { remindersBlock }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await events.refresh() }
    }

    private var calendarBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Today", trailingRule: true)
            if events.calendarDenied {
                Text("Calendar access is off. System Settings, Privacy, Calendars.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textHint)
            } else if events.events.isEmpty {
                Text("Nothing today.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textHint)
            } else {
                ForEach(events.events) { event in
                    HStack(spacing: Theme.Space.m) {
                        Text(event.time)
                            .font(Theme.Fonts.captionMono)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 62, alignment: .leading)
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(event.title)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var remindersBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Reminders", trailingRule: true)
            if events.remindersDenied {
                Text("Reminders access is off. System Settings, Privacy, Reminders.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textHint)
            } else if events.reminders.isEmpty {
                Text("Nothing open.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textHint)
            } else {
                ForEach(events.reminders) { reminder in
                    Button {
                        Task { await events.complete(reminder) }
                    } label: {
                        HStack(spacing: Theme.Space.m) {
                            Image(systemName: "circle")
                                .font(Theme.Fonts.icon(.s))
                                .foregroundStyle(Theme.textTertiary)
                            Text(reminder.title)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Mark done")
                }
            }
        }
    }

}
