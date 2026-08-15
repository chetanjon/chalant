import Foundation
import Testing

@testable import ChalantDictationCore

/// Global case 2 of the M1 protocol: "Focus stolen mid-dictation → must refuse
/// or clipboard-fall-back, **never insert into the wrong app**."
///
/// Observed live on 2026-08-12: an insertion aimed at Terminal landed in a
/// browser, because the target was captured at key-down and never re-checked
/// at the moment of pasting. For a dictation tool that is the worst available
/// failure, since the text being misplaced is whatever the user just said.
@Suite("TargetGuard")
struct TargetGuardTests {
    private func target(_ bundle: String?, _ pid: pid_t?) -> InsertionTarget {
        InsertionTarget(bundleID: bundle, processID: pid, capturedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("the same process proceeds")
    func samePID() {
        let t = target("com.apple.Terminal", 42)
        #expect(TargetGuard.check(target: t, frontBundleID: "com.apple.Terminal", frontPID: 42) == .proceed)
    }

    @Test("the same app under a different process still proceeds")
    func sameBundleDifferentPID() {
        // Some apps front a helper process, and an app can be relaunched
        // between key-down and key-up. Same bundle is the same destination as
        // far as the user is concerned.
        let t = target("com.apple.Terminal", 42)
        #expect(TargetGuard.check(target: t, frontBundleID: "com.apple.Terminal", frontPID: 99) == .proceed)
    }

    @Test("a different app is refused, and both names are reported")
    func differentApp() {
        let t = target("com.apple.Terminal", 42)
        let verdict = TargetGuard.check(
            target: t, frontBundleID: "ai.perplexity.comet", frontPID: 77
        )
        // The exact case seen live.
        #expect(verdict == .changed(from: "com.apple.Terminal", to: "ai.perplexity.comet"))
    }

    @Test("an unreadable front app refuses rather than guessing")
    func unknownFront() {
        let t = target("com.apple.Terminal", 42)
        #expect(TargetGuard.check(target: t, frontBundleID: String?.none, frontPID: pid_t?.none) == .unknown)
    }

    @Test("a target with no identity at all refuses")
    func unknownTarget() {
        // Nothing to compare against is not permission to paste anywhere.
        let t = target(String?.none, pid_t?.none)
        #expect(TargetGuard.check(target: t, frontBundleID: "com.apple.Terminal", frontPID: 42) == .unknown)
    }

    @Test("a PID match wins even when the bundle identifier is missing")
    func pidMatchWithoutBundle() {
        let t = target(String?.none, 42)
        #expect(TargetGuard.check(target: t, frontBundleID: String?.none, frontPID: 42) == .proceed)
    }
}
