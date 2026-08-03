import Foundation

/// A thing the island can show, as a unit the user can move.
///
/// Raw values are the storage format and are never renamed: a layout
/// saved by an older build has to keep meaning the same thing.
enum IslandElement: String, Codable, CaseIterable, Identifiable, Sendable {
    case media
    /// Moved into its own tab (B1, founder 2026-08-02: "add a tab to
    /// see a list of all the sessions running"). The case stays only so
    /// a layout saved before that migration still decodes; `repaired()`
    /// never places it as a row again, whatever a stored layout says.
    case sessions
    case activities
    case ambience
    case timers
    case switcher
    case input

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: return "Now playing"
        case .sessions: return "Agent sessions"
        case .activities: return "Activity"
        case .ambience: return "Ambience"
        case .timers: return "Focus and timers"
        case .switcher: return "Tools"
        case .input: return "Ask and answer"
        }
    }

    var symbol: String {
        switch self {
        case .media: return "music.note"
        case .sessions: return "chevron.left.forwardslash.chevron.right"
        case .activities: return "circle.dashed"
        case .ambience: return "waveform"
        case .timers: return "timer"
        // Not the Shortcuts tab's grid glyph: that one is a grid of
        // launchable tiles, this is the switcher itself, a toolbar.
        case .switcher: return "wrench.and.screwdriver"
        case .input: return "text.cursor"
        }
    }

    /// The island stops being the island without these, so they cannot
    /// be dragged out — only moved.
    var isRequired: Bool {
        switch self {
        case .switcher, .input: return true
        default: return false
        }
    }

    /// Elements that share a row well. Tall, self-sizing content wants
    /// the full width or it gets crushed against its neighbour.
    var fitsBesideAnother: Bool {
        switch self {
        case .ambience, .activities, .sessions: return true
        case .media, .timers, .switcher, .input: return false
        }
    }
}

/// What can take the space beside the notch when the island is shut.
///
/// Not `IslandElement`: these are not the island's contents, they are
/// glances. The list they come from is an order of precedence, since
/// only one of them fits at a time — an early attempt reused the
/// element enum and produced a setting for arranging things that could
/// never appear there.
enum CollapsedItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case agents
    case timers
    case event
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return "Agents running"
        case .timers: return "Focus and timers"
        case .event: return "Next event"
        case .battery: return "Battery"
        }
    }
}

/// One row of the island, holding one element or two side by side.
///
/// The island is a narrow surface — a free 2D grid would mostly produce
/// unusable half-width cells — so the grid is rows deep and at most two
/// columns wide, which is as much as 520 points can carry legibly.
struct IslandRow: Codable, Equatable, Identifiable, Sendable {
    var id: String { elements.map(\.rawValue).joined(separator: "+") }
    var elements: [IslandElement]

    init(_ elements: [IslandElement]) {
        self.elements = elements
    }

    static let maxColumns = 2
}

/// How one island is arranged.
struct IslandLayout: Codable, Equatable, Sendable {
    var rows: [IslandRow]
    /// What the resting island shows beside the notch, most important
    /// first. Only one fits, so this is a precedence order rather than
    /// a list of things that all appear.
    var collapsed: [CollapsedItem]

    /// Every element the build that saved this layout could see.
    ///
    /// Without it there is no way to tell "the user took this out" from
    /// "the build that wrote this had never heard of it" — both look
    /// like an absent element. An element missing from a layout but
    /// listed here was removed on purpose and stays out; one missing
    /// from both is new and gets added, so a feature shipped later is
    /// not invisible forever to everyone who already had a layout.
    var knownElements: [IslandElement] = IslandElement.allCases

    /// The arrangement the island has always shipped with.
    static let standard = IslandLayout(
        rows: [
            IslandRow([.timers]),
            IslandRow([.media]),
            IslandRow([.activities]),
            IslandRow([.ambience]),
            IslandRow([.switcher]),
            IslandRow([.input]),
        ],
        collapsed: [.agents, .timers, .event, .battery]
    )

    var placed: [IslandElement] { rows.flatMap(\.elements) }

    /// Moves the row holding `element` so it sits at `index`.
    func moving(_ element: IslandElement, to index: Int) -> IslandLayout {
        guard let from = rows.firstIndex(where: { $0.elements.contains(element) })
        else { return self }
        var moved = self
        moved.rows = rows.movingItem(at: from, to: index)
        return moved
    }

    /// Reorders which glance outranks which beside the notch.
    func movingCollapsed(_ item: CollapsedItem, to index: Int) -> IslandLayout {
        guard let from = collapsed.firstIndex(of: item) else { return self }
        var moved = self
        moved.collapsed = collapsed.movingItem(at: from, to: index)
        return moved
    }


