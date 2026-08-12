import AppKit
import CoreGraphics
import os

/// Watches for right Option being held.
///
/// Right Option rather than a function key: it is rarely bound to anything on
/// a Mac, it is comfortable to hold, and it does not collide with Superwhisper,
/// which is live on the founder's machine and needs to stay usable side by
/// side while this is evaluated.
///
/// A modifier key never produces keyDown/keyUp, only `.flagsChanged`, so the
/// press and release are derived from the device-dependent right-Option bit
/// together with the keycode of the key that changed.
final class EventTapMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "hotkey")

    /// `kVK_RightOption`.
    private static let rightOptionKeyCode: Int64 = 61
    /// `NX_DEVICERALTKEYMASK`. The general `.maskAlternate` bit cannot tell
    /// the two Option keys apart, and binding both would make left Option
    /// unusable for typing accented characters.
    private static let rightOptionFlag: UInt64 = 0x0000_0040

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    /// Called on the main actor when the key goes down and comes back up.
    private let onChange: @MainActor @Sendable (Bool) -> Void

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    /// Returns false when Accessibility has not been granted, which is the
    /// normal first-run state rather than an error.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

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
            eventsOfInterest: CGEventMask(mask),
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
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == Self.rightOptionKeyCode else { break }

            let down = (event.flags.rawValue & Self.rightOptionFlag) != 0
            if down != isDown {
                isDown = down
                let handler = onChange
                // Hop off the tap thread before doing anything real.
                Task { @MainActor in handler(down) }
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
