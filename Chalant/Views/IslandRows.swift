import AppKit
import SwiftUI

/// The music row: flat 56pt artwork, stacked title/artist, bare thin
/// transport glyphs, and a full-width scrub line with elapsed and
/// remaining time beneath. The sheen and now-playing equalizer are
/// gone (premium finish, spec 2026-08-10): the row reads by
/// typography and brightness, never decoration. One quiet exception
/// (round 3, task 6): a soft accent-colored pool breathes behind the
/// zone while music plays, matching the album's own color.
struct MusicRow: View {
    @ObservedObject var music: MusicController
    @Environment(\.chalantAccent) private var accent
    /// Local slider value while the user is dragging, so the 1s
    /// player poll can't yank the knob back mid-gesture.
    @State private var volumeOverride: Double?
    /// An optimistic seek target held until the player's slow poll
    /// converges on it (or 3s pass), so the bar never snaps back to
    /// the stale position after a release.
    @State private var pendingSeek: (target: Double, at: Date)?
    /// Drives the background pool's slow opacity breath. Only ever
    /// animated through withAnimation in updateBreathing, never by an
    /// .animation modifier, so the repeatForever loop can't leak onto
    /// sibling views.
    @State private var breathing = false

    var body: some View {
        if let playing = music.nowPlaying {
            VStack(spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.xl) {
                    Button {
                        music.openMusicApp()
                    } label: {
                        artworkView()
                    }
                    .buttonStyle(PressableStyle())
                    .help("Open \(playing.source.displayName)")

                    VStack(alignment: .leading, spacing: Theme.Space.stacked) {
                        Text(playing.track)
                            .font(Theme.Fonts.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(playing.artist)
                            .font(Theme.Fonts.subhead)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: Theme.Space.xxl) {
                        if playing.supportsShuffle {
                            HoverGlyphButton(
                                symbol: "shuffle",
                                label: "Shuffle",
                                scale: .xs,
                                tint: playing.shuffling ? Theme.textPrimary : Theme.textTertiary
                            ) {
                                music.toggleShuffle()
                            }
                            .help(playing.shuffling ? "Shuffle is on" : "Shuffle")
                        }
                        HoverGlyphButton(
                            symbol: "backward.fill", label: "Previous track",
                            scale: .m, tint: Theme.textPrimary, weight: .regular
                        ) {
                            music.previous()
                        }
                        Button {
                            playing.isPlaying ? music.pause() : music.play()
                        } label: {
                            Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                                .font(Theme.Fonts.icon(.l))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(minWidth: 22, minHeight: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        HoverGlyphButton(
                            symbol: "forward.fill", label: "Next track",
                            scale: .m, tint: Theme.textPrimary, weight: .regular
                        ) {
                            music.next()
                        }
                        HStack(spacing: Theme.Space.xs) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(Theme.Fonts.icon(.xs))
                                .foregroundStyle(Theme.textTertiary)
                            ThinSlider(
                                value: Binding(
                                    get: { volumeOverride ?? playing.volume },
                                    set: { value in
                                        volumeOverride = value
                                        // Applied live but debounced, so the
                                        // drag feels attached to the sound.
                                        music.previewVolume(value)
                                    }
                                ),
                                in: 0...100,
                                label: "Volume",
                                onCommit: { target in
                                    music.commitVolume(target)
                                    volumeOverride = nil
                                }
                            )
                        }
                        .help(
                            playing.source.scriptable == nil
                                ? "System volume"
                                : "\(playing.source.displayName) volume"
                        )
                    }
                }

                // Position is projected between the player's 1s polls,
                // so the line and clocks glide instead of stepping once
                // a second. The fill width still relayouts every tick,
                // but inside ScrubBar's own fixed 16pt frame, so it is
                // what keeps the island's measured height out of it.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let livePosition = music.position(at: context.date)
                    let shown = Self.displayPosition(
                        live: livePosition, pending: pendingSeek, now: context.date)
                    VStack(spacing: Theme.Space.m) {
                        ScrubBar(
                            position: shown,
                            duration: max(playing.duration, 1),
                            tint: Color.white.opacity(0.9),
                            onSeek: {
                                pendingSeek = (target: $0, at: Date())
                                music.seek(to: $0)
                            }
                        )
                        HStack {
                            Text(Self.clock(shown))
                                .font(Theme.Fonts.timeMono)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                    }
                }
            }
            .background {
                if playing.isPlaying {
                    // The one drop of color the founder asked back: the album's own
                    // light, pooled soft behind the zone, breathing slowly while the
                    // music plays. Feel-gated: Still means a quiet, motionless pool.
                    RadialGradient(
                        colors: [accent.opacity(0.14), .clear],
                        center: .init(x: 0.22, y: 0.35),
                        startRadius: 8, endRadius: 220
                    )
                    .blur(radius: 18)
                    .opacity(breathing ? 1.0 : 0.7)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(Theme.Motion.content, value: playing.isPlaying)
            .onAppear { updateBreathing(isPlaying: playing.isPlaying) }
            .onChange(of: playing.isPlaying) { _, isPlaying in
                updateBreathing(isPlaying: isPlaying)
            }
        }
    }

    /// Starts (or stops) the pool's breathing loop. The repeatForever
    /// animation is attached to this state change alone, never to an
    /// .animation modifier on the view, so it can't leak onto siblings
    /// and dies with the view's @State when MusicRow unmounts.
    private func updateBreathing(isPlaying: Bool) {
        if isPlaying, Theme.Feel.current.ambient {
            withAnimation(
                .easeInOut(duration: 3.2 * Theme.Motion.ambientSlow)
                    .repeatForever(autoreverses: true)
            ) {
                breathing = true
            }
        } else {
            breathing = false
        }
    }

    private func artworkView() -> some View {
        Group {
            if let artwork = music.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.surface
                    Image(systemName: "music.note")
                        .font(Theme.Fonts.icon(.l))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
    }

    /// Hours appear only when needed: videos and live streams run
    /// long, songs stay "3:41".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// What the bar and clock show: an optimistic seek target until the
    /// player's slow poll catches up (within 2s of the target), capped
    /// at 3s so a player that ignored the seek cannot pin a lie.
    static func displayPosition(
        live: Double, pending: (target: Double, at: Date)?, now: Date
    ) -> Double {
        guard let pending else { return live }
        if now.timeIntervalSince(pending.at) > 3 { return live }
        if abs(live - pending.target) <= 2 { return live }
        return pending.target
    }
}

/// A live equalizer: accent bars dancing while a track plays. This is
/// playback feedback, not ambient decoration, so it keeps moving under
/// the Still feel (it disappears the moment playback pauses); only the
/// system Reduce Motion setting parks it.
struct NowPlayingBars: View {
    let accent: Color
    var barCount = 5
    var maxHeight: CGFloat = 14

    var body: some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            bars { index in restHeight(index) }
        } else {
            // 15, not 30. Every tick of a TimelineView re-runs the
            // hosting view's whole layout pass, not just this Canvas's
            // draw: sampled on 2026-08-10, a playing island spent 18%
            // of its main thread inside NSHostingView.layout() under
            // the display-cycle observer, and switching this signal off
            // took that path to ZERO samples. The Canvas fix from
            // Round 22b stopped the bars invalidating layout by
            // changing a frame; it could not stop the tick itself.
            //
            // Halving the rate halves the passes. Bars still read as
            // dancing at 15, and the app already holds this precedent:
            // the aurora runs at 12 deliberately, with "CPU halved, do
            // not raise" written beside it.
            TimelineView(.animation(minimumInterval: 1 / 15)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                bars { index in liveHeight(t: t, index: index) }
            }
        }
    }

    private var barWidth: CGFloat { 2.5 }
    private var barSpacing: CGFloat { 2 }

    /// Two incommensurate sines plus a slow swell per bar: loop-free,
    /// organic bounce, the way a real analyzer never quite repeats.
    private func liveHeight(t: Double, index: Int) -> CGFloat {
        let phase = Double(index) * 1.9
        let fast = sin(t * 4.6 + phase)
        let cross = sin(t * 2.9 + phase * 2.3)
        let swell = sin(t * 0.7 + phase * 0.9)
        let unit = 0.5 + 0.5 * (0.55 * fast + 0.3 * cross + 0.15 * swell)
        return maxHeight * CGFloat(0.22 + 0.78 * unit)
    }

    private func restHeight(_ index: Int) -> CGFloat {
        maxHeight * [0.45, 0.8, 0.6, 0.9, 0.5][index % 5]
    }

    /// Drawn in a fixed-size Canvas, not height-animated subviews: a
    /// `.frame(height:)` that changes 30 times a second invalidates
    /// layout of the whole island every tick (measured at ~30% of
    /// main-thread time while collapsed). Drawing repaints only these
    /// few points of screen and never touches layout.
    private func bars(_ height: @escaping (Int) -> CGFloat) -> some View {
        Canvas { context, size in
            for index in 0..<barCount {
                let barHeight = max(barWidth, height(index))
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + barSpacing),
                    y: (size.height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(Capsule().path(in: rect), with: .color(accent))
            }
        }
        .frame(
            width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing,
            height: maxHeight
        )
    }
}

/// The ambience row: text chips, one per sound, no label zone and no
/// icons. The active chip is white (`Theme.textPrimary`); tapping it
/// is how you stop it, same button as the one that started it. The
/// volume control appears only while a sound is actually playing.
struct AmbienceRow: View {
    @ObservedObject var ambience: AmbienceController

    var body: some View {
        HStack(spacing: Theme.Space.xxl) {
            ForEach(NoiseEngine.NoiseColor.chipChoices, id: \.self) { color in
                Button {
                    ambience.toggle(color)
                } label: {
                    Text(color.displayName)
                        .font(ambience.active == color
                              ? Theme.Fonts.bodyEmphasis : Theme.Fonts.body)
                        .foregroundStyle(ambience.active == color
                                         ? Theme.textPrimary : Theme.textSecondary)
                }
                .buttonStyle(PressableStyle())
                .help(ambience.active == color
                      ? "Stop \(color.displayName)" : "Play \(color.displayName)")
            }
            if let failure = ambience.failure {
                Text("No sound")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
                    .help("Tried to play, but \(failure).")
            }
            Spacer(minLength: 0)
            // The founder's rule, already true here and staying true:
            // the volume control exists only while a sound is on.
            if ambience.active != nil {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(Theme.Fonts.icon(.xs))
                        .foregroundStyle(Theme.textTertiary)
                    ThinSlider(value: $ambience.volume, in: 0...1, label: "Ambience volume")
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.content, value: ambience.active)
    }
}

/// The answer surface: the reply, the working state, or, when idle,
/// a voice-forward hint. Input is voice (the mic, or holding the notch),
/// not a text field.
struct AnswerView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let context = model.pendingContext {
                contextChip(context.name)
            }
            // Voice answers carry their transcript, so a mishearing
            // is visible instead of mysterious.
            if let heard = model.lastHeard {
                Text("heard \u{201C}\(heard)\u{201D}")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textGhost)
                    .lineLimit(2)
            }
            if model.isWorking, model.answer.isEmpty {
                ThinkingDots()
                    .padding(.top, Theme.Space.xs)
            } else if !model.errorText.isEmpty {
                Text(model.errorText)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.answer.isEmpty {
                // One line, not three. "Type below, or tap the mic and
                // say it" said what the field below and the mic above
                // already say, and the examples said it a third time.
                // Idle is the island's most common state, so every row
                // it spends here is height the whole surface carries
                // ("too overwhelming and cluttered").
                //
                // Hint, not ghost: this is the only place the verbs are
                // named, so it carries information, and Theme reserves
                // ghost for marks that carry none.
                Text("remind me to call amma at 6 · focus 25 · note: an idea · say help")
                    .font(Theme.Fonts.label)
                    .fontWeight(.regular)
                    .foregroundStyle(Theme.textHint)
            } else if model.answer.count > 900 {
                ScrollView {
                    answerText
                }
                .frame(maxHeight: 280)
            } else {
                answerText
            }
            commandBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The reliable twin to voice: the same verbs, typed. One input
    /// modality is a single point of failure (a whole day of voice
    /// archaeology, 2026-07-21, proved it), so the engine keeps a
    /// second mouth that no microphone can betray.
    private var commandBar: some View {
        HStack(spacing: Theme.Space.s) {
            TextField("remind, note, focus, or ask", text: $model.draftPrompt)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .onSubmit(submitDraft)
            if !model.draftPrompt.isEmpty {
                HoverGlyphButton(
                    symbol: "arrow.up.circle.fill", label: "Send", scale: .m, tint: accent
                ) {
                    submitDraft()
                }
                .transition(.opacity)
            }
        }
        .padding(Theme.Space.m)
        .chalantField()
        .padding(.top, Theme.Space.xs)
        .animation(Theme.Motion.hover, value: model.draftPrompt.isEmpty)
    }

    private func submitDraft() {
        let typed = model.draftPrompt.trimmingCharacters(in: .whitespaces)
        model.draftPrompt = ""
        guard !typed.isEmpty else { return }
        model.submit(typed)
    }

    private var answerText: some View {
        Text(model.answer)
            .font(Theme.Fonts.reading)
            .lineSpacing(3)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextChip(_ name: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "paperclip")
                .font(Theme.Fonts.icon(.xs))
            Text(name)
                .font(Theme.Fonts.caption)
                .lineLimit(1)
            Button {
                model.pendingContext = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Fonts.icon(.xs, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .foregroundStyle(accent)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
    }
}
