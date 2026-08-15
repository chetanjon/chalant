import Foundation

/// Turns a stream of `TranscriptEvent` into text, honouring the one contract
/// that streaming ASR gets wrong more than any other.
///
/// Part 1 §3, banned pattern #1: volatile results are provisional and get
/// **replaced**; finalized results **append** and are immutable. Treating a
/// volatile result as final produces the classic duplication bug, where
/// "hello" then "hello there" becomes "hello hello there".
///
/// Pure and `Sendable` by construction: Part 2 §2 requires every text
/// transformation to be testable without a Mac in any particular state, and
/// Part 1 §2 requires the same. This type knows only Foundation.
public struct TranscriptAssembler: Sendable, Equatable {
    /// Committed words. Immutable once appended, and the only thing Part 0
    /// §0.5 permits insertion to fire on.
    public private(set) var finalized: [Token]

    /// The current provisional span. Replaced wholesale by the next volatile
    /// event and cleared by the next finalized one.
    public private(set) var uncommitted: [Token]

    public init() {
        self.finalized = []
        self.uncommitted = []
    }

    /// True when a provisional span is outstanding. Part 1 §2 forbids losing
    /// the user's text, so a caller ending a session while this is true has
    /// something to recover rather than discard.
    public var hasUncommittedSpan: Bool { !uncommitted.isEmpty }

    /// What may be inserted. Finalized words only.
    public var finalizedText: String { Self.join(finalized) }

    /// What the live readout shows while the user is still speaking:
    /// everything committed, plus the provisional span once.
    public var displayText: String { Self.join(finalized + uncommitted) }

    /// Apply one event from the engine.
    public mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let tokens):
            // Replace. Never append: that is the bug this type exists to stop.
            uncommitted = tokens

        case .finalized(let tokens):
            // Append, and drop the provisional span the engine has now
            // superseded. The finalized event carries the authoritative
            // wording for the span it covers, so keeping both would duplicate.
            finalized.append(contentsOf: tokens)
            uncommitted = []
        }
    }

    /// Return to birth, for the next utterance.
    public mutating func reset() {
        finalized = []
        uncommitted = []
    }

    private static func join(_ tokens: [Token]) -> String {
        tokens.map(\.text).joined(separator: " ")
    }
}
