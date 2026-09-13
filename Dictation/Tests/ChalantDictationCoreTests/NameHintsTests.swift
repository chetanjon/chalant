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

    /// The second ear's prompt is the one that pays for its own length: 0.05 s
    /// per name, in front of the words landing. A sentence with nothing
    /// name-shaped in it gets the floor, not the cap.
    @Test("the prompt stops at the standing floor when nothing sounds like a name")
    func promptStopsAtTheFloor() {
        let many = (1...40).map { "Standing\($0)" }
        let prompt = NameHints.select(
            heard: "Put the kettle on and close the window.",
            always: many, pool: contacts,
            standingFills: NameHints.promptStandingFloor)
        #expect(prompt.count == NameHints.promptStandingFloor)
        let matching = NameHints.select(
            heard: "Put the kettle on and close the window.",
            always: many, pool: contacts)
        #expect(matching.count == NameHints.promptLimit)
    }

    /// The floor is a floor, not a cap: a sentence full of sound-alikes still
    /// gets them, because they are the part that earns the slot.
    @Test("sound-alikes are never cut to make room for the floor")
    func floorNeverCutsTheSoundAlikes() {
        let prompt = NameHints.select(
            heard: "Deploy versal first, then super base, then friction lens.",
            always: pinned, pool: contacts,
            standingFills: NameHints.promptStandingFloor)
        #expect(prompt.contains("Vercel"))
        #expect(prompt.contains("Supabase"))
        #expect(prompt.contains("FrictionLens"))
    }

    /// The first ear writes Capgemini as "cap Gemini". "cap" is three letters,
    /// and the pair rule used to want `minimumProbeLength` from both halves,
    /// so "capgemini" was never built and the name it matches exactly was
    /// never offered. One half is enough (2026-09-13).
    @Test("a split name is found when only one half is a long word")
    func joinsSplitNamesWithAShortHalf() {
        let prompt = NameHints.select(
            heard: "I did real time payments in cap Gemini.",
            always: ["Capgemini", "Chalant", "Kizu"], pool: [],
            standingFills: 0)
        #expect(prompt.contains("Capgemini"))
        #expect(!prompt.contains("Kizu"))
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
