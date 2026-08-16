import Testing

@testable import ChalantDictationCore

/// Long dictation is cleaned a few sentences at a time, because that is where
/// the small on-device model is reliable.
///
/// **Measured on the founder's own 703-character paragraph, 2026-08-16.**
/// Whole: 5 runs, 3 clean, 1 dropped a negation, 1 invented a fragment, and
/// one "clean" run silently rewrote "I" as "he" throughout. Chunked at ~40
/// words: 11 runs across three chunk sizes, zero of any of those. The model
/// did not get better; the pieces got small enough for it.
@Suite("CleanupPrompt chunking")
struct ChunkingTests {

    @Test("a short utterance is one chunk, untouched")
    func shortIsOneChunk() {
        let text = "Ship Chalant to the Kizu group today."
        #expect(CleanupPrompt.chunks(text) == [text])
    }

    @Test("splits fall on sentence ends, never mid-sentence")
    func splitsOnSentences() {
        let text = String(repeating: "This is a sentence about something. ", count: 12).trimmingCharacters(in: .whitespaces)
        let pieces = CleanupPrompt.chunks(text)
        #expect(pieces.count > 1)
        for piece in pieces {
            #expect(piece.hasSuffix("."), "\(piece.suffix(20)) should end a sentence")
        }
    }

    /// Part 1 §2 in a different coat: chunking may not lose a word, and it may
    /// not reorder them. Rejoined, the pieces are the original.
    @Test("no words are lost or reordered by splitting")
    func losesNothing() {
        let text = """
            So my friend just called me from San Francisco. He said he went to a party. \
            He was dancing with a girl and bought her some drinks. His friend came in and \
            took her with him. He was sad and he called me to express his feelings. I told \
            him not to worry about it. Be strong because you are there for yourself. That is \
            what I told him. He said he will call in half an hour. If he does not call I will \
            go back to sleep.
            """
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let rejoined = CleanupPrompt.chunks(text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(rejoined == words)
    }

    @Test("chunks stay near the target size")
    func staysNearTarget() {
        let text = String(repeating: "Here is one more sentence of ordinary length for the test. ", count: 20)
            .trimmingCharacters(in: .whitespaces)
        for piece in CleanupPrompt.chunks(text) {
            let count = piece.split(whereSeparator: \.isWhitespace).count
            // One sentence is 11 words; a chunk may overshoot by at most one
            // sentence past the target, never by more.
            #expect(count <= CleanupPrompt.chunkTargetWords + 11)
        }
    }

    /// Question marks and exclamations end sentences too, and a splitter that
    /// only knew full stops would run a question into the next thought.
    @Test("questions and exclamations end a chunk")
    func otherTerminators() {
        let text = "Is he coming? I do not think so! We will see. " + String(repeating: "More words here. ", count: 15)
        let pieces = CleanupPrompt.chunks(text.trimmingCharacters(in: .whitespaces))
        #expect(pieces.first?.hasPrefix("Is he coming?") == true)
    }

    /// A single run-on with no punctuation cannot be split on sentences. It
    /// still must not be handed over whole if it is over budget: better to
    /// split at a word boundary than to refuse and ship it raw.
    @Test("a run-on with no punctuation still splits, at word boundaries")
    func runOnStillSplits() {
        let text = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let pieces = CleanupPrompt.chunks(text)
        #expect(pieces.count > 1)
        for piece in pieces { #expect(!piece.hasPrefix(" ") && !piece.hasSuffix(" ")) }
        #expect(pieces.joined(separator: " ") == text)
    }

    @Test("empty in, nothing out")
    func empty() {
        #expect(CleanupPrompt.chunks("").isEmpty)
        #expect(CleanupPrompt.chunks("   ").isEmpty)
    }

    /// Decimal points and abbreviations must not be read as sentence ends.
    /// "3.15" is one number, "e.g." is one token, and splitting inside either
    /// hands the model half a fact.
    @Test("a decimal point inside a number is not a sentence end")
    func decimalsAreNotSentences() {
        let text = "The invoice came to $9.99 and the meeting is at 3.15 today. " + String(repeating: "Then more text follows here. ", count: 12)
        let pieces = CleanupPrompt.chunks(text.trimmingCharacters(in: .whitespaces))
        #expect(pieces.first?.contains("$9.99 and the meeting is at 3.15") == true)
    }
}
