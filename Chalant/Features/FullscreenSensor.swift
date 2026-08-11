import AppKit
import CoreGraphics

/// Which displays a fullscreen app owns right now.
///
/// The island's panel rides at status-bar level with fullScreenAuxiliary,
/// so a resting pill floats over a fullscreen app's own chrome: Safari's
/// fullscreen toolbar wore a black bar (founder, 1.10.2, still open
/// then). Reshaping the pill was tried once and overruled ("if the user
/// selects to have a pill on monitor it should be a pill"), so the fix
/// is the one the menu bar itself uses: yield while a fullscreen app
/// owns the screen, come back when the pointer reaches for the top edge.
///
/// This is the sensing half. The pill lives at the display's top
/// centre, so what matters is a normal-layer window whose chrome sits
/// under that home: one that touches the very top, runs the display's
/// full height, and reaches the middle of the screen. A single
/// fullscreen window does; each tile of a split-view Space does; an
/// ordinary maximized window under a visible menu bar never does (it
/// stops short of the menu bar's strip); a narrow full-height panel
/// parked at an edge never does (nothing of it is under the pill).
/// Read through the public window list, which serves bounds, layer and
/// owner without any permission; only window TITLES would need Screen
/// Recording, and none are asked for.
enum FullscreenSensor {
    /// The displays where some other app is fullscreen at this moment.
    @MainActor
    static func fullscreenDisplays(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Set<CGDirectDisplayID> {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var taken: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            // CGDisplayBounds speaks the window list's own coordinate
            // space (origin top-left of the main display), so the two
            // compare directly, no AppKit flip by hand.
            if hasFullscreenWindow(
                in: windows, displayBounds: CGDisplayBounds(id), excludingPID: ownPID
            ) {
                taken.insert(id)
            }
        }
        return taken
    }

    /// The pure half, pinned by tests: does this window list hold a
    /// visible normal-layer window whose chrome sits under the pill?
    static func hasFullscreenWindow(
        in windows: [[String: Any]], displayBounds: CGRect, excludingPID: pid_t
    ) -> Bool {
        windows.contains { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != excludingPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { return false }
            return underThePill(bounds, display: displayBounds)
        }
    }

    /// Touches the very top, runs the full height, and reaches the
    /// middle third of the display, where the pill lives. A point of
    /// slack each way: display metrics and window bounds can disagree
    /// by a rounding hair, never by the menu bar's height.
    static func underThePill(_ bounds: CGRect, display: CGRect) -> Bool {
        let third = display.width / 3
        return abs(bounds.minY - display.minY) <= 1
            && abs(bounds.height - display.height) <= 1
            && bounds.maxX > display.minX + third
            && bounds.minX < display.maxX - third
    }
}
