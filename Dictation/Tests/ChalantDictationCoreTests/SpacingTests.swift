import Testing

@testable import ChalantDictationCore

/// Case 6 of the M1 protocol: "two in a row, correct spacing between them".
/// Measured 2026-08-12, two consecutive insertions produced `firstsecond`.
///
/// The full context-aware policy belongs to M3 ("trailing-space and
/// capitalization policy from surrounding context"). This is the minimum M1's
/// own gate needs, written so M3 extends it rather than replaces it.
@Suite("Spacing")
struct SpacingTests {
    @Test("a trailing space is added so the next insertion does not collide")
    func trailingSpace() {
        #expect(Spacing.pad("first", precededBy: nil) == "first ")
    }

    @Test("an existing trailing space is not doubled")
    func noDoubleTrailing() {
        #expect(Spacing.pad("first ", precededBy: nil) == "first ")
    }

    @Test("a leading space is added mid-word, when the context is known")
    func leadingSpaceMidSentence() {
        // "one two|" then inserting "beta" must not give "one twobeta".
        #expect(Spacing.pad("beta", precededBy: "o") == " beta ")
    }

    @Test("no leading space after whitespace")
    func noLeadingAfterSpace() {
        #expect(Spacing.pad("beta", precededBy: " ") == "beta ")
        #expect(Spacing.pad("beta", precededBy: "\n") == "beta ")
    }

    @Test("no leading space at the very start of a field")
    func noLeadingAtStart() {
        // nil means the context could not be read, which is the common case in
        // Electron and web views. Defaulting to no leading space keeps an
        // empty field clean; the trailing space still fixes consecutive runs.
        #expect(Spacing.pad("alpha", precededBy: nil) == "alpha ")
    }

    @Test("no leading space after an opening bracket or quote")
    func noLeadingAfterOpener() {
        #expect(Spacing.pad("beta", precededBy: "(") == "beta ")
        #expect(Spacing.pad("beta", precededBy: "\"") == "beta ")
    }

    @Test("a leading space follows sentence punctuation")
    func leadingAfterPunctuation() {
        #expect(Spacing.pad("Beta", precededBy: ".") == " Beta ")
        #expect(Spacing.pad("beta", precededBy: ",") == " beta ")
    }

    @Test("empty text is left completely alone")
    func emptyUntouched() {
        // Never invent a space out of nothing: Part 1 §2's spirit is that the
        // pipeline does not add what the user did not say.
        #expect(Spacing.pad("", precededBy: "o") == "")
    }
}
