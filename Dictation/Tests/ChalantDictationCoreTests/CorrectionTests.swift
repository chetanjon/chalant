import Foundation
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

    /// 2026-08-16, the founder's own first try in Chrome: "Send the Chalawant
    /// bill to Pisu and tell it and it is ready". Three words wrong, and a
    /// person fixes all of them in one go. Refusing to learn anything from that
    /// is refusing to learn from exactly the sentences that need it most. Each
    /// changed word is judged on its own; the ones that sound like what they
    /// replaced are corrections, the rest is editing and is ignored.
    @Test("several words fixed at once are several corrections, each judged alone")
    func learnsEachOfSeveralFixes() {
        let pairs = Correction.learnings(
            inserted: "Send the Chalawant bill to Kisu and tell Aden it is ready",
            nowReads: "Send the Chalant bill to Kizu and tell Aidan it is ready")
        #expect(pairs.map(\.meant) == ["Chalant", "Kizu", "Aidan"])
        #expect(pairs.map(\.heard) == ["Chalawant", "Kisu", "Aden"])
    }

    @Test("a fix beside a revision learns the fix and ignores the revision")
    func learnsTheFixBesideARevision() {
        // Chalan -> Chalant is a correction; Kizu -> Aatram sounds nothing alike.
        let pairs = Correction.learnings(
            inserted: "Ship Chalan to the Kizu group",
            nowReads: "Ship Chalant to the Aatram group")
        #expect(pairs == [Correction.Pair(heard: "Chalan", meant: "Chalant")])
        // The single-pair door reports the first of them.
        #expect(Correction.learning(
            inserted: "Ship Chalan to the Kizu group",
            nowReads: "Ship Chalant to the Aatram group") == Correction.Pair(heard: "Chalan", meant: "Chalant"))
    }

    @Test("changing most of the words is a rewrite, and nothing is learned from it")
    func refusesWholesaleRewrites() {
        #expect(
            Correction.learnings(
                inserted: "Ship Chalan to the Kizu group today please",
                nowReads: "Chip Shalant two thee Keezu groop toady pleas").isEmpty)
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
    /// **Names in one shot (2026-08-16).** The founder's ask, verbatim: "it
    /// should remember names", and after the first live test, "make it work in
    /// one or two shots". Two sightings of the SAME pair almost never happen
    /// for a name, because a name is misheard differently every time: Chalant
    /// arrived as Shalan, Chalawant and Chalant inside five minutes; Kizu as
    /// Kizu, Pisu and Kisu. So a word the user typed with a capital letter,
    /// which is what a name looks like, is trusted the first time. An ordinary
    /// lowercase word still needs two, because "affect" typed over "effect"
    /// once can be a slip and learning it would rewrite ordinary English.
    @Test("a capitalised fix, a name, is trusted the first time")
    func namesAreTrustedAtOnce() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "Kisu", meant: "Kizu"), at: .init(day: 0), heardIsWord: false)
        #expect(ledger.trusted(at: .init(day: 0)) == ["Kizu"])
        #expect(ledger.aliases(at: .init(day: 0)) == ["kisu": "Kizu"])
    }

    /// The one danger in one-shot aliases, met on the very first live run
    /// (2026-08-16): the engine heard "challenge" for Chalant, the fix was
    /// learned, and an exact alias would now rewrite every ordinary "challenge"
    /// into "Chalant" forever. So when the misheard word is a real word, the
    /// NAME still joins the vocabulary at once (that path is gated by sound,
    /// length and confidence), but the exact, confidence-blind rewrite waits
    /// for a second sighting, as it always did.
    @Test("a name misheard as a real word joins the vocabulary at once, but the exact rewrite waits")
    func realWordMishearingsDoNotAliasAtOnce() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "challenge", meant: "Chalant"), at: .init(day: 0), heardIsWord: true)
        #expect(ledger.trusted(at: .init(day: 0)) == ["Chalant"])
        #expect(ledger.aliases(at: .init(day: 0)).isEmpty)

        ledger.record(Correction.Pair(heard: "challenge", meant: "Chalant"), at: .init(day: 1), heardIsWord: true)
        #expect(ledger.aliases(at: .init(day: 1)) == ["challenge": "Chalant"])
    }

    @Test("a lowercase fix is remembered but does not fire until seen twice")
    func ordinaryWordsStillNeedTwoSightings() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "affect", meant: "effect"), at: .init(day: 0))
        #expect(ledger.trusted(at: .init(day: 0)).isEmpty)
        #expect(ledger.aliases(at: .init(day: 0)).isEmpty)

        ledger.record(Correction.Pair(heard: "affect", meant: "effect"), at: .init(day: 1))
        #expect(ledger.trusted(at: .init(day: 1)) == ["effect"])
        #expect(ledger.aliases(at: .init(day: 1)) == ["affect": "effect"])
    }

    @Test("two different lowercase pairs do not add up to one trusted pair")
    func countsPerPair() {
        var ledger = Correction.Ledger()
        ledger.record(Correction.Pair(heard: "affect", meant: "effect"), at: .init(day: 0))
        ledger.record(Correction.Pair(heard: "there", meant: "their"), at: .init(day: 0))
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
    @Test("the whole loop: mishear, get corrected once, then get it right")
    func theMoat() {
        var ledger = Correction.Ledger()

        // Day one. Chalant mishears, the user fixes it by hand.
        let first = Correction.learning(
            inserted: "Ship Chalan to the Kizu group",
            nowReads: "Ship Chalant to the Kizu group")
        #expect(first != nil)
        ledger.record(first!, at: .init(day: 0))

        // A name, typed once, is enough (2026-08-16: names in one shot).
        #expect(ledger.trusted(at: .init(day: 0)) == ["Chalant"])

        // Day two. Same mistake, same fix: still trusted, still one entry.
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

    // MARK: - Surviving a quit

    /// The ledger is the only thing in Chalant a user can BUILD by using it.
    /// Losing it on quit would not be a bug, it would be the feature failing to
    /// exist, so the wire format gets its own test rather than trusting a
    /// synthesised conformance.
    @Test("everything learned survives a save and a reload")
    func roundTrips() throws {
        var ledger = Correction.Ledger()
        let kept = Correction.Pair(heard: "Chalan", meant: "Chalant")
        let deleted = Correction.Pair(heard: "review", meant: "Ravi")
        ledger.record(kept, at: .init(day: 3))
        ledger.record(kept, at: .init(day: 7))
        ledger.forget(deleted)

        let data = try JSONEncoder().encode(ledger)
        let reloaded = try JSONDecoder().decode(Correction.Ledger.self, from: data)

        #expect(reloaded == ledger)
        #expect(reloaded.trusted(at: .init(day: 7)) == ["Chalant"])
        #expect(reloaded.aliases(at: .init(day: 7)) == ["chalan": "Chalant"])

        // The deletion has to survive too, or every restart resurrects the
        // pair the user threw away.
        var after = reloaded
        after.record(deleted, at: .init(day: 8))
        after.record(deleted, at: .init(day: 9))
        #expect(after.trusted(at: .init(day: 9)) == ["Chalant"])
    }

    @Test("an empty ledger round-trips as empty rather than as a failure")
    func roundTripsEmpty() throws {
        let data = try JSONEncoder().encode(Correction.Ledger())
        let reloaded = try JSONDecoder().decode(Correction.Ledger.self, from: data)
        #expect(reloaded == Correction.Ledger())
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
    // MARK: - The ear teaches (2026-08-28)

    /// 46 hearings lifetime, 28 refused swaps, all in VS Code, 25 carrying a
    /// real correction: the ear heard better and the lesson was thrown away.
    /// Now a refused swap records what the ear heard, and after TWO ear
    /// sightings the pair fires at landing as an exact, confidence-gated
    /// correction. Two always: the ear is a model, not the user's own hand,
    /// so even a capitalized name earns no one-shot trust from it.
    @Test("two ear sightings make an exact correction, one does not")
    func earSightingsTrustSlowly() {
        var ledger = Correction.Ledger()
        let pair = Correction.Pair(heard: "inverse", meant: "invoice")
        ledger.record(pair, at: Correction.Day(day: 100), heardIsWord: true, source: .ear)
        #expect(ledger.earCorrections(at: Correction.Day(day: 100)).isEmpty)
        ledger.record(pair, at: Correction.Day(day: 101), heardIsWord: true, source: .ear)
        #expect(ledger.earCorrections(at: Correction.Day(day: 101)) == ["inverse": "invoice"])
    }

    @Test("the ear never creates an exact alias, however often it hears")
    func earNeverAliases() {
        var ledger = Correction.Ledger()
        let pair = Correction.Pair(heard: "inverse", meant: "Invoice")
        for day in 100...105 {
            ledger.record(pair, at: Correction.Day(day: day), heardIsWord: true, source: .ear)
        }
        #expect(ledger.aliases(at: Correction.Day(day: 105)).isEmpty)
    }

    @Test("user sightings and ear sightings count apart")
    func sightingSourcesStayApart() {
        var ledger = Correction.Ledger()
        let pair = Correction.Pair(heard: "chalan", meant: "Chalant")
        ledger.record(pair, at: Correction.Day(day: 100), heardIsWord: false, source: .ear)
        ledger.record(pair, at: Correction.Day(day: 100), heardIsWord: false)
        // One of each: the alias path sees ONE user sighting of a non-word
        // name, which one-shot-trusts by the standing rule; the ear path
        // sees one, short of its two.
        #expect(ledger.aliases(at: Correction.Day(day: 100))["chalan"] == "Chalant")
        #expect(ledger.earCorrections(at: Correction.Day(day: 100)).isEmpty)
    }

    @Test("a forgotten pair stays forgotten to the ear too")
    func forgottenOutranksTheEar() {
        var ledger = Correction.Ledger()
        let pair = Correction.Pair(heard: "inverse", meant: "invoice")
        ledger.forget(pair)
        ledger.record(pair, at: Correction.Day(day: 100), heardIsWord: true, source: .ear)
        ledger.record(pair, at: Correction.Day(day: 101), heardIsWord: true, source: .ear)
        #expect(ledger.earCorrections(at: Correction.Day(day: 101)).isEmpty)
    }

    @Test("ear sightings survive the file and old files still read")
    func earSightingsRoundTrip() throws {
        var ledger = Correction.Ledger()
        let pair = Correction.Pair(heard: "inverse", meant: "invoice")
        ledger.record(pair, at: Correction.Day(day: 100), heardIsWord: true, source: .ear)
        ledger.record(pair, at: Correction.Day(day: 100), heardIsWord: true, source: .ear)
        let data = try JSONEncoder().encode(ledger)
        let back = try JSONDecoder().decode(Correction.Ledger.self, from: data)
        #expect(back.earCorrections(at: Correction.Day(day: 100)) == ["inverse": "invoice"])
        // A file from before the field decodes as zero ear sightings.
        let old = Data("""
            {"entries":[{"heard":"chalan","meant":"Chalant","sightings":2,"lastSeen":100,"heardIsWord":false}],"forgotten":[]}
            """.utf8)
        let vintage = try JSONDecoder().decode(Correction.Ledger.self, from: old)
        #expect(vintage.earCorrections(at: Correction.Day(day: 100)).isEmpty)
        #expect(vintage.aliases(at: Correction.Day(day: 100))["chalan"] == "Chalant")
    }

}
