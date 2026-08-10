import AppKit
import SwiftUI

/// The music row: flat 56pt artwork, stacked title/artist, bare thin
/// transport glyphs, and a full-width scrub line with elapsed and
/// remaining time beneath. The glow, sheen and now-playing equalizer
/// are gone (premium finish, spec 2026-08-10): the row reads by
/// typography and brightness, never decoration.
struct MusicRow: View {
    @ObservedObject var music: MusicController
    /// Local slider value while the user is dragging, so the 1s
    /// player poll can't yank the knob back mid-gesture.
    @State private var volumeOverride: Double?

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

                    VStack(alignment: .leading, spacing: 2) {
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
                            Slider(
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
                                onEditingChanged: { editing in
                                    if !editing, let target = volumeOverride {
                                        music.commitVolume(target)
                                        volumeOverride = nil
                                    }
                                }
                            )
                            .controlSize(.mini)
                            .tint(Color.white.opacity(0.5))
                            .frame(width: 84)
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
                // a second. ScrubBar draws at a fixed 16pt height, so
                // this periodic tick never touches layout.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let livePosition = music.position(at: context.date)
                    VStack(spacing: Theme.Space.m) {
                        ScrubBar(
                            position: livePosition,
                            duration: max(playing.duration, 1),
                            tint: Color.white.opacity(0.9),
                            onSeek: { music.seek(to: $0) }
                        )
                        HStack {
                            Text(Self.clock(livePosition))
                                .font(Theme.Fonts.timeMono)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(Self.remainingClock(elapsed: livePosition, duration: playing.duration))
                                .font(Theme.Fonts.timeMono)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .animation(Theme.Motion.content, value: playing.isPlaying)
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

    /// The right side of the progress line counts down (founder's
    /// mockup, 2026-08-10): what is left, not what the whole is.
    static func remainingClock(elapsed: Double, duration: Double) -> String {
        "-" + clock(max(0, duration - elapsed))
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
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
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

/// The ambience row: a label that names the feature (and the sound
/// that's playing), then the sound icons. Hover an icon for its name;
/// the active one tints and reveals a volume slider.
struct AmbienceRow: View {
    @ObservedObject var ambience: AmbienceController
    @Environment(\.chalantAccent) private var accent

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Group {
                if let active = ambience.active {
                    // While a sound plays its name becomes a quiet accent
                    // pill; tapping it stops. Reads as "on, tap to stop"
                    // the way the sound chips already do.
                    Button {
                        ambience.stop()
                    } label: {
                        Text(active.displayName)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(accent.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Stop \(active.displayName)")
                } else if let failure = ambience.failure {
                    // The chip has already gone dark; this says why,
                    // rather than leaving the tap looking ignored.
                    Text("No sound")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textHint)
                        .lineLimit(1)
                        .help("Tried to play, but \(failure).")
                } else {
                    Text("Ambience")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 92, alignment: .leading)

            // White is gone from the row: piercing, nobody's friend.
            // On one track, for the same reason the switcher below is:
            // five loose glyphs above seven more read as one scatter of
            // twelve, with nothing to say where one row ends.
            HStack(spacing: Theme.Space.s) {
                ForEach(NoiseEngine.NoiseColor.chipChoices, id: \.self) { color in
                    NoiseButton(
                        color: color,
                        selected: ambience.active == color,
                        compact: true
                    ) {
                        ambience.toggle(color)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xs)
            .background(Capsule().fill(Theme.surface))
            Spacer(minLength: 0)
            if ambience.active != nil {
                Slider(value: $ambience.volume, in: 0...1)
                    .controlSize(.mini)
                    .tint(Color.white.opacity(0.5))
                    .frame(width: 44)
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
