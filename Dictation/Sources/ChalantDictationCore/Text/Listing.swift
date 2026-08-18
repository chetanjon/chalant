import Foundation

/// A spoken list, made into a list without the model.
///
/// "Refined at once" (spec 2026-08-17, late): the words that land the moment
/// the key comes up should already be shaped, and the commonest shape the
/// founder dictates is an enumeration ("three things: first… second… third",
/// "number one… number two…", "bullet point…"). The model can do this too, but
/// a list is one long chunk and costs it over a second; this is free.
///
/// Deliberately narrow, like every deterministic pass here (Part 0 §0.16):
/// explicit cues only, three or more of them for ordinals and "number N",
/// two or more for "bullet point", in ascending order, each starting a real
/// item, and never an ordinal that is just an adjective ("the first draft").
/// Anything less ships as prose; the model may still make a list of it later.
public enum Listing {

    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    /// An ordinal after one of these is describing a noun, not starting an item.
    private static let determiners: Set<String> = ["the", "a", "an", "my", "our", "your", "his", "her", "their", "its", "this", "that", "at", "in", "on"]

    private enum Kind { case ordinal, numbered, bullet }

    public static func format(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 4 else { return text }
        for kind in [Kind.bullet, .numbered, .ordinal] {
            if let formatted = format(tokens, as: kind) { return formatted }
        }
        return text
    }

    /// (index of the cue's first token, how many tokens the cue spans, its rank)
    private static func cues(in tokens: [String], as kind: Kind) -> [(at: Int, span: Int, rank: Int)] {
        var found: [(at: Int, span: Int, rank: Int)] = []
        var i = 0
        while i < tokens.count {
            let word = bare(tokens[i])
            switch kind {
            case .ordinal:
                if let rank = ordinals.firstIndex(of: word) {
                    let previous = i > 0 ? bare(tokens[i - 1]) : ""
                    if !determiners.contains(previous) { found.append((i, 1, rank)) }
                }
            case .numbered:
                if word == "number", i + 1 < tokens.count, let rank = numbers.firstIndex(of: bare(tokens[i + 1])) {
                    found.append((i, 2, rank)); i += 1
                }
            case .bullet:
                if word == "bullet", i + 1 < tokens.count, bare(tokens[i + 1]).hasPrefix("point") {
                    found.append((i, 2, found.count)); i += 1
                }
            }
            i += 1
        }
        return found
    }

    private static func format(_ tokens: [String], as kind: Kind) -> String? {
        let cues = cues(in: tokens, as: kind)
        let minimum = kind == .bullet ? 2 : 3
        guard cues.count >= minimum else { return nil }
        // Ascending, starting at the first rank: "first… second… third", not
        // "third… first…" and not a stray "second" on its own.
        for (n, cue) in cues.enumerated() where cue.rank != n { return nil }

        var items: [String] = []
        for (n, cue) in cues.enumerated() {
            let start = cue.at + cue.span
            let end = n + 1 < cues.count ? cues[n + 1].at : tokens.count
            guard start < end else { return nil }
            let item = clean(Array(tokens[start..<end]))
            guard !item.isEmpty else { return nil }
            items.append(item)
        }

        var lines: [String] = []
        let lead = clean(Array(tokens[0..<cues[0].at]), trailing: true)
        if !lead.isEmpty { lines.append(lead + ":") }
        for (n, item) in items.enumerated() {
            lines.append(kind == .numbered ? "\(n + 1). \(item)" : "- \(item)")
        }
        return lines.joined(separator: "\n")
    }

    /// Words joined, leading punctuation the engine left after a cue removed,
    /// first letter capitalised; a lead-in also loses its trailing punctuation
    /// so it can take a colon.
    private static func clean(_ tokens: [String], trailing: Bool = false) -> String {
        var s = tokens.joined(separator: " ")
        while let f = s.first, f.isPunctuation || f.isWhitespace { s.removeFirst() }
        if trailing { while let l = s.last, l.isPunctuation || l.isWhitespace { s.removeLast() } }
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }

    private static func bare(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
