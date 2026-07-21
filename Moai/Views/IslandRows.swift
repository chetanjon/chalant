import AppKit
import SwiftUI

/// The music row: dimensional artwork that glows while it plays, a
/// now-playing equalizer, title/artist, and a scrubber with elapsed and
/// total time. Rich but still one tight block, volume lives on the
/// system keys, not here.
struct MusicRow: View {
    @ObservedObject var music: MusicController
    @Environment(\.moaiAccent) private var accent
    @State private var scrubPosition: Double?
    /// Local slider value while the user is dragging, so the 1s
    /// player poll can't yank the knob back mid-gesture.
    @State private var volumeOverride: Double?

    var body: some View {
        if let playing = music.nowPlaying {
            HStack(spacing: Theme.Space.l) {
                Button {
                    music.openMusicApp()
                } label: {
                    artworkView(isPlaying: playing.isPlaying)
                }
                .buttonStyle(PressableStyle())
                .help("Open \(playing.source.displayName)")

                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                    HStack(spacing: Theme.Space.s) {
                        Text(playing.track)
                            .font(Theme.Fonts.bodyEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(playing.artist)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if playing.isPlaying {
                            NowPlayingBars(accent: accent)
                                .transition(.opacity)
                        }
                    }
                    // Position is projected between the player's 1s
                    // polls, so the knob and clock glide instead of
                    // stepping once a second.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let livePosition = music.position(at: context.date)
                        VStack(alignment: .leading, spacing: Theme.Space.snug) {
                            Slider(
                                value: Binding(
                                    get: { scrubPosition ?? livePosition },
                                    set: { scrubPosition = $0 }
                                ),
                                in: 0...max(playing.duration, 1),
                                onEditingChanged: { editing in
                                    if !editing, let target = scrubPosition {
                                        music.seek(to: target)
                                        scrubPosition = nil
                                    }
                                }
                            )
                            .controlSize(.mini)
                            .tint(accent)
                            HStack {
                                Text(Self.clock(scrubPosition ?? livePosition))
                                Spacer()
                                Text(Self.clock(playing.duration))
                            }
                            .font(Theme.Fonts.microMono)
                            .foregroundStyle(Theme.textGhost)
                        }
                    }
                }

                VStack(spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        if playing.supportsShuffle {
                            HoverGlyphButton(
                                symbol: "shuffle",
                                scale: .xs,
                                tint: playing.shuffling ? accent : Theme.textTertiary
                            ) {
                                music.toggleShuffle()
                            }
                            .help(playing.shuffling ? "Shuffle is on" : "Shuffle")
                        }
                        HoverGlyphButton(symbol: "backward.fill", scale: .s, tint: Theme.textPrimary) {
                            music.previous()
                        }
                        Button {
                            playing.isPlaying ? music.pause() : music.play()
                        } label: {
                            Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                                .font(Theme.Fonts.icon(.m, weight: .bold))
                                .foregroundStyle(Color.black)
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.96))
                                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                                )
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressableStyle())
                        HoverGlyphButton(symbol: "forward.fill", scale: .s, tint: Theme.textPrimary) {
                            music.next()
                        }
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
                        .frame(width: 68)
                    }
                    .help(
                        playing.source.scriptable == nil
                            ? "System volume"
                            : "\(playing.source.displayName) volume"
                    )
                }
            }
            .animation(Theme.Motion.content, value: playing.isPlaying)
        }
    }

    private func artworkView(isPlaying: Bool) -> some View {
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
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
        // Top-lit sheen: the art reads as a physical, lit surface.
        .overlay(
            LinearGradient(
                colors: [Color.white.opacity(0.22), .clear],
                startPoint: .top, endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous))
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        // Album-colored glow while playing; a plain drop shadow when paused.
        .shadow(
            color: isPlaying ? accent.opacity(0.38) : Color.black.opacity(0.4),
            radius: isPlaying ? 9 : 5,
            y: 3
        )
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
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
    @Environment(\.moaiAccent) private var accent

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
                } else {
                    Text("Ambience")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 92, alignment: .leading)

            // White is gone from the row: piercing, nobody's friend.
            ForEach(NoiseEngine.NoiseColor.chipChoices, id: \.self) { color in
                NoiseButton(
                    color: color,
                    selected: ambience.active == color,
                    compact: true
                ) {
                    ambience.toggle(color)
                }
            }
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
    @Environment(\.moaiAccent) private var accent

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
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(idleHint)
                        .font(Theme.Fonts.reading)
                        .foregroundStyle(Theme.textHint)
                    Text("remind me to call amma at 6 · focus 25 · note: an idea · say help for the rest")
                        .font(Theme.Fonts.label)
                        .fontWeight(.regular)
                        .foregroundStyle(Theme.textGhost)
                }
            } else if model.answer.count > 900 {
                ScrollView {
                    answerText
                }
                .frame(maxHeight: 280)
            } else {
                answerText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Name the summon key while one is set; the words track Settings.
    private var idleHint: String {
        let key = HotkeySummon.current
        guard key != .off else {
            return "Hold the notch or tap the mic, I'm listening."
        }
        return "Hold the notch, tap the mic, or hit \(key.display) anywhere."
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
