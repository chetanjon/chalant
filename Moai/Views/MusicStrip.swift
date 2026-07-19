import SwiftUI

struct MusicStrip: View {
    @ObservedObject var music: MusicController
    @Environment(\.moaiAccent) private var accent
    @State private var scrubPosition: Double?
    @State private var volumeDraft: Double?
    @State private var artworkHovered = false

    var body: some View {
        if let playing = music.nowPlaying {
            HStack(spacing: Theme.Space.l) {
                artworkView

                VStack(alignment: .leading, spacing: 3) {
                    Text(playing.track)
                        .font(Theme.Fonts.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(playing))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)

                    HStack(spacing: Theme.Space.s) {
                        Text(Self.clock(scrubPosition ?? playing.position))
                            .font(Theme.Fonts.microMono)
                            .foregroundStyle(Theme.textTertiary)
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
                        Text(Self.clock(playing.duration))
                            .font(Theme.Fonts.microMono)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                VStack(spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        transportButton("backward.fill") {
                            music.previous()
                        }
                        Button {
                            playing.isPlaying ? music.pause() : music.play()
                        } label: {
                            Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                                .font(Theme.Fonts.icon(.m, weight: .bold))
                                .foregroundStyle(Color.black)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.white.opacity(0.92)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressableStyle())
                        transportButton("forward.fill") {
                            music.next()
                        }
                    }
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(Theme.Fonts.icon(.xs))
                            .foregroundStyle(Theme.textTertiary)
                        Slider(
                            value: Binding(
                                get: { volumeDraft ?? playing.volume },
                                set: { volumeDraft = $0 }
                            ),
                            in: 0...100,
                            onEditingChanged: { editing in
                                if !editing, let target = volumeDraft {
                                    music.setVolume(target)
                                    volumeDraft = nil
                                }
                            }
                        )
                        .controlSize(.mini)
                        .tint(accent)
                        .frame(width: 70)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .moaiCard()
        }
    }

    private var artworkView: some View {
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
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        // Hovering the artwork reveals a play/pause veil, the way
        // every system player does it.
        .overlay {
            if artworkHovered, let playing = music.nowPlaying {
                Button {
                    playing.isPlaying ? music.pause() : music.play()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.artwork, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                        Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                            .font(Theme.Fonts.icon(.l, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.92))
                    }
                }
                .buttonStyle(PressableStyle())
                .transition(.opacity)
            }
        }
        .onHover { artworkHovered = $0 }
        .animation(Theme.Motion.hover, value: artworkHovered)
        .shadow(color: Color.black.opacity(0.35), radius: 5, y: 2)
    }

    private func subtitle(_ playing: MusicController.NowPlaying) -> String {
        playing.album.isEmpty
            ? playing.artist
            : "\(playing.artist) — \(playing.album)"
    }

    private func transportButton(
        _ symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        HoverGlyphButton(
            symbol: symbol,
            scale: .s,
            tint: Theme.textPrimary,
            action: action
        )
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
