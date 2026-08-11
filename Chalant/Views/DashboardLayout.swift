import SwiftUI
import UniformTypeIdentifiers

/// Rearranging what the island shows.
///
/// Drag rather than a `List` with `.onMove`: the dashboard's detail is
/// already a ScrollView, and a List inside one fights it for scrolling.
/// This was labelled "coming soon" for a day because dragging a row
/// moved the whole dashboard window instead of reordering. The gesture
/// was never the problem: the window was set movable by its background,
/// so AppKit began a window drag on mouse-down anywhere that was not a
/// control and pre-empted the row's own gesture. Fixed where it lived,
/// in `DashboardWindowController` (2026-08-02).
///
/// `draggable`/`dropDestination` gives the same gesture on an ordinary
/// stack, and it is the platform's own drag, not a reimplementation.
struct LayoutSection: View {
    @ObservedObject var layout: IslandLayoutStore

    var body: some View {
        // Same five cards, same order, as `islandArrangement` and
        // `collapsedOrder` render them below: "Beside the notch" sits
        // between "Not shown" and "Presets" today, so it cannot be
        // reproduced by placing the two builders end to end. This reads
        // from the same card properties they're built from, not a copy.
        VStack(alignment: .leading, spacing: Theme.Space.settingsGroup) {
            inTheIsland
            notShown
            collapsedOrder
            presets
            startOver
        }
    }

    // MARK: Island arrangement

    /// What's on the island, what's held back, saved presets, and the
    /// reset. Grouped as one unit so a later task can lift it onto its
    /// own settings page without touching the row/drag machinery below.
    @ViewBuilder
    var islandArrangement: some View {
        inTheIsland
        notShown
        presets
        startOver
    }

    /// The "beside the notch" precedence card, alone: a later task moves
    /// it to a different page than `islandArrangement`.
    @ViewBuilder
    var collapsedOrder: some View {
        SettingCard(title: "Beside the notch") {
            ForEach(Array(layout.layout.collapsed.enumerated()), id: \.element.id) {
                index, item in
                if index > 0 { SettingDivider() }
                collapsedRow(item, at: index)
            }
            SettingNote(
                "Only one of these fits beside a shut island, so this is an order of "
                + "precedence: the first with something to say gets the space."
            )
        }
    }

    @ViewBuilder
    private var inTheIsland: some View {
        SettingCard(title: "In the island") {
            ForEach(Array(layout.layout.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { SettingDivider() }
                rowEditor(row, at: index)
            }
            SettingNote("Drag a row to move it. Top of the list is top of the island.")
        }
    }

    @ViewBuilder
    private var notShown: some View {
        if !hidden.isEmpty {
            SettingCard(title: "Not shown") {
                ForEach(hidden) { element in
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: element.symbol)
                            .font(Theme.Fonts.icon(.s))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 18)
                        Text(element.title)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: Theme.Space.m)
                        Button("Add") { add(element) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var startOver: some View {
        SettingCard(title: "Start over") {
            Button("Reset the arrangement") { layout.reset() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            SettingNote("Puts every element back where Chalant ships it.")
        }
    }

    // MARK: Rows

    private func rowEditor(_ row: IslandRow, at index: Int) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "line.3.horizontal")
                .font(Theme.Fonts.icon(.s))
                .foregroundStyle(Theme.textGhost)
                .frame(width: 14)
                .accessibilityHidden(true)
            ForEach(row.elements) { element in
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: element.symbol)
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(Theme.textSecondary)
                    Text(element.title)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.m)
            // Required elements move but cannot leave: without the tools
            // and the input there is no way to use the island at all.
            if row.elements.allSatisfy({ !$0.isRequired }) {
                Button {
                    remove(row)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(Theme.Fonts.icon(.s))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(PressableStyle())
                .help("Take \(row.elements.map(\.title).joined(separator: " and ")) out")
            } else {
                Text("Always shown")
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(Theme.textGhost)
            }
        }
        .contentShape(Rectangle())
        .draggable(row.elements.first?.rawValue ?? "") {
            // The drag preview, or macOS renders the whole row width.
            Label(row.elements.first?.title ?? "", systemImage: row.elements.first?.symbol ?? "square")
                .font(Theme.Fonts.body)
                .padding(Theme.Space.m)
                .background(Theme.surface)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let moved = IslandElement(rawValue: raw) else { return false }
            move(moved, above: index)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.elements.map(\.title).joined(separator: " and ")), row \(index + 1)")
    }

    /// One glance in the precedence order. Same drag as the rows above,
    /// with its rank shown: "first with something to say" is a rule the
    /// list has to make visible, or the order looks arbitrary.
    private func collapsedRow(_ item: CollapsedItem, at index: Int) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "line.3.horizontal")
                .font(Theme.Fonts.icon(.s))
                .foregroundStyle(Theme.textGhost)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("\(index + 1)")
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14, alignment: .trailing)
            Text(item.title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.m)
        }
        .contentShape(Rectangle())
        .draggable(item.rawValue) {
            Text(item.title)
                .font(Theme.Fonts.body)
                .padding(Theme.Space.m)
                .background(Theme.surface)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let moved = CollapsedItem(rawValue: raw)
            else { return false }
            layout.apply(layout.layout.movingCollapsed(moved, to: index))
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), priority \(index + 1)")
    }

    // MARK: Presets

    private var presets: some View {
        SettingCard(title: "Presets") {
            ForEach(Array(layout.presets.enumerated()), id: \.element.id) { index, preset in
                if index > 0 { SettingDivider() }
                HStack(spacing: Theme.Space.m) {
                    Text(preset.name)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Theme.Space.m)
                    Button("Save") { layout.capture(into: index) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Store the arrangement you have now into \(preset.name)")
                    Button("Use") { layout.recall(index) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Put \(preset.name)'s arrangement back on the island")
                }
            }
            SettingNote("Save keeps what the island looks like now. Use puts it back.")
        }
    }

    // MARK: Edits

    private var hidden: [IslandElement] {
        let placed = Set(layout.layout.placed)
        // `.sessions` moved into its own tab (B1) and is never placeable
        // here again, so it has no business showing up as an "Add" offer.
        return IslandElement.allCases.filter { $0 != .sessions && !placed.contains($0) }
    }

    private func move(_ element: IslandElement, above index: Int) {
        layout.apply(layout.layout.moving(element, to: index))
    }

    private func remove(_ row: IslandRow) {
        var next = layout.layout
        next.rows.removeAll { $0.id == row.id }
        layout.apply(next)
    }

    private func add(_ element: IslandElement) {
        var next = layout.layout
        // Above the chrome: a content row appended after the switcher
        // and the input would land under the panel, which is not a
        // place anything can be seen.
        let chrome = next.rows.firstIndex { $0.elements.contains { $0.isRequired } }
        next.rows.insert(IslandRow([element]), at: chrome ?? next.rows.count)
        layout.apply(next)
    }
}
