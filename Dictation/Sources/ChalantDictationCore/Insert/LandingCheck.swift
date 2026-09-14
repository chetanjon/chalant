import Foundation

/// Did the text actually arrive?
///
/// **Because "the AppleScript reported no error" is not an answer.** Part 0
/// §0.3 is explicit that "event sent" is not "text landed", and
/// `InsertionChain`'s own header claims that no tier reports success it has
/// not verified. The primary tier did exactly that: `SystemEventsPaste.run()`
/// returns whether `NSAppleScript` raised, which says the keystroke was
/// dispatched and nothing at all about where it went.
///
/// The old proxy was worse than none. The fallback tier asked
/// `NSPasteboard.changeCount != placedAt`, but the change count advances when
/// something WRITES to the pasteboard, and a paste reads it. So that check
/// answered "did anybody copy something in the last 120 ms", which is nearly
/// always no, so the tier reported failure on a paste that worked.
///
/// This asks the focused field instead, and it is careful about what it does
/// not know:
///
/// - **`uncertain` is the common case and is treated as success.** Electron
///   and web views report no focused element at all, which is most of the
///   apps people dictate into. Part 1 §1 established that accessibility never
///   gates an insertion, and that stands: this reads, it does not veto.
/// - **`refuted` needs the field to have answered twice and not moved**, and
///   only from a caret rather than a selection, because a paste replacing
///   selected text of the same length would look identical to one that did
///   nothing.
/// - **Nothing is ever pasted twice on the strength of this.** A refuted
///   paste hands the words back; it does not try again. Pasting again on a
///   wrong verdict would double the user's text, which is the one outcome
///   this whole subsystem exists to avoid.
public enum LandingCheck {

    /// What the focused field said, when it would say anything.
    public struct Reading: Sendable, Hashable {
        /// Characters in the whole field.
        public let length: Int
        /// Characters selected. Zero is a caret.
        public let selection: Int

        public init(length: Int, selection: Int) {
            self.length = length
            self.selection = selection
        }
    }

    public enum Verdict: String, Sendable, Equatable {
        /// The field answered and grew. The only verdict that may claim the
        /// words are on screen.
        case confirmed
        /// The field would not say, or said something this cannot reason
        /// about. Treated as success, exactly as before this existed.
        case uncertain
        /// The field answered, from a caret, and did not change. Nothing
        /// landed.
        case refuted
    }

    public static func verdict(before: Reading?, after: Reading?, inserted: Int) -> Verdict {
        guard inserted > 0 else { return .uncertain }
        guard let before, let after else { return .uncertain }
        // A replacement cannot be told from a no-op by length alone.
        guard before.selection == 0 else { return .uncertain }
        if after.length > before.length { return .confirmed }
        if after.length == before.length { return .refuted }
        // Shorter than it was: something other than our paste changed the
        // field. Not our evidence either way.
        return .uncertain
    }

    /// Whether a verdict should count against the app's insertion tier.
    ///
    /// **Only a refusal, never a doubt.** Counting `uncertain` would demote
    /// every Electron app to the clipboard floor inside two dictations, since
    /// they are precisely the apps that never answer.
    public static func countsAsFailure(_ verdict: Verdict) -> Bool { verdict == .refuted }
}
