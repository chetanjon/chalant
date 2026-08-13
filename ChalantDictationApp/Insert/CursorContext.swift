import ApplicationServices
import Foundation

/// The character immediately before the cursor, when it can be read.
///
/// **This reads; it never gates.** Part 1 §1 removed the Accessibility path
/// from insertion because Electron and web apps report no focused element, so
/// "any AX gate silently refuses to paste into Slack and VS Code". That
/// objection is to letting AX decide *whether* to paste. Asking it for context
/// and shrugging when it declines is a different thing: the worst outcome is a
/// missing leading space, never a refused insertion.
///
/// Expect nil in exactly the apps Part 1 §1 names. `Spacing` is built so nil
/// is the safe default rather than a degraded one.
enum CursorContext {
    static func characterBeforeCursor() -> Character? {
        let system = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else { return nil }
        let target = unsafeBitCast(element, to: AXUIElement.self)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeRef = rangeValue
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &range) else { return nil }
        guard range.location > 0 else { return nil }  // start of field

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String
        else { return nil }

        // The AX range is in UTF-16 units, which is what NSString indexes in.
        let ns = text as NSString
        let index = range.location - 1
        guard index >= 0, index < ns.length else { return nil }
        return Character(ns.substring(with: NSRange(location: index, length: 1)))
    }
}
