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
    /// is the one the user is looking at. Bounds are in global top-left
    /// coordinates; `NSScreen.frame` is bottom-left, so the match converts.
    static func displayShowing(pid: pid_t) -> CGDirectDisplayID? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        let totalHeight = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 1, h > 1
            else { continue }
            // Centre of the window, flipped into NSScreen space.
            let point = NSPoint(x: x + w / 2, y: totalHeight - (y + h / 2))
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                return screen.displayID
            }
        }
        return nil
    }
}
