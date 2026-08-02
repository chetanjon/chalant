import SwiftUI

/// One strip for anything counting, a pomodoro session, a plain
/// timer, or the stopwatch. Same grammar; tap to open the Focus pane.
struct SessionStrip: View {
    enum Kind {
        case focus
        case timer
        case stopwatch
    }

    let kind: Kind
    @ObservedObject var focus: FocusController
    @ObservedObject var timer: CountdownController
    @ObservedObject var stopwatch: StopwatchController
    let open: () -> Void

    @Environment(\.chalantAccent) private var accent

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if kind == .stopwatch {
                // Counting up has no endpoint for a ring to close.
                Image(systemName: "stopwatch")
                    .font(Theme.Fonts.icon(.s))
                    .foregroundStyle(accent)
            } else {
                ProgressRing(
                    progress: kind == .focus ? focus.progress : timer.progress,
                    size: 14,
                    lineWidth: 1.5,
                    tint: ringTint
                )
            }
            Text(title)
                .font(Theme.Fonts.bodyEmphasisMono)
                .foregroundStyle(Theme.textPrimary)
                .opacity(
                    (kind == .focus && focus.isPaused)
                        || (kind == .stopwatch && !stopwatch.isRunning)
                        ? 0.5 : 1
                )
            if kind == .focus {
                Text("cycle \(focus.cycle)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textHint)
            }
            Spacer()
            if kind == .focus {
                HoverGlyphButton(
                    symbol: focus.isPaused ? "play.fill" : "pause.fill",
                    label: focus.isPaused ? "Resume focus" : "Pause focus",
                    scale: .xs,
                    tint: Theme.textSecondary
                ) {
                    focus.togglePause()
                }
            }
            if kind == .stopwatch {
                HoverGlyphButton(
                    symbol: stopwatch.isRunning ? "pause.fill" : "play.fill",
                    label: stopwatch.isRunning ? "Pause stopwatch" : "Start stopwatch",
                    scale: .xs,
                    tint: Theme.textSecondary
                ) {
                    stopwatch.toggle()
                }
            }
            CloseButton {
                switch kind {
                case .focus: focus.stop()
                case .timer: timer.stop()
                case .stopwatch: stopwatch.reset()
                }
            }
        }
        .rowInsets()
        .chalantCard()
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
        case .stopwatch:
            return "Stopwatch \(stopwatch.display)"
        }
    }

    private var ringTint: Color {
        if kind == .focus, focus.phase != .work {
            return Theme.accentFallback
        }
        return accent
    }
}
