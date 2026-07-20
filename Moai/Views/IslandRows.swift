import SwiftUI

/// The music row: dimensional artwork that glows while it plays, a
/// now-playing equalizer, title/artist, and a scrubber with elapsed and
/// total time. Rich but still one tight block, volume lives on the
/// system keys, not here.
struct MusicRow: View {
    @ObservedObject var music: MusicController
    @Environment(\.moaiAccent) private var accent
    @State private var scrubPosition: Double?

    var body: some View {
        if let playing = music.nowPlaying {
            HStack(spacing: Theme.Space.l) {
                artworkView(isPlaying: playing.isPlaying)

                VStack(alignment: .leading, spacing: 5) {
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
                    Slider(
                        value: Binding(
                            get: { scrubPosition ?? playing.position },
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
                        Text(Self.clock(scrubPosition ?? playing.position))
                        Spacer()
                        Text(Self.clock(playing.duration))
                    }
                    .font(Theme.Fonts.microMono)
                    .foregroundStyle(Theme.textGhost)
                }

                HStack(spacing: Theme.Space.s) {
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
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Top-lit sheen: the art reads as a physical, lit surface.
        .overlay(
            LinearGradient(
                colors: [Color.white.opacity(0.22), .clear],
                startPoint: .top, endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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

/// A tiny live equalizer, three accent bars breathing while a track
/// plays. Still glass (or Reduce Motion) shows them at rest.
struct NowPlayingBars: View {
    let accent: Color

    var body: some View {
        if Theme.Feel.current.ambient {
            TimelineView(.animation(minimumInterval: 1 / 12)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                bars { index in
                    3 + 6 * (0.5 + 0.5 * sin(t * 4.2 + Double(index) * 1.7))
                }
            }
        } else {
            bars { index in [5.0, 9.0, 6.0][index] }
        }
    }

    private func bars(_ height: @escaping (Int) -> CGFloat) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(accent)
                    .frame(width: 2.5, height: height(index))
            }
        }
        .frame(height: 12)
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

            ForEach(NoiseEngine.NoiseColor.allCases, id: \.self) { color in
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
                    Text("Hold the notch or tap the mic, I'm listening.")
                        .font(Theme.Fonts.reading)
                        .foregroundStyle(Theme.textHint)
                    Text("remind me to call amma at 6 · what's on today · focus 25 · note: an idea")
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
