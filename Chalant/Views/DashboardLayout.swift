import SwiftUI

/// Rearranging what the island shows.
///
/// Reordering by drag used to live here and does not right now: on this
/// window it dragged the whole dashboard rather than the row (D3,
/// founder 2026-08-02, "moving the entire dashboard window instead").
/// Add, remove and the presets below are unaffected and stay live; a
/// real drag surface is a later milestone (F1), on the island itself
/// rather than in a settings list.
struct LayoutSection: View {
    @ObservedObject var layout: IslandLayoutStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "In the island") {
                ForEach(Array(layout.layout.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingDivider() }
                    rowEditor(row, at: index)
                }
                // Dragging a row moved the whole dashboard window instead
                // of reordering (D3, founder 2026-08-02). Rather than ship
                // that, the drag is off and this says so; Add and the
                // remove button still work. The real fix is a later
                // milestone (F1: drag on the island itself).
                comingSoonNote
            }

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
                comingSoonNote
            }

            presets

            SettingCard(title: "Start over") {
                Button("Reset the arrangement") { layout.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                SettingNote("Puts every element back where Chalant ships it.")
            }
        }
    }

    /// Drag-to-reorder is disabled everywhere on this page (D3); one
    /// line, reused rather than retyped at each card it applies to.
    private var comingSoonNote: some View {
        SettingNote("Reordering by drag is coming soon. Add, remove and the presets below still work.")
    }

    // MARK: Rows

    private func rowEditor(_ row: IslandRow, at index: Int) -> some View {
        HStack(spacing: Theme.Space.m) {
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
            // Required elements cannot leave: without the tools and the
            // input there is no way to use the island at all.
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.elements.map(\.title).joined(separator: " and ")), row \(index + 1)")
    }

    /// One glance in the precedence order, with its rank shown: "first
    /// with something to say" is a rule the list has to make visible, or
    /// the order looks arbitrary.
    private func collapsedRow(_ item: CollapsedItem, at index: Int) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text("\(index + 1)")
                .font(Theme.Fonts.microMono)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14, alignment: .trailing)
            Text(item.title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.m)
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
