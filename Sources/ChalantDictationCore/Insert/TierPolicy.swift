import Foundation

/// Which insertion tiers to try for an app, and how the app earns a worse one.
///
/// The ladder is Part 0 §0.3's, not the original spec's: AppleScript System
/// Events first, `CGEvent` as a fallback that must verify after pasting
/// because macOS 26 can silently drop synthetic keystrokes, and the clipboard
/// floor as a first-class outcome.
///
/// The demotion is Part 8 §2's: two consecutive failures at a tier and the app
/// stops being offered it. "The app gets more reliable the more you use it,
/// without you configuring anything."
///
/// Pure, so the whole ladder is testable without a Mac in any state.
public enum TierPolicy {
    /// Two, not one. A single failure is as likely to be a stuck modifier or a
    /// window that lost focus as it is a genuine incompatibility, and demoting
    /// on it would strand an app on a worse tier for good.
    public static let failuresBeforeDemotion = 2

    /// The tiers to attempt, best first.
    public static func plan(for profile: AppProfile?) -> [InsertionTier] {
        let ceiling = profile?.maxInsertionTier ?? InsertionTier.systemEvents.rawValue
        return InsertionTier.allCases
            .filter { $0.rawValue >= ceiling }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Note a failure, demoting once the streak reaches the threshold.
    public static func recordingFailure(of tier: InsertionTier, in profile: AppProfile) -> AppProfile {
        var updated = profile
        let streak = (profile.consecutiveFailures[tier.rawValue] ?? 0) + 1
        updated.consecutiveFailures[tier.rawValue] = streak

        guard streak >= failuresBeforeDemotion else { return updated }

        // Nothing lives below the floor, so it cannot be demoted.
        guard let next = InsertionTier(rawValue: tier.rawValue + 1) else { return updated }

        // One-way: never raise the ceiling back toward a tier already refused.
        let current = updated.maxInsertionTier ?? InsertionTier.systemEvents.rawValue
        updated.maxInsertionTier = max(current, next.rawValue)
        updated.consecutiveFailures[tier.rawValue] = 0
        return updated
    }

    /// Note a success, which clears the streak but never promotes.
    ///
    /// Clearing matters so one bad afternoon does not permanently cost an app
    /// its best tier. Not promoting matters because an app that has already
    /// failed twice should not be able to charge the user two more failures
    /// just because a fallback happened to work once.
    public static func recordingSuccess(of tier: InsertionTier, in profile: AppProfile) -> AppProfile {
        var updated = profile
        updated.consecutiveFailures[tier.rawValue] = 0
        return updated
    }
}
