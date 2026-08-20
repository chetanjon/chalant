import Foundation

/// Whether the focused element could have taken the words, judged from its
/// accessibility role, AFTER the paste. Part 1 §1 stands: accessibility never
/// gates an insertion, because Electron and web apps report no focused
/// element while having one. This is the other direction, and it only ever
/// acts on AFFIRMATIVE evidence: a role that provably takes no text (the
/// desktop's icon view, a button) means the ⌘V was a no-op and the words
/// would be silently lost ("if the user forget to pick a place to speak...
/// it should record and give them what they spoke", the founder, 2026-08-20).
/// Anything uncertain is `.unknowable` and changes nothing.
public enum LandingRoles {

    public enum Verdict: Equatable {
        /// A text field of some kind had focus; the paste landed.
        case takesText
        /// Affirmatively not a text taker: the paste went nowhere.
        case doesNot
        /// No element, an unknown role, or web content (fields hide inside
        /// an AXWebArea). Today's behavior, untouched.
        case unknowable
    }

    /// Roles that hold text and take a paste.
    private static let text: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Roles that provably do not. Deliberately a closed list: a role this
    /// table has never seen is `.unknowable`, never `.doesNot`, so a new or
    /// private role can only ever fail toward doing nothing.
    private static let never: Set<String> = [
        "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuButton", "AXMenuBar", "AXMenuBarItem",
        "AXImage", "AXStaticText", "AXLink", "AXSlider", "AXIncrementor",
        "AXColorWell", "AXDisclosureTriangle", "AXTabGroup", "AXToolbar",
        "AXOutline", "AXTable", "AXList", "AXScrollArea", "AXGroup",
        "AXSplitGroup", "AXRow", "AXCell", "AXWindow", "AXDrawer",
    ]

    public static func verdict(role: String?) -> Verdict {
        guard let role, !role.isEmpty else { return .unknowable }
        if text.contains(role) { return .takesText }
        if never.contains(role) { return .doesNot }
        return .unknowable
    }
}
