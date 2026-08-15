import Testing

@testable import ChalantDictationCore

/// The tier ladder and the demotion that makes it feel reliable over time.
///
/// Part 8 §2: "if Tier 1 fails twice for a bundle ID, permanently demote that
/// app to Tier 2. The app gets more reliable the more you use it, without you
/// configuring anything." Part 0 §0.3 then reordered the ladder itself:
/// AppleScript System Events is primary, CGEvent is a demoted fallback that
/// must verify after pasting, and the clipboard floor is a first-class
/// outcome rather than an apology.
@Suite("TierPolicy")
struct TierPolicyTests {
    private let slack = "com.tinyspeck.slackmacgap"

    @Test("an unknown app tries the full ladder in order")
    func unknownAppTriesEverything() {
        #expect(TierPolicy.plan(for: nil) == [.systemEvents, .cgEvent, .clipboardOnly])
    }

    @Test("one failure is not enough to demote")
    func oneFailureDoesNotDemote() {
        // A single failure can be a stuck modifier or a window that lost focus.
        // Demoting on it would strand an app on a worse tier forever.
        var profile = AppProfile(bundleID: slack)
        profile = TierPolicy.recordingFailure(of: .systemEvents, in: profile)
        #expect(profile.maxInsertionTier == nil)
        #expect(TierPolicy.plan(for: profile).first == .systemEvents)
    }

    @Test("two failures demote the app past System Events, permanently")
    func twoFailuresDemote() {
        var profile = AppProfile(bundleID: slack)
        profile = TierPolicy.recordingFailure(of: .systemEvents, in: profile)
        profile = TierPolicy.recordingFailure(of: .systemEvents, in: profile)

        #expect(profile.maxInsertionTier == InsertionTier.cgEvent.rawValue)
        #expect(TierPolicy.plan(for: profile) == [.cgEvent, .clipboardOnly])
    }

    @Test("a success clears the failure count so one bad day is not permanent")
    func successResets() {
        var profile = AppProfile(bundleID: slack)
        profile = TierPolicy.recordingFailure(of: .systemEvents, in: profile)
        profile = TierPolicy.recordingSuccess(of: .systemEvents, in: profile)
        profile = TierPolicy.recordingFailure(of: .systemEvents, in: profile)

        // Two failures total, but not consecutive: still no demotion.
        #expect(profile.maxInsertionTier == nil)
    }

    @Test("demotion cascades: CGEvent failing twice leaves only the floor")
    func cgEventDemotesToFloor() {
        var profile = AppProfile(bundleID: slack, maxInsertionTier: InsertionTier.cgEvent.rawValue)
        profile = TierPolicy.recordingFailure(of: .cgEvent, in: profile)
        profile = TierPolicy.recordingFailure(of: .cgEvent, in: profile)

        #expect(TierPolicy.plan(for: profile) == [.clipboardOnly])
    }

    @Test("the floor never demotes, because there is nothing below it")
    func floorIsTerminal() {
        var profile = AppProfile(bundleID: slack, maxInsertionTier: InsertionTier.clipboardOnly.rawValue)
        profile = TierPolicy.recordingFailure(of: .clipboardOnly, in: profile)
        profile = TierPolicy.recordingFailure(of: .clipboardOnly, in: profile)
        #expect(TierPolicy.plan(for: profile) == [.clipboardOnly])
    }

    @Test("a success at a worse tier never promotes the app back up")
    func successDoesNotPromote() {
        // Demotion is deliberately one-way and permanent per Part 8 §2. An app
        // that failed twice does not get to cost the user two more failures
        // just because the fallback worked once.
        var profile = AppProfile(bundleID: slack, maxInsertionTier: InsertionTier.cgEvent.rawValue)
        profile = TierPolicy.recordingSuccess(of: .cgEvent, in: profile)
        #expect(profile.maxInsertionTier == InsertionTier.cgEvent.rawValue)
    }
}
