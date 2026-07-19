import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var music: MusicController
    @ObservedObject var timer: CountdownController
    @ObservedObject var focus: FocusController
    @ObservedObject var voice: VoiceController
    @ObservedObject var stats: SystemStatsController
    @State private var isDropTargeted = false
    @State private var pressStarted: Date?

    @AppStorage("expandedSizePreset") private var sizePreset = "compact"
    // Declared so the view re-renders (and re-reads Theme.Motion) the
    // moment the user changes the feel in settings.
    @AppStorage("motionFeel") private var motionFeel = "serene"
    @AppStorage("auroraOn") private var auroraOn = true
    @AppStorage("glowOn") private var glowOn = true
    @AppStorage("idleEdgeOn") private var idleEdgeOn = true
    @AppStorage("batteryWingOn") private var batteryWingOn = true
    @AppStorage("accentMode") private var accentMode = "album"

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
        self.stats = model.stats
    }

    private var hasLeftWing: Bool {
        focus.isActive || timer.isActive || music.nowPlaying?.isPlaying == true
    }

    private var batteryVisible: Bool {
        batteryWingOn && stats.battery != nil
    }

    private var statusWings: CGFloat {
        (hasLeftWing ? 88 : 0) + (batteryVisible ? 34 : 0)
    }

    /// Stable per-state sizes: content is framed to its own state's
    /// size (not the live island size), so an outgoing view fades out
    /// at its natural size instead of being crushed into the pill.
    private var collapsedSize: CGSize {
        let growW: CGFloat = model.isHovering ? 14 : 0
        let growH: CGFloat = model.isHovering ? 4 : 0
        return CGSize(
            width: model.notchSize.width + statusWings + growW,
            height: model.notchSize.height + growH
        )
    }

    private static let listeningSize = CGSize(width: 380, height: 156)

    private var islandSize: CGSize {
        switch model.state {
        case .collapsed: return collapsedSize
        case .listening: return Self.listeningSize
        case .expanded: return NotchViewModel.expandedSize(for: sizePreset)
        }
    }

    private var islandShape: IslandShape {
        if model.state == .collapsed {
            // On hover the droplet "reaches" — shoulders widen, belly
            // sags — a soft beat of anticipation before opening.
            let reaching = model.isHovering && Theme.Feel.current.ambient
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
                // meniscus shoulders keep it flush with the notch.
                // One constant fill + an opacity-animated black layer:
                // switching fill *styles* between states makes SwiftUI
                // cross-fade the whole shape (a ghosted double image)
                // instead of morphing it.
                islandShape
                    .fill(Theme.backdrop)
                    .overlay(
                        islandShape
                            .fill(Color.black)
                            .opacity(model.state == .collapsed ? 1 : 0)
                    )
                    // Album-colored aurora drifting inside the glass.
                    // Fades out fast on close — a slow fade inside the
                    // shrinking clip reads as shimmer.
                    .overlay {
                        if auroraOn, Theme.Feel.current.ambient, model.state != .collapsed {
                            AuroraView(accent: accent)
                                .clipShape(islandShape)
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity.animation(.easeIn(duration: 0.4)),
                                        removal: .opacity.animation(.easeOut(duration: 0.1))
                                    )
                                )
                        }
                    }
                    // Top-lit glass edge; brighter where light would catch it.
                    .overlay(
                        islandShape
                            .strokeBorder(Theme.specularEdge, lineWidth: 1)
                            .opacity(
                                model.state == .collapsed
                                    ? (model.isHovering ? 0.9 : (idleEdgeOn ? 0.55 : 0.4))
                                    : 1
                            )
                    )
                    // Bottom-lit lip: keeps the idle droplet findable
                    // over fullscreen apps' pure black top strip.
                    .overlay(
                        islandShape
                            .strokeBorder(Theme.lipLight, lineWidth: 1)
                            .opacity(idleEdgeOn && model.state == .collapsed ? 1 : 0)
                    )
                    // A soft specular highlight that follows the cursor
                    // along the top edge — the glass answers the hand.
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
                    // place — nothing travels along the border.
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
                                    // same rhythm — same clock, no new timer.
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
                            .opacity(isDropTargeted ? 1 : 0)
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
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .animation(Theme.Motion.island, value: model.state)
            .animation(Theme.Motion.hover, value: model.isHovering)
            .animation(Theme.Motion.hover, value: statusWings)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // The user's accent choice, not the raw album color — fixed
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
                // then fade in — appearing mid-shrink reads as flicker.
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
                    .frame(
                        width: NotchViewModel.expandedSize(for: sizePreset).width,
                        height: NotchViewModel.expandedSize(for: sizePreset).height
                    )
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

    /// Wings beside the physical notch: countdown or waveform left,
    /// a live spark on the right.
    private var collapsedContent: some View {
        HStack {
            if focus.isActive {
                HStack(spacing: 5) {
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
                HStack(spacing: 5) {
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
                Image(systemName: "waveform")
                    .font(Theme.Fonts.icon(.s))
                    .foregroundStyle(accent)
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: Theme.Feel.current.ambient
                    )
                    .padding(.leading, Theme.Space.wingInset)
            }
            Spacer()
            if hasLeftWing || model.isHovering {
                Image(systemName: "sparkles")
                    .font(Theme.Fonts.icon(.s))
                    .foregroundStyle(model.isHovering ? Theme.textSecondary : Theme.textTertiary)
                    .symbolEffect(.bounce, value: model.isHovering)
                    .padding(.trailing, batteryVisible ? Theme.Space.s : Theme.Space.l)
            }
            if batteryVisible, let battery = stats.battery {
                HStack(spacing: 2) {
                    if battery.charging {
                        Image(systemName: "bolt.fill")
                            .font(Theme.Fonts.icon(.xs))
                    }
                    Text("\(battery.level)%")
                        .font(Theme.Fonts.captionMono)
                }
                .foregroundStyle(battery.level <= 20 && !battery.charging ? accent : Theme.textTertiary)
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    model.shelf.add(url)
                    model.tab = .shelf
                    model.expand()
                }
            }
        }
        return accepted
    }
}
