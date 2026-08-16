import Testing

@testable import ChalantDictationCore

/// Watching what the user fixes, and working out whether it was a fix.
///
/// **This is the moat and it has no prior art.** Part 0 §0.15: the round-2
/// literature search found *no published solution* for separating "the ASR was
/// wrong" edits from "the user changed their mind" edits, and warns the
/// revision class is intrinsically hard (BERT F1 43-66%). So the whole design
/// is conservative by construction: it would rather learn nothing than learn a
/// lie, because a learned lie fires on every future utterance.
///
/// The single distinguishing signal is SOUND. `Chalan` → `Chalant` is a
/// correction because they sound alike, so the engine plausibly misheard.
/// `Tuesday` → `Wednesday` is a revision: nobody mishears one as the other, the
/// speaker simply changed their mind.
@Suite("Correction")
struct CorrectionTests {

    // MARK: - What it should learn

    @Test("a single word swapped for one that sounds like it is a correction")
    func learnsTheObviousCase() {
        let pair = Correction.learning(
            inserted: "Ship Chalan to the Kizu group",
            nowReads: "Ship Chalant to the Kizu group")
        #expect(pair == Correction.Pair(heard: "Chalan", meant: "Chalant"))
    }

    @Test("the surrounding document is ignored, only our own span is read")
    func ignoresSurroundingText() {
        let pair = Correction.learning(
            inserted: "Email Chatan today",
            nowReads: "Hi there. Email Chetan today. Thanks, see you soon.")
        #expect(pair == Correction.Pair(heard: "Chatan", meant: "Chetan"))
    }

    @Test("punctuation the user did not touch does not count as a change")
    func punctuationIsNotAnEdit() {
        let pair = Correction.learning(
            inserted: "Ask Athram, whether it is ready.",
            nowReads: "Ask Aatram, whether it is ready.")
        #expect(pair == Correction.Pair(heard: "Athram", meant: "Aatram"))
    }

    @Test("a capitalisation-only fix is a correction worth learning")
    func learnsCasing() {
        let pair = Correction.learning(
            inserted: "we use posthog daily", nowReads: "we use PostHog daily")
        #expect(pair == Correction.Pair(heard: "posthog", meant: "PostHog"))
    }

    // MARK: - What it must refuse, which is nearly everything

