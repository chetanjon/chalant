import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var stopwatch: StopwatchController
    @ObservedObject var focus: FocusController
    @ObservedObject var voice: VoiceController
    @ObservedObject var ambience: AmbienceController
    @ObservedObject var stats: SystemStatsController
    @ObservedObject var focusStats: FocusStatsStore
    @ObservedObject var events: EventKitService
    @ObservedObject var activities: ActivityStore
    @State private var pressStarted: Date?

    // Declared so the view re-renders (and re-reads Theme.Motion) the
    // moment the user changes the feel in settings.
    @AppStorage("motionFeel") private var motionFeel = "serene"
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    // Silver by default: a fixed, calm accent. Album-following color
    // is the opt-in, not the ambient condition (user call, 2026-07-21).
    @AppStorage("accentMode") private var accentMode = "silver"
    // What the collapsed glance may show, user-tunable in Settings.
    @AppStorage("glanceMusic") private var glanceMusic = true
    @AppStorage("playingSignal") private var playingSignal = "wave"
    @AppStorage("glanceSession") private var glanceSession = true
    @AppStorage("islandMaterial") private var islandMaterial = "ink"
    @AppStorage("glassClarity") private var glassClarity = "balanced"
    @AppStorage("glanceNextEvent") private var glanceNextEvent = true
    // "none" by default: an idle island earns no width, especially on
    // monitors where the pill sits over working windows (user call,
    // 2026-07-20).
    @AppStorage("glanceIdle") private var glanceIdle = "none"

    /// This view injects the accent into the environment for everything
    /// below it, so it reads the source directly rather than @Environment
    /// (which would resolve from the parent scope and never update).
    private var accent: Color {
        Theme.fixedAccent(for: accentMode) ?? music.accent
    }

    init(model: NotchViewModel) {
        self.model = model
        self.music = model.music
        self.timer = model.timer
        self.stopwatch = model.stopwatch
        self.focus = model.focus
        self.voice = model.voice
        self.ambience = model.ambience
        self.stats = model.stats
        self.focusStats = model.focusStats
        self.events = model.events
        self.activities = model.activities
    }

    /// The event about to start, if the user lets the glance carry it.
    private var upcomingEvent: DayEvent? {
        glanceNextEvent ? events.nextEvent : nil
    }

    /// Anything counting: a pomodoro, a plain timer, the stopwatch.
    private var sessionActive: Bool {
        focus.isActive || timer.isActive || stopwatch.isActive
    }

    /// Music and a session at once: the wave keeps the left wing and
    /// the session mark takes the right (user, 2026-07-22).
    private var sessionOnRight: Bool {
        glanceSession && sessionActive
            && music.nowPlaying?.isPlaying == true
    }

    /// Each wing earns exactly what its content needs: the session
    /// mark wants 26 (digits clipped at real pomodoro widths, so the
    /// wing wears a symbol that cannot: the ring, or the stopwatch
    /// glyph; user, 2026-07-22), the slimmed wave takes 28. Quiet
    /// mode keeps the bare pill and lets the rim carry it (both moods
    /// proved real within one day, so it's a setting).
    private var leftWingNeed: CGFloat {
        if playingSignal == "wave", music.nowPlaying?.isPlaying == true { return 28 }
        if glanceSession, sessionActive, !sessionOnRight { return 26 }
        return 0
    }

    private var statusWings: CGFloat {
        // Beside a physical notch the pill must widen symmetrically:
        // the camera sits at the screen's center, so each side gets
        // the larger wing's width or content slides under the notch.
        if model.hasPhysicalNotch {
            return 2 * max(leftWingNeed, notchSideNeed)
        }
        return leftWingNeed
    }

    /// Width the right-of-camera glance needs on notched displays.
    private var notchSideNeed: CGFloat {
        if model.glanceToast != nil { return 124 }
        if activities.glanceActivity != nil { return 118 }
        if sessionOnRight { return 30 }
        // A session shows only its left-wing ring and countdown; the
        // right-side FOCUS 1 OF 4 label was width without value
        // (user call, 2026-07-21). A joinable meeting's camera mark
        // earns its own width; stealing the marquee's sent titles
        // into perpetual scroll.
        if let next = upcomingEvent {
            return next.joinURL != nil ? 128 : 112
        }
        // Playing needs no right-side width at all; the symmetric
        // wing math otherwise drags both sides out to the title's.
        if music.nowPlaying?.isPlaying == true, glanceMusic { return 0 }
        switch glanceIdle {
        case "none": return 0
        case "day": return 78
        case "streak": return focusStats.days.isEmpty ? 55 : 130
        default: return 55
        }
    }

    // MARK: Notchless pill accounting
    // On a monitor there is no hardware to mimic, so the pill hugs
    // its content exactly: bars left, a middle line only when it
    // earns the space, the session countdown right. Song titles do
    // not ride the middle here; they were width without value.

    private var monitorPlaying: Bool { music.nowPlaying?.isPlaying == true }
    private var monitorSession: Bool { sessionActive }

    private var monitorMiddleWidth: CGFloat {
        if model.glanceToast != nil { return 148 }
        if activities.glanceActivity != nil { return 150 }
        if let next = upcomingEvent {
            return next.joinURL != nil ? 166 : 150
        }
        switch glanceIdle {
        case "day": return 84
        case "streak": return focusStats.days.isEmpty ? 60 : 136
        case "clock": return 60
        default: return 0
        }
    }

    private var monitorContentWidth: CGFloat {
        (monitorPlaying ? 44 : 0)
            + (ambience.active != nil && !monitorPlaying ? 26 : 0)
            + monitorMiddleWidth
            + (monitorSession ? 90 : 0)
    }

    /// Nothing to say and no hardware to hug: on a monitor the
    /// resting droplet has no business sitting on window chrome.
    private var collapsedIsEmpty: Bool {
        !model.hasPhysicalNotch && monitorContentWidth == 0
    }

    /// On a monitor the collapsed island shows nothing: there is no
    /// hardware to dress and every pixel it wore sat on top of
    /// someone's window (user, 2026-07-22, "we can't show anything on
    /// external monitors"). The hover zone is coordinate math, not
    /// pixels, so the top edge still summons the island. Two
    /// exceptions surface anyway, because a signal nobody can see is
    /// not a signal (review-caught): a glance toast lives six seconds
    /// and clears itself, and a needs-input agent is literally asking
    /// for the user. Idle, music, and running sessions stay hidden.
    private var monitorTucked: Bool {
        guard !model.hasPhysicalNotch, model.state == .collapsed else { return false }
        if model.glanceToast != nil { return false }
        if activities.glanceActivity?.state == .needsInput { return false }
        return true
    }

    /// Stable per-state sizes: content is framed to its own state's
    /// size (not the live island size), so an outgoing view fades out
    /// at its natural size instead of being crushed into the pill.
    private var collapsedSize: CGSize {
        if !model.hasPhysicalNotch {
            if collapsedIsEmpty {
                // A sliver, not a pill: idle on a monitor the island
                // yields the chrome, but stays findable. 120x14 with
                // a firmer edge: at half brightness the old 84x10
                // simply did not exist.
                let grow: CGFloat = model.isHovering ? 1 : 0
                return CGSize(width: 120 + 56 * grow, height: 14 + 16 * grow)
            }
            let grow: CGFloat = model.isHovering ? 1 : 0
            return CGSize(
                width: monitorContentWidth + 40 + 12 * grow,
                height: 18 + 10 * grow
            )
        }
        let growW: CGFloat = model.isHovering ? 14 : 0
        let growH: CGFloat = model.isHovering ? 4 : 0
        // Height is the safe area plus a 3pt apron: flush-exact put
        // the rim's bottom arc ON the glass edge and it read as the
        // border touching the hardware (user, 2026-07-22); the apron
        // drops the visible line just clear of the notch, the way a
        // dynamic island wraps its cutout. Every LARGER overhang the
        // computed-chin era added here was a bug (full story with the
        // placement code). The width tuck: the reported gap sits a
        // hair wider than the glass, and the pill wears the camera's
        // clothes, not the report's ("reduced just a little bit").
        return CGSize(
            width: model.notchSize.width - 8 + statusWings + growW,
            height: model.notchSize.height + 3 + growH
        )
    }

    // Height covers bars, two transcript lines, RELEASE TO RUN, and
    // the live device caption underneath.
    private static let listeningSize = CGSize(width: 380, height: 192)

    private var islandSize: CGSize {
        switch model.state {
        case .collapsed: return collapsedSize
        case .listening: return Self.listeningSize
        case .expanded: return model.expandedSize
        }
    }

    private var islandShape: IslandShape {
        if model.state == .collapsed {
            // On hover the droplet "reaches", shoulders widen, belly
            // sags, a soft beat of anticipation before opening.
            let reaching = model.isHovering && Theme.Feel.current.ambient
            if collapsedIsEmpty {
                // The sliver is too short for the full geometry.
                let grown = model.isHovering
                return IslandShape(
                    eave: grown ? 8 : 3,
                    bottomRadius: grown ? 10 : 4,
                    belly: reaching ? 1.5 : 0.5
                )
            }
            if !model.hasPhysicalNotch {
                // The compact content pill sits between sliver and
                // notch scale; its curves scale with it.
                return IslandShape(
                    eave: 6,
                    bottomRadius: 8,
                    belly: reaching ? 1.5 : 0.5
                )
            }
            return IslandShape(
                eave: Theme.Island.eaveCollapsed + (reaching ? 1.5 : 0),
                bottomRadius: Theme.Island.radiusCollapsed,
                belly: reaching ? 3 : Theme.Island.bellyCollapsed
            )
        }
        return IslandShape(
            eave: Theme.Island.eaveExpanded,
            bottomRadius: Theme.Island.radiusExpanded,
            belly: Theme.Island.bellyExpanded
        )
    }

    /// The shell's material. Ink everywhere by default (the blurred
    /// glass read as clutter, user call 2026-07-20). Glass returned
    /// 2026-07-21 as an opt-in, smoked and expanded-only: the closed
    /// pill always stays ink so it melts into the hardware.
    ///
    /// One stable hierarchy across states: swapping views at the
    /// moment of expansion made the blur mount mid-bloom and the
    /// shape lose its morph, which read as a glitch. The blur is
    /// always present in glass mode and only opacity moves.
    /// The glass itself: real Liquid Glass where the OS has it, the
    /// old blur-and-smoke underneath older systems. The branch is
    /// fixed at launch; only opacities ever move with state (the
    /// R74 law: never swap the shell's identity mid-bloom).
    /// How see-through the glass is, the user's own dial. Fully
    /// untinted .clear glass let background text collide with the
    /// island's words and read as noise (tried 2026-07-22, rejected
    /// on sight); .regular melts the desktop into color, and the
    /// tint sets how much of it survives.
    private var glassTint: Double {
        switch glassClarity {
        case "veiled": return 0.35
        case "clear": return 0.06
        default: return 0.18
        }
    }

    @ViewBuilder
    private var glassFill: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(glassTint)), in: islandShape)
        } else {
            ZStack {
                VisualEffectBlur()
                    .clipShape(islandShape)
                islandShape
                    .fill(Color.black.opacity(0.45))
            }
        }
    }

    /// How much ink still lies over the open glass; scales with the
    /// chosen clarity where the real material exists.
    private var openSmoke: Double {
        if #available(macOS 26.0, *) {
            switch glassClarity {
            case "veiled": return 0.12
            case "clear": return 0
            default: return 0.06
            }
        }
        return 0.30
    }

    private var islandBase: some View {
        ZStack {
            if islandMaterial == "glass" {
                glassFill
                    .opacity(model.state == .collapsed ? 0 : 1)
            }
            islandShape
                .fill(Color.black)
                .opacity(islandMaterial == "glass" && model.state != .collapsed ? openSmoke : 1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The droplet clings to the top edge of the screen; its
                // meniscus shoulders keep it flush with the notch.
                islandBase
                    // Top-lit glass edge; brighter where light would catch it.
                    .overlay(
                        islandShape
                            .strokeBorder(Theme.specularEdge, lineWidth: 1)
                            .opacity(
                                model.state == .collapsed
                                    ? (model.isHovering ? 0.9 : (idleEdgeOn ? 0.75 : 0.4))
                                    : 1
                            )
                    )
                    // A whisper of the album color rims the open glass,
                    // the one place the accent touches the shell.
                    .overlay(
                        islandShape
                            .strokeBorder(accent.opacity(0.16), lineWidth: 1)
                            .opacity(model.state == .expanded ? 1 : 0)
                    )
                    // Bottom-lit lip: keeps the idle droplet findable
                    // over fullscreen apps' pure black top strip.
                    .overlay(
                        islandShape
                            .strokeBorder(Theme.lipLight, lineWidth: 1)
                            .opacity(idleEdgeOn && model.state == .collapsed ? 1 : 0)
                    )
                    // A soft specular highlight that follows the cursor
                    // along the top edge, the glass answers the hand.
                    .overlay {
                        if Theme.Feel.current.ambient, let unit = model.pointerUnit {
                            islandShape
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5)
                                .mask(
                                    RadialGradient(
                                        colors: [.white, .clear],
                                        center: UnitPoint(x: unit, y: 0),
                                        startRadius: 0,
                                        endRadius: 110
                                    )
                                )
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .animation(Theme.Motion.hover, value: model.pointerUnit)
                    // Breathing accent ring: idle life on the edges when
                    // music or a timer is going. Intensity breathes in
                    // place, nothing travels along the border.
                    .overlay {
                        if glowOn, Theme.Feel.current.ambient,
                           model.state == .collapsed,
                           sessionActive || music.nowPlaying?.isPlaying == true {
                            TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                                let t = context.date.timeIntervalSinceReferenceDate
                                let breath = 0.5 + 0.5 * sin(t / (1.6 * Theme.Motion.ambientSlow))
                                ZStack {
                                    islandShape
                                        .strokeBorder(accent.opacity(0.03 + 0.04 * breath), lineWidth: 4)
                                    islandShape
                                        .strokeBorder(accent.opacity(0.08 + 0.10 * breath), lineWidth: 1.5)
                                    // The belly light breathes with the
                                    // same rhythm, same clock, no new timer.
                                    islandShape
                                        .strokeBorder(Theme.lipLight, lineWidth: 1)
                                        .opacity(0.10 + 0.20 * breath)
                                }
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        }
                    }
                    .overlay(
                        islandShape
                            .strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
                            .opacity(model.isDropTargeted ? 1 : 0)
                    )
                    .shadow(
                        color: Color.black.opacity(model.state == .collapsed ? 0 : 0.45),
                        radius: 14, y: 7
                    )

                contentLayer
            }
            .frame(width: islandSize.width, height: islandSize.height)
            .opacity(monitorTucked ? 0 : 1)
            .contentShape(Rectangle())
            // Hover is tracked by NotchWindowController against stable
            // state-based zones; tracking this animating view flickers.
            .onLongPressGesture(
                minimumDuration: Theme.pressToTalkDelay,
                // Effectively unlimited: drifting the cursor mid-hold
                // must not cancel the gesture, or release goes dead.
                maximumDistance: 10_000,
                pressing: { pressing in
                    if pressing {
                        pressStarted = Date()
                    } else {
                        if model.state == .listening {
                            model.endListening()
                        } else if model.state == .collapsed,
                                  let start = pressStarted,
                                  Date().timeIntervalSince(start) < Theme.pressToTalkDelay {
                            model.expand()
                        }
                        pressStarted = nil
                    }
                },
                perform: {
                    model.beginListening()
                }
            )
            // Drop handling is at the AppKit level in NotchWindowController
            // (SwiftUI's onDrop never fires in this panel); the accent edge
            // lights via model.isDropTargeted. The island opens after the
            // drop lands, not during the drag, so nothing disrupts it.
            .animation(Theme.Motion.island, value: model.state)
            .animation(Theme.Motion.hover, value: model.isHovering)
            .animation(Theme.Motion.hover, value: statusWings)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // The user's accent choice, not the raw album color, fixed
        // modes must win everywhere below this point.
        .environment(\.moaiAccent, accent)
    }

    /// State contents at their own natural sizes, clipped to the
    /// morphing droplet. On close, content vanishes in a fast fade and
    /// the shell does the shrinking; on open, the shell leads and
    /// content breathes in just behind it.
    private var contentLayer: some View {
        ZStack(alignment: .top) {
            if model.state == .collapsed {
                // Wings and battery wait for the shell to mostly settle,
                // then fade in, appearing mid-shrink reads as flicker.
                collapsedContent
                    .frame(width: collapsedSize.width, height: collapsedSize.height)
                    .transition(contentTransition(insertionDelay: 0.28))
            }

            if model.state == .listening {
                listeningContent
                    .frame(width: Self.listeningSize.width, height: Self.listeningSize.height)
                    .transition(contentTransition(insertionDelay: 0.09))
            }

            if model.state == .expanded {
                ExpandedView(model: model)
                    .transition(contentTransition(insertionDelay: 0.09))
            }
        }
        .frame(width: islandSize.width, height: islandSize.height, alignment: .top)
        .clipShape(islandShape)
    }

    private func contentTransition(insertionDelay: Double) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.22).delay(insertionDelay)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    /// Wings beside the notch on the built-in display; on monitors,
    /// a compact pill that hugs exactly what is worth showing.
    @ViewBuilder
    private var collapsedContent: some View {
        if model.hasPhysicalNotch {
            wingsContent
        } else {
            monitorPill
        }
    }

    /// Bars left, middle only when it earns the space, session right.
    private var monitorPill: some View {
        HStack(spacing: Theme.Space.s) {
            if monitorPlaying {
                NowPlayingBars(accent: accent, barCount: 4, maxHeight: 8)
            }
            if let active = ambience.active, !monitorPlaying {
                Image(systemName: active.symbol)
                    .font(Theme.Fonts.icon(.xs))
                    .foregroundStyle(accent)
            }
            monitorMiddle
            if monitorSession {
                sessionCompact
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var monitorMiddle: some View {
        // The landing moment outranks everything: it is six seconds
        // long and often arrives just as a break begins.
        if let toast = model.glanceToast {
            toastGlance(toast)
        } else if let activity = activities.glanceActivity {
            activityGlance(activity, width: 128)
        } else if let next = upcomingEvent {
            upcomingGlance(next, width: 120)
        } else {
            idleGlance
        }
    }

    /// The countdown at the pill's right, ring and all.
    private var sessionCompact: some View {
        HStack(spacing: Theme.Space.snug) {
            if stopwatch.isActive, !focus.isActive, !timer.isActive {
                Image(systemName: "stopwatch")
                    .font(Theme.Fonts.icon(.xs))
                    .foregroundStyle(accent)
                    .opacity(stopwatch.isRunning ? 1 : 0.5)
                Text(stopwatch.display)
                    .font(Theme.Fonts.labelMono)
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(stopwatch.isRunning ? 1 : 0.5)
            } else {
                ProgressRing(
                    progress: focus.isActive ? focus.progress : timer.progress,
                    size: 10,
                    lineWidth: 1.5,
                    tint: accent,
                    trackOpacity: 0.15
                )
                Text(focus.isActive ? focus.display : timer.display)
                    .font(Theme.Fonts.labelMono)
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(focus.isActive && focus.isPaused ? 0.5 : 1)
            }
        }
    }

    /// The same glance beside the camera on notched displays, where
    /// the middle belongs to hardware and only the wings are usable.
    @ViewBuilder
    private var notchSideContent: some View {
        if let toast = model.glanceToast {
            toastGlance(toast)
        } else if let activity = activities.glanceActivity {
            activityGlance(activity, width: 106)
        } else if sessionOnRight {
            // Music holds the left wing, so the session mark crosses
            // over; the running session outranks quieter glances.
            sessionMark
        } else if let next = upcomingEvent {
            upcomingGlance(next, width: 100)
        } else if music.nowPlaying?.isPlaying == true, glanceMusic {
            // Playing: the bars on the left carry the state. A
            // scrolling title here was width without value, the same
            // call that removed the session label (user, 2026-07-21).
            EmptyView()
        } else {
            idleGlance
        }
    }

    /// A pushed activity riding the glance: state glyph and title.
    /// Needs-input wears the accent; nothing here is tappable, the
    /// island opens as ever and the strip has the details.
    private func activityGlance(_ activity: ActivityStore.Activity, width: CGFloat) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: activity.state.symbol)
                .font(Theme.Fonts.icon(.xs))
                .foregroundStyle(
                    activity.state == .needsInput ? accent : Theme.textSecondary
                )
            MarqueeText(title: activity.title)
                .frame(width: width)
        }
        .id(activity.id + activity.state.rawValue)
    }

    /// The event about to start: an accent dot (the calendar's mark in
    /// the Today pane too), the title, and a minute countdown that
    /// turns into "now" as it begins. A meeting with a link wears a
    /// small camera: the glance teaching that "join" will work.
    private func upcomingGlance(_ event: DayEvent, width: CGFloat? = nil) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Circle()
                .fill(accent)
                .frame(width: 4.5, height: 4.5)
            TimelineView(.everyMinute) { context in
                MarqueeText(
                    title: event.title,
                    subtitle: event.countdown(from: context.date)
                )
            }
            .frame(width: width)
            if event.joinURL != nil {
                Image(systemName: "video.fill")
                    .font(Theme.Fonts.icon(.xs))
                    .foregroundStyle(accent)
            }
        }
        .id(event.id)
    }

    /// Nothing playing, nothing running: whatever quiet thing the
    /// user chose for the empty moment.
    @ViewBuilder
    private var idleGlance: some View {
        switch glanceIdle {
        case "none":
            EmptyView()
        case "day":
            TimelineView(.everyMinute) { context in
                Text(
                    context.date,
                    format: .dateTime.weekday(.abbreviated)
                        .hour(.defaultDigits(amPM: .omitted)).minute()
                )
                .font(Theme.Fonts.captionMono)
                .foregroundStyle(Theme.textTertiary)
            }
        case "streak":
            if focusStats.days.isEmpty {
                clockGlance
            } else {
                Text(streakLine)
                    .font(Theme.Fonts.captionMono)
                    .foregroundStyle(Theme.textTertiary)
            }
        default:
            clockGlance
        }
    }

    /// A finished session or timer, spoken softly in the accent for a
    /// few seconds, then gone.
    private func toastGlance(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.captionMono)
            .foregroundStyle(accent)
            .lineLimit(1)
            .transition(.opacity)
    }

    private var streakLine: String {
        // With a goal set, the empty moment measures the day against
        // it; otherwise it just counts the day.
        let today: String
        if focusStats.goalMinutes > 0 {
            today = focusStats.goalMet
                ? "\(FocusStatsStore.clock(focusStats.todayMinutes)) · goal met"
                : "\(FocusStatsStore.clock(focusStats.todayMinutes)) of \(FocusStatsStore.clock(focusStats.goalMinutes))"
        } else {
            today = "\(FocusStatsStore.clock(focusStats.todayMinutes)) today"
        }
        guard focusStats.streak >= 2 else { return today }
        return "\(focusStats.streak)d streak · \(today)"
    }

    private var clockGlance: some View {
        TimelineView(.everyMinute) { context in
            Text(
                context.date,
                format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
            )
            .font(Theme.Fonts.captionMono)
            .foregroundStyle(Theme.textTertiary)
        }
    }

    /// One symbol, never digits: numbers clipped at real widths
    /// ("24:53" is five characters), a mark cannot (user, 2026-07-22,
    /// "add a visual symbol"). The ring still says how far along; the
    /// stopwatch has no endpoint, so it wears its own glyph.
    @ViewBuilder
    private var sessionMark: some View {
        if focus.isActive || timer.isActive {
            ProgressRing(
                progress: focus.isActive ? focus.progress : timer.progress,
                size: 11,
                lineWidth: 1.5,
                tint: accent,
                trackOpacity: 0.15
            )
            .opacity(focus.isActive && focus.isPaused ? 0.5 : 1)
        } else if stopwatch.isActive {
            Image(systemName: "stopwatch")
                .font(Theme.Fonts.icon(.xs))
                .foregroundStyle(accent)
                .opacity(stopwatch.isRunning ? 1 : 0.5)
        }
    }

    private var wingsContent: some View {
        HStack {
            if playingSignal == "wave", music.nowPlaying?.isPlaying == true {
                NowPlayingBars(accent: accent, barCount: 4, maxHeight: 7)
                    .padding(.leading, Theme.Space.wingInset)
            } else if glanceSession, sessionActive, !sessionOnRight {
                sessionMark
                    .padding(.leading, Theme.Space.wingInset)
            }
            // While music plays the glance belongs to the song and its
            // wave alone; the soundscape symbol steps back.
            if let active = ambience.active, music.nowPlaying?.isPlaying != true {
                Image(systemName: active.symbol)
                    .font(Theme.Fonts.icon(.xs))
                    .foregroundStyle(accent)
                    .padding(.leading, leftWingNeed > 0 ? 0 : Theme.Space.wingInset)
            }
            Spacer()
            if model.hasPhysicalNotch {
                notchSideContent
                    .padding(.trailing, Theme.Space.wingInset)
            }
        }
    }

    private var listeningContent: some View {
        VStack(spacing: Theme.Space.m) {
            listeningCaption
            levelBars
            // Fixed two-line box: arriving words must not bounce the
            // whole stack vertically.
            Text(voice.transcript.isEmpty ? "Say it." : voice.transcript)
                .font(Theme.Fonts.body)
                .foregroundStyle(voice.transcript.isEmpty ? Theme.textHint : Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.xxl)
                .frame(height: 34)
            Text("RELEASE TO RUN")
                .font(Theme.Fonts.micro)
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
            // Which ear is live. When the watchdog hops mid-hold the
            // name changes in place, so a wrong mic is never a mystery.
            if let device = voice.activeDeviceName {
                Text(device)
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(Theme.textGhost)
                    .lineLimit(1)
            }
        }
        .padding(.top, model.notchSize.height + 6)
        .contentShape(Rectangle())
        .onTapGesture {
            model.endListening()
        }
        .overlay(alignment: .topTrailing) {
            CloseButton {
                model.cancelListening()
            }
            .padding(.top, model.notchSize.height + Theme.Space.xs)
            .padding(.trailing, Theme.Space.m)
        }
    }

    /// "listening" with a slow shimmer while ambient motion is on.
    private var listeningCaption: some View {
        Group {
            if Theme.Feel.current.ambient {
                TimelineView(.animation(minimumInterval: 1 / 10)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Text("listening")
                        .font(Theme.Fonts.label)
                        .tracking(3)
                        .foregroundStyle(Theme.textSecondary)
                        .opacity(0.75 + 0.25 * sin(t / 1.1))
                }
            } else {
                Text("listening")
                    .font(Theme.Fonts.label)
                    .tracking(3)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var levelBars: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<21, id: \.self) { index in
                let center = 1 - abs(CGFloat(index) - 10) / 11
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(0.35 + center * 0.65)
                    .frame(
                        width: 3.5,
                        height: 4 + voice.level * 30 * (0.35 + center * 0.65)
                    )
            }
        }
        .frame(height: 36)
        // Live glow only while sound is actually arriving.
        .shadow(color: accent.opacity(voice.level > 0.05 ? 0.35 : 0), radius: 6)
        .animation(.easeOut(duration: 0.1), value: voice.level)
    }

}
