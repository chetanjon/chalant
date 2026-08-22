import Foundation

/// The comma before a contrastive "not": "153 not 135" reads as "153, not
/// 135".
///
/// Why it exists (2026-08-22, EVAL-LOG "what does the model buy?"): across
/// 90 scripted rows the on-device model moved exactly one Set C row closer
/// to the truth, C14, and the whole edit was this comma. A pass that costs
/// nothing can make it.
///
/// Why it is narrow on purpose: Part 0 §0.16, "anything ambiguous ships
/// verbatim". The comma goes in only when "not" sits between two VALUE
/// tokens: a number (any token with a digit: 153, $9.99, 3:15, 21st), a
/// number word, a capitalised word that does not open its sentence (a
/// name), or a possessive pronoun; the right-hand value may follow "the",
/// "a" or "an". Ordinary negation never qualifies, because a verb, an
/// auxiliary, a pronoun or an adverb is never a value: "I do not", "I'm not
/// sure", "not really", "15 not counting Sarah" all ship as said. Measured
/// before wiring (same entry): dry-run over the 387 real dictation rows in
/// the founder's corpus.
public enum Contrast {
    public static func commaBeforeNot(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 3 else { return text }
        var i = 1
        while i < tokens.count - 1 {
            defer { i += 1 }
            guard tokens[i] == "not" else { continue }
            let previous = tokens[i - 1]
            guard !endsWithPunctuation(previous) else { continue }
            let previousOpensSentence = i - 1 == 0 || endsSentence(tokens[i - 2])
            guard isValue(previous, opensSentence: previousOpensSentence) else { continue }
            var right = i + 1
            if articles.contains(bare(tokens[right]).lowercased()), right + 1 < tokens.count {
                right += 1
            }
            guard isValue(tokens[right], opensSentence: false) else { continue }
            tokens[i - 1] = previous + ","
        }
        return tokens.joined(separator: " ")
    }

    private static let articles: Set<String> = ["the", "a", "an"]
    private static let possessives: Set<String> = ["hers", "his", "mine", "yours", "theirs", "ours"]
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion",
    ]

    /// A token that names a value rather than saying something about one.
    static func isValue(_ token: String, opensSentence: Bool) -> Bool {
        let core = bare(token)
        guard !core.isEmpty else { return false }
        if core.contains(where: \.isNumber) { return true }
        let lowered = core.lowercased()
        if numberWords.contains(lowered) || possessives.contains(lowered) { return true }
        guard let first = core.first, first.isUppercase, core.count > 1, !opensSentence else { return false }
        // A capitalised word mid-sentence is a name. "I" is excluded above by
        // length; "I'm" and the like by the apostrophe test here.
        return !token.contains("'") && !token.contains("\u{2019}")
    }

    private static func bare(_ token: String) -> String {
        token.filter { $0.isLetter || $0.isNumber }
    }

    private static func endsWithPunctuation(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return last.isPunctuation
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return last == "." || last == "?" || last == "!" || last == "\n"
    }
}
