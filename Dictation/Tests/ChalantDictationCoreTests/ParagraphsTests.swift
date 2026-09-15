import Testing

@testable import ChalantDictationCore

/// Spoken line breaks, and the sentences about text that must survive them.
///
/// **This pass exists because the feature only ever worked in a mode nobody
/// is in.** The instruction has been in the model's prompt since the cleanup
/// pass was written, and the default mode is `shadow`, where the model's
/// answer reaches the corpus file and never the page. So on a default install,
/// saying "new paragraph" typed the words "new paragraph" into the document.
@Suite("Paragraphs")
struct ParagraphsTests {

    @Test("a spoken paragraph break becomes a blank line")
    func paragraphBreaks() {
        #expect(
            Paragraphs.applying("That is the first part. New paragraph. Here is the second.")
                == "That is the first part.\n\nHere is the second.")
    }

    @Test("a spoken line break becomes one newline")
    func lineBreaks() {
        #expect(
            Paragraphs.applying("Milk and eggs. New line. Bread and coffee.")
                == "Milk and eggs.\nBread and coffee.")
    }

    /// The whole reason the rule is narrow. Each of these is a sentence
    /// somebody really says, and each would be mangled by matching on the
    /// words alone.
    @Test("sentences about text keep their words")
    func realSentencesSurvive() {
        let kept = [
            "Add a new line to the file.",
            "Start another new paragraph here.",
            "We need a brand new line of shoes.",
            "This new paragraph needs work.",
            "Give me the new line numbers.",
            "Every new line costs a review.",
        ]
        for sentence in kept {
            #expect(Paragraphs.applying(sentence) == sentence, "mangled: \(sentence)")
        }
    }

    @Test("a comma is enough to show the cue stood alone")
    func aCommaOpensIt() {
        #expect(
            Paragraphs.applying("So that is settled, new line so let us move on.")
                == "So that is settled,\nso let us move on.")
    }

    /// **At the start, the punctuation has to be on the cue itself.** Nothing
    /// precedes it to prove it stood alone, and "New line items are up" is a
    /// real sentence: without this rule the opening words of a dictation would
    /// be eaten whenever they happened to be these two.
    @Test("a cue at the very start needs its own punctuation")
    func atTheStart() {
        #expect(
            Paragraphs.applying("New paragraph. This is the opening.") == "This is the opening.")
        #expect(
            Paragraphs.applying("New line items are up.") == "New line items are up.")
        #expect(
            Paragraphs.applying("New paragraph styles shipped.") == "New paragraph styles shipped.")
    }

    /// A break into nothing is not a break. Trailing whitespace pasted into
    /// somebody's document is the kind of thing `CleanupPrompt.unwrap` already
    /// strips from the model's replies.
    @Test("a cue at the end leaves no dangling newline")
    func atTheEnd() {
        #expect(Paragraphs.applying("That is everything. New paragraph.") == "That is everything.")
        #expect(Paragraphs.applying("Done. New line.") == "Done.")
    }

    @Test("two cues in a row are one break, and the wider one wins")
    func runsCollapse() {
        #expect(
            Paragraphs.applying("One. New line. New paragraph. Two.") == "One.\n\nTwo.")
        #expect(
            Paragraphs.applying("One. New paragraph. New line. Two.") == "One.\nTwo.")
    }

    @Test("no space is left beside a break")
    func noStraySpaces() {
        let out = Paragraphs.applying("First. New paragraph. Second.")
        #expect(!out.contains(" \n"))
        #expect(!out.contains("\n "))
    }

    /// Byte-identical when there is nothing to do, so a clean paragraph is
    /// never reshaped by a pass with no work. The same rule `Restatement`
    /// follows.
    @Test("text with no cue comes back untouched")
    func untouchedWithoutACue() {
        let plain = "Ship the build today and tell Priya about the review."
        #expect(Paragraphs.applying(plain) == plain)
        #expect(Paragraphs.applying("") == "")
        #expect(Paragraphs.applying("new") == "new")
    }

    @Test("the cue is matched whatever case and punctuation it arrives in")
    func caseAndPunctuationTolerated() {
        #expect(Paragraphs.applying("Done. new paragraph next.") == "Done.\n\nnext.")
        #expect(Paragraphs.applying("Done. NEW LINE next.") == "Done.\nnext.")
        #expect(Paragraphs.applying("Done; new line, next.") == "Done;\nnext.")
    }

    /// "new" on its own is a word, and a cue needs both halves.
    @Test("new without line or paragraph is just a word")
    func newAloneIsAWord() {
        #expect(Paragraphs.applying("Done. New features shipped.") == "Done. New features shipped.")
    }
}
