import SwiftUI

/// The content tabs with their sliding pill. The pill's namespace
/// lives here — nothing outside the row matches against it.
struct TabRow: View {
    @ObservedObject var model: NotchViewModel
    @Namespace private var ns

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            pill("Do", .ask)
            pill("Go", .links)
            pill("Clips", .clipboard)
            pill("Shelf", .shelf)
            Spacer()
        }
    }

    private static let order: [NotchViewModel.Tab] = [.ask, .links, .clipboard, .shelf]

    private func pill(_ title: String, _ tab: NotchViewModel.Tab) -> some View {
        TabPill(title: title, selected: model.tab == tab, namespace: ns) {
            let from = Self.order.firstIndex(of: model.tab) ?? 0
            let to = Self.order.firstIndex(of: tab) ?? 0
            model.tabSlideDirection = to >= from ? 1 : -1
            withAnimation(Theme.Motion.content) {
                model.tab = tab
            }
        }
    }
}

/// One tab in the sliding-pill row. Inactive tabs answer hover with
/// a tint lift and a ghost of the pill.
struct TabPill: View {
    let title: String
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.label)
                .foregroundStyle(
                    selected ? Theme.textPrimary
                        : hovered ? Theme.textSecondary : Theme.textTertiary
                )
                .padding(.horizontal, Theme.Space.wingInset)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
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
