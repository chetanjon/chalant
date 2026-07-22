import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var focus: FocusController
    @ObservedObject var voice: VoiceController
    @ObservedObject var ambience: AmbienceController
    @ObservedObject var stats: SystemStatsController
    @ObservedObject var focusStats: FocusStatsStore
    @ObservedObject var events: EventKitService
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
    @AppStorage("glanceSession") private var glanceSession = true
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
        self.focus = model.focus
        self.voice = model.voice
        self.ambience = model.ambience
        self.stats = model.stats
        self.focusStats = model.focusStats
        self.events = model.events
    }

    /// The event about to start, if the user lets the glance carry it.
    private var upcomingEvent: DayEvent? {
        glanceNextEvent ? events.nextEvent : nil
    }

    private var hasLeftWing: Bool {
        focus.isActive || timer.isActive || music.nowPlaying?.isPlaying == true
    }

    private var statusWings: CGFloat {
        // Beside a physical notch the pill must widen symmetrically:
        // the camera sits at the screen's center, so each side gets
        // the larger wing's width or content slides under the notch.
        // 54 per side is just enough for the waveform or the ring
        // and clock; 88 read as the island eating the menu bar.
        if model.hasPhysicalNotch {
            return 2 * max(hasLeftWing ? 54 : 0, notchSideNeed)
        }
        return hasLeftWing ? 54 : 0
    }

    /// Width the right-of-camera glance needs on notched displays.
    private var notchSideNeed: CGFloat {
        if model.glanceToast != nil { return 124 }
        if (focus.isActive || timer.isActive), glanceSession { return 92 }
        if upcomingEvent != nil { return 112 }
        if music.nowPlaying?.isPlaying == true, glanceMusic { return 107 }
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
    private var monitorSession: Bool { focus.isActive || timer.isActive }

    private var monitorMiddleWidth: CGFloat {
        if model.glanceToast != nil { return 148 }
        if upcomingEvent != nil { return 150 }
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
        return CGSize(
            width: model.notchSize.width + statusWings + growW,
            height: model.notchSize.height + growH
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

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The droplet clings to the top edge of the screen; its
                // meniscus shoulders keep it flush with the notch. One
                // opaque black fill in every state: the blurred glass
                // let the desktop bleed through and read as clutter,
                // black is the island's true material (user call,
                // 2026-07-20).
                islandShape
                    .fill(Color.black)
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
                           model.state == .collapsed, hasLeftWing {
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
        } else if let next = upcomingEvent {
            upcomingGlance(next, width: 120)
        } else {
            idleGlance
        }
    }

    /// The countdown at the pill's right, ring and all.
    private var sessionCompact: some View {
        HStack(spacing: Theme.Space.snug) {
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

    /// The same glance beside the camera on notched displays, where
    /// the middle belongs to hardware and only the wings are usable.
    @ViewBuilder
    private var notchSideContent: some View {
        if let toast = model.glanceToast {
            toastGlance(toast)
        } else if (focus.isActive || timer.isActive), glanceSession {
            sessionHint
        } else if let next = upcomingEvent {
            upcomingGlance(next, width: 100)
        } else if let playing = music.nowPlaying, playing.isPlaying, glanceMusic {
            MarqueeText(title: playing.track)
                .id(playing.track)
                .frame(width: 96)
        } else {
            idleGlance
        }
    }

    /// The event about to start: an accent dot (the calendar's mark in
    /// the Today pane too), the title, and a minute countdown that
    /// turns into "now" as it begins.
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

    private var sessionHint: some View {
        Text(
            focus.isActive
                ? (focus.phase == .work ? "FOCUS \(focus.roundInSet) OF 4" : "BREAK")
                : "TIMER"
        )
        .font(Theme.Fonts.micro)
        .tracking(1.3)
        .foregroundStyle(Theme.textTertiary)
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

    private var wingsContent: some View {
        HStack {
            if focus.isActive {
                HStack(spacing: Theme.Space.snug) {
                    ProgressRing(
                        progress: focus.progress,
                        size: 11,
                        lineWidth: 1.5,
                        tint: accent,
                        trackOpacity: 0.15
                    )
                    Text(focus.display)
                        .font(Theme.Fonts.labelMono)
                        .foregroundStyle(Theme.textPrimary)
                        .opacity(focus.isPaused ? 0.5 : 1)
                }
                .padding(.leading, Theme.Space.wingInset)
            } else if timer.isActive {
                HStack(spacing: Theme.Space.snug) {
                    ProgressRing(
                        progress: timer.progress,
                        size: 11,
                        lineWidth: 1.5,
                        tint: accent,
                        trackOpacity: 0.15
                    )
                    Text(timer.display)
                        .font(Theme.Fonts.labelMono)
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.leading, Theme.Space.wingInset)
            } else if music.nowPlaying?.isPlaying == true {
                NowPlayingBars(accent: accent, barCount: 4, maxHeight: 11)
                    .padding(.leading, Theme.Space.wingInset)
            }
            // While music plays the glance belongs to the song and its
            // wave alone; the soundscape symbol steps back.
            if let active = ambience.active, music.nowPlaying?.isPlaying != true {
                Image(systemName: active.symbol)
                    .font(Theme.Fonts.icon(.xs))
                    .foregroundStyle(accent)
                    .padding(.leading, hasLeftWing ? 0 : Theme.Space.wingInset)
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
