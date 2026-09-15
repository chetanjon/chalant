import Testing

@testable import ChalantDictationCore

/// Whether the text arrived, and the three answers this is allowed to give.
///
/// **The check this replaces was not weak, it was wrong.** The fallback tier
/// asked `NSPasteboard.changeCount != placedAt` after sending ⌘V, but the
/// change count advances when something WRITES to the pasteboard and a paste
/// reads it. So it answered "did anybody copy something in the last 120 ms":
/// almost always no, so the tier reported failure on pastes that worked.
@Suite("LandingCheck")
struct LandingCheckTests {

    private func reading(_ length: Int, selection: Int = 0) -> LandingCheck.Reading {
        LandingCheck.Reading(length: length, selection: selection)
    }

    @Test("a field that grew confirms the paste")
    func grewIsConfirmed() {
        #expect(
            LandingCheck.verdict(before: reading(10), after: reading(28), inserted: 18)
                == .confirmed)
    }

    /// The common case, and the one the whole design turns on: Electron and
    /// web views report no focused element, which is most of the apps people
    /// dictate into. Part 1 §1 keeps accessibility out of the decision.
    @Test("a field that will not answer is uncertain, never a failure")
    func silenceIsUncertain() {
        #expect(LandingCheck.verdict(before: nil, after: reading(28), inserted: 18) == .uncertain)
        #expect(LandingCheck.verdict(before: reading(10), after: nil, inserted: 18) == .uncertain)
        #expect(LandingCheck.verdict(before: nil, after: nil, inserted: 18) == .uncertain)
        #expect(LandingCheck.countsAsFailure(.uncertain) == false)
    }

    @Test("a field that answered from a caret and did not move refutes it")
    func unchangedIsRefuted() {
        #expect(
            LandingCheck.verdict(before: reading(10), after: reading(10), inserted: 18) == .refuted)
        #expect(LandingCheck.countsAsFailure(.refuted))
    }

    /// **A selection makes length useless.** Pasting 18 characters over 18
    /// selected ones leaves the field exactly as long as it was, which is
    /// indistinguishable from nothing happening. Guessing wrong here would
    /// tell the user their words were lost while they are on screen.
    @Test("a paste over a selection is never refuted")
    func selectionIsUncertain() {
        #expect(
            LandingCheck.verdict(
                before: reading(40, selection: 18), after: reading(40), inserted: 18) == .uncertain)
        #expect(
            LandingCheck.verdict(
                before: reading(40, selection: 5), after: reading(40), inserted: 18) == .uncertain)
    }

    /// Something other than our paste changed the field. Not our evidence in
    /// either direction.
    @Test("a field that shrank is uncertain")
    func shrankIsUncertain() {
        #expect(
            LandingCheck.verdict(before: reading(40), after: reading(12), inserted: 18) == .uncertain)
    }

    @Test("nothing to insert is nothing to verify")
    func emptyIsUncertain() {
        #expect(
            LandingCheck.verdict(before: reading(10), after: reading(10), inserted: 0) == .uncertain)
    }

    /// The rule that keeps the ladder usable. Counting doubt as failure would
    /// demote every Electron app to the clipboard floor within two dictations,
    /// since they are exactly the apps that never answer.
    @Test("only a refusal counts against an app's tier")
    func onlyRefusalDemotes() {
        #expect(LandingCheck.countsAsFailure(.confirmed) == false)
        #expect(LandingCheck.countsAsFailure(.uncertain) == false)
        #expect(LandingCheck.countsAsFailure(.refuted) == true)
    }

    /// An insertion still reads as inserted when nobody could verify it, so
    /// the outcome's default must be the permissive one.
    @Test("an outcome with no verdict given is uncertain, not confirmed")
    func outcomeDefaultsToUncertain() {
        #expect(InsertionOutcome.inserted(tier: .systemEvents) == .inserted(tier: .systemEvents, landing: .uncertain))
    }
}
