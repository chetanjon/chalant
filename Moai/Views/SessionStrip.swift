import SwiftUI

/// One strip for anything counting down, a pomodoro session or a
/// plain timer. Same ring, same grammar; tap to open the Focus pane.
struct SessionStrip: View {
    enum Kind {
        case focus
        case timer
    }

    let kind: Kind
    @ObservedObject var focus: FocusController
    @ObservedObject var timer: CountdownController
    let open: () -> Void

    @Environment(\.moaiAccent) private var accent

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ProgressRing(
                progress: kind == .focus ? focus.progress : timer.progress,
                size: 14,
                lineWidth: 1.5,
                tint: ringTint
            )
            Text(title)
                .font(Theme.Fonts.bodyEmphasisMono)
                .foregroundStyle(Theme.textPrimary)
                .opacity(kind == .focus && focus.isPaused ? 0.5 : 1)
            if kind == .focus {
                Text("cycle \(focus.cycle)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
            }
            Spacer()
            if kind == .focus {
                HoverGlyphButton(
                    symbol: focus.isPaused ? "play.fill" : "pause.fill",
                    scale: .xs,
                    tint: Theme.textSecondary
                ) {
                    focus.togglePause()
                }
            }
            CloseButton {
                kind == .focus ? focus.stop() : timer.stop()
            }
        }
        .rowInsets()
        .moaiCard()
        .hoverHighlight(radius: Theme.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onTapGesture(perform: open)
    }

    private var title: String {
        switch kind {
        case .focus:
            return focus.phase == .work ? "Focus \(focus.display)" : "Break \(focus.display)"
        case .timer:
            return "Timer \(timer.display)"
        }
    }

    private var ringTint: Color {
        if kind == .focus, focus.phase != .work {
            return Theme.accentFallback
        }
        return accent
    }
}
