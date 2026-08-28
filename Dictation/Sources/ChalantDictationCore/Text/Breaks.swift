import Foundation

/// Turns the pause-commas of a long spoken run-on into the full stops the
/// speaker meant.
///
/// **Born 2026-08-28, 3 AM, from the founder's own flagged sentence:**
/// "Okay, I was sitting in the living room alone, working on Chalant, and
/// everybody was sleeping, and it was all calm and serene right now,
/// because it's 3 AM today, and today there is a festival." Thirty-six
/// words, six commas, not a full stop anywhere: the transcriber writes a
/// comma at every breath and never ends a sentence the voice did not end.
/// The model cannot fix this class either: whole, it cannot finish inside
/// any release window; in pieces, it echoes fragments (measured the same
/// night, EVAL-LOG). So the fix is a rule, and the rule is deliberately
/// narrow:
///
/// In a sentence LONGER than `CleanupPrompt.freshPieceWordCeiling` words,
/// ", and " / ", but " / ", so " followed by a word that opens a clause
/// (a subject pronoun or an everyday subject like "everybody") becomes a
/// full stop and a capital: "..., and everybody was sleeping" reads
/// "... And everybody was sleeping." Everything else stands:
/// "calm and serene" has no comma and is never touched; ", because" and
/// every other subordinate joint keeps its comma; short sentences keep
/// their spoken rhythm whole; and a sentence the speaker finished with
/// full stops of their own is already several short sentences and never
/// qualifies.
public enum Breaks {

    /// Coordinators that may carry a sentence break when a clause follows.
    private static let coordinators: Set<String> = ["and", "but", "so"]

    /// Words that begin a new clause after a coordinator. The pronoun core
    /// is shared with the boundary-comma rule in `Fillers` by measurement,
    /// not by import: both lists were read off the founder's real rows.
    private static let openers: Set<String> = [
        "i", "we", "you", "he", "she", "it", "they",
        "i'm", "i'll", "i've", "i'd", "we're", "we'll", "we've", "we'd",
        "you're", "you'll", "you've", "you'd", "he's", "he'll", "he'd",
        "she's", "she'll", "she'd", "it's", "it'll", "it'd",
        "they're", "they'll", "they've", "they'd", "there's", "there",
        "let's", "everybody", "everyone", "nobody", "somebody", "someone",
        "this", "that's", "today", "tomorrow", "yesterday", "now", "then",
    ]

    /// A sentence that OPENS subordinate ("While holding the button, ...",
    /// "But, if we're going off on a tangent, and we don't want...") is one
    /// long condition waiting for its main clause; a break in its middle
    /// orphans the condition. Found on the corpus dry-run (2026-08-28,
    /// cap-20260819-170457): two of fifteen changed rows were damaged, both
    /// in sentences opening this way, so they are excluded whole.
    private static let subordinators: Set<String> = [
        "if", "when", "while", "because", "since", "unless", "although",
        "though", "whenever", "until", "before", "after", "whether", "once",
    ]

    public static func sentencing(_ text: String) -> String {
        let sentences = split(text)
        guard !sentences.isEmpty else { return text }
        return sentences.map { sentence in
            sentence.split(whereSeparator: \.isWhitespace).count
                > CleanupPrompt.freshPieceWordCeiling
                && !opensSubordinate(sentence)
                ? breaking(sentence) : String(sentence)
        }.joined(separator: " ")
    }

    /// The sentence's first content word, read past a leading coordinator
    /// ("But, if we're going..." opens with "if" for this purpose).
    private static func opensSubordinate(_ sentence: Substring) -> Bool {
        let words = sentence.split(whereSeparator: \.isWhitespace).prefix(2)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        guard let first = words.first else { return false }
        if subordinators.contains(first) { return true }
        if coordinators.contains(first), words.count > 1 {
            return subordinators.contains(words[1])
        }
        return false
    }

    /// One long sentence, its qualifying ", and|but|so <opener>" joints
    /// turned into sentence ends. Pure text walking: the words are never
    /// reordered, added or removed; only ", and" becomes ". And".
    private static func breaking(_ sentence: Substring) -> String {
        var words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 2 else { return String(sentence) }
        for i in 0..<(words.count - 2) {
            let joint = words[i]
            guard joint.hasSuffix(","), !words[i + 1].isEmpty else { continue }
            let coordinator = words[i + 1].lowercased()
            guard coordinators.contains(coordinator) else { continue }
            let opener = words[i + 2].lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            guard openers.contains(opener) else { continue }
            words[i] = String(joint.dropLast()) + "."
            words[i + 1] = words[i + 1].prefix(1).uppercased() + words[i + 1].dropFirst()
        }
        return words.joined(separator: " ")
    }

    /// Sentences including their terminators, the same cheap walk the
    /// chunker uses: a terminator counts only when whitespace or the end
    /// follows it, so decimals stay whole.
    private static func split(_ text: String) -> [Substring] {
        var out: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            if ch == "." || ch == "?" || ch == "!",
               next == text.endIndex || text[next].isWhitespace {
                out.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex {
            let rest = text[start...]
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { out.append(rest) }
        }
        // Each piece sheds the space it inherited from the walk, so the
        // rejoin's single separator is the only space between sentences.
        return out.map { piece in
            var p = piece
            while let f = p.first, f.isWhitespace { p = p.dropFirst() }
            while let l = p.last, l.isWhitespace { p = p.dropLast() }
            return p
        }
    }
}
