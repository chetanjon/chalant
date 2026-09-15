import AppKit
import ChalantDictationCore
import CoreGraphics
import os

/// Watches for the hold key, and for anything that means the hold was not one.
///
/// Which key is `DictationShortcut`'s business, and the default is still left
/// Option: it exists on every keyboard, sits under the left hand, and is only
/// meaningful for typing when combined with a letter. A modifier key never
/// produces keyDown/keyUp, only `.flagsChanged`, so press and release are
/// derived from the device-dependent bit for that physical key together with
/// the keycode of the key that changed.
///
/// **It also watches `.keyDown` now, and that is a posture change worth
/// stating plainly.** Left Option is a real modifier: `Option+←` moves by
/// word, `Option+Delete` deletes one, `Option+e` starts an accent. Every one
/// of those was indistinguishable from the start of a dictation, because this
/// tap could not see the second key. It can now, and what it does with it is
/// deliberately the least it can:
///
/// - it reads `keyboardEventKeycode` and nothing else, never the character,
///   never the modifiers, never the target;
/// - it keeps nothing and logs nothing, in keeping with Part 1's rule that
///   what you type never enters a log;
/// - it acts only while our own key is held, and every other keystroke in the
///   day reaches `PushToTalk.otherKeyPressed()` in the idle state and is
///   dropped there;
/// - the tap stays `.listenOnly`, so it cannot alter or swallow a keystroke.
///
/// The app already ran a global `.keyDown` monitor on this same path
/// (`UserActivityWatch`, armed after an insert), so this is not a new
/// capability. What it does mean is that two pieces of copy that said Chalant
/// never watches keys are no longer true, and both were corrected in the same
/// commit rather than left standing.
final class EventTapMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "hotkey")

    /// Which key, read once when the tap is installed. Changing the shortcut
    /// in Settings restarts the tap rather than mutating this, so a live tap
    /// and the stored choice can never disagree.
    private let shortcut: DictationShortcut

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    /// Called on the main actor when the key goes down and comes back up.
    private let onChange: @MainActor @Sendable (Bool) -> Void
    /// Called on the main actor when some other key arrives while ours is
    /// held. Carries nothing about which key it was.
    private let onConflict: @MainActor @Sendable () -> Void

    init(
        shortcut: DictationShortcut = .default,
        onChange: @escaping @MainActor @Sendable (Bool) -> Void,
        onConflict: @escaping @MainActor @Sendable () -> Void
    ) {
        self.shortcut = shortcut
        self.onChange = onChange
        self.onConflict = onConflict
    }

    /// Returns false when Accessibility has not been granted, which is the
    /// normal first-run state rather than an error.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        // ONLY the events actually being watched, and each bit built from its
        // own type. The two `tapDisabled` types are delivered to the callback
        // whether or not they are in the mask, and their raw values are
        // 0xFFFFFFFE and 0xFFFFFFFF: shifting 1 by those is undefined
        // behaviour and corrupts the mask into something that matches
        // nothing. The tap then installs cleanly, logs success, and never
        // fires, which is indistinguishable from a permissions problem. Found
        // by standing up a second identical tap that did work.
        let mask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Listen only. Part 0 §0.3 keeps insertion on AppleScript, and a
            // tap that cannot alter events is a smaller thing to trust.
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.log.error("could not create event tap; Accessibility is probably not granted")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        Self.log.info("event tap installed")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
        }
        tap = nil
        runLoopSource = nil
    }

    /// The tap callback. Part 2 §6: do no work here, and re-enable the tap
    /// when the system disables it. A tap that dies silently is a hotkey that
    /// stops working for no visible reason.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                Self.log.error("tap disabled (\(type.rawValue, privacy: .public)); re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            guard let down = shortcut.isDown(keyCode: keyCode, rawFlags: event.flags.rawValue)
            else { break }
            Self.log.info(
                "flagsChanged hold key down=\(down, privacy: .public) wasDown=\(self.isDown, privacy: .public)")
            if down != isDown {
                isDown = down
                let handler = onChange
                // Hop off the tap thread before doing anything real.
                Task { @MainActor in handler(down) }
            }

        case .keyDown:
            // Only while our own key is held, and only the fact that it
            // happened. Nothing about the keystroke is read beyond whether it
            // is ours, kept, or logged.
            guard isDown else { break }
            let handler = onConflict
            Task { @MainActor in handler() }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
