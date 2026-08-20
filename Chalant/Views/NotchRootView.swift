import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    /// This display's render state: style, geometry, hover, the
    /// pointer light. `state` itself still comes from `model` — see
    /// `IslandFace.state`'s doc comment for why.
    @ObservedObject var face: IslandFace
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
    @ObservedObject var sessions: SessionStore
    @State private var pressStarted: Date?
    /// The dictation strip's "sent" light, alive only for the half second
    /// after a hold ends (see `DictationSentLight`).
    @State private var sentLightVisible = false
    @State private var sentLightPhase: CGFloat = 0

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
    @AppStorage(MusicController.playingSignalKey) private var playingSignal
        = MusicController.playingSignalDefault
    @AppStorage("glanceSession") private var glanceSession = true
    // These four are read again, directly by key, inside
    // NotchViewModel's collapsed-glance rules now (moved there
    // 2026-08-01); the model cannot use @AppStorage, that wrapper is a
    // SwiftUI DynamicProperty and does nothing outside a View. They
    // stay declared here anyway, because that is what makes this view
    // re-render the instant one flips in Settings — delete them as
    // "unused" and the glance freezes until some unrelated state
    // change happens to force a redraw.
    @AppStorage("glanceBattery") private var glanceBattery = false
    @AppStorage("collapsedSong") private var collapsedSong = true
    @AppStorage("glanceAgents") private var glanceAgents = true
    @AppStorage("glanceNextEvent") private var glanceNextEvent = true
    /// Keep the island out of the way until it is reached for. The
    /// door is coordinate math rather than pixels, so the top edge
    /// still summons it while nothing is drawn there (founder,
    /// 2026-08-02).
    @AppStorage("autoHideIsland") private var autoHideIsland = false
    @AppStorage("islandMaterial") private var islandMaterial = "ink"
    @AppStorage("glassClarity") private var glassClarity = "balanced"

    /// This view injects the accent into the environment for everything
    /// below it, so it reads the source directly rather than @Environment
    /// (which would resolve from the parent scope and never update).
    private var accent: Color {
        Theme.fixedAccent(for: accentMode) ?? music.accent
    }

    init(model: NotchViewModel, face: IslandFace) {
        self.model = model
        self.face = face
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
        self.sessions = model.sessions
    }

    /// The agents' mark on the resting island: their count, breathing
    /// while they work, steady and accented the moment one wants you.
    ///
    /// It stops moving when a session is waiting on purpose. A pulse
    /// says "still going"; an answer is needed now, and something that
    /// keeps moving reads as something still busy.
    @ViewBuilder
    private func agentMarkGlance(_ agents: (count: Int, waiting: Bool)) -> some View {
        let content = HStack(spacing: Theme.Space.xs) {
            AgentMark(agent: .claude, size: 10, state: agents.waiting ? .needsInput : .working)
            if agents.count > 1 {
                Text("\(agents.count)")
                    .font(Theme.Fonts.microMono)
            }
        }
        .foregroundStyle(agents.waiting ? accent : Theme.textSecondary)
        .help(agents.waiting
              ? "An agent is waiting for you"
              : "\(agents.count) agent\(agents.count == 1 ? "" : "s") running")

        if agents.waiting || !Theme.Feel.current.ambient {
            content
        } else {
            TimelineView(.animation(minimumInterval: 1 / 12)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                content.opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(t / (1.1 * Theme.Motion.ambientSlow))))
            }
        }
    }

    /// How wide the wings need to be, for the notch-widening math below.
    /// One function for the width and the show/hide decision now
    /// (`NotchViewModel.collapsedSpan`), so a pill and a notch answer
    /// this from the same numbers (2026-08-02). `face.style`/`face.state`
    /// rather than the model's, so four faces can answer this four
    /// different ways in the same instant (W-C, 2026-08-02).
    private var statusWings: CGFloat {
        let left = model.leftWingNeed(style: face.style, state: face.state)
        let right = model.notchSideNeed(style: face.style)
        return NotchViewModel.collapsedSpan(left: left, right: right, style: face.style) ?? 0
    }

    // MARK: Collapsed sizing
    // A pill and a notch carry the same glance now: the only
    // difference is that a notch has hardware in its middle, so its
    // wings widen symmetrically while a pill's sit adjacent
    // (2026-08-02; the old separate monitor-only rendering system —
    // narrower, and blind to most of what the notch already drew — is
    // what the founder's screenshots were catching).

    /// The sliver shape, for when the island has nothing to carry.
    ///
    /// It used to mean "collapsed on a monitor, always", because content
    /// there sat on top of windows. That is now a choice rather than a
    /// rule: a monitor island shows what the user asked it to and wears
    /// the sliver only when there is nothing to show.
    ///
    /// Narrowed to `.pill` rather than `!hasPhysicalNotch` (which also
    /// covers `.off`) because a notch's wings always draw something —
    /// the camera mark — and an Off display never gets a face to ask
    /// this question of at all: `rebuildIslands()` builds one for every
    /// display except Off, so there is nothing left for an opacity
    /// gate to guard against (island-per-display-plan, W-C, 2026-08-02).
    private var collapsedIsEmpty: Bool {
        face.style == .pill && !model.collapsedHasSomethingToSay(style: face.style, state: face.state)
    }

    /// Stable per-state sizes: content is framed to its own state's
    /// size (not the live island size), so an outgoing view fades out
    /// at its natural size instead of being crushed into the pill.
    private var collapsedSize: CGSize {
        if face.style == .pill {
            if collapsedIsEmpty {
                // A sliver, not a pill: idle on a monitor the island
                // yields the chrome, but stays findable. 120x14 with
                // a firmer edge: at half brightness the old 84x10
                // simply did not exist.
                let grow: CGFloat = face.isHovering ? 1 : 0
                return CGSize(width: 120 + 56 * grow, height: 14 + 16 * grow)
            }
            let grow: CGFloat = face.isHovering ? 1 : 0
            let left = model.leftWingNeed(style: face.style, state: face.state)
            let right = model.notchSideNeed(style: face.style)
            let span = NotchViewModel.collapsedSpan(left: left, right: right, style: .pill) ?? 0
            return CGSize(
                width: span + 40 + 12 * grow,
                height: 18 + 10 * grow
            )
        }
        // Flush with the cutout — exactly the hardware's own size, no
        // apron, no tuck — whenever there is nothing to say and nobody
        // reaching (A2): on a MacBook the cutout has no pixels, so an
        // island exactly that size is eaten by the hardware and is
        // invisible by construction. The 3pt height apron and the 8pt
        // width tuck (user, 2026-07-22: flush-exact read as the
        // border touching the hardware; the reported gap sits a hair
        // wider than the glass) come back the moment the island has a
        // reason to be outside the hole anyway — flush and apron
        // cannot both be true at once (user, 2026-08-02). An emulated
        // notch has no hardware to hide inside and keeps them
        // unconditionally (EC-5).
        return NotchViewModel.collapsedFrame(
            cutout: face.cutout, base: face.notchSize, wings: statusWings, hovering: face.isHovering
        )
    }

    // Height chalantrs bars, two transcript lines, RELEASE TO RUN, and
    // the live device caption underneath.
    private static let listeningSize = CGSize(width: 380, height: 192)

    /// The dictation strip: one small floating shape on every display
    /// (`DictationStripLevel.stripSize`, 260 × 28). It does not wrap a
    /// notch: on a notch display it floats beneath the hardware (see
    /// `topGap`). The founder chose the slim strip over the full listening
    /// surface (2026-08-16), asked for it smaller and lighter (2026-08-17),
    /// lower and tauter (2026-08-20, Slipstream), then smaller again and off
    /// the notch ("it looks weird cause its covering the notch").
    private var dictatingSize: CGSize {
        DictationStripLevel.stripSize
    }

    /// How far a resting pill clears the top of its screen. Small on
    /// purpose: enough that it reads as floating rather than wedged
    /// into the corner, not so much that it stops belonging to the
    /// menu bar line.
    private static let pillTopGap: CGFloat = 5

    /// Whether this island is currently keeping out of the way.
    ///
    /// Two reasons to: the user asked for it always ("hide until
    /// reached for"), or a fullscreen app owns this display and a
    /// resting PILL yields to it the way the menu bar does (a notch
    /// island never needs to, fullscreen keeps clear of real housing;
    /// and reshaping the pill instead was overruled: a pill the user
    /// chose stays a pill).
    ///
    /// Only ever true at rest: an open island, a voice session and a
    /// toast all outrank it, so neither reason can swallow something
    /// the user is looking at or something the island is trying to
    /// tell them. Reaching for the top edge brings it back either way.
    private var hiddenUntilReachedFor: Bool {
        (autoHideIsland || (face.style == .pill && face.fullscreenBelow))
            && face.state == .collapsed
            && !face.pointerNear
            && model.glanceToast == nil
            && !model.somethingWantsYou
    }

    private var islandSize: CGSize {
        switch face.state {
        case .collapsed: return collapsedSize
        case .listening: return Self.listeningSize
        case .dictating: return dictatingSize
        case .expanded: return model.expandedSize
        }
    }

    /// The island pours between states on one curve, with one exception:
    /// INTO dictation it pops (`Theme.Motion.dictationPop`). This evaluates
    /// with the state already changed, so entering `.dictating` pops and
    /// leaving it pours shut like everything else.
    private var stateMotion: Animation {
        face.state == .dictating ? Theme.Motion.dictationPop : Theme.Motion.island
    }

    private var islandShape: IslandShape {
        // The dictation strip is its own small shape on EVERY display:
        // machined corners all round (just over a third of its height,
        // never the soft full pill), no eaves, floating. On a notch Mac it
        // sits beneath the hardware rather than wrapping it: at 260 wide
        // the wrap read as the notch swelling (founder, 2026-08-20, "it
        // looks weird cause its covering the notch").
        if face.state == .dictating {
            let radius = DictationStripLevel.cornerRadius(height: dictatingSize.height)
            return IslandShape(
                eave: 0,
                bottomRadius: radius,
                belly: Theme.Island.bellyExpanded,
                topRadius: radius
            )
        }
        // Pill: a free-floating bar with all four corners turned and no
        // eaves to cling with. A screen with no cutout has nothing to
        // wrap, and wearing the notch silhouette there is what made the
        // island read as "still a notch" on an external display.
        if face.style == .pill {
            let expanded = face.state != .collapsed
            let radius = expanded
                ? max(face.cornerRadius, Theme.Island.radiusCollapsed)
                : face.cornerRadius
            return IslandShape(
                eave: 0,
                bottomRadius: radius,
                belly: expanded ? Theme.Island.bellyExpanded : Theme.Island.bellyCollapsed,
                // All four corners, always. A square top was tried for
                // one build to stop the resting pill reading as a
                // sticker on a fullscreen window's toolbar, and it was
                // WRONG: this branch runs because the user picked Pill,
                // the picker calls it "a free-floating bar", and a
                // setting has to mean what it says (founder, 2026-08-10:
                // "if the user selects to have a pill on monitor it
                // should be a pill"). A pill that stops floating is a
                // different shape wearing the same name. Whatever the
                // island does about overlapping a fullscreen window, it
                // does by moving or hiding, never by quietly becoming
                // something the user did not choose.
                topRadius: radius
            )
        }
        if face.state == .collapsed {
            // Reaching here means style is .notch (.pill returned
            // above, and .off never builds a face or panel to reach
            // this view with at all — rebuildIslands() only makes one
            // for a display that is not Off, W-C, 2026-08-02), so the
            // sliver and compact-pill branches this used to test for
            // here were unreachable in every visible state and are
            // gone (2026-08-01).
            //
            // On hover the droplet "reaches", shoulders widen, belly
            // sags, a soft beat of anticipation before opening.
            let reaching = face.isHovering && Theme.Feel.current.ambient
            // How far the frame drawn above already overhangs the
            // cutout: zero exactly when `collapsedSize` just returned
            // the cutout itself (flush, A2), so the eave and belly
            // below vanish with it too (A3's arc gone). An emulated
            // notch has no real cutout to measure an overhang against
            // and never hides inside one (EC-5), so it always reads as
            // overhanging by the collapsed eave ceiling instead.
            let overhang: CGFloat = face.cutout.map { (collapsedSize.width - $0.width) / 2 }
                ?? Theme.Island.eaveCollapsed
            let (eave, belly) = NotchViewModel.eaveAndBelly(overhang: overhang)
            return IslandShape(
                eave: eave + (reaching ? 1.5 : 0),
                bottomRadius: face.cornerRadius,
                belly: reaching ? 3 : belly
            )
        }
        return IslandShape(
            eave: Theme.Island.eaveExpanded,
            bottomRadius: Theme.Island.radiusExpanded,
            belly: Theme.Island.bellyExpanded
        )
    }

    /// How far the island stands off the screen's top edge. The dictation
    /// strip floats: beneath the hardware notch on a notch display, and by
    /// the resting pill's own gap on a pill display. Everything else keeps
    /// the old rule (a collapsed pill floats; open islands and notches meet
    /// the edge).
    private var topGap: CGFloat {
        if face.state == .dictating {
            // Hardware wins, the same rule as `contentTopReserve`: a screen
            // with a real cutout floats the strip beneath it WHATEVER style
            // the user chose. The founder runs Pill style on the MacBook,
            // and gating this on style left the strip straddling the
            // housing ("look hwo ugly it looks", 2026-08-20). An emulated
            // notch draws its silhouette and gets the same room.
            if face.cutout != nil || face.style == .notch {
                return face.contentTopReserve + DictationStripLevel.notchGap
            }
            return Self.pillTopGap
        }
        return face.style == .pill && face.state == .collapsed ? Self.pillTopGap : 0
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
    /// The dictation strip is glass whatever the island's material: the
    /// founder chose "dark glass" for it over ink (2026-08-17, round four),
    /// so an ink island lends the strip the veiled clarity, and a glass
    /// island keeps its own.
    private var glassBody: Bool { islandMaterial == "glass" || face.state == .dictating }
    private var bodyClarity: String { islandMaterial == "glass" ? glassClarity : "veiled" }

    private var glassTint: Double {
        switch bodyClarity {
        case "veiled": return 0.35
        case "clear": return 0.06
        default: return 0.18
        }
    }

    @ViewBuilder
    private var glassFill: some View {
        // The compiler gate mirrors the runtime one: glassEffect is
        // an Xcode 26 SDK symbol, and CI's older toolchain must
        // still compile this file (the runtime #available alone
        // cannot save a symbol the SDK never heard of).
        #if compiler(>=6.2)
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
        #else
        ZStack {
            VisualEffectBlur()
                .clipShape(islandShape)
            islandShape
                .fill(Color.black.opacity(0.45))
        }
        #endif
    }

    /// How much ink still lies over the open glass; scales with the
    /// chosen clarity where the real material exists.
    private var openSmoke: Double {
        if #available(macOS 26.0, *) {
            switch bodyClarity {
            case "veiled": return 0.12
            case "clear": return 0
            default: return 0.06
            }
        }
        return 0.30
    }

    private var islandBase: some View {
        ZStack {
            if glassBody {
                glassFill
                    .opacity(face.state == .collapsed ? 0 : 1)
            }
            islandShape
                .fill(Color.black)
                .opacity(glassBody && face.state != .collapsed ? openSmoke : 1)
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
                                face.state == .collapsed
                                    ? (face.isHovering ? 0.9 : (idleEdgeOn ? 0.75 : 0.4))
                                    : 1
                            )
                    )
                    // A whisper of the album color rims the open glass,
                    // the one place the accent touches the shell.
                    .overlay(
                        islandShape
                            .strokeBorder(accent.opacity(0.16), lineWidth: 1)
                            .opacity(face.state == .expanded ? 1 : 0)
                    )
                    // Bottom-lit lip: keeps the idle droplet findable
                    // over fullscreen apps' pure black top strip.
                    .overlay(
                        islandShape
                            .strokeBorder(Theme.lipLight, lineWidth: 1)
                            .opacity(idleEdgeOn && face.state == .collapsed ? 1 : 0)
                    )
                    // A soft specular highlight that follows the cursor
                    // along the top edge, the glass answers the hand.
                    .overlay {
                        if Theme.Feel.current.ambient, let unit = face.pointerUnit {
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
                    .animation(Theme.Motion.hover, value: face.pointerUnit)
                    // Breathing accent ring: idle life on the edges when
                    // music or a timer is going. Intensity breathes in
                    // place, nothing travels along the border. The
                    // breath itself plays on Core Animation: the old
                    // 8Hz TimelineView cost a full hosting-view layout
                    // pass per tick (the measurement is written up on
                    // NowPlayingBars in IslandRows.swift), and the rim
                    // was the second most expensive thing a resting
                    // island did while music played.
                    .overlay {
                        if glowOn, Theme.Feel.current.ambient,
                           face.state == .collapsed,
                           model.sessionActive || music.nowPlaying?.isPlaying == true {
                            RimLayerView(shape: islandShape, accent: accent)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .overlay(
                        islandShape
                            .strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
                            .opacity(face.isDropTargeted ? 1 : 0)
                    )
                    // The strip IS the meter: a thin core and one tight glow
                    // on the outline, near dark in silence and vivid on the
                    // voice, a dim pool inside the glass, glints racing the
                    // top edge on every syllable, all in the speaker's own
                    // gear (`DictationStripLight`, "Slipstream"). Absent
                    // everywhere except while dictating, so the resting
                    // island is untouched. Arrives WITH the pour: a first cut
                    // faded it in 0.18 s after the strip settled and the
                    // founder felt that half second as lag.
                    .overlay {
                        if face.state == .dictating {
                            DictationStripLight(
                                shape: islandShape, accent: accent,
                                level: model.dictationLevel, fill: model.dictationFill,
                                pulse: model.dictationPulse, pace: model.dictationPace,
                                beat: model.dictationBeat,
                                size: dictatingSize
                            )
                            .transition(.opacity)
                        }
                    }
                    // Letting go is a small satisfaction: a point of light
                    // gathers at the strip's centre and slips up into the
                    // notch while the strip pours shut. Once.
                    .overlay(alignment: .top) {
                        if sentLightVisible {
                            DictationSentLight(
                                accent: accent, phase: sentLightPhase,
                                stripHeight: dictatingSize.height
                            )
                        }
                    }
                    .onChange(of: face.state) { was, now in
                        guard was == .dictating, now != .dictating else { return }
                        sentLightPhase = 0
                        sentLightVisible = true
                        withAnimation(.easeOut(duration: DictationStripLevel.sentDuration)) {
                            sentLightPhase = 1
                        }
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + DictationStripLevel.sentDuration + 0.05
                        ) { sentLightVisible = false }
                    }
                    .shadow(
                        color: Color.black.opacity(face.state == .collapsed ? 0 : 0.45),
                        radius: 14, y: 7
                    )

                contentLayer
            }
            .frame(width: islandSize.width, height: islandSize.height)
            // This used to gate the whole shell's opacity so it could
            // hand off to the bead (`NotchWindowController.rebuildSlivers`,
            // now deleted) whenever collapsed with nothing to say — the
            // two used to disagree, drawing both shapes at once
            // (2026-08-01). The bead is gone (W-C, 2026-08-02): every
            // non-Off display wears its own island and nothing else
            // can draw the resting handle in its place, so a quiet
            // pill keeps its sliver instead of fading to nothing —
            // `collapsedIsEmpty` above already shrinks it rather than
            // hiding it.
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
                        if face.state == .listening {
                            model.endListening()
                        } else if face.state == .collapsed,
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
            // lights via face.isDropTargeted. The island opens after the
            // drop lands, not during the drag, so nothing disrupts it.
            .animation(stateMotion, value: face.state)
            .animation(Theme.Motion.hover, value: face.isHovering)
            .animation(Theme.Motion.hover, value: statusWings)

            Spacer(minLength: 0)
        }
        // A notch dresses hardware and has to meet the top edge exactly
        // or the cutout shows above it. A pill is free-floating and was
        // meeting that edge for no reason other than sharing the code
        // path, which read as jammed into the corner of the screen
        // (founder, 2026-08-02, "the pill placement is too top"). The
        // gap is dropped while a pill is open, so an expanded island
        // still hangs from the top the way it always has.
        .padding(.top, topGap)
        // Out of the way until reached for. A toast still comes
        // through: it is the island saying something happened, and a
        // notification nobody can see is not a quieter notification,
        // it is a lost one.
        .opacity(hiddenUntilReachedFor ? 0 : 1)
        .animation(Theme.Motion.island, value: hiddenUntilReachedFor)
        .animation(stateMotion, value: face.state)
        .frame(maxWidth: .infinity, alignment: .top)
        // The user's accent choice, not the raw album color, fixed
        // modes must win everywhere below this point.
        .environment(\.chalantAccent, accent)
    }

    /// State contents at their own natural sizes, clipped to the
    /// morphing droplet. On close, content vanishes in a fast fade and
    /// the shell does the shrinking; on open, the shell leads and
    /// content breathes in just behind it.
    private var contentLayer: some View {
        ZStack(alignment: .top) {
            if face.state == .collapsed {
                // Wings and battery wait for the shell to mostly settle,
                // then fade in, appearing mid-shrink reads as flicker.
                collapsedContent
                    .frame(width: collapsedSize.width, height: collapsedSize.height)
                    .transition(contentTransition(insertionDelay: 0.28))
            }

            if face.state == .listening {
                listeningContent
                    .frame(width: Self.listeningSize.width, height: Self.listeningSize.height)
                    .transition(contentTransition(insertionDelay: 0.09))
            }

            if face.state == .dictating {
                dictatingContent
                    .frame(width: dictatingSize.width, height: dictatingSize.height)
                    .transition(contentTransition(insertionDelay: 0.09))
            }

            if face.state == .expanded {
                ExpandedView(model: model, face: face)
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

    /// A pill and a notch carry the same glance now (2026-08-02): the
    /// resting sliver is a handle, not a display, whenever there is
    /// nothing to say; otherwise both draw `wingsContent`.
    @ViewBuilder
    private var collapsedContent: some View {
        if collapsedIsEmpty {
            Color.clear
        } else {
            wingsContent
        }
    }

    /// The countdown at the pill's right, ring and all. A pill has the
    /// room for digits that a notch's narrow wing does not.
    /// The finish reached this pill last (founder, 2026-08-10: "it
    /// looks cramped too"). Semibold mono at 13 with a 1.5pt ring five
    /// points away read as heavy and tight on an external monitor,
    /// where nothing is Retina and every stroke is a whole pixel. The
    /// digits now wear the island's own number voice, the ring is drawn
    /// thinner, and the two have room between them.
    private var sessionCompact: some View {
        HStack(spacing: Theme.Space.m) {
            if stopwatch.isActive, !focus.isActive, !timer.isActive {
                Image(systemName: "stopwatch")
                    .font(Theme.Fonts.iconThin(.xs))
                    .foregroundStyle(accent)
                    .opacity(stopwatch.isRunning ? 1 : 0.5)
                Text(stopwatch.display)
                    .font(Theme.Fonts.timeMono)
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(stopwatch.isRunning ? 1 : 0.5)
            } else {
                ProgressRing(
                    progress: focus.isActive ? focus.progress : timer.progress,
                    size: 11,
                    lineWidth: 1.2,
                    tint: accent,
                    trackOpacity: 0.15
                )
                Text(focus.isActive ? focus.display : timer.display)
                    .font(Theme.Fonts.timeMono)
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
        } else if let item = model.winningCollapsedItem(style: face.style) {
            collapsedGlance(item)
        }
    }

    /// One glance, drawn. The precedence is decided above; this only
    /// knows how each looks.
    @ViewBuilder
    private func collapsedGlance(_ item: CollapsedItem) -> some View {
        switch item {
        case .agents:
            if let agents = model.agentGlance { agentMarkGlance(agents) }
        case .timers:
            // Music holds the left wing, so the session mark crosses
            // over rather than fighting it for the same side. A pill
            // has the room to keep its digits; a notch's narrow wing
            // never did (2026-08-02).
            if face.hasPhysicalNotch { sessionMark } else { sessionCompact }
        case .event:
            if let next = model.upcomingEvent { upcomingGlance(next, width: 100) }
        case .battery:
            if let battery = stats.battery { batteryGlance(battery) }
        }
    }

    /// The quietest glance there is, and last in this chain on purpose:
    /// the charge only takes the wing when nothing with actual news
    /// wants it. `SystemStatsController` had been polling for this the
    /// whole time with no view reading it.
    private func batteryGlance(_ battery: SystemStatsController.Battery) -> some View {
        let charging = battery.state == .charging
        let low = battery.level <= 20 && !charging
        return HStack(spacing: Theme.Space.xs) {
            // The glyph carries charging and low on its own, so the
            // number is never the only thing saying which it is.
            Image(systemName: charging ? "bolt.fill" : (low ? "battery.25" : "battery.100"))
                .font(Theme.Fonts.icon(.xs))
            Text("\(battery.level)")
                .font(Theme.Fonts.microMono)
        }
        .foregroundStyle(low ? Theme.danger : Theme.textTertiary)
        .help("Battery \(battery.level)%\(charging ? ", charging" : "")")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Battery \(battery.level) percent\(charging ? ", charging" : low ? ", low" : "")"
        )
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

    /// A finished session or timer, spoken softly in the accent for a
    /// few seconds, then gone.
    private func toastGlance(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.microMono)
            .foregroundStyle(accent)
            .lineLimit(1)
            .transition(.opacity)
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
        // This face's own style and state, not the model's: the song
        // beside the wave only belongs here when THIS display is the
        // pill showing it collapsed (W-C, 2026-08-02).
        let showsSong = model.showsSongBeside(style: face.style, state: face.state)
        let leftWingNeed = model.leftWingNeed(style: face.style, state: face.state)
        return HStack {
            if showsSong, let playing = music.nowPlaying {
                songBeside(playing)
                    .padding(.leading, Theme.Space.wingInset)
            } else if playingSignal == "wave", music.nowPlaying?.isPlaying == true {
                NowPlayingBars(accent: accent, barCount: 4, maxHeight: 7)
                    .padding(.leading, Theme.Space.wingInset)
            } else if glanceSession, model.sessionActive, !model.sessionOnRight {
                // No music to share the wing with here: a pill still
                // has the room for the countdown's digits, the same
                // room a notch's narrow wing never had (2026-08-02).
                Group {
                    if face.hasPhysicalNotch { sessionMark } else { sessionCompact }
                }
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
            // Not gated on there being a notch any more. A pill has the
            // same right-hand room and more of it, and gating this meant
            // the toast, the session mark, the next event and the charge
            // were all invisible on an external display.
            notchSideContent
                .padding(.trailing, Theme.Space.wingInset)
        }
    }

    /// What is playing, on the resting island: the bars for life, then
    /// the title. Artist is left out — at this size it is the first
    /// thing to become unreadable, and the title is what identifies a
    /// song at a glance.
    private func songBeside(_ playing: MusicController.NowPlaying) -> some View {
        HStack(spacing: Theme.Space.s) {
            NowPlayingBars(accent: accent, barCount: 3, maxHeight: 7)
            Text(playing.track)
                .font(Theme.Fonts.micro)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: Theme.Island.songGlanceWidth, alignment: .leading)
    }

    private var listeningContent: some View {
        VStack(spacing: Theme.Space.m) {
            listeningCaption
            // Speaking into a full-screen view with no idea where the
            // words are going is the failure this line prevents
            // (notch-messaging-plan-2026-08-01.md, W-D item 31).
            if case .session(_, let title) = model.voiceDestination {
                Text("to \(title)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
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
            // Said by the entrance, not hardcoded: a hold ends on the
            // release, a tapped mic (the ask bar, the `.talk` key) ends
            // on a second click anywhere on this surface. "RELEASE TO
            // RUN" was told to both, and the half that never pressed
            // anything had no instruction that was true.
            Text(model.listeningFinishHint)
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
        .padding(.top, face.contentTopReserve + Theme.Space.notchClearance)
        .contentShape(Rectangle())
        .onTapGesture {
            model.endListening()
        }
        .overlay(alignment: .topTrailing) {
            CloseButton {
                model.cancelListening()
            }
            .padding(.top, face.contentTopReserve + Theme.Space.notchClearance)
            .padding(.trailing, Theme.Space.m)
        }
    }

    /// The dictation strip's one word: where the words are going. Nothing
    /// else on the strip itself; the light is `DictationStripLight`. No
    /// words while talking, no finish hint (letting go is the instruction),
    /// no dot, no microphone name (a dead mic is visible as light that never
    /// lifts). The name matters in the first second, then it is noise: once
    /// you are talking it steps back to almost nothing, and the strip earns
    /// its emptiness.
    private var dictatingContent: some View {
        HStack {
            Text(model.dictationInfo?.appName ?? "")
                .font(Theme.Fonts.micro)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .opacity(
                    model.dictationFill > DictationStripLevel.nameFadesAtFill
                        ? DictationStripLevel.nameFadedOpacity : 1
                )
                .animation(
                    .easeInOut(duration: DictationStripLevel.nameFadeDuration),
                    value: model.dictationFill > DictationStripLevel.nameFadesAtFill
                )
            Spacer(minLength: Theme.Space.l)
        }
        .padding(.horizontal, Theme.Space.xxl)
        // No reserve: the strip no longer contains a notch to clear.
        .padding(.top, DictationStripLevel.stripTopAir)
        .padding(.bottom, DictationStripLevel.stripBottomAir)
        .frame(maxHeight: .infinity, alignment: .bottom)
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

/// The breathing rim's layer half: the same three strokes the
/// TimelineView drew, breathing on the render server instead of on
/// SwiftUI ticks. An autoreversed opacity curve costs the app nothing
/// per frame, and easeInOut standing in for a true sine is
/// imperceptible at a tenth of a hertz. Paths are rebuilt only when
/// the island's size or shape actually changes, which a resting
/// island's never does.
private struct RimLayerView: NSViewRepresentable {
    let shape: IslandShape
    let accent: Color

    func makeNSView(context: Context) -> RimHostView {
        let view = RimHostView()
        view.apply(shape: shape, accent: NSColor(accent))
        return view
    }

    func updateNSView(_ view: RimHostView, context: Context) {
        view.apply(shape: shape, accent: NSColor(accent))
    }

    final class RimHostView: NSView {
        /// (lineWidth, resting opacity, breath amplitude), outermost
        /// first: the two accent strokes, then the belly light. Same
        /// numbers the stroked borders carried.
        private static let strokes: [(width: CGFloat, base: Float, amp: Float)] = [
            (4, 0.03, 0.04), (1.5, 0.08, 0.10), (1, 0.10, 0.20),
        ]
        private var accentRings: [CAShapeLayer] = []
        /// The belly light is Theme.lipLight, a white gradient (clear
        /// at the top, a tenth at the bottom), so it rides a gradient
        /// layer wearing its stroke as a mask.
        private var lipGradient = CAGradientLayer()
        private let lipMask = CAShapeLayer()
        private var currentShape: IslandShape?
        private var breathDuration: Double = 0

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(shape: IslandShape, accent: NSColor) {
            wantsLayer = true
            if accentRings.isEmpty {
                accentRings = Self.strokes.prefix(2).map { spec in
                    let ring = CAShapeLayer()
                    ring.fillColor = nil
                    ring.lineWidth = spec.width
                    ring.opacity = spec.base
                    layer?.addSublayer(ring)
                    return ring
                }
                lipMask.fillColor = nil
                lipMask.strokeColor = NSColor.white.cgColor
                lipMask.lineWidth = Self.strokes[2].width
                lipGradient.colors = [
                    NSColor.white.withAlphaComponent(0).cgColor,
                    NSColor.white.withAlphaComponent(0.10).cgColor,
                ]
                lipGradient.startPoint = CGPoint(x: 0.5, y: 0)
                lipGradient.endPoint = CGPoint(x: 0.5, y: 1)
                lipGradient.mask = lipMask
                lipGradient.opacity = Self.strokes[2].base
                layer?.addSublayer(lipGradient)
            }
            currentShape = shape
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            accentRings[0].strokeColor = accent.cgColor
            accentRings[1].strokeColor = accent.cgColor
            rebuildPaths()
            CATransaction.commit()
            armBreath()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rebuildPaths()
            CATransaction.commit()
        }

        private func rebuildPaths() {
            guard let currentShape, bounds.width > 0, bounds.height > 0 else { return }
            for (ring, spec) in zip(accentRings, Self.strokes.prefix(2)) {
                ring.frame = bounds
                // strokeBorder kept its stroke inside the shape; a
                // shape layer strokes astride the path, so the path
                // pulls in by half the width to land identically.
                let inset = spec.width / 2
                ring.path = currentShape
                    .path(in: bounds.insetBy(dx: inset, dy: inset))
                    .cgPath
            }
            lipGradient.frame = bounds
            lipMask.frame = lipGradient.bounds
            let lipInset = Self.strokes[2].width / 2
            lipMask.path = currentShape
                .path(in: bounds.insetBy(dx: lipInset, dy: lipInset))
                .cgPath
        }

        /// One breath cycle, re-armed only when the Feel changes its
        /// tempo. The sine ran sin(t / (1.6 * ambientSlow)), a period
        /// of 2pi * 1.6 * ambientSlow; autoreverse walks half of it
        /// each way.
        private func armBreath() {
            let duration = Double.pi * 1.6 * Theme.Motion.ambientSlow
            guard breathDuration != duration else { return }
            breathDuration = duration
            let breathers: [(CALayer, base: Float, amp: Float)] =
                zip(accentRings, Self.strokes.prefix(2)).map { ($0, $1.base, $1.amp) }
                + [(lipGradient, Self.strokes[2].base, Self.strokes[2].amp)]
            for (ring, base, amp) in breathers {
                ring.removeAnimation(forKey: "breath")
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = base
                breath.toValue = base + amp
                breath.duration = duration
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                breath.isRemovedOnCompletion = false
                ring.add(breath, forKey: "breath")
            }
        }
    }
}
