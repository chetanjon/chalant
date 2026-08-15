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

    /// Bring dictation up. Safe to call when unsupported or switched off; it
    /// simply does nothing, so callers do not need their own guard.
    func start(defaults: UserDefaults = .standard) {
        guard Self.isOpen(in: defaults) else { return }
        guard stack == nil else { return }
        guard #available(macOS 26, *) else { return }

        let live = DictationStack()
        tapInstalled = live.start()
        stack = live

        if tapInstalled {
            Self.log.info("dictation is listening for the hold key")
        } else {
            // Not an error state to crash on: the user has to grant something,
            // and the surface that offers the switch is where that is said.
            Self.log.error("dictation started but the event tap did not install")
        }
    }

    func stop() {
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
