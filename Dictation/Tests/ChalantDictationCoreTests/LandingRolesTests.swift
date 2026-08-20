import Testing

@testable import ChalantDictationCore

/// The rescue acts only on affirmative evidence. The costly mistakes each
/// direction: calling a real text field `.doesNot` clobbers the clipboard and
/// toasts over a paste that landed; calling the desktop `.unknowable` loses
/// the founder's words, which is the bug the feature exists to end.
@Suite("LandingRoles")
struct LandingRolesTests {

    @Test("text fields take text")
    func textRoles() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            #expect(LandingRoles.verdict(role: role) == .takesText)
        }
    }

    @Test("the desktop and controls provably do not")
    func neverRoles() {
        // The founder's case: dictating onto the desktop, whose focused
        // element is Finder's icon view.
        for role in ["AXScrollArea", "AXGroup", "AXOutline", "AXButton", "AXImage", "AXWindow"] {
            #expect(LandingRoles.verdict(role: role) == .doesNot)
        }
    }

    /// Electron and web apps report no element or hide fields inside an
    /// AXWebArea; both must change nothing (Part 1 §1's whole objection).
    @Test("silence and web content are unknowable, never doesNot")
    func unknowableRoles() {
        #expect(LandingRoles.verdict(role: nil) == .unknowable)
        #expect(LandingRoles.verdict(role: "") == .unknowable)
        #expect(LandingRoles.verdict(role: "AXWebArea") == .unknowable)
        // A role this table has never seen fails toward doing nothing.
        #expect(LandingRoles.verdict(role: "AXSomethingNew") == .unknowable)
    }
}
