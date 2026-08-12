import AppKit
import Foundation
import os

/// Asks for permission to drive System Events, properly.
///
/// Discovering this through a failed `NSAppleScript` run does not work. The
/// consent prompt and the AppleEvent timeout are in a race: measured
/// 2026-08-12, with no timeout the insert hung for **120 seconds**, and with a
/// sane 3 second timeout the script gives up before the user can answer the
/// dialog, so the permission can never be granted through that path at all.
///
/// `AEDeterminePermissionToAutomateTarget` is the way out. It raises the same
/// system prompt, waits on the human rather than on an event timeout, and
/// returns a status instead of an exception. The script's short timeout then
/// only ever applies to a paste that is genuinely allowed.
enum AutomationPermission {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "insert")

    enum Outcome: Sendable {
        case granted
        case denied
        case failed(OSStatus)
    }

    /// Part 2 §5 wants permissions asked lazily and one at a time, so this is
    /// called on the first insertion rather than at launch.
    static func ensureSystemEvents(askUser: Bool = true) async -> Outcome {
        // `AEDeterminePermissionToAutomateTarget` answers -600 (procNotFound)
        // when the target is not running, and it will not start it. System
        // Events is launched on demand and is usually asleep, so the very
        // first insertion on a fresh login hits this instead of a prompt.
        // Wake it first, then ask.
        if !isSystemEventsRunning {
            await launchSystemEvents()
        }
        return determine(askUser: askUser)
    }

    private static var isSystemEventsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty
    }

    private static func launchSystemEvents() async {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let config = NSWorkspace.OpenConfiguration()
        // It is a faceless helper; never steal the user's focus for it.
        config.activates = false
        config.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            log.error("could not launch System Events: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func determine(askUser: Bool) -> Outcome {
        var target = AEAddressDesc()
        let bundleID = "com.apple.systemevents"

        // AECreateDesc returns OSErr (Int16), not OSStatus (Int32).
        let created: OSErr = bundleID.withCString { pointer in
            AECreateDesc(
                AEKeyword(typeApplicationBundleID),
                pointer,
                strlen(pointer),
                &target
            )
        }
        guard created == noErr else { return .failed(OSStatus(created)) }
        defer { AEDisposeDesc(&target) }

        // `typeWildCard` asks about the whole application rather than one
        // event, which is what the System Settings toggle actually governs.
        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUser
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            log.error("automation of System Events is denied")
            return .denied
        default:
            log.error("automation check returned \(status, privacy: .public)")
            return .failed(status)
        }
    }
}