    /// **The case the whole classifier exists to reject.** Part 0 §0.15 and
    /// Part 8 §3: a word swapped for one that sounds nothing like it is the
    /// speaker changing their mind, not the engine mishearing. Learning it
    /// would teach Chalant to rewrite "Tuesday" as "Wednesday" forever.
    @Test("a word swapped for one that sounds nothing like it is a revision")
    func refusesRevisions() {
        for (before, after) in [
            ("send it Tuesday", "send it Wednesday"),
            ("meet at the office", "meet at the studio"),
            ("this is good", "this is terrible"),
            ("call Ravi tonight", "call Sarah tonight"),
        ] {
            #expect(
                Correction.learning(inserted: before, nowReads: after) == nil,
                "\(before) -> \(after) is a revision")
        }
    }

    @Test("more than one word changed is editing, not correcting")
    func refusesMultiWordEdits() {
        #expect(
            Correction.learning(
                inserted: "Ship Chalan to the Kizu group",
                nowReads: "Ship Chalant to the Aatram group") == nil)
    }

    @Test("a rewrite that keeps almost nothing is not a correction")
    func refusesRewrites() {
        #expect(
            Correction.learning(
                inserted: "Ship Chalan to the Kizu group today",
                nowReads: "Actually let us wait until next week") == nil)
    }

    @Test("text left exactly as it arrived teaches nothing")
    func refusesUntouchedText() {
        #expect(
            Correction.learning(
                inserted: "Ship Chalant today", nowReads: "Ship Chalant today") == nil)
    }

    @Test("words added or deleted are not a substitution")
    func refusesInsertionsAndDeletions() {
        #expect(Correction.learning(inserted: "ship it today", nowReads: "ship it") == nil)
        #expect(
            Correction.learning(inserted: "ship it today", nowReads: "ship it today please")
                == nil)
    }

    /// **A number that changed is the fidelity guard's territory, never the
    /// learner's.** "15" becoming "50" might be a mishearing, but a learned
    /// pair that rewrites digits is the single most dangerous thing this
    /// subsystem could produce.
    @Test("numbers are never learned, whatever they sound like")
    func refusesNumbers() {
        #expect(Correction.learning(inserted: "send 15 copies", nowReads: "send 50 copies") == nil)
        #expect(Correction.learning(inserted: "build 153", nowReads: "build 253") == nil)
        #expect(Correction.learning(inserted: "the 21st", nowReads: "the 12th") == nil)
    }

    /// Today's other hard-won lesson: `review` and `ravi` are phonetically
    /// IDENTICAL, so sound alone would accept this and teach Chalant to rewrite
    /// a common English word into a name permanently.
    @Test("a word too different in length is refused however identical it sounds")
    func refusesOnLength() {
        #expect(Correction.learning(inserted: "without a review", nowReads: "without a ravi") == nil)
    }

    @Test("function words are never learned in either direction")
    func refusesStopwords() {
        #expect(Correction.learning(inserted: "put it on the desk", nowReads: "put it in the desk") == nil)
        #expect(Correction.learning(inserted: "he was here", nowReads: "he is here") == nil)
    }

    @Test("nothing at all in, nothing out")
    func handlesEmpty() {
        #expect(Correction.learning(inserted: "", nowReads: "anything") == nil)
        #expect(Correction.learning(inserted: "something", nowReads: "") == nil)
    }

    // MARK: - Counting, because one sighting is not evidence

    /// Part 3 M5 and Part 8 §3: **a pair must be seen at least twice before it
    /// is allowed to change anything.** One sighting can be a typo, a slip, or
    /// the user editing for a reason that has nothing to do with what they
    /// said. Two is the cheapest possible guard against learning from noise.
    @Test("one sighting is remembered but does not fire")
    func requiresTwoSightings() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 0))
        #expect(ledger.trusted(at: .init(day: 0)).isEmpty)

        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 1))
        #expect(ledger.trusted(at: .init(day: 1)) == ["Chalant"])
    }

    @Test("two different pairs do not add up to one trusted pair")
    func countsPerPair() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 0))
        ledger.record(Correction.Pair(heard: "Chatan", meant: "Chetan"), at: .init(day: 0))
        #expect(ledger.trusted(at: .init(day: 0)).isEmpty)
    }

    /// Part 3 M5: 90-day decay, so a term from a project that ended stops
    /// competing for the 100 active slots §0.13 allows.
    @Test("a pair not seen for ninety days stops being trusted")
    func decays() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 0))
        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 1))
        #expect(ledger.trusted(at: .init(day: 89)) == ["Chalant"])
        #expect(ledger.trusted(at: .init(day: 91)).isEmpty)
    }

    @Test("seeing it again renews it")
    func renewsOnUse() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 0))
        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 1))
        ledger.record(Correction.Pair(heard: "Chalan", meant: "Chalant"), at: .init(day: 80))
        #expect(ledger.trusted(at: .init(day: 150)) == ["Chalant"])
    }

    /// §0.13 caps the ACTIVE list at 100 after phonetic dedup, because a bigger
    /// dictionary is a bigger false-positive surface rather than a bigger
    /// safety net. The ledger may remember more; it may not offer more.
    @Test("the trusted list never exceeds the active cap")
    func respectsTheCap() {
        var ledger = Correction.Ledger()
        for i in 0..<150 {
            let pair = Correction.Pair(heard: "heard\(i)", meant: "Meant\(i)")
            ledger.record(pair, at: .init(day: 0))
            ledger.record(pair, at: .init(day: 1))
        }
        #expect(ledger.trusted(at: .init(day: 1)).count == 100)
    }

    // MARK: - The milestone's own acceptance criterion

    /// **Part 3 M5, verbatim: "dictate a term, correct it manually twice,
    /// dictate again, and it comes out right without touching settings."**
    ///
    /// Everything else in this file tests a part. This tests the loop, using
    /// the real mis-hearing the corpus produced on 2026-08-15 (`Chalan` for
    /// `Chalant`, at 0.87 confidence) and the real matcher that has to act on
    /// what was learned.
    @Test("the whole loop: mishear, get corrected twice, then get it right")
    func theMoat() {
        var ledger = Correction.Ledger()

        // Day one. Chalant mishears, the user fixes it by hand.
        let first = Correction.learning(
            inserted: "Ship Chalan to the Kizu group",
            nowReads: "Ship Chalant to the Kizu group")
        #expect(first != nil)
        ledger.record(first!, at: .init(day: 0))

        // Still nothing: one sighting is not evidence.
        #expect(ledger.trusted(at: .init(day: 0)).isEmpty)

        // Day two. Same mistake, same fix.
        let second = Correction.learning(
            inserted: "Send Chalan the notes", nowReads: "Send Chalant the notes")
        #expect(second != nil)
        ledger.record(second!, at: .init(day: 1))

        #expect(ledger.trusted(at: .init(day: 1)) == ["Chalant"])

        // Day three. The engine makes the same mistake, and this time it is
        // CONFIDENT about it, which is the normal case for a proper noun:
        // `Chalan` measured 0.87 on the real corpus. A confidence gate would
        // refuse the very repair the user asked for twice, so the alias path
        // does not consult it.
        let heard = [Token(text: "Chalan", confidence: 0.87)]
        let repaired = TermMatcher.applyingAliases(
            tokens: heard, aliases: ledger.aliases(at: .init(day: 1)))
        #expect(repaired.map(\.text) == ["Chalant"])

        // And nobody opened settings.
    }

    /// The alias path fires on a word the phonetic matcher would refuse, which
    /// is the whole reason it exists. `Chalan` sits below the 0.90 similarity
    /// floor the 2026-08-15 sweep set, so without this the loop learns the pair
    /// and then declines to use it.
    @Test("an alias reaches what the phonetic matcher cannot")
    func aliasesReachWhatSoundCannot() {
        let heard = [Token(text: "Chalan", confidence: 0.41)]
        #expect(TermMatcher.resolving(tokens: heard, terms: ["Chalant"]).map(\.text) == ["Chalan"])
        #expect(
            TermMatcher.applyingAliases(tokens: heard, aliases: ["chalan": "Chalant"])
                .map(\.text) == ["Chalant"])
    }

    @Test("an alias keeps the speaker's punctuation and matches whatever the case")
    func aliasesKeepPunctuation() {
        let tokens = [Token(text: "CHALAN,", confidence: 0.9), Token(text: "chalan.", confidence: 0.9)]
        let out = TermMatcher.applyingAliases(tokens: tokens, aliases: ["chalan": "Chalant"])
        #expect(out.map(\.text) == ["Chalant,", "Chalant."])
    }

    @Test("no aliases means nothing is touched")
    func noAliasesNoChange() {
        let tokens = [Token(text: "anything", confidence: 0.2)]
        #expect(TermMatcher.applyingAliases(tokens: tokens, aliases: [:]) == tokens)
    }

    /// The other half of M5's acceptance: **"a measured false-positive rate
    /// showing learned aliases don't introduce new errors."** A vocabulary
    /// learned this way must not start rewriting ordinary words.
    @Test("what it learns does not corrupt ordinary sentences")
    func learnedTermsDoNotIntroduceErrors() {
        var ledger = Correction.Ledger()
        for pair in [
            Correction.Pair(heard: "Chalan", meant: "Chalant"),
            Correction.Pair(heard: "Chatan", meant: "Chetan"),
            Correction.Pair(heard: "Kisu", meant: "Kizu"),
        ] {
            ledger.record(pair, at: .init(day: 0))
            ledger.record(pair, at: .init(day: 1))
        }
        let vocabulary = ledger.trusted(at: .init(day: 1))

        let ordinary = "the meeting moved to Monday and nobody was certain about the database"
        let tokens = ordinary.split(separator: " ").map {
            // Unsure about every word, which is the worst case for the matcher.
            Token(text: String($0), confidence: 0.2)
        }
        let out = TermMatcher.resolving(tokens: tokens, terms: vocabulary)
        #expect(out.map(\.text).joined(separator: " ") == ordinary)
    }

    /// Part 0 §0.15 requires every learned pair to be inspectable and
    /// reversible. A user who cannot see what it learned cannot trust it, and a
    /// wrong pair they cannot delete is a permanent bug in their own words.
    @Test("a pair can be forgotten, and stays forgotten")
    func canBeForgotten() {
        var ledger = Correction.Ledger()
        let pair = Correction.Pair(heard: "Chalan", meant: "Chalant")
        ledger.record(pair, at: .init(day: 0))
        ledger.record(pair, at: .init(day: 1))
        #expect(ledger.trusted(at: .init(day: 1)) == ["Chalant"])

        ledger.forget(pair)
        #expect(ledger.trusted(at: .init(day: 1)).isEmpty)

        // And it does not creep back on the next sighting alone.
        ledger.record(pair, at: .init(day: 2))
        #expect(ledger.trusted(at: .init(day: 2)).isEmpty)
    }
}
