import SwiftUI

/// The lower-panel switcher: Today (when your day is turned on) plus
/// whichever tools you keep, and the settings gear. Every item wears its
/// name, so the features are findable at a glance, not guessed from an
/// icon.
struct Switcher: View {
    @ObservedObject var model: NotchViewModel
    /// Observed in its own right: a nested ObservableObject does not
    /// republish through its owner, so watching `model` alone would
    /// leave the mark below arriving only on the next unrelated redraw.
    @ObservedObject var updates: UpdateChecker
    let todayEnabled: Bool
    let tools: [NotchViewModel.Tab]
    @Environment(\.chalantAccent) private var accent

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
            // A new version announces itself once, in a glance that
            // lives eight seconds. Miss it and nothing on screen said
            // so any more: the button that installs it sits in the
            // settings footer, and you would have to go looking on a
            // hunch. This app's own owner sat on an old build that way
            // while a newer one was out. The mark keeps the news
            // standing without adding a surface or nagging: it is the
            // gear already there, wearing a dot until you have looked.
            HoverGlyphButton(symbol: "gearshape", scale: .m, tint: Theme.textTertiary) {
                // Settings is a window now, so the island gets out of
                // the way rather than sitting lit over the window that
                // just took focus.
                model.collapse()
                model.openDashboard?(nil)
            }
            .overlay(alignment: .topTrailing) {
                if let latest = updates.latest {
                    Circle()
                        .fill(accent)
                        .frame(width: 6, height: 6)
                        // Ringed in the island's own backdrop so the
                        // dot keeps a clean edge against the gear's
                        // teeth rather than merging with them.
                        .overlay(Circle().strokeBorder(Theme.backdropTop, lineWidth: 1.5))
                        // Onto the gear's shoulder, not floating off
                        // its corner: the button's padding puts plain
                        // topTrailing out in empty space, where it read
                        // as a stray pixel instead of a mark on this.
                        .offset(x: -2, y: 4)
                        .transition(.opacity)
                        .help("Chalant \(latest) is out")
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(Theme.Motion.content, value: model.tab)
        .animation(Theme.Motion.content, value: updates.latest)
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
        case .sessions: return "chevron.left.forwardslash.chevron.right"
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
        case .sessions: return "Sessions"
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
            // Which way the panel travels, decided before the change so
            // the direction and the tab land in the same transaction.
            // Moving right along the switcher brings the new panel in
            // from the right, so the motion agrees with the tap.
            let order = NotchViewModel.Tab.allCases
            let from = order.firstIndex(of: model.tab) ?? 0
            let to = order.firstIndex(of: tab) ?? 0
            model.tabSlideDirection = to >= from ? 1 : -1
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
