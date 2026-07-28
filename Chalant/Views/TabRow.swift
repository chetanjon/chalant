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
            // The tools sit on one quiet track, so the row reads as a
            // single switcher rather than as a scatter of loose glyphs.
            // Nothing is hidden by this: with a soundscape row directly
            // above wearing chips of the same size and colour, twelve
            // small symbols stacked in two rows had nothing to say
            // which were navigation and which were controls (user,
            // relaying "too much to see").
            HStack(spacing: Theme.Space.xs) {
                if todayEnabled {
                    SwitcherItem(tab: .today, model: model)
                }
                ForEach(tools, id: \.self) { tab in
                    SwitcherItem(tab: tab, model: model)
                }
            }
            .padding(.horizontal, Theme.Space.xs)
            .background(Capsule().fill(Theme.surface))
            Spacer(minLength: 0)
            HoverGlyphButton(symbol: "gearshape", scale: .m, tint: Theme.textTertiary) {
                withAnimation(Theme.Motion.content) { model.pane = .settings }
            }
        }
        .animation(Theme.Motion.content, value: model.tab)
    }

    static func symbol(_ tab: NotchViewModel.Tab) -> String {
        switch tab {
        case .today: return "calendar"
        case .ask: return "chalant.mark"
        case .links: return "square.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray.full"
        case .notes: return "note.text"
        case .focus: return "timer"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    static func label(_ tab: NotchViewModel.Tab) -> String {
        switch tab {
        case .today: return "Today"
        case .ask: return "Answer"
        case .links: return "Shortcuts"
        case .clipboard: return "Clipboard"
        case .shelf: return "Shelf"
        case .notes: return "Notes"
        case .focus: return "Focus"
        case .chat: return "Chat"
        }
    }
}

/// One switcher pill. Only the active tab wears its name; the rest
/// are quiet glyphs that lift on hover and answer with a tooltip, so
/// six tools sit comfortably where three used to.
private struct SwitcherItem: View {
    let tab: NotchViewModel.Tab
    @ObservedObject var model: NotchViewModel
    @Environment(\.chalantAccent) private var accent
    @State private var hovered = false

    var body: some View {
        let on = model.tab == tab
        Button {
            withAnimation(Theme.Motion.content) { model.tab = tab }
        } label: {
            HStack(spacing: Theme.Space.snug) {
                // A size up and a tier brighter than they were: the
                // tools read at a glance now (user call, 2026-07-22,
                // "looks too small").
                GlyphImage(symbol: Switcher.symbol(tab), scale: .m)
                if on {
                    Text(Switcher.label(tab))
                        .font(Theme.Fonts.bodyEmphasis)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(
                on ? Theme.textPrimary
                    : hovered ? Theme.textPrimary : Theme.textSecondary
            )
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 7)
            // The active tool wears a quiet wash of the accent, the
            // island's one habit of color inside the glass.
            .background(Capsule().fill(on ? accent.opacity(0.14) : Color.clear))
            .overlay(
                Capsule().strokeBorder(
                    on ? accent.opacity(0.22) : Color.clear, lineWidth: 1
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        .help(Switcher.label(tab))
    }
}
