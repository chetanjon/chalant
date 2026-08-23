import Foundation

/// Self-corrections, repaired deterministically: what the speaker withdrew
/// goes, what they replaced it with stays.
///
/// Measured before it was written (EVAL-LOG 2026-08-22, "does the model
/// repair speech?", Set F recorded): of 19 self-corrections the ASR heard,
/// the deterministic passes repaired none and the on-device model repaired
/// four, three of which its own guard then rejected, at 0.68 s a call. The
/// repairs the model did make were all one grammar, written down here
/// first (prompt 7, task 1) and ruled on by the founder before any code.
///
/// ## Where it runs
///
/// BEFORE `Fillers` (ruling 3): `Fillers` strips "I mean", and "Tell Sarah,
/// I mean, tell Sara" needs it as a PHRASE marker. Fillers' noise (um, uh,
/// erm, uhh, umm, hmm, mmm, ah) is transparent to this pass: skipped when
/// matching LEFT, the marker and RIGHT, and removed with whatever cut it
/// sits inside. An "I mean" that fires on nothing is left for `Fillers` as
/// today. Before `Restatement` too, so a restart this pass repairs leaves a
/// clean pair for the prefix rule below. Like every Core pass: pure,
/// whole-transcript, and "anything ambiguous ships verbatim" (Part 0 §0.16).
///
/// ## Markers
///
/// `no`, `no wait`, `no no`, `sorry`, `I mean`, `scratch that`, `wait`,
/// `actually`, `make that`, `rather`. `wait` on its own (ruling 1) is a
/// VALUE-only marker and only with punctuation on both sides of it
/// (`3, wait, 2.5`); in a chain it merges like any other, and `wait for
/// Aidan` has no right-hand value and never fires. Matched case-insensitively, with any
/// punctuation the ASR attaches to their tokens (`No,` `no.` `Sorry,`
/// `wait.`) and with a comma or period tolerated inside a two-word marker
/// (`no, wait` `no, no.`). Adjacent markers merge into one (`wait. No,`
/// `actually, no,` `actually, make that`), so a chain of hedges counts
/// once. A period or question mark the ASR put directly before the marker
/// (`153. No wait, 135` `Chetan? No, ask Aidan`) does not end the
/// sentence for the pass: that boundary is the ASR's, not the speaker's.
///
/// ## Three shapes, and a marker fires on exactly one of them
///
/// **VALUE.** `LEFT marker RIGHT`, where LEFT is the last value token before
/// the marker and RIGHT the first value token after it, and both are the
/// same shape: a number (any token with a digit: 153, 315, $1200, 2.5,
/// 21st, 125), a day or month name, a capitalised word that does not open
/// its sentence (a name), or a pronoun (his, her, hers, him, their, them,
/// theirs, my, mine, our, your, yours; ruling 2), pronoun pairing only
/// with pronoun. The echo rule: RIGHT may repeat one word from either side
/// of LEFT, the word before it (`on Thursday. No, on Friday`, `the 20th.
/// Sorry, the 21st`) or the word after it (`her access, sorry, his
/// access`), or an article. Result: LEFT, its echoed neighbour and the
/// marker go; RIGHT and its echo stay. `Tuesday, no Wednesday` →
/// `Wednesday`; `$120 sorry $1200` → `$1200`; `930. No, 1015` → `1015`;
/// `her access, sorry, his access` → `his access`; `Monday, no Tuesday,
/// actually, make that Thursday` → `Thursday` (two firings, left to right).
///
/// **PHRASE.** `marker` followed by a restart: the tokens after the marker
/// begin with the first one or more tokens of the current clause (the
/// text since the previous sentence end, the ASR's boundary directly
/// before the marker excepted), compared without case or punctuation; one
/// repeated token is enough. Result: the clause from its first token to
/// the marker goes; the restart stays. `Ask Chetan? No, ask Aidan to
/// review` → `Ask Aidan to review`; `Email Journa, Journa Lagada. No,
/// email Chetan` → `Email Chetan`; `Ship version 125. No, wait. Ship 126
/// to the Kizo group` → `Ship 126 to the Kizo group`; `Tell Sarah, I
/// mean, tell Sara, that` → `Tell Sara, that`.
///
/// **CLAUSE.** `scratch that` alone: the current clause from its first
/// token to the marker goes; what follows stays. `The deploy to
/// production, scratch that, the deploy to staging finished` → `The deploy
/// to staging finished`; `Cancel the subscription today. Scratch that.
/// Keep the subscription` → `Keep the subscription`.
///
/// ## When a marker does not fire
///
/// Only when both sides of one shape exist in the same sentence (the
/// tolerated ASR boundary aside). So: a sentence-initial `No,` with no
/// left value (`No, I don't think so`), `actually` as a plain adverb (`We
/// actually shipped it`: nothing on the right is a value and nothing
/// restarts the clause), `sorry` with nothing to replace (`Sorry, I missed
/// that`), `no` as a determiner (`Send 15, no more`: "more" is not a
/// number; `there is no time`), `wait` as a verb (`wait for Aidan`), and
/// `I mean` as an aside between commas (already `Fillers`' business) all
/// ship as said. A VALUE pair of different shapes (`Monday, no 15`) does
/// not fire. The first word after a CLAUSE or PHRASE cut is capitalised
/// when the cut reached the start of the sentence.
///
/// ## What it will not repair, by design
///
/// A restart that does not repeat the clause's opening (`Deploy it to
/// production, wait. No, do not deploy it until Sarah signs off`: the
/// restart begins "do not", the clause began "Deploy"), a value whose echo
/// is two words (`999 a month. Make that 1999 a month`), a value that is
/// only part of what was withdrawn (`Chetan at Gmail. No, Jonalagada 8800
/// at gmail.com`: VALUE replaces one token, so the repair is partial), and
/// any marker outside the list (`hang on`, `okay`). Those ship verbatim,
/// or partially repaired; the numbers say how often. (A whole sentence
/// restated after a marker IS a PHRASE restart: `We are raising the price.
/// Actually, no, we are not raising the price` → the restated sentence.)
///
/// ## Restatement's new rule, beside the old one
///
/// `Restatement` keeps collapsing a whole sentence said twice (first copy
/// kept). It gains a prefix restart: when a run of at least two tokens
/// occurs twice in one sentence (the ASR's boundary tolerated only when
/// the first copy ended its sentence and the speaker started over), the
/// second occurrence within two tokens of the first run's end (ruled at
/// four, tightened the same day: see `Restatement.maximumGap`), and the
/// two continue differently, everything from the first occurrence up to
/// the second goes and the LATER run stays. `Priya, and Sarah, Priya, and
/// Aidan on the deploy` → `Priya, and Aidan on the deploy`; `I can't make
/// it. I, okay, I can't make it on Friday` → `I can't make it on Friday`;
/// `My email, my email is` → `my email is`; `Tell Sarah tell Sarah, that`
/// → `tell Sarah, that`. A single repeated token is `Disfluency`'s and
/// stays there.
public enum Repair {
    public static func repairing(_ text: String) -> String {
        repair(text).text
    }

