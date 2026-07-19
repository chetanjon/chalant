import SwiftUI

/// The pomodoro home: presets when idle, and while a session runs, a
/// progress ring, the countdown, round dots, noise, and transport.
struct FocusPanel: View {
    @ObservedObject var focus: FocusController
    @Environment(\.moaiAccent) private var accent

    var body: some View {
        if focus.isActive {
            activeCard
        } else {
            presets
        }
    }

    // MARK: Idle — pick a session length

    private var presets: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("FOCUS")
                .font(Theme.Fonts.micro)
                .tracking(1.3)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: Theme.Space.m) {
                presetChip(15)
                presetChip(25)
                presetChip(50)
            }
            Text("Four rounds to a set, short breaks between, a long one after. Noise optional.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textHint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func presetChip(_ minutes: Int) -> some View {
        Button {
            focus.start(work: minutes)
        } label: {
            VStack(spacing: 2) {
                Text("\(minutes)")
                    .font(Theme.Fonts.numeral)
                    .foregroundStyle(Theme.textPrimary)
                Text("min")
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 64)
            .padding(.vertical, Theme.Space.l)
            .moaiCard(radius: Theme.Radius.card)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(radius: Theme.Radius.card)
    }

    // MARK: Active session

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(spacing: Theme.Space.xl) {
                ProgressRing(
                    progress: focus.progress,
                    size: 54,
                    lineWidth: 3,
                    tint: focus.phase == .work ? accent : Theme.accentFallback,
                    trackOpacity: 0.08
                ) {
                    Text("\(focus.roundInSet)")
                        .font(Theme.Fonts.counterMono)
                        .foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(focus.phase == .work ? "FOCUS" : "BREAK")
                        .font(Theme.Fonts.micro)
                        .tracking(1.3)
                        .foregroundStyle(focus.phase == .work ? accent : Theme.textTertiary)
                    Text(focus.display)
                        .font(Theme.Fonts.display)
                        .foregroundStyle(Theme.textPrimary)
                        .opacity(focus.isPaused ? 0.45 : 1)
                    roundDots
                }
                Spacer()
                controls
            }
            HStack(spacing: Theme.Space.m) {
                Text("noise")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(NoiseEngine.NoiseColor.allCases, id: \.self) { color in
                    NoiseButton(
                        color: color,
                        selected: focus.noiseColor == color
                    ) {
                        focus.setNoise(color)
                    }
                }
                Spacer()
                if focus.isPaused {
                    Text("paused")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.xs)
        .animation(Theme.Motion.content, value: focus.isPaused)
        .animation(Theme.Motion.content, value: focus.phase)
    }

    private var roundDots: some View {
        HStack(spacing: 5) {
            ForEach(1...4, id: \.self) { round in
                Circle()
                    .fill(
                        round < focus.roundInSet ? AnyShapeStyle(accent)
                            : round == focus.roundInSet ? AnyShapeStyle(accent.opacity(0.55))
                            : AnyShapeStyle(Color.white.opacity(0.12))
                    )
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.s) {
            HoverGlyphButton(
                symbol: focus.isPaused ? "play.fill" : "pause.fill",
                scale: .m,
                tint: Theme.textPrimary
            ) {
                focus.togglePause()
            }
            HoverGlyphButton(
                symbol: "forward.end.fill",
                scale: .s,
                tint: Theme.textSecondary
            ) {
                focus.skip()
            }
            CloseButton(scale: .s) {
                focus.stop()
            }
        }
    }
}
