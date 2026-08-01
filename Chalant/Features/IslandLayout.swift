import Foundation

/// A thing the island can show, as a unit the user can move.
///
/// Raw values are the storage format and are never renamed: a layout
/// saved by an older build has to keep meaning the same thing.
enum IslandElement: String, Codable, CaseIterable, Identifiable, Sendable {
    case media
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
        case .switcher: return "square.grid.2x2"
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
    /// What the resting island shows, in the order it gets the space.
    var collapsed: [IslandElement]

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
            IslandRow([.sessions]),
            IslandRow([.ambience]),
            IslandRow([.switcher]),
            IslandRow([.input]),
        ],
        collapsed: [.media, .sessions, .activities]
    )

    var placed: [IslandElement] { rows.flatMap(\.elements) }

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
                .filter { seen.insert($0).inserted }
                .prefix(IslandRow.maxColumns)
            if !unique.isEmpty { fixedRows.append(IslandRow(Array(unique))) }
        }
        let known = Set(knownElements)
        for element in IslandElement.allCases where !seen.contains(element) {
            // Required, or new since this layout was written. An
            // optional element the user deliberately removed is known
            // and absent, and stays that way.
            guard element.isRequired || !known.contains(element) else { continue }
            fixedRows.append(IslandRow([element]))
            seen.insert(element)
        }
        let collapsedFixed = collapsed.reduce(into: [IslandElement]()) { result, element in
            if !result.contains(element) { result.append(element) }
        }
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
