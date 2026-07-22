import AppKit
import AVFoundation
import Contacts
import EventKit
import Speech

/// One button in the welcome tour asks for everything the island
/// uses, so a new user is not ambushed by prompts one feature at a
/// time. Anything denied stays deniable; this only fronts the asking.
enum PermissionPrimer {
    static func primeAll() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                continuation.resume()
            }
        }
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToReminders()
        _ = try? await store.requestFullAccessToEvents()
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        primeRunningPlayers()
    }

    /// The player-control dialog can only be raised for an app that
    /// is running (Apple Events cannot ask about a program that is
    /// not there to answer), so this fronts the ask for whichever
    /// players already are. Everyone else meets the dialog the first
    /// time they play something, which at least is in context; found
    /// unanswered for a whole day on 2026-07-21.
    static func primeRunningPlayers() {
        for bundleID in ["com.spotify.client", "com.apple.Music"] {
            guard !NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .isEmpty else { continue }
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            _ = AEDeterminePermissionToAutomateTarget(
                target.aeDesc, typeWildCard, typeWildCard, true
            )
        }
    }
}
