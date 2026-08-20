import Foundation

/// A thought said twice lands once.
///
/// The founder, 2026-08-20: "if I'm talking the same thing again, it's
/// giving me exactly the same thing. It's not refining at all." The model's
/// prompt already collapses rephrasings, but it can only see one ~40-word
/// chunk at a time, so a sentence repeated across chunks always survives;
/// and when the words land raw, no model runs at all. This pass is
/// deterministic and runs on every path.
///
/// Part 0 §0.16 keeps it narrow on purpose: only a sentence that is EXACTLY
/// a sentence already said, once case, punctuation and whitespace are set
/// aside, and only sentences of three or more words. A rephrasing is the
/// model's judgment call, never this pass's; "Yes. Yes." is emphasis and
/// stays. The first occurrence keeps its place; later copies go.
public enum Restatement {

    public static func collapsing(_ text: String) -> String {
        let sentences = sentencesOf(text)
        guard sentences.count > 1 else { return text }
        var seen = Set<String>()
        var kept: [String] = []
        var dropped = false
        for sentence in sentences {
            let key = normalized(sentence)
            if key.split(separator: " ").count >= 3, seen.contains(key) {
                dropped = true
                continue
            }
            seen.insert(key)
            kept.append(sentence)
        }
        // Byte-identical input when there was nothing to do, so a clean
        // paragraph is never reshaped by a pass with no work.
        return dropped ? kept.joined(separator: " ") : text
    }

    private static func normalized(_ sentence: String) -> String {
        let letters = String(sentence.lowercased().map {
            $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " "
        })
        return letters.split(separator: " ").joined(separator: " ")
    }

    /// Sentences, each keeping its own terminator: `.`, `?` or `!` followed
    /// by whitespace ends one, so a decimal point inside a number does not.
    /// The same rule `CleanupPrompt` chunks by, so the two agree on what a
    /// sentence is.
    private static func sentencesOf(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        for (index, ch) in chars.enumerated() {
            current.append(ch)
            let ends = ch == "." || ch == "?" || ch == "!"
            let followedByGap = index + 1 == chars.count || chars[index + 1].isWhitespace
            if ends && followedByGap {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { sentences.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}
