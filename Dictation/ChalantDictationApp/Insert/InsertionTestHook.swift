import AppKit
import ChalantDictationCore
import os

/// A way to exercise the insertion ladder without speaking.
///
/// M1 is about insertion, not transcription, and the 12-app protocol is 75
/// cells. Driving each one through the microphone makes every cell depend on
/// speech recognition succeeding, which turns a deterministic test of the
/// insertion path into a flaky one and buries insertion failures under
/// transcription noise.
///
/// So the hook inserts a known string on demand, through the real
/// `InsertionChain`, into whatever app is frontmost. Same tiers, same
/// pasteboard guard, same demotion. It changes nothing about the code being
/// tested; it only removes the microphone from the loop.
///
/// A distributed notification rather than a menu item, because clicking a menu
/// item would move focus to this app and destroy the very thing under test.
///
/// Debug builds only: `DEBUG` is set by the Xcode configuration, and a
/// release build has no observer at all, so nothing outside can ask a shipped
/// Chalant to type into the user's apps.
@MainActor
/// macOS 15+, inherited from `InsertionChain`. Debug builds only.
@available(macOS 15, *)
enum InsertionTestHook {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")
    static let notification = Notification.Name("com.cj.chalant.dictation.testInsert")

    #if DEBUG
    static func install(using chain: InsertionChain) {
        DistributedNotificationCenter.default().addObserver(
            forName: notification, object: nil, queue: .main
        ) { note in
            let text = note.userInfo?["text"] as? String ?? "the quick brown fox"
            // Seconds to wait between capturing the target and inserting, so
            // the focus race in global case 2 can actually be staged.
            let delay = Double(note.userInfo?["delay"] as? String ?? "0") ?? 0
            Task { @MainActor in
                let front = NSWorkspace.shared.frontmostApplication
                let target = InsertionTarget(
                    bundleID: front?.bundleIdentifier,
                    processID: front?.processIdentifier,
                    capturedAt: Date()
                )
                if delay > 0 {
                    log.info("TESTHOOK holding target for \(delay, privacy: .public)s")
                    try? await Task.sleep(for: .seconds(delay))
                }
                let started = Date()
                let outcome = await chain.insert(text, into: target)
                let elapsed = Date().timeIntervalSince(started)
                log.info(
                    """
                    TESTHOOK app=\(front?.bundleIdentifier ?? "unknown", privacy: .public) \
                    outcome=\(String(describing: outcome), privacy: .public) \
                    elapsed=\(elapsed, privacy: .public)s
                    """
                )
            }
        }
        log.info("insertion test hook installed (debug build)")
    }
    #else
    static func install(using chain: InsertionChain) {}
    #endif
}
