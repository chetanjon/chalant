import ApplicationServices
import ChalantDictationCore
import Foundation

/// How long the focused text field is, and how much of it is selected.
///
/// The same two attributes `CursorContext` and `CorrectionObserver` already
/// read, asked together so an insertion can be checked afterwards. Like both
/// of those: **this reads, it never gates.** Nil where the app will not say,
/// which is Electron and every web view, and `LandingCheck` treats nil as
/// uncertain rather than as failure.
enum FocusedField {
    @MainActor
    static func measure() -> LandingCheck.Reading? {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success, let element = focused
        else { return nil }
        let target = unsafeBitCast(element, to: AXUIElement.self)

        var valueRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &valueRef) == .success,
            let text = valueRef as? String
        else { return nil }

        // The selection is best-effort inside a best-effort read: a field that
        // reports its value but not its selection is treated as a caret,
        // because that is the overwhelmingly common state and the verdict it
        // enables is the conservative one.
        var selection = 0
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
            == .success, let value = rangeRef
        {
            var range = CFRange()
            if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) {
                selection = max(0, range.length)
            }
        }
        // UTF-16, to match what the AX range is measured in.
        return LandingCheck.Reading(length: (text as NSString).length, selection: selection)
    }
}
