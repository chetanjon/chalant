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
    // MARK: - Pieces close at every finished sentence (2026-08-27)

    /// **The live test that forced this** (rows cap-20260827-1905*): with
    /// pieces filling to 40 words, a four-sentence dictation made two pieces,
    /// only one was closed early enough to be cleaned while the founder was
    /// still talking, and the release's 0.65 s window expired on the rest:
    /// polish landed 0 of 4 times. A piece now closes at a sentence end as
    /// soon as it is worth cleaning on its own (`minimumCharactersForCleanup`),
    /// so by release everything but the tail is already clean, and the tail
    /// is one sentence, which the window fits (0.45 to 0.65 s measured).
    @Test("pieces close at every finished sentence once worth cleaning")
    func piecesCloseAtSentences() {
        let text = "I looked at the resume again this morning and I think the summary section is too long. "
            + "We should cut it down to three lines. "
            + "Also the project descriptions need real numbers in them, not just words. "
            + "Send me the new version when you are done."
        let pieces = CleanupPrompt.chunks(text)
        #expect(pieces.count == 3)
        #expect(pieces.first == "I looked at the resume again this morning and I think the summary section is too long.")
        #expect(pieces.last == "Send me the new version when you are done.")
        // The tail the release waits on is one short sentence, not half the text.
        #expect((pieces.last?.split(whereSeparator: \.isWhitespace).count ?? 99) <= 13)
    }

    /// A sentence too small to clean alone rides with the next one, so no
    /// piece below the worth-cleaning floor is ever sent to the model.
    @Test("a tiny sentence merges forward")
    func tinySentenceMerges() {
        let text = "Not just words. Send me the new version when you are done."
        #expect(CleanupPrompt.chunks(text) == [text])
    }

    /// The clean-while-talking contract: text only ever grows at the end, so
    /// a piece once closed must never move. Every closed piece of a prefix is
    /// a closed piece of the longer text, byte for byte.
    @Test("closed pieces never move as the speaker goes on")
    func closedPiecesAreStable() {
        // No ordinals: "first, second, third" reads as a spoken list to
        // `looksLikeList`, and a list is deliberately one piece, never
        // pre-tidied. The stability contract is for ordinary running speech.
        let full = "The morning light comes into the kitchen very slowly today. "
            + "We talked about the resume over coffee for quite a while. "
            + "Something about the summary section still reads far too long. "
            + "And the tail is still growing"
        var previous: [String] = []
        for end in stride(from: 40, through: full.count, by: 7) {
            let prefix = String(full.prefix(end))
            let closed = CleanupPrompt.closedChunks(prefix)
            #expect(Array(closed.prefix(previous.count)) == previous)
            if closed.count > previous.count { previous = closed }
        }
    }

    // MARK: - Worth waiting (2026-08-27, the retest's verdict)

    /// The second live test: pieces cached beautifully (2 of 3 warm on the
    /// long row) and the release STILL landed 0 of 4, because the wait was
    /// spent on pieces that never had a chance: a fresh 15-to-18-word
    /// sentence needs ~0.9 s warm (measured), and two fresh pieces need two
    /// calls. The rule: the release waits only when at most ONE piece is
    /// missing and that piece is small enough to finish inside the window.
    /// Everything else lands as said IMMEDIATELY, zero wait, instead of
    /// paying the full window for nothing.
    @Test("the release waits only when the wait can be won")
    func worthWaiting() {
        // Nothing missing: wait (the pieces in flight have a head start).
        #expect(CleanupPrompt.worthWaiting(freshPieces: []))
        // One small missing piece: the window fits it.
        let small = "Send me the new version when you are done today please."
        #expect(CleanupPrompt.worthWaiting(freshPieces: [small]))
        // One piece past the ceiling: hopeless, land at once.
        let big = String(repeating: "word ", count: CleanupPrompt.freshPieceWordCeiling + 1)
            .trimmingCharacters(in: .whitespaces)
        #expect(!CleanupPrompt.worthWaiting(freshPieces: [big]))
        // Two missing pieces are two model calls: hopeless, land at once.
        #expect(!CleanupPrompt.worthWaiting(freshPieces: [small, small]))
    }

}
