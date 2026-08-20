import Foundation

/// Removes the words nobody meant to say.
///
/// **Part 0 §0.16 draws the line and it is not "remove every filler":**
/// obvious fillers go, but *"for discourse markers such as `like`, `you know`,
/// `basically`, `so`, `well`, do not remove solely by word identity. Use local
/// grammatical role or the language model classifier."* Anything ambiguous
/// ships verbatim, because deleting a word the speaker meant is a worse bug
/// than leaving one they did not.
///
/// **Measured on 418 words of the founder's real speech, 2026-08-15:** 19
/// fillers, and three cases where `like` was a real word that must survive.
///
/// ```
/// something like a name          real, keep
/// like post hog or 11 labs       real, means "such as", keep
/// Like, you know, use some...    filler
/// we are doing like, uh, ...     filler
/// ```
///
/// That is the whole rule for `like`: it is a filler only when a **comma
/// follows it**. Removing it by word identity would have broken two real
/// sentences out of four.
public enum Fillers {

    /// Never a real word in dictated English. Safe to remove anywhere.
    private static let noise: Set<String> = ["uh", "um", "erm", "uhh", "umm", "hmm", "mmm"]

    /// Discourse markers, removed only when the speaker's own punctuation
    /// shows they were an aside: comma before *and* after.
    ///
    /// This deliberately misses "it should, you know Remember that", which has
    /// no closing comma. Catching it would mean also catching "Do you know,
    /// Sarah?" and turning it into "Do Sarah?".
    private static let asides: [[String]] = [["you", "know"], ["i", "mean"]]

    public static func removing(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return text }

        var kept: [String] = []
        var i = 0
        while i < tokens.count {
            // `atStart` is about the OUTPUT, not the input, and about the
            // SENTENCE, not the text. Once "Like," is dropped, the aside behind
            // it has become the sentence's first words and must be judged as
            // such; so has anything following a full stop.
            if let width = asideWidth(
                at: i, in: tokens,
                precededByComma: endsWithComma(kept.last),
                atStart: kept.isEmpty || endsSentence(kept.last))
            {
                droppingPauseComma(&kept)
                i += width
                continue
            }
            let bare = strip(tokens[i])
            if noise.contains(bare) {
                droppingPauseComma(&kept)
                i += 1
                continue
            }
            // `like` is a filler when a comma follows it, or when the next
            // word is noise ("Like uh, the local one"). Not otherwise: bare
            // `like` is a real preposition, as in "something like a name" and
            // "like post hog or 11 labs", and removing those breaks the
            // sentence. The filler's own comma leaves with the filler, which
            // is why nothing is inherited here.
            let nextIsNoise = i + 1 < tokens.count && noise.contains(strip(tokens[i + 1]))
            if bare == "like", tokens[i].hasSuffix(",") || nextIsNoise {
                droppingPauseComma(&kept)
                i += 1
                continue
            }
            kept.append(tokens[i])
            i += 1
        }
        return tidy(kept, original: text)
    }

    private static func endsSentence(_ token: String?) -> Bool {
        guard let last = token?.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// How many tokens the aside occupies, or nil when this is not one.
    private static func asideWidth(
        at i: Int, in tokens: [String], precededByComma: Bool, atStart: Bool
    ) -> Int? {
        for phrase in asides {
            guard i + phrase.count <= tokens.count else { continue }
            let slice = (0..<phrase.count).map { strip(tokens[i + $0]) }
            guard slice == phrase else { continue }

            let closes = tokens[i + phrase.count - 1].hasSuffix(",")
            // Either the speaker bracketed it, or it opened the sentence.
            let opens = precededByComma || atStart
            if closes && opens { return phrase.count }
        }
        return nil
    }

    private static func strip(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    private static func endsWithComma(_ token: String?) -> Bool {
        token?.hasSuffix(",") ?? false
    }

    /// The comma the pause left behind. When a filler goes, a comma on the
    /// word before it was marking the pause around the filler, not grammar,
    /// and it goes too: "because, you know, the" must come back "because
    /// the", never "because, the". Measured on the founder's own outputs
    /// (2026-08-20, "chalant is using a lot of commas"): the transcriber
    /// puts a comma at every pause, and stranding it after the filler is
    /// removed was the single ugliest class in the corpus. A full stop is
    /// never touched.
    private static func droppingPauseComma(_ kept: inout [String]) {
        guard let last = kept.last, last.hasSuffix(",") else { return }
        kept[kept.count - 1] = String(last.dropLast())
    }

    /// Put the sentence back together after words were taken out of it.
    ///
    /// Removing "Like," from the front leaves ", it's not there yet", and a
    /// cleanup that produces that is not cleanup. Returns the original
    /// untouched when nothing was removed, so a clean sentence is never
    /// reshaped by a pass that had no work to do.
    private static func tidy(_ tokens: [String], original: String) -> String {
        guard !tokens.isEmpty else { return original }
        var out = tokens.joined(separator: " ")
        guard out != original else { return original }

        // A stranded leading comma, left where an opening aside used to be.
        while let first = out.first, first == "," || first == " " {
            out.removeFirst()
        }
        // Two commas that used to have a filler between them.
        while out.contains(", ,") { out = out.replacingOccurrences(of: ", ,", with: ",") }
        while out.contains(",,") { out = out.replacingOccurrences(of: ",,", with: ",") }

        // The sentence's first letter is the sentence's own, and whichever word
        // inherits the position has to carry it. Every sentence, not only the
        // first: removing "Like," from mid-paragraph leaves a lowercase word
        // sitting after a full stop.
        if let first = out.first, first.isLowercase,
           let originalFirst = original.first, originalFirst.isUppercase {
            out.replaceSubrange(out.startIndex...out.startIndex, with: String(first).uppercased())
        }
        var chars = Array(out)
        var j = 0
        while j + 2 < chars.count {
            if (chars[j] == "." || chars[j] == "?" || chars[j] == "!"), chars[j + 1] == " ",
               chars[j + 2].isLowercase {
                chars[j + 2] = Character(String(chars[j + 2]).uppercased())
            }
            j += 1
        }
        return String(chars)
    }
}
