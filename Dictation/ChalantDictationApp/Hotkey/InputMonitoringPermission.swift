import AppKit
import CoreGraphics
import Foundation
import Security
import os

/// Whether this app may WATCH the keyboard.
///
/// **The permission the app has never once asked for, and the one the hotkey
/// actually needs.** Distinct from Accessibility (which governs sending
/// keystrokes) and from Automation. Part 2 §5's permission list does not
/// mention it at all.
///
/// **Why it needs its own type rather than a comment.** `CGEvent.tapCreate`
/// SUCCEEDS without this grant. It returns a valid tap, the run loop source
/// attaches, `tapEnable` reports no error, and the tap then receives nothing
/// for the life of the process. Every log line says the hotkey installed
/// correctly. `Dictation.tapInstalled` is set from that return value and is
/// therefore not evidence of anything.
///
/// So the app can ship permanently deaf with no error anywhere, and the only
/// symptom is that holding the key does nothing.
///
/// **Second-order, and the reason the signing identity is recorded here.** TCC
/// decisions are tied to code identity. Re-signing with a different identity
/// can require a fresh grant, so the app can go deaf BETWEEN BUILDS with
/// nothing in the logs to explain it. Correlating a deaf state with a signing
/// change is otherwise guesswork.
enum InputMonitoringPermission {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "hotkey")

    /// Does this process already hold the grant? Never prompts.
    ///
    /// `CGPreflightListenEventAccess`, macOS 10.15+, verified present in the
    /// S0 SDK dump.
    static var isGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Ask for it. Raises the system prompt once per process; thereafter macOS
    /// returns the standing answer without showing anything.
    ///
    /// Returns the status as it stands NOW, which on a first run is false: the
    /// user answers in System Settings, not in the dialog, and usually has to
    /// relaunch. Callers must not read false as "denied forever".
    @discardableResult
    static func request() -> Bool {
        let granted = CGRequestListenEventAccess()
        if !granted {
            log.error("input monitoring not granted; the event tap will install and hear nothing")
        }
        return granted
    }

    /// One click into the exact pane. The same scheme the calendar and
    /// reminders recovery paths already use, with Input Monitoring's anchor.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// What this binary is signed as, for correlating a deaf tap with a
    /// re-sign.
    ///
    /// Returns nil rather than throwing: this is diagnostic, and a failure to
    /// read it must never affect whether dictation runs.
    static var signingIdentity: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return "unknown"
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return "unknown"
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return "unknown" }

        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String ?? "?"
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? "no-team"
        return "\(identifier)/\(team)"
    }
}
