import Carbon.HIToolbox
import Foundation

/// Is a password field, or anything else that locks the keyboard, currently
/// focused anywhere on the system?
///
/// Part 1 §1 corrects the original spec here: the check is
/// `IsSecureEventInputEnabled()`, **not** inspecting the focused element for
/// an `AXSecureTextField` role. The AX-role approach rests on the same broken
/// mechanism as the abandoned AX-set insertion path, which reports no focused
/// element at all in Electron and web apps.
///
/// **Scope note:** Part 3 files the secure-input probe under M1. It is here in
/// M0, with the founder's approval, for one practical reason: while secure
/// input is enabled the system silently drops synthetic keystrokes, so M0's
/// own acceptance test would show a paste that does nothing and look exactly
/// like a broken insertion path. Three lines here save an hour of chasing that.
enum SecureInputProbe {
    static var isActive: Bool {
        IsSecureEventInputEnabled()
    }
}