    /// Repairs a layout so it is safe to render.
    ///
    /// A stored layout is written by one build and read by another, so
    /// it is assumed wrong until proven otherwise: an element can be
    /// duplicated by a bad drag, dropped by a rename, or simply not
    /// exist yet in the version that saved it.
    ///
    /// - a duplicate keeps only its first placement, so an element is
    ///   never rendered twice
    /// - a row longer than the column limit is truncated
    /// - a required element that went missing comes back, or the island
    ///   would have no way to be used
    /// - anything new since the layout was saved is appended rather
    ///   than silently invisible forever
    /// - empty rows are dropped
    func repaired() -> IslandLayout {
        var seen = Set<IslandElement>()
        var fixedRows: [IslandRow] = []
        for row in rows {
            let unique = row.elements
                // `.sessions` moved into its own tab (B1) and is never a
                // row again, even for a layout saved before that, which
                // may still list it here.
                .filter { $0 != .sessions && seen.insert($0).inserted }
                .prefix(IslandRow.maxColumns)
            if !unique.isEmpty { fixedRows.append(IslandRow(Array(unique))) }
        }
        let known = Set(knownElements)
        for element in IslandElement.allCases where element != .sessions && !seen.contains(element) {
            // Required, or new since this layout was written. An
            // optional element the user deliberately removed is known
            // and absent, and stays that way.
            guard element.isRequired || !known.contains(element) else { continue }
            fixedRows.append(IslandRow([element]))
            seen.insert(element)
        }
        var collapsedFixed = collapsed.reduce(into: [CollapsedItem]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
        // Anything this build knows about that the stored order does
        // not is appended, so a glance added later is reachable rather
        // than permanently last-and-invisible.
        collapsedFixed += CollapsedItem.allCases.filter { !collapsedFixed.contains($0) }
        return IslandLayout(
            rows: fixedRows,
            collapsed: collapsedFixed,
            knownElements: IslandElement.allCases
        )
    }
}

/// The island's arrangement, and the four presets beside it.
@MainActor
final class IslandLayoutStore: ObservableObject {
    private static let layoutKey = "islandLayout"
    private static let presetsKey = "islandPresets"

    /// Always repaired on the way in and on the way out, so nothing
    /// downstream has to wonder whether it can trust what it renders.
    @Published private(set) var layout: IslandLayout = .standard
    @Published private(set) var presets: [LayoutPreset] = LayoutPreset.defaults()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.layoutKey),
           let stored = try? JSONDecoder().decode(IslandLayout.self, from: data) {
            layout = stored.repaired()
        }
        if let data = defaults.data(forKey: Self.presetsKey),
           let stored = try? JSONDecoder().decode([LayoutPreset].self, from: data),
           stored.count == LayoutPreset.count {
            presets = stored.map {
                LayoutPreset(id: $0.id, name: $0.name, layout: $0.layout.repaired())
            }
        }
    }

    func apply(_ new: IslandLayout) {
        layout = new.repaired()
        defaults.set(try? JSONEncoder().encode(layout), forKey: Self.layoutKey)
    }

    /// Stores the arrangement on screen into one of the four slots.
    func capture(into slot: Int, named name: String? = nil) {
        guard presets.indices.contains(slot) else { return }
        presets[slot] = LayoutPreset(
            id: slot, name: name ?? presets[slot].name, layout: layout
        )
        defaults.set(try? JSONEncoder().encode(presets), forKey: Self.presetsKey)
    }

    func recall(_ slot: Int) {
        guard presets.indices.contains(slot) else { return }
        apply(presets[slot].layout)
    }

    func reset() {
        apply(.standard)
    }
}

/// Four saved arrangements the user can switch between.
struct LayoutPreset: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var name: String
    var layout: IslandLayout

    static let count = 4

    static func defaults() -> [LayoutPreset] {
        (0..<count).map {
            LayoutPreset(id: $0, name: "Preset \($0 + 1)", layout: .standard)
        }
    }
}

extension Array {
    /// Moves the item at `from` so it sits at `to`.
    ///
    /// The arithmetic is the whole of it: pulling the item out first
    /// shifts everything below it up by one, so a drop *below* the
    /// original position would otherwise land one place too far. Off by
    /// one here is invisible until you drag downward and the row stops
    /// in the wrong place — which is why both reorderable lists share
    /// this rather than each carrying its own copy of the bug.
    func movingItem(at from: Int, to index: Int) -> [Element] {
        guard indices.contains(from), from != index else { return self }
        var copy = self
        let item = copy.remove(at: from)
        let target = from < index ? index - 1 : index
        copy.insert(item, at: Swift.min(Swift.max(target, 0), copy.count))
        return copy
    }
}
