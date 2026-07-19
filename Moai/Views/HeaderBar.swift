import SwiftUI

/// The expanded island's top line. Content mode shows the wordmark
/// and utility buttons; with a pane open it becomes back + pane title.
struct HeaderBar: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var focus: FocusController
    @Environment(\.moaiAccent) private var accent

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if model.pane == .none {
                Text("Moai")
                    .font(Theme.Fonts.brand)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                HoverGlyphButton(symbol: "chevron.left", tint: Theme.textSecondary) {
                    withAnimation(Theme.Motion.content) { model.pane = .none }
                }
                Text(model.pane == .focus ? "Focus" : "Settings")
                    .font(Theme.Fonts.brand)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            if model.pane == .none {
                HoverGlyphButton(symbol: "mic.fill", tint: accent) {
                    model.toggleListening()
                }
                HoverGlyphButton(
                    symbol: "timer",
                    tint: focus.isActive ? accent : Theme.textTertiary
                ) {
                    withAnimation(Theme.Motion.content) { model.pane = .focus }
                }
                HoverGlyphButton(symbol: "gearshape", tint: Theme.textTertiary) {
                    withAnimation(Theme.Motion.content) { model.pane = .settings }
                }
            }
            CloseButton {
                model.collapse()
            }
        }
    }
}
