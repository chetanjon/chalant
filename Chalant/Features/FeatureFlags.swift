import Foundation

/// The dark-ship switches (founder, 2026-08-09): sessions and chat are
/// hidden, not removed. Nothing underneath was deleted; every engine,
/// view and test still builds, and flipping a value back to true
/// restores the feature whole (update `testTheDarkShipIsOn` in the
/// same change, it pins the shipped state on purpose).
///
/// Hiding a surface hides its every door: the tab, the panels, the
/// dashboard section, the settings rows, the hotkey and the watchers
/// that feed it. The ActivityServer stays up either way; the
/// activities pills are their own feature, and a server that answers
/// on 4242 is what keeps a second Chalant honest about being a guest.
enum FeatureFlags {
    /// The agent sessions surface: the Sessions tab and room, the
    /// dashboard section with its arm buttons, the approval and
    /// question cards, and the registry/discovery watchers. Hiding it
    /// on a machine with armed hooks would leave agents waiting on a
    /// card that can never be drawn, so arming ships hidden with it.
    static let sessionsVisible = false

    /// The Chat tab: a small built-in browser onto the user's own
    /// Claude, ChatGPT or Gemini account. The local ask bar and voice
    /// verbs are not chat and stay.
    static let chatVisible = false
}
