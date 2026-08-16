import Foundation
import os

/// Hold-to-dictate, and the one place that decides whether it exists here.
///
/// Merged from the standalone build 2026-08-15. It is a different job from
/// everything else under Voice: `VoiceController` turns speech into island
/// commands, this turns speech into text at whatever cursor you were already
/// using. Two doors, deliberately kept separate.
///
/// This type exists to keep the availability dance in one file. Chalant ships a
/// macOS 15 floor and `SpeechTranscriber` is macOS 26 with no backport, so the
/// whole dictation stack lives behind `@available` and cannot be named from
/// ordinary code. Everything below stores it as `AnyObject` and unwraps it
/// inside one `#available` check.
@MainActor
final class Dictation {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "dictation")

    /// One instance, because the settings toggle and the app lifecycle both
    /// need to reach the same event tap. Without this, turning the switch on
    /// would only take effect after a relaunch, and a switch that appears to do
    /// nothing is worse than no switch.
    static let shared = Dictation()

    /// Whether this OS has the engine at all.
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The user's own switch. Defaults to off, and that is not timidity.
    ///
    /// Installing the event tap is what raises the Input Monitoring and
    /// Accessibility asks. Doing that at launch would hand every existing
    /// Chalant user two permission prompts they did not ask for, on an update
    /// whose release notes they have not read yet. Part 2 §5 is explicit:
    /// lazily, one at a time, never at launch. So the switch is the consent,
    /// and turning it on is what triggers the asks.
    static let enabledKey = "dictationEnabled"

    /// Read through a seam rather than `UserDefaults.standard`, because a test
    /// that touches the real domain edits the running app's settings.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    /// Whether the door is really open on this machine: the OS can do it and
    /// the user has said yes. This is what `VoiceDoor.shipped` must be told,
    /// because a door that needs an OS you do not have, or a switch you have
    /// not flipped, is not a door.
    static func isOpen(in defaults: UserDefaults = .standard) -> Bool {
        isSupported && isEnabled(in: defaults)
    }

    /// The live stack, when running. `DictationController` on macOS 26.
    private var stack: AnyObject?

    /// Whether the event tap actually installed.
    ///
    /// Worth its own property because the failure is silent and misleading:
    /// without Input Monitoring, `CGEvent.tapCreate` succeeds and logs that the
    /// tap is installed while receiving no events at all. "Started" is not
    /// "hearing", and any UI that reports this must not conflate them.
    private(set) var tapInstalled = false

    var isRunning: Bool { stack != nil }

    /// What the user needs to be told, if anything.
    ///
    /// **This exists because the app could previously be permanently deaf while
    /// every log said the hotkey installed correctly.** The only symptom was
    /// that holding the key did nothing, which reads as a broken app rather
    /// than a missing switch.
    enum Hearing: Equatable {
        /// Grant held and the tap has received at least one real event.
        case hearing
        /// Grant not held. Terminal until the user acts, and the app must say so.
        case notPermitted
        /// Grant held, tap installed, and nothing has arrived yet. Not an error
        /// on its own: nobody may have touched a modifier key yet.
        case unproven
        /// Grant held, tap installed, the app has been in use, and STILL
        /// nothing has arrived. This is the deaf state that used to be
        /// invisible.
        case suspect
    }

    /// How many times `checkHearing` may find nothing before calling it
    /// suspect. Each check happens on a real interaction, so this is "the user
    /// has done several things and the tap saw none of them".
    private static let suspicionThreshold = 3
    private var quietChecks = 0

    private(set) var hearing: Hearing = .unproven

    /// Re-read the tap's health. Call on interaction, not on a timer: the
    /// question is "the user is doing things, is the tap seeing them", and a
    /// timer would answer it while the machine sits idle and report nonsense.
    @discardableResult
    func checkHearing() -> Hearing {
        guard isRunning else { return hearing }

        // Re-preflight every time: the grant can be revoked while running, and
        // that transition is one of the acceptance tests.
        guard InputMonitoringPermission.isGranted else {
            quietChecks = 0
            hearing = .notPermitted
            return hearing
        }

        guard #available(macOS 26, *), let live = stack as? DictationStack else { return hearing }

        if live.hasHeardAnything {
            quietChecks = 0
            hearing = .hearing
            return hearing
        }

        quietChecks += 1
        hearing = quietChecks >= Self.suspicionThreshold ? .suspect : .unproven
        if hearing == .suspect {
            Self.log.error(
                "event tap has received nothing after \(self.quietChecks, privacy: .public) checks; likely deaf"
            )
        }
        return hearing
    }

    /// Bring dictation up. Safe to call when unsupported or switched off; it
    /// simply does nothing, so callers do not need their own guard.
    func start(defaults: UserDefaults = .standard) {
        guard Self.isOpen(in: defaults) else { return }
        guard stack == nil else { return }
        guard #available(macOS 26, *) else { return }

        // Ask BEFORE creating the tap. Without this the tap installs, reports
        // success, and hears nothing, and the user is never told why. The
        // prompt appears once per process; afterwards macOS returns the
        // standing answer silently.
        let permitted = InputMonitoringPermission.isGranted || InputMonitoringPermission.request()

        let live = DictationStack()
        tapInstalled = live.start()
        stack = live
        quietChecks = 0
        hearing = permitted ? .unproven : .notPermitted

        // The signing identity, because TCC is keyed to code identity and a
        // re-sign can revoke this grant with nothing in the logs to say so.
        // Belongs in the session journal when S7 lands; logged here meanwhile
        // so the correlation is at least possible today.
        Self.log.info(
            """
            dictation started: tap=\(self.tapInstalled, privacy: .public) \
            inputMonitoring=\(permitted, privacy: .public) \
            signedAs=\(InputMonitoringPermission.signingIdentity, privacy: .public)
            """
        )

        if !permitted {
            // Not an error to crash on, and not something to leave silent
            // either. The switch that turned this on is where it gets said.
            Self.log.error("dictation cannot hear: Input Monitoring is not granted")
        }
    }

    func stop() {
        hearing = .unproven
        quietChecks = 0
        guard #available(macOS 26, *), let live = stack as? DictationStack else {
            stack = nil
            tapInstalled = false
            return
        }
        live.stop()
        stack = nil
        tapInstalled = false
    }
}

/// The macOS 26 half, kept private so nothing outside this file has to carry
/// the availability annotation.
@available(macOS 26, *)
@MainActor
private final class DictationStack {
    private let controller = DictationController()
    private var monitor: EventTapMonitor?

    /// Whether the tap has received a single real event. See
    /// `EventTapMonitor.hasHeardAnything`.
    var hasHeardAnything: Bool { monitor?.hasHeardAnything ?? false }

    /// Returns whether the event tap installed.
    func start() -> Bool {
        let monitor = EventTapMonitor { [weak self] down in
            guard let self else { return }
            Task { down ? await self.controller.keyDown() : await self.controller.keyUp() }
        }
        self.monitor = monitor
        let installed = monitor.start()

        // Debug-only, and a no-op in release: drives the real insertion chain
        // with a known string so a test can exercise insertion without speech.
        InsertionTestHook.install(using: controller.insertionChain)

        // Warming is what makes the first hold feel like the tenth:
        // `prepareToAnalyze` and the asset state machine both run here rather
        // than on the critical path at key-down.
        Task { await controller.warmUp() }
        return installed
    }

    func stop() {
        monitor?.stop()
        monitor = nil
    }
}
