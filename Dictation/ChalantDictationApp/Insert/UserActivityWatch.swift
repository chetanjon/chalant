import AppKit
import Foundation

/// Did the user type or click between the instant insert and the tidied swap?
///
/// The swap undoes the paste and pastes again. If the user has typed a single
/// character since, ⌘Z would take THEIR character, not our paste, so the
/// policy keeps the raw text the moment any key or click is seen. Global
/// monitors deliver keys only with Input Monitoring, which the dictation
/// hotkey already needs, and only while another app is active, which is
/// exactly the situation (the user is in their document, not in Chalant).
///
/// Armed right after an insert, disarmed as soon as the swap decision is
/// made; it never watches otherwise. Nothing about the events is kept beyond
/// the fact that one happened.
@MainActor
final class UserActivityWatch {
    private var monitors: [Any] = []
    private(set) var sawActivity = false

    func arm() {
        disarm()
        sawActivity = false
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.sawActivity = true }
        }) {
            monitors.append(monitor)
        }
    }

    func disarm() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
