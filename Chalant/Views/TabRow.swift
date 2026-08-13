import SwiftUI

/// The lower-panel switcher: Today (when your day is turned on) plus
/// whichever tools you keep, and the settings gear. It reads by
/// brightness now, not by pills: the active tool's icon is white, the
/// rest sit faint until the cursor lifts one. A name never left the
/// row, it just moved into the tooltip, where a sweep of the cursor
/// still turns up every label without a single word sitting on screen
/// at rest.
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
            // No track under these any more: brightness alone tells
            // the active tool from the rest, so the row reads as a
            // single switcher without needing a shared background to
            // say so. Nothing is hidden by this: with a soundscape row
            // directly above wearing chips of the same size and colour,
            // twelve small symbols stacked in two rows had nothing to
            // say which were navigation and which were controls (user,
            // relaying "too much to see").
            HStack(spacing: Theme.Space.xxl) {
                if todayEnabled {
                    SwitcherItem(tab: .today, model: model)
                }
                ForEach(tools, id: \.self) { tab in
                    SwitcherItem(tab: tab, model: model)
                }
            }
            Spacer(minLength: 0)
            // Voice's one visible door (VoiceDoor), and it is here for
            // the reason the note below gives about the full-height
            // button: this app has spent long enough hiding answers in
            // gestures nobody goes looking for. Between 2026-08-02 and
            // now it hid voice itself in one, and the first outside
            // download reported the app as having no dictation at all.
            //
            // Not the media row, where H1 removed it from and where it
            // never belonged. Not the ask bar either, which draws only
            // on one tab: this row is required in every layout
            // (`IslandElement.isRequired`), so the mic is on screen
            // wherever the island opens. Always drawn, unlike the
            // button below: a control appears only when it can act, and
            // voice can always act.
            HoverGlyphButton(
                symbol: "mic.fill", label: "Speak, or hold the island",
                scale: .m, tint: Theme.textTertiary
            ) {
                model.toggleListening()
            }
            // The door into the full-height island, and only on the
            // destinations that have one. A visible button rather than
            // a second meaning loaded onto a tab you already tapped:
            // this app has spent long enough hiding answers in tooltips
            // and gestures nobody goes looking for.
            if model.tab.canFocus {
                HoverGlyphButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    label: "Open full", scale: .m, tint: Theme.textTertiary
                ) {
                    withAnimation(Theme.Motion.content) { model.focus(on: model.tab) }
                }
            }
            // A new version announces itself once, in a glance that
            // lives eight seconds. Miss it and nothing on screen said
            // so any more: the button that installs it sits in the
            // settings footer, and you would have to go looking on a
            // hunch. This app's own owner sat on an old build that way
            // while a newer one was out. The mark keeps the news
            // standing without adding a surface or nagging: it is the
            // gear already there, wearing a dot until you have looked.
            HoverGlyphButton(
                symbol: "gearshape", label: "Settings", scale: .m, tint: Theme.textGhost
            ) {
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
        // A terminal, not angle brackets. These are agents running in
        // terminals; `</>` says "code", which is what they work on
        // rather than what they are.
        case .sessions: return "apple.terminal"
        case .battery: return "battery.100"
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
        case .battery: return "Battery"
        }
    }
}

/// One switcher glyph, icon only. No pill, no label at rest: the
/// active tab is the one drawn white, and the rest sit faint until
/// hovered a shade brighter. The name never disappeared, it just moved
/// off the canvas and into `.help`, so a sweep across the row with the
/// cursor still turns up every one of them.
///
/// Every name at once needs about 780pt and the island is 518, which
/// is why these were glyphs to begin with. Reading the row by
/// brightness instead of by a pill or a revealed word means the eye
/// never has to wait for a hover to know which tool is active.
private struct SwitcherItem: View {
    let tab: NotchViewModel.Tab
    @ObservedObject var model: NotchViewModel
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
            // The pour: a tab change moves the shell, so it rides the island's own curve.
            withAnimation(Theme.Motion.island) { model.tab = tab }
        } label: {
            // Thin, not semibold: the row's finish reads by brightness,
            // never by bulk. `weight: .regular` at this scale is
            // `Theme.Fonts.iconThin(.m)`, reached through GlyphImage's
            // own scale/weight pair since it takes no raw `Font`.
            GlyphImage(symbol: Switcher.symbol(tab), scale: .m, weight: .regular)
                .foregroundStyle(
                    on ? Theme.textPrimary
                        : hovered ? Theme.textSecondary : Theme.textGhost
                )
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        .help(Switcher.label(tab))
    }
}
