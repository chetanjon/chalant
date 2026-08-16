import AppKit
import CoreGraphics
import os

/// The second tier: synthesize ⌘V directly, when System Events will not.
///
/// **Part 0 §0.3 demoted this and attached a condition.** Two independent
/// reports show synthetic `CGEvent` keystrokes being silently dropped on macOS
/// 26 even with Accessibility and Input Monitoring granted, while AppleScript
/// System Events keystrokes from the same app identity land. So this is a
/// fallback rather than the workhorse the original spec made it, and:
///
/// > every use must **verify-after-paste** (changeCount consumption or
/// > read-back) — "event sent" is not "text landed".
///
/// A tier that cannot prove it worked is a tier that quietly loses text, which
/// Part 1 §2 forbids outright.
enum CGEventInserter {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")

    /// `kVK_ANSI_V`.
    private static let vKeyCode: CGKeyCode = 9

    /// Send ⌘V to the frontmost app. Says only whether the events were posted;
    /// whether the paste LANDED is the caller's job to verify.
    static func sendPaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("no event source for synthetic paste")
            return
        }
        // Suppress our own synthetic events from being seen as user input by
        // this process, so the dictation hotkey tap cannot react to them.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
