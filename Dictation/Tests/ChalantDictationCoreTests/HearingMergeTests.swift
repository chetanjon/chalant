import Foundation
import Testing

@testable import ChalantDictationCore

/// Two ears, one sentence, and who wins each word.
///
/// **Every case in here is a real row from the founder's own corpus**, dated,
/// because the whole reason this type exists is that the app was computing
/// these corrections and throwing them away. The wins are the corrections it
/// lost. The refusals are the hearings that were WORSE than what landed, and
/// they matter more: a wrong merge is invisible, because the user never sees
/// the version it replaced.
@Suite("HearingMerge")
struct HearingMergeTests {

    /// The engine's side, with a confidence on every word. Sub-floor values
    /// mean the engine doubted itself, which is what it does on most of the
    /// words it gets wrong.
    private func engine(_ text: String, confidence: Double = 0.5) -> [Token] {
        text.split(separator: " ").map { Token(text: String($0), confidence: confidence) }
    }

    private func signals(
        words: [String] = [], vocabulary: [String] = [], quality: HearingMerge.Quality = .init()
    ) -> HearingMerge.Signals {
        HearingMerge.Signals(
            knownWords: Set(words.map { HearingMerge.bare($0) }), vocabulary: vocabulary,
            quality: quality)
    }

    private func text(_ outcome: HearingMerge.Outcome) -> String {
        outcome.tokens.map(\.text).joined(separator: " ")
    }

    // MARK: - The corrections the app was throwing away

    @Test("the recruiter it heard as agriculture")
    func recoversARealMishearing() {
        // cap-20260904-012625-935, landed in Chrome, ear discarded as userActed.
        let outcome = HearingMerge.merge(
            engine: engine("Do you think agriculture is going to read all of that?"),
            ear: "Do you think a recruiter is going to read all of that?",
            signals: signals(words: [
                "do", "you", "think", "agriculture", "is", "going", "to", "read", "all", "of",
                "that", "a", "recruiter",
            ]))
        #expect(text(outcome) == "Do you think a recruiter is going to read all of that?")
        #expect(outcome.verdict == .merged)
    }

    @Test("the commas it heard as commerce")
    func recoversAnOrdinaryWordForAnOrdinaryWord() {
        // cap-20260903-143200-203. Both words are ordinary English, which is
        // why a dictionary shield would refuse this and must not be used here.
        let outcome = HearingMerge.merge(
            engine: engine("There are a lot of commerce here"),
            ear: "There are a lot of commas here",
            signals: signals(words: [
                "there", "are", "a", "lot", "of", "commerce", "commas", "here",
            ]))
        #expect(text(outcome) == "There are a lot of commas here")
    }

    @Test("the option button it heard as an auction button")
    func recoversTheOptionKey() {
        // cap-20260903-123624-725 and again in -173922-822, both noUndoHere.
        let outcome = HearingMerge.merge(
            engine: engine("When I press the auction button"),
            ear: "When I press the option button",
            signals: signals(words: [
                "when", "i", "press", "the", "auction", "option", "button",
            ]))
        #expect(text(outcome) == "When I press the option button")
    }

    @Test("a name the engine could not spell")
    func theEngineWritingANonWordLosesEvenWhenItIsSure() {
        // cap-20260903-1304xx: three attempts at the founder's own surname,
        // three non-words, and the engine was not always unsure about them.
        let outcome = HearingMerge.merge(
            engine: engine("Chetan Journalagada", confidence: 0.95),
            ear: "Chetan Jonnalagadda",
            signals: signals(words: ["chetan"], vocabulary: ["Jonnalagadda", "Chetan"]))
        #expect(text(outcome) == "Chetan Jonnalagadda")
    }

    @Test("the negation that reversed the sentence")
    func recoversADroppedNegation() {
        // cap-20260903-130505-007. The ear had it and the fix was discarded:
        // the founder said the opposite of what shipped.
        let outcome = HearingMerge.merge(
            engine: engine("I want the box"),
            ear: "I don't want the box",
            signals: signals(words: ["i", "want", "the", "box", "dont"]))
        #expect(text(outcome) == "I don't want the box")
        #expect(outcome.negationChanges == 1)
    }

    // MARK: - The hearings that were worse, which must never win

