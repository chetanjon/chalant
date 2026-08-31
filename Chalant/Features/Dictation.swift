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

    /// The island. Set once by the app after the notch controller exists;
    /// before that, dictation cannot start, which is fine: it is off by
    /// default and the switch is in the island's own settings.
    var surface: (any DictationSurface)?

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

        guard let surface else {
            Self.log.error("dictation cannot start: no surface installed yet")
            return
        }
        let live = DictationStack(surface: surface)
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

    // MARK: - Why it is not working

    /// Everything hold-to-dictate needs, each with a live answer.
    ///
    /// **Built 2026-08-31, auditing the stranger's path before a public
    /// launch.** Three of these four could be wrong while the app said
    /// nothing: the key press itself never arrives when Input Monitoring is
    /// refused, so there is no code path that can speak at the moment of
    /// failure. This is the surface that can, because it is read on demand
    /// rather than during a hold.
    struct Health: Sendable, Equatable {
        enum State: Sendable, Equatable {
            case ready
            case missing
            case working(String)
            case unavailable(String)
        }
        var microphone: State
        var noticingTheKey: State
        var typingIntoApps: State
        var words: State

        var allReady: Bool {
            [microphone, noticingTheKey, typingIntoApps, words].allSatisfy { $0 == .ready }
        }
    }

    /// Read fresh every time: a permission can be revoked in System Settings
    /// while the app is running, which is exactly when somebody comes looking
    /// at this screen.
    @MainActor
    func health() -> Health {
        guard Self.isSupported else {
            let why = Health.State.unavailable("needs macOS 26")
            return Health(microphone: why, noticingTheKey: why, typingIntoApps: why, words: why)
        }
        let mic: Health.State
        switch MicPermission.current {
        case .granted: mic = .ready
        case .pending: mic = .working("macOS has not asked yet")
        case .denied: mic = .missing
        }
        // `tapInstalled` is what `CGEvent.tapCreate` returned, and it is only
        // trustworthy as a negative: the call can succeed and still receive
        // nothing without Input Monitoring, which is why this row says
        // "running" rather than "granted" when it is true.
        let tap: Health.State = isRunning
            ? (tapInstalled ? .ready : .missing)
            : .working("hold to dictate is off")
        let ax: Health.State = AccessibilityPermission.isTrusted ? .ready : .missing
        return Health(
            microphone: mic, noticingTheKey: tap, typingIntoApps: ax,
            words: wordsState())
    }

    /// The speech assets, asked of the live stack when there is one.
    @MainActor
    private func wordsState() -> Health.State {
        guard #available(macOS 26, *), let live = stack as? DictationStack else {
            return .working("hold to dictate is off")
        }
        switch live.assetState() {
        case .available: return .ready
        case .checking: return .working("checking")
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded())
            return .working(percent > 0 ? "downloading, \(percent)%" : "downloading")
        case .unsupported(let requested): return .unavailable("no model for \(requested)")
        case .failed: return .missing
        }
    }

    // MARK: - The first run's practice hold

    /// Hold the landing spot: while this is set, dictated words are handed
    /// here instead of typed into another app. The tour's try-it card sets
    /// it while it is on screen and clears it when it leaves, so a new
    /// install's first sentence always has somewhere to go (2026-08-30).
    /// A no-op when dictation is not running, which is the honest answer:
    /// there is nothing to practise with yet.
    func holdPracticeLanding(_ landing: ((String) -> Void)?) {
        guard #available(macOS 26, *), let live = stack as? DictationStack else { return }
        live.setPracticeLanding(landing)
    }

    /// The button's half of the try-it card: press and release WITHOUT the
    /// Option key, so the first success does not depend on the event tap
    /// having installed. That matters more than it sounds: without Input
    /// Monitoring `CGEvent.tapCreate` still succeeds and simply receives
    /// nothing (see `tapInstalled`), which is exactly the silent nothing a
    /// first run must never be.
    func practicePress() {
        guard #available(macOS 26, *), let live = stack as? DictationStack else { return }
        live.press()
    }

    func practiceRelease() {
        guard #available(macOS 26, *), let live = stack as? DictationStack else { return }
        live.release()
    }
}

/// The macOS 26 half, kept private so nothing outside this file has to carry
/// the availability annotation.
@available(macOS 26, *)
@MainActor
private final class DictationStack {
    private let controller: DictationController
    private var monitor: EventTapMonitor?

    init(surface: any DictationSurface) {
        controller = DictationController(surface: surface)
    }

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

    func assetState() -> SpeechAssetState { controller.assetState }

    func setPracticeLanding(_ landing: ((String) -> Void)?) {
        controller.practiceLanding = landing
    }

    /// The same two calls the event tap makes, from a button instead.
    func press() { Task { await controller.keyDown() } }
    func release() { Task { await controller.keyUp() } }
}
