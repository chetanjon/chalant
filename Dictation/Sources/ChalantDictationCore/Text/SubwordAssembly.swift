import Foundation

/// Sub-word pieces into words, keeping the confidence the vocabulary layer
/// runs on.
///
/// **This is `TokenAssembly`'s problem again, one engine along.** Apple hands
/// back attributed runs and `TokenAssembly` turns them into words. A
/// SentencePiece model hands back pieces (`" ch"`, `"al"`, `"an"`) and this
/// turns those into words. Both exist for the same reason, written down at
/// `TokenAssembly.swift:5`: the app once flattened the engine's output to a
/// plain string and split on spaces, every `Token` arrived with
/// `confidence == nil`, and the entire vocabulary layer was wired to a signal
/// being deleted one line earlier.
///
/// It matters more here, because the engine's own helper throws the signal
/// away. FluidAudio returns a confidence on every sub-word piece and its
/// `buildWordTimings(from:)` discards it, keeping only the word and its
/// times. Using that helper would have reproduced the 2026-08-15 bug exactly.
///
/// Pure, Foundation only, and the aggregation is a parameter rather than a
/// preference: which of `minimum`, `maximum` and `mean` best separates the
/// engine's wrong words from its right ones is a fact about the engine, to be
/// measured on the corpus, not argued about here.
public enum SubwordAssembly {

    /// One piece as the engine gives it, marker and all.
    public struct Piece: Sendable, Hashable {
        /// The raw piece. A leading space, or a `▁`, is the engine saying
        /// "a new word starts here".
        public let text: String
        public let confidence: Double?
        public let start: TimeInterval?
        public let end: TimeInterval?

        public init(
            text: String, confidence: Double? = nil, start: TimeInterval? = nil,
            end: TimeInterval? = nil
        ) {
            self.text = text
            self.confidence = confidence
            self.start = start
            self.end = end
        }
    }

    /// How a word's confidence is read off its pieces.
    ///
    /// Not a style choice. Measured on the founder's own Set E, the pieces of
    /// a misheard name and a correct one overlap under one rule and separate
    /// under another:
    ///
    /// ```
    /// "chalan"   ch 0.575  al 0.871  an 0.711     wrong (Chalant)
    /// "Kizu"     K  0.527  iz 0.895  u  0.937     right
    /// "Atram"    At 0.697  ram 0.999              wrong (Aatram)
    /// "release"  r  1.000  ele 1.000  ase 1.000   right
    /// ```
    ///
    /// `minimum` is the sensitive reading and `maximum` the conservative one,
    /// and `Kizu` is exactly why neither is obviously correct. The corpus
    /// decides; `tools/engineprobe` sweeps it.
    public enum Aggregation: String, Sendable, CaseIterable {
        case minimum
        case maximum
        case mean
    }

    /// The marker SentencePiece uses for a word boundary. FluidAudio
    /// normalises it to a plain space before it reaches us, but a decoder
    /// that stops doing that must not silently glue every word together, so
    /// both are honoured.
    public static let boundaryMarker: Character = "\u{2581}"

    public static func tokens(
        from pieces: [Piece], aggregation: Aggregation = .minimum
    ) -> [Token] {
        var out: [Token] = []
        var text = ""
        var confidences: [Double] = []
        var start: TimeInterval?
        var end: TimeInterval?

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                text = ""
                confidences = []
                start = nil
                end = nil
                return
            }
            out.append(
                Token(
                    text: trimmed, confidence: combine(confidences, by: aggregation),
                    range: range(start, end)))
            text = ""
            confidences = []
            start = nil
            end = nil
        }

        for piece in pieces {
            let raw = piece.text
            guard !raw.isEmpty else { continue }
            let opensWord = raw.first == " " || raw.first == boundaryMarker
            if opensWord { flush() }

            var body = raw
            if opensWord { body.removeFirst() }
            // A piece can carry an inner space ("a b") when the decoder
            // emits two words in one step. Split on it rather than producing
            // a token with a space inside, which nothing downstream expects.
            let parts = body.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            for (index, part) in parts.enumerated() {
                if index > 0 { flush() }
                text += part
            }

            if let confidence = piece.confidence { confidences.append(confidence) }
            start = [start, piece.start].compactMap { $0 }.min()
            end = [end, piece.end].compactMap { $0 }.max()
        }
        flush()
        return out
    }

    static func combine(_ values: [Double], by aggregation: Aggregation) -> Double? {
        guard !values.isEmpty else { return nil }
        switch aggregation {
        case .minimum: return values.min()
        case .maximum: return values.max()
        case .mean: return values.reduce(0, +) / Double(values.count)
        }
    }

    /// Same rule `TokenAssembly` uses: nil unless both ends exist and the
    /// range is not reversed, because a reversed `ClosedRange` traps at
    /// runtime, mid-transcription, on the user's machine.
    static func range(_ start: TimeInterval?, _ end: TimeInterval?) -> ClosedRange<TimeInterval>? {
        guard let start, let end, start <= end else { return nil }
        return start...end
    }
}
