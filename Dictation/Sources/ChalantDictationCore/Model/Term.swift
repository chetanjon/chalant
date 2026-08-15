import Foundation

/// A word the user says that generic dictation gets wrong: a name, a product,
/// an identifier. The store holds every term ever learned; `BiasSelector`
/// decides which ~100 of them are live for a given utterance (Part 0 §0.13).
public struct Term: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The spelling the user wants to see.
    public var text: String
    /// How often it has been used, for recency and frequency scoring.
    public var useCount: Int
    /// Last time it was used, so `BiasSelector` can decay stale terms.
    /// Always supplied by a `Clock`, never `Date()` (Part 2 §3).
    public var lastUsed: Date?
    /// Set by the user by hand rather than learned from a correction.
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        useCount: Int = 0,
        lastUsed: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.text = text
        self.useCount = useCount
        self.lastUsed = lastUsed
        self.isPinned = isPinned
    }
}

/// A term selected for one utterance, carrying the weight the selector gave it.
///
/// Part 0 §0.1 is unresolved here on purpose: whether this reaches the engine
/// as native `contextualStrings` (path A, `DictationTranscriber`) or is applied
/// after the fact by term-list rescoring (path B, `SpeechTranscriber`) is M2's
/// deciding experiment. The seam carries the terms either way.
public struct BiasTerm: Sendable, Hashable {
    public let text: String
    /// Contextual bias weight. `cbw` is a locked constant of 4.5 (Part 0 §0.13).
    public let weight: Double

    public init(text: String, weight: Double) {
        self.text = text
        self.weight = weight
    }
}

/// An observed pair of "what the engine heard" against "what the user meant",
/// learned by watching corrections (M5, the moat).
public struct Confusion: Sendable, Hashable {
    public let heard: String
    public let meant: String
    /// Substitution does not fire below 2 (Part 3 M5).
    public var count: Int
    public var lastSeen: Date?

    public init(heard: String, meant: String, count: Int = 1, lastSeen: Date? = nil) {
        self.heard = heard
        self.meant = meant
        self.count = count
        self.lastSeen = lastSeen
    }
}
