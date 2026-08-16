import Foundation

/// Where the text is going, captured at key-down and re-validated at key-up.
///
/// Validating at both ends is what stops a notification stealing focus
/// mid-utterance and the text landing in the wrong app, which is one of the
/// three global cases the M1 gate tests.
public struct InsertionTarget: Sendable, Hashable {
    public let bundleID: String?
    public let processID: pid_t?
    /// Captured at key-down so key-up can detect that focus moved.
    public let capturedAt: Date
    /// The frontmost app's display name at key-down. Read where the strip is
    /// shown, so the surface can say who it is listening for.
    public let appName: String?

    public init(bundleID: String?, processID: pid_t?, capturedAt: Date, appName: String? = nil) {
        self.bundleID = bundleID
        self.processID = processID
        self.capturedAt = capturedAt
        self.appName = appName
    }
}

/// Which path actually delivered the text.
///
/// Part 0 §0.3: AppleScript System Events is primary; CGEvent is demoted to an
/// attempted fallback that must verify after pasting, because synthetic events
/// can be silently dropped on macOS 26 even with permission granted. "Event
/// sent" is not "text landed".
public enum InsertionTier: Int, Sendable, CaseIterable {
    case systemEvents = 1
    case cgEvent = 2
    /// Part 0 §0.3 promotes this to a first-class outcome with good UX rather
    /// than an apology: the text is on the clipboard and the user is told.
    case clipboardOnly = 3
}

public enum InsertionRefusal: Sendable, Hashable {
    /// `IsSecureEventInputEnabled()` was true. Part 1 §1: this, never the
    /// `AXSecureTextField` role, which rests on the same broken mechanism as
    /// the abandoned AX-set path. The holder app is named so the user can act.
    case secureInputActive(holder: String?)
    /// Focus moved between key-down and key-up.
    case targetChanged
    case noTarget
}

public enum InsertionOutcome: Sendable, Hashable {
    case inserted(tier: InsertionTier)
    case leftOnClipboard(reason: String)
    case refused(reason: InsertionRefusal)
}

/// The insertion seam.
///
/// Part 1 §1 removed the Accessibility direct-set path entirely: Electron and
/// web apps report no focused element, so an AX gate silently refuses to paste
/// into Slack and VS Code, which are the two most important targets.
public protocol TextInserter: Sendable {
    func insert(_ text: String, into target: InsertionTarget) async -> InsertionOutcome
}