    @Test("the role it misheard as a troll")
    func refusesTheEarWhenTheEngineWasSure() {
        // cap-20260904-014520-257: what landed was RIGHT and the ear wanted to
        // break it. Both words are real, so only confidence separates them.
        let outcome = HearingMerge.merge(
            engine: engine("a good fit for that role at all?", confidence: 0.93),
            ear: "a good fit for the troll at all?",
            signals: signals(words: [
                "a", "good", "fit", "for", "that", "role", "the", "troll", "at", "all",
            ]))
        #expect(text(outcome) == "a good fit for that role at all?")
        #expect(outcome.verdict == .agreed)
    }

    @Test("strong-legry is not a word and never wins")
    func refusesAnInventedWord() {
        // cap-20260902-182413-695, and the engine was UNSURE here, so
        // confidence alone would have taken the ear's side.
        let outcome = HearingMerge.merge(
            engine: engine("I strongly agree with that", confidence: 0.4),
            ear: "I strong-legry with that",
            signals: signals(words: ["i", "strongly", "agree", "with", "that"]))
        #expect(text(outcome) == "I strongly agree with that")
    }

    @Test("a name the user taught us is never corrected into English")
    func theVocabularyProtectsTheEngine() {
        // The 2026-08-16 lesson, restated for the merge: "challenge" for
        // Chalant would be a one-way door if the ear could win it.
        let outcome = HearingMerge.merge(
            engine: engine("ship Chalant today", confidence: 0.4),
            ear: "ship challenge today",
            signals: signals(
                words: ["ship", "challenge", "today"], vocabulary: ["Chalant"]))
        #expect(text(outcome) == "ship Chalant today")
    }

    @Test("an invented sentence is refused whole")
    func refusesAnImplausibleHearing() {
        // "Baddie wannabe." on a starved microphone, measured 2026-08-17.
        let outcome = HearingMerge.merge(
            engine: engine("I think we should ship it on Thursday afternoon"),
            ear: "Baddie wannabe.")
        #expect(text(outcome) == "I think we should ship it on Thursday afternoon")
        #expect(outcome.verdict == .implausible)
    }

    @Test("a hearing the ear itself doubts is refused whole")
    func refusesOnQuality() {
        let outcome = HearingMerge.merge(
            engine: engine("the meeting is at noon"),
            ear: "the meeting was at noon",
            signals: signals(
                words: ["the", "meeting", "is", "was", "at", "noon"],
                quality: HearingMerge.Quality(noSpeechProbability: 0.9)))
        #expect(text(outcome) == "the meeting is at noon")
        #expect(outcome.verdict == .qualityRejected)
    }

    @Test("two different sentences are not merged")
    func refusesWhenTheyBarelyAgree() {
        let outcome = HearingMerge.merge(
            engine: engine("send the invoice to Priya before Friday"),
            ear: "corner the office through media offer sunny",
            signals: signals(words: [
                "send", "the", "invoice", "to", "priya", "before", "friday", "corner", "office",
                "through", "media", "offer", "sunny",
            ]))
        #expect(text(outcome) == "send the invoice to Priya before Friday")
        #expect(outcome.verdict == .tooMuchDisagreement)
    }

    @Test("the ear never adds content")
    func refusesAnInsertionThatIsNotANegation() {
        // cap-20260903-181506-095: "Shut up, guys" arrived in a sentence
        // nobody said it in.
        let outcome = HearingMerge.merge(
            engine: engine("Is it working?"),
            ear: "Shut up guys Is it working?",
            signals: signals(words: ["is", "it", "working", "shut", "up", "guys"]))
        #expect(text(outcome) == "Is it working?")
    }

    @Test("the engine never loses a word to the ear's silence")
    func keepsWhatOnlyTheEngineHeard() {
        let outcome = HearingMerge.merge(
            engine: engine("send it to Priya tomorrow morning"),
            ear: "send it to Priya morning",
            signals: signals(words: [
                "send", "it", "to", "priya", "tomorrow", "morning",
            ]))
        #expect(text(outcome) == "send it to Priya tomorrow morning")
    }

    @Test("digits stay with the engine")
    func refusesToTouchNumbers() {
        let outcome = HearingMerge.merge(
            engine: engine("transfer 4500 to the account", confidence: 0.3),
            ear: "transfer 4900 to the account",
            signals: signals(words: ["transfer", "to", "the", "account"]))
        #expect(text(outcome) == "transfer 4500 to the account")
    }

