import Foundation

/// Where the spaces go around an insertion.
///
/// M1's protocol case 6 is "two in a row, correct spacing between them", and
/// without this two insertions produce `firstsecond`. M3 owns the full policy
/// ("trailing-space and capitalization policy from surrounding context"); this
/// is the minimum the gate needs, shaped so M3 extends it.
///
/// The asymmetry is deliberate. A **trailing** space is always safe: it costs
/// one character at the end of a message and it is what makes the next
/// dictation land correctly. A **leading** space is only safe when the
/// character before the cursor is known, and it usually is not: Part 1 §1
/// records that Electron and web views report no focused element, so context
/// reads fail exactly where dictation is most used. Unknown therefore means no
/// leading space, which keeps an empty field clean and leaves the common case
/// correct.
public enum Spacing {
    /// Characters after which a leading space would be wrong.
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "-", "_", "@", "#"]

    /// - Parameter preceding: the character immediately before the cursor, or
    ///   nil when it could not be read.
    public static func pad(_ text: String, precededBy preceding: Character?) -> String {
        guard !text.isEmpty else { return text }

        var out = text

        if let preceding,
           !preceding.isWhitespace,
           !openers.contains(preceding) {
            out = " " + out
        }

        if !out.hasSuffix(" ") {
            out += " "
        }
        return out
    }
}
