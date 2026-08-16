import ApplicationServices
import Foundation
import os

/// Whether this app may send keystrokes.
///
/// Distinct from the Input Monitoring grant the event tap needs, and distinct
/// again from Automation. All three are separate switches in System Settings,
/// and only this one governs whether System Events will actually type for us.
/// Without it the paste fails with `System Events got an error:
/// ChalantDictation is not allowed to send keystrokes.`, which names the app
/// rather than the permission and sends you looking in the wrong place.
///
/// Part 2 §5's permission list names Microphone, Accessibility, Automation and
/// Screen Recording. Measured on 2026-08-12, a working push-to-talk insert
/// needs **Microphone, Input Monitoring and Accessibility**, and Input
/// Monitoring is not in that list at all.
enum AccessibilityPermission {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Raises the system prompt, which offers a button straight to the right
    /// pane of System Settings. Returns the status as it stands now: the user
    /// answers in Settings, not in the dialog, so this is expected to report
    /// false on the first call.
    @discardableResult
    static func request() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a global `var` in the C headers, so
        // Swift 6 treats reading it as shared mutable state. The value is a
        // documented constant string; naming it directly keeps strict
        // concurrency satisfied without an unsafe opt-out.
        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        if !trusted {
            log.error("accessibility not granted; keystrokes will be refused")
        }
        return trusted
    }
}
