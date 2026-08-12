import AppKit
import CoreGraphics
import os

/// Watches for left Option being held.
///
/// Left rather than right: the founder's keyboard has no right Option key at
/// all, which is a good reminder that "every Mac has it" is a layout
/// assumption rather than a fact. Left Option exists on every keyboard, sits
/// under the left hand, and is only meaningful for typing when combined with a
/// letter, so holding it alone is free.
///
/// A modifier key never produces keyDown/keyUp, only `.flagsChanged`, so the
/// press and release are derived from the device-dependent right-Option bit
/// together with the keycode of the key that changed.
final class EventTapMonitor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "hotkey")

    /// `kVK_Option`, the left one.
    private static let optionKeyCode: Int64 = 58
    /// `NX_DEVICELALTKEYMASK`. The general `.maskAlternate` bit cannot tell the
    /// two Option keys apart, and this is the device-dependent bit for the
    /// left one specifically.
    private static let optionFlag: UInt64 = 0x0000_0020

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

        // ONLY the events actually being watched. The two `tapDisabled` types
        // are delivered to the callback whether or not they are in the mask,
        // and their raw values are 0xFFFFFFFE and 0xFFFFFFFF: shifting 1 by
        // those is undefined behaviour and corrupts the mask into something
        // that matches nothing. The tap then installs cleanly, logs success,
        // and never fires, which is indistinguishable from a permissions
        // problem. Found by standing up a second identical tap that did work.
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue

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
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == Self.optionKeyCode else { break }

            let down = (event.flags.rawValue & Self.optionFlag) != 0
            Self.log.info("flagsChanged leftOption down=\(down, privacy: .public) wasDown=\(self.isDown, privacy: .public)")
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
