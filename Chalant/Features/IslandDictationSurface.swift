import AppKit
import CoreGraphics

/// The island, as dictation sees it. Three calls in, three view-model calls
/// out, and the display rule applied on the way.
@MainActor
final class IslandDictationSurface: DictationSurface, DictationDisplayLookup {
    private weak var model: NotchViewModel?
    private let displays: DisplayConfigStore

    init(model: NotchViewModel, displays: DisplayConfigStore) {
        self.model = model
        self.displays = displays
    }

    func show(into appName: String, mic: String?, on display: CGDirectDisplayID?) {
        let pointerOn = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.displayID
        let resolved = DictationDisplay.resolve(
            target: display,
            pointerOn: pointerOn,
            main: NSScreen.main?.displayID,
            any: NSScreen.screens.first?.displayID,
            // Brief guessed `displays.config(for: id).style` (an id-keyed
            // accessor that does not exist). The real one takes an
            // `NSScreen`, so the id is resolved to a screen first; a
            // display that no longer matches any attached screen counts
            // as off, since there is nothing left to show it on.
            isOff: { [displays] id in
                guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else {
                    return true
                }
                return displays.config(for: screen).style == .off
            }
        )
        model?.beginDictating(into: appName, mic: mic, on: resolved)
    }

    func update(level: CGFloat, mic: String?) {
        // What arrives is the raw peak off the audio ring, and it is scaled
        // here rather than at the meter because `Dictation/` cannot see the
        // formulas: they live in `DictationStripLevel`, beside the three they
        // have to stay in step with. Unscaled, the strip hardly moves.
        model?.updateDictating(level: DictationStripLevel.normalize(peak: level), mic: mic)
    }

    func hide() {
        model?.endDictating()
    }

    func displayShowing(pid: pid_t) -> CGDirectDisplayID? {
        DictationDisplay.displayShowing(pid: pid)
    }
}
