import ApplicationServices
import Foundation

/// The focused element's accessibility role, when it can be read.
///
/// Like `CursorContext`, **this reads; it never gates.** It runs after the
/// paste, and its answer only ever matters when it is affirmative
/// (`LandingRoles.verdict`): Electron and web apps that report no element
/// come back nil and nothing changes for them.
enum LandingProbe {
    @MainActor static func focusedRole() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused
        else { return nil }
        let target = unsafeBitCast(element, to: AXUIElement.self)
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String
        else { return nil }
        return role
    }
}
