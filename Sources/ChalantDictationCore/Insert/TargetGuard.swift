import Foundation

/// Is the text still going where the user aimed it?
///
/// Global case 2 of the M1 protocol says focus stolen mid-dictation must never
/// insert into the wrong app. The chain originally captured the target at
/// key-down and checked it once at key-up, which leaves everything after that
/// unguarded: the modifier-clear wait alone can run 500ms, and the permission
/// checks, context read and pasteboard work all happen after it.
///
/// Observed live 2026-08-12: an insertion aimed at Terminal landed in a
/// browser.
///
/// Pure, so the decision is testable without arranging a focus change on a
/// real Mac. The caller supplies what the system currently reports.
public enum TargetGuard {
    public enum Verdict: Sendable, Equatable {
        case proceed
        /// The front app is not the one aimed at. Both are named so the user
        /// can be told where their words went instead of nowhere.
        case changed(from: String?, to: String?)
        /// Not determinable. Treated as a refusal: nothing to compare against
        /// is not permission to paste anywhere.
        case unknown
    }

    public static func check(
        target: InsertionTarget,
        frontBundleID: String?,
        frontPID: pid_t?
    ) -> Verdict {
        // Same process is the strongest signal available.
        if let wanted = target.processID, let actual = frontPID, wanted == actual {
            return .proceed
        }

        // Same app is good enough: apps front helper processes, and an app can
        // be relaunched between key-down and the paste. The user aimed at the
        // app, not the process.
        if let wanted = target.bundleID, let actual = frontBundleID {
            return wanted == actual ? .proceed : .changed(from: wanted, to: actual)
        }

        // One side is unidentifiable. Refuse rather than guess: the cost of a
        // wrong guess is the user's words in someone else's window.
        return .unknown
    }
}