    @Test("a substitution may not quietly flip a negation")
    func refusesANegationSubstitutionWhenTheEngineWasNotDesperate() {
        let outcome = HearingMerge.merge(
            engine: engine("we can ship it", confidence: 0.7),
            ear: "we cannot ship it",
            signals: signals(words: ["we", "can", "cannot", "ship", "it"]))
        #expect(text(outcome) == "we can ship it")
    }

    // MARK: - Shape

    @Test("the engine keeps the punctuation around a replaced word")
    func punctuationSurvivesASubstitution() {
        let outcome = HearingMerge.merge(
            engine: engine("I need the commerce, then we ship."),
            ear: "I need the commas then we ship",
            signals: signals(words: [
                "i", "need", "the", "commerce", "commas", "then", "we", "ship",
            ]))
        #expect(text(outcome) == "I need the commas, then we ship.")
    }

    @Test("a replacement at the start of a sentence is still capitalised")
    func capitalisationSurvivesASubstitution() {
        let outcome = HearingMerge.merge(
            engine: engine("Agriculture will read it"),
            ear: "a recruiter will read it",
            signals: signals(words: ["agriculture", "a", "recruiter", "will", "read", "it"]))
        #expect(text(outcome) == "A recruiter will read it")
    }

    @Test("agreement changes nothing and says so")
    func agreementIsANoOp() {
        let outcome = HearingMerge.merge(
            engine: engine("ship it on Thursday"),
            ear: "ship it on Thursday",
            signals: signals(words: ["ship", "it", "on", "thursday"]))
        #expect(text(outcome) == "ship it on Thursday")
        #expect(outcome.verdict == .agreed)
        #expect(outcome.disputedSpans == 0)
    }

    @Test("an empty hearing changes nothing")
    func emptyHearingIsANoOp() {
        let outcome = HearingMerge.merge(engine: engine("ship it on Thursday"), ear: "")
        #expect(text(outcome) == "ship it on Thursday")
        #expect(outcome.verdict == .earEmpty)
    }

    @Test("every decision names itself for the row")
    func spansCarryTheirReasons() {
        let outcome = HearingMerge.merge(
            engine: engine("There are a lot of commerce here"),
            ear: "There are a lot of commas here",
            signals: signals(words: [
                "there", "are", "a", "lot", "of", "commerce", "commas", "here",
            ]))
        let dispute = outcome.spans.first { $0.kind == .substitution }
        #expect(dispute?.reason == "theEarLeads")
        #expect(dispute?.choseEar == true)
    }

    // MARK: - The policies differ only where the refusals allowed a choice

    @Test("engineLeads keeps a word the engine was merely unsure about")
    func policiesDisagreeOnSurvivingDisputes() {
        let heard = engine("There are a lot of commerce here", confidence: 0.75)
        let known = signals(words: [
            "there", "are", "a", "lot", "of", "commerce", "commas", "here",
        ])
        let leading = HearingMerge.merge(
            engine: heard, ear: "There are a lot of commas here", signals: known,
            policy: .earLeads)
        let following = HearingMerge.merge(
            engine: heard, ear: "There are a lot of commas here", signals: known,
            policy: .engineLeads)
        #expect(text(leading) == "There are a lot of commas here")
        #expect(text(following) == "There are a lot of commerce here")
    }

    @Test("no policy can take an invented word or a number")
    func theRefusalsHoldUnderEveryPolicy() {
        for policy in HearingMerge.Policy.allCases {
            let invented = HearingMerge.merge(
                engine: engine("I strongly agree", confidence: 0.2),
                ear: "I strong-legry",
                signals: signals(words: ["i", "strongly", "agree"]), policy: policy)
            #expect(text(invented) == "I strongly agree")

            let numbers = HearingMerge.merge(
                engine: engine("transfer 4500 now", confidence: 0.2),
                ear: "transfer 4900 now",
                signals: signals(words: ["transfer", "now"]), policy: policy)
            #expect(text(numbers) == "transfer 4500 now")
        }
    }

    // MARK: - Alignment

    @Test("alignment finds the added word rather than shifting everything")
    func alignmentHandlesAnInsertion() {
        let spans = HearingMerge.align(
            engine: engine("I want the box"), ear: ["I", "don't", "want", "the", "box"])
        #expect(spans.map(\.kind) == [.agreed, .insertion, .agreed])
        #expect(spans[1].ear == ["don't"])
    }
}
