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
        let restarted = collapsingPrefixRestarts(text)
        let sentences = sentencesOf(restarted)
        guard sentences.count > 1 else { return restarted }
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
        return dropped ? kept.joined(separator: " ") : restarted
    }

    // MARK: - Prefix restarts

    /// The later run of a restart stays (founder's ruling, 2026-08-22).
    ///
    /// A run of at least `minimumRun` tokens said twice, the second copy
    /// starting within `maximumGap` tokens of the first run's end, and the
    /// two continuing differently: everything from the first copy up to
    /// the second goes. "Priya, and Sarah, Priya, and Aidan on the deploy"
    /// keeps "Priya, and Aidan on the deploy"; "I can't make it. I, okay, I
    /// can't make it on Friday" keeps "I can't make it on Friday". The ASR's
    /// own sentence boundary inside the gap is tolerated, which is how the
    /// false start "I can't make it." survives into the second copy. Exact
    /// whole-sentence repeats continue identically and are left to the
    /// rule above (first copy kept); a single repeated token is
    /// `Disfluency`'s and stays there.
    private static let conjunctions: Set<String> = ["and", "or", "but", "nor", "if", "when", "then", "so", "because"]
    static let minimumRun = 2
    /// Ruled at four (2026-08-22), tightened to two the same day: every
    /// Set F restart has a gap of two tokens or fewer ("Sarah,", "I,
    /// okay,", "153, no,"), and four let "day by day it gets better, and
    /// day by day we ship" collapse to its second half.
    static let maximumGap = 2

    static func collapsingPrefixRestarts(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var changed = false
        var rounds = 0
        while rounds < 12, let cut = firstRestart(in: tokens) {
            let opensSentence = cut.lowerBound == 0 || endsSentence(tokens[cut.lowerBound - 1])
            tokens.removeSubrange(cut)
            if opensSentence, cut.lowerBound < tokens.count, let first = tokens[cut.lowerBound].first, first.isLowercase {
                tokens[cut.lowerBound] = String(first).uppercased() + tokens[cut.lowerBound].dropFirst()
            }
            changed = true
            rounds += 1
        }
        return changed ? tokens.joined(separator: " ") : text
    }

    private static func firstRestart(in tokens: [String]) -> Range<Int>? {
        let words = tokens.map(bare)
        guard words.count >= 2 * minimumRun else { return nil }
        for start in 0..<(words.count - minimumRun) {
            guard !words[start].isEmpty else { continue }
            let firstOpens = start == 0 || endsSentence(tokens[start - 1])
            var best: Range<Int>?
            var length = minimumRun
            while start + 2 * length <= words.count {
                defer { length += 1 }
                let run = Array(words[start..<(start + length)])
                guard run.allSatisfy({ !$0.isEmpty }) else { break }
                var second: Int?
                var candidate = start + length
                while candidate + length <= words.count, candidate - (start + length) <= maximumGap {
                    if Array(words[candidate..<(candidate + length)]) == run { second = candidate; break }
                    candidate += 1
                }
                guard let second else { continue }
                // Both copies in one sentence, or the first copy ended its
                // sentence and the speaker started over ("I can't make it.
                // I, okay, I can't make it on Friday"). Two sentences that
                // merely open alike ("Then we tell everyone. Then we rest")
                // and a phrase that recurs across sentences ("the bank. I
                // should visit the bank") are not restarts.
                let crossesBoundary = tokens[start..<second].contains(where: endsSentence)
                guard !crossesBoundary || (firstOpens && endsSentence(tokens[start + length - 1])) else { continue }
                // The whole stretch said twice back to back, with nothing
                // after, is a repeat and not a restart ("I need to go to the
                // bank I need to go to the bank"): Part 0 §0.16, the
                // ambiguous ships verbatim. (A sub-run of such a phrase
                // matches with a gap made of the phrase's own tail, so the
                // test is on the stretch, not the run.)
                let stretch = second - start
                let tail = Array(words[second...].prefix(stretch))
                let tailEnds = second + tail.count == words.count || endsSentence(tokens[second + tail.count - 1])
                if tailEnds, tail == Array(words[start..<(start + tail.count)]) {
                    continue
                }
                // An exact twin sentence belongs to the whole-sentence rule
                // ("No, no. No, no." stays, "We need the data." twice keeps
                // the first), whatever prefix of it recurs.
                let secondOpens = endsSentence(tokens[second - 1])
                if firstOpens, secondOpens, sentenceWords(from: start, in: words, tokens) == sentenceWords(from: second, in: words, tokens) {
                    continue
                }
                // Tightened on the founder's real rows (2026-08-22, 391 of
                // them): a restart is a stumble, and the gap between the
                // copies is the abandoned fragment. Coordination is not a
                // restart ("local or can be hybrid", "turn it on and turn it
                // off", "he was sad, and he called"): no conjunction in the
                // gap. The second copy follows a comma or follows the first
                // directly ("I don't, I don't", "Look at this, look at"). A
                // run that recurs a third time within the same window is a
                // list ("in terms of effects, in terms of sound, in terms of
                // music"), not a restart.
                let gap = Array(words[(start + length)..<second])
                if gap.contains(where: { conjunctions.contains($0) }) { continue }
                // A run that opens with a conjunction is coordination too
                // ("an entrepreneur and a businessman, and a designer").
                if conjunctions.contains(run[0]) { continue }
                if second > start + length, !tokens[second - 1].hasSuffix(",") { continue }
                // A third copy within the window, before the pair or after
                // it, makes a list.
                var isList = false
                var third = second + length
                while third + length <= words.count, third - (second + length) <= maximumGap {
                    if Array(words[third..<(third + length)]) == run { isList = true; break }
                    third += 1
                }
                var earlier = start - length
                while earlier >= 0, start - (earlier + length) <= maximumGap {
                    if Array(words[earlier..<(earlier + length)]) == run { isList = true; break }
                    earlier -= 1
                }
                if isList { continue }
                best = start..<second
            }
            if let best { return best }
        }
        return nil
    }

    private static func sentenceWords(from index: Int, in words: [String], _ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = index
        while i < tokens.count {
            out.append(words[i])
            if endsSentence(tokens[i]) { break }
            i += 1
        }
        return out
    }

    private static func bare(_ token: String) -> String {
        String(token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return last == "." || last == "?" || last == "!"
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
