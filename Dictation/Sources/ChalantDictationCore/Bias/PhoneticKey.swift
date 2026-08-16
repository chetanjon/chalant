import Foundation

/// What a word sounds like, reduced to a comparable key.
///
/// **Part 0 §0.14 names the algorithm and the reason.** Phoneme-aware biasing
/// beats text matching by a wide margin: PROCTER (ICASSP 2023) reports 44% and
/// 57% WER reduction on personalised and rare entities from adding phonemic
/// embeddings, and the production pattern (Garg et al., Interspeech 2020) is a
/// three-stage matcher: word match, then Double Metaphone, then edit distance.
///
/// **Why not orthographic similarity.** `Chatan` and `Chetan` differ by one
/// letter, but so do `cat` and `cut`. Spelling distance says they are equally
/// close. Sound says the first pair is the same word twice and the second is
/// two different ones. The errors this has to catch are *acoustic* errors, so
/// the key has to be acoustic.
///
/// This is the primary Double Metaphone code. The algorithm also produces an
/// alternate code for words with more than one plausible pronunciation; that is
/// worth adding when a term needs it, and is deliberately not here yet.
public enum PhoneticKey {

    /// The sound of a word, as an uppercase consonant skeleton.
    ///
    /// Vowels survive only in first position, because English vowels carry far
    /// less identity than consonants and dropping them is what lets
    /// `Junalagadda` and `Jonnalagadda` land on the same key.
    public static func of(_ word: String) -> String {
        let s = Array(word.uppercased().filter { $0.isLetter })
        guard !s.isEmpty else { return "" }

        var out = ""
        var i = 0

        // A silent first letter is still a sound the listener heard nothing of.
        if s.count >= 2 {
            switch String(s[0...1]) {
            case "GN", "KN", "PN", "WR", "PS": i = 1
            default: break
            }
        }
        if s[0] == "X" { out += "S"; i = 1 }

        while i < s.count {
            let c = s[i]
            let next = i + 1 < s.count ? s[i + 1] : " "
            let prev = i > 0 ? s[i - 1] : " "

            // A doubled consonant is one sound, except CC which can be two.
            if c == prev, c != "C", !isVowel(c) { i += 1; continue }

            switch c {
            case "A", "E", "I", "O", "U", "Y":
                if i == 0 { out += "A" }
                i += 1

            case "B": out += "P"; i += 1
            case "C":
                if next == "H" { out += "X"; i += 2 }               // CHalant, CHetan
                else if next == "I" || next == "E" || next == "Y" { out += "S"; i += 1 }
                else { out += "K"; i += 1 }
            case "D":
                if next == "G" { out += "J"; i += 2 } else { out += "T"; i += 1 }
            case "F": out += "F"; i += 1
            case "G":
                if next == "H" { out += "K"; i += 2 }
                else if next == "N" { i += 2 }                       // siGN
                else if next == "I" || next == "E" || next == "Y" { out += "J"; i += 1 }
                else { out += "K"; i += 1 }
            case "H":
                // Heard only between a vowel and a following vowel.
                if isVowel(prev) && !isVowel(next) { i += 1 } else { out += "H"; i += 1 }
            case "J": out += "J"; i += 1
            case "K": out += "K"; i += 1
            case "L": out += "L"; i += 1
            case "M": out += "M"; i += 1
            case "N": out += "N"; i += 1
            case "P":
                if next == "H" { out += "F"; i += 2 } else { out += "P"; i += 1 }
            case "Q": out += "K"; i += 1
            case "R": out += "R"; i += 1
            case "S":
                if next == "H" { out += "X"; i += 2 } else { out += "S"; i += 1 }
            case "T":
                if next == "H" { out += "0"; i += 2 }                // TH as one sound
                else if next == "I" && i + 2 < s.count && (s[i + 2] == "O" || s[i + 2] == "A") {
                    out += "X"; i += 1                               // -TION, -TIAL
                } else { out += "T"; i += 1 }
            case "V": out += "F"; i += 1
            case "W":
                if isVowel(next) { out += "W" }
                i += 1
            case "X": out += "KS"; i += 1
            case "Z": out += "S"; i += 1
            default: i += 1
            }
        }
        return out
    }

    private static func isVowel(_ c: Character) -> Bool {
        "AEIOUY".contains(c)
    }

    /// 0 to 1, how alike two words sound. 1 means indistinguishable by key.
    ///
    /// The stage after the key, per §0.14: two words rarely produce identical
    /// keys, and requiring that would reject `Shalan` against `Chalant`, which
    /// is exactly the substitution worth making.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let ka = of(a), kb = of(b)
        if ka.isEmpty || kb.isEmpty { return 0 }
        if ka == kb { return 1 }
        let distance = editDistance(Array(ka), Array(kb))
        return 1 - Double(distance) / Double(max(ka.count, kb.count))
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