    /// What fired, for the measurement tools: each edit's shape and the
    /// tokens it removed, in order.
    public struct Fired: Sendable, Equatable {
        public let shape: String
        public let removed: String
    }

    public static func trace(_ text: String) -> [Fired] {
        repair(text).fired
    }

    private static func repair(_ text: String) -> (text: String, fired: [Fired]) {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 3 else { return (text, []) }
        var rounds = 0
        var fired: [Fired] = []
        while rounds < 12, let edit = firstRepair(in: tokens) {
            fired.append(Fired(shape: edit.shape, removed: tokens[edit.remove].joined(separator: " ")))
            tokens = applying(edit, to: tokens)
            rounds += 1
        }
        // Byte-identical input when there was nothing to do.
        return (fired.isEmpty ? text : tokens.joined(separator: " "), fired)
    }

    // MARK: - The markers

    private static let markers: [[String]] = [
        ["no", "wait"], ["no", "no"], ["i", "mean"], ["scratch", "that"], ["make", "that"],
        ["no"], ["sorry"], ["wait"], ["actually"], ["rather"],
    ]

    private static let noise: Set<String> = ["uh", "um", "erm", "uhh", "umm", "hmm", "mmm", "ah"]
    private static let articles: Set<String> = ["the", "a", "an"]
    private static let days: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
    ]
    private static let pronouns: Set<String> = [
        "his", "her", "hers", "him", "their", "them", "theirs", "my", "mine", "our", "your", "yours",
    ]

    /// A merged run of markers: `[start, end)` in token indices.
    private struct Marker {
        let start: Int
        let end: Int
        let words: [String]
        var containsScratch: Bool { words.contains("scratch") }
        var isBareWait: Bool { words == ["wait"] }
    }

    private struct Edit {
        let remove: Range<Int>
        let capitalizeAfter: Bool
        let shape: String
    }

    private enum Shape { case number, day, month, name, pronoun }

    // MARK: - Finding work

    private static func firstRepair(in tokens: [String]) -> Edit? {
        var i = 0
        while i < tokens.count {
            guard let marker = marker(at: i, in: tokens) else {
                i += 1
                continue
            }
            if marker.containsScratch, let edit = clause(for: marker, in: tokens) { return edit }
            if let edit = value(for: marker, in: tokens) { return edit }
            if !marker.isBareWait, let edit = phrase(for: marker, in: tokens) { return edit }
            i = marker.end
        }
        return nil
    }

    /// The marker starting at `index`, merged with any markers that follow
    /// it directly, or nil. Fillers between are transparent.
    private static func marker(at index: Int, in tokens: [String]) -> Marker? {
        guard let first = single(at: index, in: tokens) else { return nil }
        var merged = first
        while let next = nextContent(after: merged.end - 1, in: tokens), let more = single(at: next, in: tokens) {
            merged = Marker(start: merged.start, end: more.end, words: merged.words + more.words)
        }
        return merged
    }

    private static func single(at index: Int, in tokens: [String]) -> Marker? {
        guard index < tokens.count, !isFiller(tokens[index]) else { return nil }
        for candidate in markers {
            guard let second = candidate.count == 2 ? candidate[1] : nil else {
                if word(tokens[index]) == candidate[0] { return Marker(start: index, end: index + 1, words: candidate) }
                continue
            }
            guard word(tokens[index]) == candidate[0], let next = nextContent(after: index, in: tokens),
                  word(tokens[next]) == second else { continue }
            return Marker(start: index, end: next + 1, words: candidate)
        }
        return nil
    }

    // MARK: - The three shapes

    private static func clause(for marker: Marker, in tokens: [String]) -> Edit? {
        guard let start = clauseStart(before: marker, in: tokens), start < marker.start,
              nextContent(after: marker.end - 1, in: tokens) != nil else { return nil }
        return Edit(remove: start..<marker.end, capitalizeAfter: opensSentence(start, in: tokens), shape: "CLAUSE")
    }

    private static func value(for marker: Marker, in tokens: [String]) -> Edit? {
        guard let before = previousContent(before: marker.start, in: tokens) else { return nil }
        var left = before
        var echoAfter: Int?
        if shape(of: tokens[left], at: left, in: tokens) == nil {
            // The echoed word after LEFT ("her ACCESS, sorry, his access").
            guard let earlier = previousContent(before: before, in: tokens),
                  shape(of: tokens[earlier], at: earlier, in: tokens) != nil else { return nil }
            echoAfter = before
            left = earlier
        }
        guard let leftShape = shape(of: tokens[left], at: left, in: tokens) else { return nil }
        if marker.isBareWait {
            guard punctuated(between: left, and: marker.start, in: tokens),
                  punctuated(between: marker.end - 1, and: marker.end, in: tokens) else { return nil }
        }
        guard var right = nextContent(after: marker.end - 1, in: tokens) else { return nil }
        // Everything from LEFT up to the first kept token goes, fillers
        // inside included. The first kept token is RIGHT, or an article in
        // front of it that echoes nothing.
        var firstKept = right
        let wordBeforeLeft = previousContent(before: left, in: tokens).map { word(tokens[$0]) }
        if shape(of: tokens[right], at: right, in: tokens) == nil {
            let candidate = word(tokens[right])
            guard articles.contains(candidate) || candidate == wordBeforeLeft,
                  let further = nextContent(after: right, in: tokens) else { return nil }
            if candidate == wordBeforeLeft { firstKept = further }
            right = further
        }
        guard shape(of: tokens[right], at: right, in: tokens) == leftShape else { return nil }
        if let echoAfter {
            guard let following = nextContent(after: right, in: tokens),
                  word(tokens[following]) == word(tokens[echoAfter]) else { return nil }
        }
        return Edit(remove: left..<firstKept, capitalizeAfter: opensSentence(left, in: tokens), shape: "VALUE")
    }

    private static func phrase(for marker: Marker, in tokens: [String]) -> Edit? {
        guard let start = clauseStart(before: marker, in: tokens), start < marker.start,
              let restart = nextContent(after: marker.end - 1, in: tokens),
              !isFiller(tokens[start]), word(tokens[start]) == word(tokens[restart]),
              !word(tokens[start]).isEmpty else { return nil }
        return Edit(remove: start..<marker.end, capitalizeAfter: opensSentence(start, in: tokens), shape: "PHRASE")
    }

    // MARK: - Sentences and tokens

    /// The first token of the clause the marker interrupts: after the last
    /// sentence end before the marker, the ASR's boundary on the token
    /// directly before the marker excepted.
    private static func clauseStart(before marker: Marker, in tokens: [String]) -> Int? {
        guard let before = previousContent(before: marker.start, in: tokens) else { return nil }
        var index = before - 1
        while index >= 0 {
            if endsSentence(tokens[index]) { return index + 1 }
            index -= 1
        }
        return 0
    }

    private static func opensSentence(_ index: Int, in tokens: [String]) -> Bool {
        index == 0 || endsSentence(tokens[index - 1])
    }

    private static func shape(of token: String, at index: Int, in tokens: [String]) -> Shape? {
        let core = core(of: token)
        guard !core.isEmpty else { return nil }
        if core.contains(where: \.isNumber) { return .number }
        let lowered = core.lowercased()
        if days.contains(lowered) { return .day }
        if months.contains(lowered) { return .month }
        if pronouns.contains(lowered) { return .pronoun }
        guard let first = core.first, first.isUppercase, core.count > 1, !token.contains("'"),
              !token.contains("\u{2019}"), !opensSentence(index, in: tokens) else { return nil }
        return .name
    }

    private static func applying(_ edit: Edit, to tokens: [String]) -> [String] {
        var out = tokens
        out.removeSubrange(edit.remove)
        let next = edit.remove.lowerBound
        if edit.capitalizeAfter, next < out.count, let first = out[next].first, first.isLowercase {
            out[next] = String(first).uppercased() + out[next].dropFirst()
        }
        return out
    }

    private static func nextContent(after index: Int, in tokens: [String]) -> Int? {
        var i = index + 1
        while i < tokens.count {
            if !isFiller(tokens[i]) { return i }
            i += 1
        }
        return nil
    }

    private static func previousContent(before index: Int, in tokens: [String]) -> Int? {
        var i = index - 1
        while i >= 0 {
            if !isFiller(tokens[i]) { return i }
            i -= 1
        }
        return nil
    }

    /// Punctuation the ASR put between two neighbouring tokens: trailing
    /// on the first or leading on the second.
    private static func punctuated(between a: Int, and b: Int, in tokens: [String]) -> Bool {
        guard a >= 0, b < tokens.count else { return false }
        if let last = tokens[a].last, last.isPunctuation { return true }
        if let first = tokens[b].first, first.isPunctuation { return true }
        return false
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    private static func isFiller(_ token: String) -> Bool {
        noise.contains(word(token))
    }

    /// Letters only, lowercased: the comparable form for markers and restarts.
    private static func word(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The token without its outer punctuation ("$1200." keeps "$1200").
    private static func core(of token: String) -> String {
        var chars = Array(token)
        while let first = chars.first, !(first.isLetter || first.isNumber || first == "$") { chars.removeFirst() }
        while let last = chars.last, !(last.isLetter || last.isNumber) { chars.removeLast() }
        return String(chars)
    }
}
