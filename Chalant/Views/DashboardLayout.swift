import SwiftUI
import UniformTypeIdentifiers

/// Rearranging what the island shows.
///
/// Drag rather than a `List` with `.onMove`: the dashboard's detail is
/// already a ScrollView, and a List inside one fights it for scrolling.
/// `draggable`/`dropDestination` gives the same gesture on an ordinary
/// stack, and it is the platform's own drag, not a reimplementation.
struct LayoutSection: View {
    @ObservedObject var layout: IslandLayoutStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SettingCard(title: "In the island") {
                ForEach(Array(layout.layout.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingDivider() }
                    rowEditor(row, at: index)
                }
                SettingNote("Drag a row to move it. Top of the list is top of the island.")
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

            presets

            SettingCard(title: "Start over") {
                Button("Reset the arrangement") { layout.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                SettingNote("Puts every element back where Chalant ships it.")
            }
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
        return IslandElement.allCases.filter { !placed.contains($0) }
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
