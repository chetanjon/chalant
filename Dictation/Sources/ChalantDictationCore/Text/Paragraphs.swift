import Foundation

/// "New paragraph" and "new line", said out loud and obeyed, without a model.
///
/// **They only ever worked in a mode nobody is in.** The instruction has been
/// in `CleanupPrompt.instructionsPlain` since the cleanup pass was written, so
/// the words are obeyed when the on-device model rewrites the sentence. The
/// default mode is `shadow`, where the model's answer goes to the corpus file
/// and never to the page, so on a default install saying "new paragraph"
/// typed the words "new paragraph" into the document. That is the wrong shape
/// of failure for a dictation command: it is not a nicety that degrades, it is
/// an instruction that lands as text.
///
/// So it is a rule. Deterministic, on every path, in every mode, whether or
/// not any model runs.
///
/// **Narrow on purpose, like every pass here (Part 0 §0.16: anything
/// ambiguous ships verbatim).** The cue fires only where the speaker's own
/// punctuation shows it stood alone: at the very start, or after a full stop,
/// question mark, exclamation, comma, colon or semicolon. That single rule is
/// what protects the sentences people actually say about text:
///
/// ```
/// "add a new line to the file"          "a" carries no punctuation, so no fire
/// "start another new paragraph here"    same
/// "we need a brand new line of shoes"   same
/// "Done. New paragraph. Next up..."     fires
/// "and that is settled, new line"       fires
/// ```
///
/// The same reasoning `Fillers` applies to "like": a discourse marker is only
/// a marker when the speaker's punctuation says so, and removing it by word
/// identity alone breaks real sentences.
public enum Paragraphs {

    /// What a cue becomes.
    private enum Break: String {
        case line = "\n"
        case paragraph = "\n\n"
    }

    /// Punctuation after which a cue is standing on its own.
    private static let opensACue: Set<Character> = [".", "?", "!", ",", ":", ";"]

    public static func applying(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return text }

        var out: [String] = []
        var index = 0
        var fired = false

        while index < tokens.count {
            if let width = cueWidth(at: index, in: tokens, after: out.last) {
                fired = true
                // The cue's own trailing punctuation goes with it: the
                // transcriber writes "New paragraph." and the full stop
                // belongs to the command, not to the sentence after it.
                out.append(marker(at: index, in: tokens))
                index += width
                continue
            }
            out.append(tokens[index])
            index += 1
        }
        guard fired else { return text }
        return assemble(out)
    }

    /// How many tokens the cue spans at `index`, or nil when there is no cue
    /// there or it is not standing alone.
    private static func cueWidth(at index: Int, in tokens: [String], after previous: String?) -> Int? {
        guard bare(tokens[index]) == "new", index + 1 < tokens.count else { return nil }
        let second = bare(tokens[index + 1])
        guard second == "line" || second == "paragraph" else { return nil }
        if previous == nil {
            // **At the very start the punctuation has to be on the cue
            // itself.** Nothing precedes it to prove it stood alone, and
            // "New line items are up" is a real sentence: without this, the
            // opening words of a dictation would be eaten whenever they
            // happened to be these two. "New paragraph." with the
            // transcriber's own full stop is the signal.
            guard closesAClause(tokens[index + 1]) else { return nil }
        } else {
            guard standsAlone(after: previous) else { return nil }
        }
        return 2
    }

    /// Whether the cue carries its own terminator.
    private static func closesAClause(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return opensACue.contains(last)
    }

    private static func marker(at index: Int, in tokens: [String]) -> String {
        let kind: Break = bare(tokens[index + 1]) == "line" ? .line : .paragraph
        return marker(kind)
    }

    /// A sentinel rather than the break itself, so `assemble` can join with
    /// single spaces without having to reason about which gaps are real.
    private static func marker(_ kind: Break) -> String {
        kind == .line ? Self.lineSentinel : Self.paragraphSentinel
    }
    private static let lineSentinel = "\u{0}L"
    private static let paragraphSentinel = "\u{0}P"

    /// Whether a cue at this position was spoken as a command rather than as
    /// part of a sentence.
    ///
    /// Nil `previous` is the start of the text, which is the one place a cue
    /// needs no punctuation to prove itself: nothing precedes it to be part of.
    private static func standsAlone(after previous: String?) -> Bool {
        guard let previous else { return true }
        if previous == lineSentinel || previous == paragraphSentinel { return true }
        guard let last = previous.last else { return false }
        return opensACue.contains(last)
    }

    /// Rejoin, turning sentinels into real breaks and leaving no space beside
    /// them, no run of blank lines, and nothing dangling at either end.
    private static func assemble(_ tokens: [String]) -> String {
        var out = ""
        for token in tokens {
            if token == lineSentinel || token == paragraphSentinel {
                // Trim whatever space the previous word left, so a break never
                // carries trailing whitespace into the document.
                while out.last == " " { out.removeLast() }
                // Two cues in a row are one break, taking the wider of them.
                let wanted = token == paragraphSentinel ? "\n\n" : "\n"
                while out.hasSuffix("\n") { out.removeLast() }
                out += wanted
                continue
            }
            if !out.isEmpty, !out.hasSuffix("\n") { out += " " }
            out += token
        }
        // A cue at either end is a break into nothing.
        while out.hasSuffix("\n") || out.hasSuffix(" ") { out.removeLast() }
        while out.hasPrefix("\n") || out.hasPrefix(" ") { out.removeFirst() }
        return out
    }

    private static func bare(_ token: String) -> String {
        String(token.filter { $0.isLetter || $0.isNumber }).lowercased()
    }
}
