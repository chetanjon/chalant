import Foundation
import os

/// Tier 1: ask System Events to type ⌘V.
///
/// Part 0 §0.3 keeps this primary. Two independent reports show synthetic
/// CGEvent keystrokes silently dropped on macOS 26 while System Events
/// keystrokes from the same app identity land.
enum SystemEventsPaste {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")

    /// True when the script reported no error.
    static func run() -> Bool {
        // `with timeout` is not optional. Measured 2026-08-12: with Automation
        // ungranted the default AppleEvent timeout froze the insert for 120
        // seconds. Part 0 §0.3 also notes Tahoe made AppleScript error
        // retrieval dramatically slower (FB20174869), so failure paths need a
        // ceiling of their own.
        let script = """
        with timeout of 3 seconds
            tell application "System Events" to keystroke "v" using command down
        end timeout
        """
        guard let apple = NSAppleScript(source: script) else { return false }

        var error: NSDictionary?
        apple.executeAndReturnError(&error)

        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown AppleScript error"
            log.error("System Events paste failed: \(message, privacy: .public)")
            return false
        }
        return true
    }
}
