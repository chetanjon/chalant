import AppKit
import ChalantDictationCore
import Foundation
import os

/// Puts text where the user's cursor is, by asking System Events to paste.
///
/// **AppleScript is primary, and there is no Accessibility-set tier at all.**
/// Part 1 §1 removed it: Electron and web apps report no focused element, so
/// an AX gate silently refuses to paste into Slack and VS Code, which are the
/// two targets that matter most. Part 0 §0.3 then demoted the `CGEvent`
/// fallback further still, because synthetic keystrokes can be silently
/// dropped on macOS 26 even with Accessibility and Input Monitoring granted,
/// while System Events keystrokes from the same app identity land.
///
/// M0 is the thin slice, so this is the AppleScript tier only. The `CGEvent`
/// fallback, the clipboard-only floor, pasteboard snapshot and restore, and
/// per-app tier demotion are all M1.
///
/// **M0 clobbers the clipboard on every insertion.** That is honest to the
/// milestone rather than an oversight: Part 3 puts "pasteboard snapshot with
/// sentinel restore" in M1, and Part 0 §0.2 requires that snapshot to be
/// redesigned around macOS 26's pasteboard privacy model before it is written.
actor SystemEventsInserter: TextInserter {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")

    func insert(_ text: String, into target: InsertionTarget) async -> InsertionOutcome {
        guard !text.isEmpty else { return .refused(reason: .noTarget) }

        // Dictating into a password field is an incident, not a bug, and while
        // secure input is on the paste would be silently dropped anyway.
        if SecureInputProbe.isActive {
            Self.log.error("refusing to insert: secure input is active")
            return .refused(reason: .secureInputActive(holder: nil))
        }

        // Part 2 §6: if the user is still holding the dictation key, the
        // synthesized paste arrives corrupted. Wait, bounded, for the
        // modifiers to clear.
        await Self.waitForClearModifiers()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let script = """
        tell application "System Events" to keystroke "v" using command down
        """

        var error: NSDictionary?
        // NSAppleScript must be built and run off the main thread here, and
        // Part 1 §3 bans swallowing errors into `try?` on the insertion path,
        // so the error dictionary is inspected rather than discarded.
        guard let apple = NSAppleScript(source: script) else {
            return .leftOnClipboard(reason: "could not compile the paste script")
        }
        apple.executeAndReturnError(&error)

        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
            Self.log.error("System Events paste failed: \(message, privacy: .public)")
            // The text is still on the clipboard, so it is not lost. Part 1
            // §2's invariant holds even on the failure path.
            return .leftOnClipboard(reason: message)
        }

        Self.log.info("inserted \(text.count, privacy: .public) characters into \(target.bundleID ?? "unknown", privacy: .public)")
        return .inserted(tier: .systemEvents)
    }

    /// Poll `NSEvent.modifierFlags` until the user has let go, up to a ceiling.
    ///
    /// Bounded rather than open-ended: a stuck modifier must degrade into a
    /// slightly-wrong paste rather than a hang.
    private static func waitForClearModifiers(timeout: TimeInterval = 0.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = await MainActor.run { NSEvent.modifierFlags }
            if flags.intersection([.command, .option, .control, .shift]).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}
