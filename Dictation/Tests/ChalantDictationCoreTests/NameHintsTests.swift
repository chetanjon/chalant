import Testing

@testable import ChalantDictationCore

/// The names both ears are handed for one utterance, chosen by what the first
/// ear heard. Every number here is from `verification/NAMES_2026-08-18.md`.
@Suite("NameHints")
struct NameHintsTests {

    let pinned = ["Chalant", "Kizu", "Aatram", "Gangothri"]
    let contacts = [
        "Priya", "Sanjay", "Lakshmi", "Venkat", "Rohan", "Ananya", "Michael", "Jennifer",
        "Sara", "Sarah", "Vercel", "Supabase", "FrictionLens", "Jonnalagadda", "SpeechAnalyzer",
    ]

    /// Measured on Set E: a name pulled in because it sounds like a word the
    /// first ear produced is what took the second ear from 14.7% to 10.0%.
    @Test("a name that sounds like something heard is offered")
    func offersSoundAlikes() {
        let heard = NameHints.select(
            heard: "Deploy versal first, then figma, then super bass.",
            always: pinned, pool: contacts)
        #expect(heard.contains("Vercel"))
        #expect(!heard.contains("Priya"))
        #expect(!heard.contains("Michael"))
    }

    /// A name the first ear broke into two words is found from the pair.
    @Test("a split name is reachable from the two halves")
    func joinsSplitNames() {
        let heard = NameHints.select(
            heard: "Ask Athram, weather friction lens is ready for Gangotri.",
            always: pinned, pool: contacts)
        #expect(heard.contains("FrictionLens"))
    }

    /// The pinned and learned names go every time; the sound-alikes follow.
    @Test("the standing names come first and the sound-alikes after")
    func standingNamesLeadTheList() {
        let heard = NameHints.select(
            heard: "Chetan Journalagada signed the release.",
            always: pinned, pool: contacts)
        #expect(Array(heard.prefix(pinned.count)) == pinned)
        #expect(heard.contains("Jonnalagadda"))
    }

    /// Set E: 34 names cost 2.17 s and heard worse than 20 (18.6% against
    /// 14.7%). The prompt is capped, and the sound-alikes are never the part
    /// that gets cut, because they are the part that earns the slot.
    @Test("the list is capped and the sound-alikes survive the cap")
    func capsWithoutCuttingTheSoundAlikes() {
        let many = (1...40).map { "Standing\($0)" }
        let heard = NameHints.select(
            heard: "Chetan Journalagada signed the release.",
            always: many, pool: contacts)
        #expect(heard.count == NameHints.promptLimit)
        #expect(heard.contains("Jonnalagadda"))
        #expect(heard.first == "Standing1")
    }

    /// Short words sound like everything ("and" reaches Amanda, Andrew,
    /// Ananya at 0.6); they are not evidence of a name.
    @Test("short heard words are not probes")
    func shortWordsAreNotProbes() {
        let heard = NameHints.select(
            heard: "and the one at ten", always: [], pool: ["Ananya", "Andrew", "Amanda", "Ethan"])
        #expect(heard.isEmpty)
    }

    @Test("a name is offered once however many lists it is in")
    func dedupes() {
        let heard = NameHints.select(
            heard: "Send it to Kizu.", always: ["Kizu", "kizu"], pool: ["Kizu", "Kisu"])
        #expect(heard.filter { $0.lowercased() == "kizu" }.count == 1)
    }

    /// The prompt Whisper reads: comma-separated, one trailing period. On Set
    /// E the period cost nothing and kept the ear's own punctuation intact.
    @Test("the prompt is a comma list with one closing period")
    func promptShape() {
        #expect(NameHints.prompt(["Chalant", "Kizu"]) == "Chalant, Kizu.")
        #expect(NameHints.prompt([]) == "")
    }

    /// The phonetic pass wants a bigger list (its own cap is 100) but the same
    /// selection: standing names, then whatever in the pool sounds like the
    /// utterance. Nothing from the pool that does not.
    @Test("the matching list is the same selection at a larger cap")
    func matchingListUsesTheSameSelection() {
        let list = NameHints.select(
            heard: "Priya is away and Sara said so.", always: pinned, pool: contacts,
            limit: 100)
        #expect(list.contains("Priya"))
        #expect(list.contains("Sara"))
        #expect(list.contains("Sarah"))
        #expect(!list.contains("Vercel"))
    }
}
