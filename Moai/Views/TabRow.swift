import SwiftUI

/// The lower-panel switcher: Today (when your day is turned on) plus
/// whichever tools you keep, and the settings gear. Every item wears its
/// name, so the features are findable at a glance, not guessed from an
/// icon.
struct Switcher: View {
    @ObservedObject var model: NotchViewModel
    let todayEnabled: Bool
    let tools: [NotchViewModel.Tab]

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if todayEnabled {
                item(.today)
            }
            ForEach(tools, id: \.self) { item($0) }
            Spacer(minLength: 0)
            HoverGlyphButton(symbol: "gearshape", scale: .m, tint: Theme.textTertiary) {
                withAnimation(Theme.Motion.content) { model.pane = .settings }
            }
        }
    }

    private func item(_ tab: NotchViewModel.Tab) -> some View {
        let on = model.tab == tab
        return Button {
            withAnimation(Theme.Motion.content) { model.tab = tab }
        } label: {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: Self.symbol(tab))
                    .font(Theme.Fonts.icon(.s))
                Text(Self.label(tab))
                    .font(Theme.Fonts.label)
            }
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(on ? 0.10 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(Self.label(tab))
    }

    static func symbol(_ tab: NotchViewModel.Tab) -> String {
        switch tab {
        case .today: return "calendar"
        case .ask: return "sparkles"
        case .links: return "square.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray.full"
        case .focus: return "timer"
        }
    }

    static func label(_ tab: NotchViewModel.Tab) -> String {
        switch tab {
        case .today: return "Today"
        case .ask: return "Answer"
        case .links: return "Shortcuts"
        case .clipboard: return "Clipboard"
        case .shelf: return "Files"
        case .focus: return "Focus"
        }
    }
}
