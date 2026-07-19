import SwiftUI

/// The content tabs with their sliding pill. The pill's namespace
/// lives here — nothing outside the row matches against it.
struct TabRow: View {
    @ObservedObject var model: NotchViewModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            pill("Do", "sparkle", .ask)
            pill("Go", "arrow.up.right", .links)
            pill("Clips", "doc.on.clipboard", .clipboard)
            pill("Shelf", "tray", .shelf)
            Spacer()
        }
    }

    private static let order: [NotchViewModel.Tab] = [.ask, .links, .clipboard, .shelf]

    private func pill(_ title: String, _ symbol: String, _ tab: NotchViewModel.Tab) -> some View {
        TabPill(title: title, symbol: symbol, selected: model.tab == tab, namespace: ns) {
            let from = Self.order.firstIndex(of: model.tab) ?? 0
            let to = Self.order.firstIndex(of: tab) ?? 0
            model.tabSlideDirection = to >= from ? 1 : -1
            withAnimation(Theme.Motion.content) {
                model.tab = tab
            }
        }
    }
}

/// One tab in the sliding-pill row: tinted icon + label. The active
/// pill carries the accent; inactive tabs answer hover with a lift.
struct TabPill: View {
    let title: String
    let symbol: String
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @Environment(\.moaiAccent) private var accent
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(Theme.Fonts.icon(.xs))
                    .foregroundStyle(
                        selected ? AnyShapeStyle(Theme.accentGradient(accent))
                            : AnyShapeStyle(hovered ? Theme.textSecondary : Theme.textTertiary)
                    )
                Text(title)
                    .font(Theme.Fonts.label)
                    .foregroundStyle(
                        selected ? Theme.textPrimary
                            : hovered ? Theme.textSecondary : Theme.textTertiary
                    )
            }
            .padding(.horizontal, Theme.Space.wingInset)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule()
                        .fill(accent.opacity(0.14))
                        .overlay(Capsule().strokeBorder(accent.opacity(0.22), lineWidth: 1))
                        .matchedGeometryEffect(id: "tabPill", in: namespace)
                } else if hovered {
                    Capsule()
                        .fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
    }
}
