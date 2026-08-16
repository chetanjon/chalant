import Foundation

/// Turns the engine's attributed runs into words that still know what the
/// engine thought of them.
///
/// **Why this type exists.** `SpeechTranscriber` reports an `AttributedString`
/// whose runs carry `transcriptionConfidence` and `audioTimeRange`. Until
/// 2026-08-15 the app flattened that to a plain `String` and split on spaces,
/// so every `Token` arrived with `confidence == nil`. `TermMatcher` reads nil
/// as "no evidence attached" and refuses to act on it, which meant the entire
/// vocabulary layer was wired to a signal that was being deleted one line
/// earlier. This is the line that stops deleting it.
///
/// **Runs are attribute spans, not words.** Nothing in the API says a run ends
/// on a space. A word may straddle two runs, and several words may share one.
/// Both are handled here rather than in the actor, because Part 1 §2 puts all
/// text transformation in pure functions that can be tested without a Mac in a
/// particular state.
public enum TokenAssembly {

    /// One attributed run, reduced to the three things Core is allowed to know
    /// about it. The shell converts `CMTimeRange` to seconds so that Core keeps
    /// importing only Foundation.
    public struct Run: Sendable, Equatable {
        public let text: String
        public let confidence: Double?
        public let start: TimeInterval?
        public let end: TimeInterval?

        public init(
            text: String, confidence: Double? = nil,
            start: TimeInterval? = nil, end: TimeInterval? = nil
        ) {
            self.text = text
            self.confidence = confidence
            self.start = start
            self.end = end
        }
    }

    public static func tokens(from runs: [Run]) -> [Token] {
        var out: [Token] = []
        var open: Partial?

        for run in runs where !run.text.isEmpty {
            let pieces = run.text.split(whereSeparator: \.isWhitespace)

            // A run of pure whitespace ends whatever word was in progress and
            // starts nothing.
            guard !pieces.isEmpty else {
                if let word = open?.token() { out.append(word) }
                open = nil
                continue
            }

            for (index, piece) in pieces.enumerated() {
                // Only the first piece can continue the previous word, and only
                // when no whitespace separates them.
                let continues =
                    index == 0 && !(run.text.first?.isWhitespace ?? false) && open != nil

                if continues {
                    open?.extend(with: String(piece), from: run)
                } else {
                    if let word = open?.token() { out.append(word) }
                    open = Partial(text: String(piece), from: run)
                }

                // Every piece but the last is followed by whitespace inside
                // this run, so it is finished.
                if index < pieces.count - 1 {
                    if let word = open?.token() { out.append(word) }
                    open = nil
                }
            }

            if run.text.last?.isWhitespace ?? false {
                if let word = open?.token() { out.append(word) }
                open = nil
            }
        }

        if let word = open?.token() { out.append(word) }
        return out
    }

    /// A word being built across one or more runs.
    private struct Partial {
        var text: String
        var confidence: Double?
        var start: TimeInterval?
        var end: TimeInterval?

        init(text: String, from run: Run) {
            self.text = text
            self.confidence = run.confidence
            self.start = run.start
            self.end = run.end
        }

        mutating func extend(with piece: String, from run: Run) {
            text += piece

            // **Deliberately the maximum, not the minimum or a mean.**
            // Confidence gates substitution: a word is only replaceable when
            // the engine was unsure. Taking the higher value over a split word
            // makes it look surer and therefore harder to overwrite, and an
            // ambiguous merge should resolve toward leaving the user's words
            // alone. `TermMatcher` exists to say no; this agrees with it.
            confidence = [confidence, run.confidence].compactMap { $0 }.max()

            start = [start, run.start].compactMap { $0 }.min()
            end = [end, run.end].compactMap { $0 }.max()
        }

        func token() -> Token? {
            guard !text.isEmpty else { return nil }
            return Token(text: text, confidence: confidence, range: range())
        }

        /// Nil unless both ends are present and ordered. A reversed range would
        /// trap `ClosedRange` at runtime, and a crash inside transcription
        /// costs the user the words they just spoke.
        private func range() -> ClosedRange<TimeInterval>? {
            guard let start, let end, start <= end else { return nil }
            return start...end
        }
    }
}
