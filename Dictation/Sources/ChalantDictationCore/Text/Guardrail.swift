import Foundation

/// Refuses output that is not transcription.
///
/// **Part 0 §0.18** asks for a post-ASR guardrail stage regardless of engine,
/// because fabricated-text-on-silence is a failure class every decoder shares:
/// *"discard or flag segments that fall inside VAD-silence spans, sit below the
/// confidence floor, or are suspiciously repetitive."*
///
/// **Observed 2026-08-15**, from a real utterance the founder spoke in Telugu
/// while the engine was pinned to `en-US`:
///
/// ```
/// Renik, Nisalu, Cheppali, Krutik, niki, Nisal, Chepp, ,, ,, ,, ,, ,, , , , ...
/// ```
///
/// Seven words and **forty-one commas**, from 135 buffers of audio, with a mean
/// confidence of 0.253 where ordinary English on the same machine runs 0.5 to
/// 0.99. The words are wrong because the locale is wrong, which is a different
/// problem. The comma run is not wrong, it is *not text*, and pasting it into
/// somebody's document makes a working app look broken.
///
/// **This trims, it never discards.** Part 1 §2: every failure path returns the
/// input unchanged and the user's words survive. Removing a trailing run of
/// bare punctuation cannot lose a word, because there are no words in it.
public enum Guardrail {

    /// Punctuation that can legitimately end an utterance on its own.
    private static let terminal: Set<Character> = [".", "?", "!"]

    /// True when a token carries no letters or digits at all.
    private static func isBarePunctuation(_ token: Substring) -> Bool {
        !token.isEmpty && !token.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// Strip a trailing run of punctuation-only tokens.
    ///
    /// One trailing mark is kept, because "Hello." and "What?" are ordinary and
    /// a guardrail that eats real punctuation is worse than the bug it fixes.
    /// Everything after the first is a run, and a run is the failure.
    public static func trimmingPunctuationRun(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !tokens.isEmpty else { return text }

        var end = tokens.count
        while end > 0, isBarePunctuation(tokens[end - 1]) { end -= 1 }

        // Nothing trailing, or only one mark: leave it exactly as it came.
        guard tokens.count - end > 1 else { return text }

        var kept = Array(tokens[0..<end])
        // If the utterance ended on a real sentence mark, keep that one.
        if end < tokens.count, let first = tokens[end].first, terminal.contains(first) {
            kept.append(tokens[end])
        }
        return kept.joined(separator: " ")
    }

    /// Whether an utterance looks like noise rather than speech.
    ///
    /// Reported rather than acted on: the caller decides, because Part 1 §2
    /// means nothing here may silently drop what somebody said. A caller that
    /// wants to warn, log, or ask can; one that wants to insert anyway may.
    public static func looksDegenerate(_ text: String, punctuationShare: Double = 0.5) -> Bool {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 4 else { return false }
        let bare = tokens.filter(isBarePunctuation).count
        return Double(bare) / Double(tokens.count) > punctuationShare
    }
}
