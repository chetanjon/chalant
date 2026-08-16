import AppKit
import CoreGraphics

/// Which screen the dictation strip opens on.
///
/// **Not `NSScreen.main`, and not the pointer's display.** The old floating
/// panel used `.main`, which on the founder's desk is the external monitor
/// while their eyes are on the app they are dictating into, and that is the
/// whole reason they reported dictation as invisible. Voice commands are
/// addressed to the island, so the pointer rule (`NotchViewModel.defaultOwner`)
/// is right for them. Dictation is addressed to another app: the strip belongs
/// on the screen showing that app.
enum DictationDisplay {

    /// The rule, pure so it can be tested. Fallback order after the target's
    /// own display: pointer, main, any. A display whose island is switched
    /// off is skipped to the next.
    static func resolve(
        target: CGDirectDisplayID?,
        pointerOn: CGDirectDisplayID?,
        main: CGDirectDisplayID?,
        any: CGDirectDisplayID?,
        isOff: (CGDirectDisplayID) -> Bool
    ) -> CGDirectDisplayID? {
        for candidate in [target, pointerOn, main, any] {
            if let candidate, !isOff(candidate) { return candidate }
        }
        return nil
    }

    /// The display holding the frontmost on-screen window of `pid`, or nil.
    ///
    /// `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` lists windows
    /// front to back, so the first one belonging to the pid with real bounds
    /// is the one the user is looking at. Compares against `CGDisplayBounds` in
    /// the window list's own coordinate space (origin at top-left of primary
    /// screen), no AppKit flip by hand.
    static func displayShowing(pid: pid_t) -> CGDirectDisplayID? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        // Every attached display's bounds, in the same top-left global space
        // the window list reports in. Compare there; never flip by hand.
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return (id, CGDisplayBounds(id))
        }

        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width > 1, bounds.height > 1
            else { continue }
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            if let hit = displays.first(where: { $0.bounds.contains(centre) }) {
                return hit.id
            }
        }
        return nil
    }
}
