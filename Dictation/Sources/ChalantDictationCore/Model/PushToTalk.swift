import Foundation

/// The push-to-talk key's own state, and every decision that follows from it.
///
/// Held apart from the microphone, the transcriber and the panel on purpose.
/// A hold is not instantaneous: the key goes down, and roughly 180ms of setup
/// follows (microphone permission, engine format, transcriber prepare, begin)
/// before anything is capturing. A finger can easily come up inside that
/// window, and what the app does about it decides whether the feature keeps
/// working.
///
/// It did not, before 2026-08-12. `keyDown` marked itself listening LAST,
/// after the setup, so a release landing mid-setup checked a flag that was
/// still false, was dropped, and setup then completed into a listening state
/// with the key already up. Nothing could clear it: the next press was refused
/// for a session believed live, and the next release was refused for a
/// transcriber already gone. The app was deaf until relaunch, and said nothing
/// about it for three hours.
///
/// Two rules come out of that, and they are what this type exists to keep:
///
/// 1. **A release is never dropped.** Arriving during setup, it is remembered,
///    and setup lands on `.abandon` rather than going live behind the user.
/// 2. **No refusal is silent.** Every ignored key carries the reason it was
///    ignored, so the app can say so rather than appear dead.
public struct PushToTalk: Sendable, Equatable {

    public enum State: Sendable, Equatable {
        /// Nothing running. The only state a fresh press is accepted from.
        case idle
        /// Key down, session being set up, not yet capturing.
        case arming
        /// Capturing. The only state a release can finish.
        case listening
    }

    /// What the caller should do about a key event. Returned rather than
    /// performed: the decision is testable without a microphone, and the
    /// mechanism stays in the app layer where the OS lives.
    public enum Decision: Sendable, Equatable {
        /// Begin a session: permission, format, prepare, begin, open the gate.
        case begin
        /// Setup finished and the key is still down. Go live.
        case capture
        /// Setup finished but the key came up during it. Tear the session down
        /// without capturing, and never go live behind the user.
        case abandon
        /// End the session and transcribe what was captured.
        case finish
        /// The release arrived mid-setup and has been remembered. The caller
        /// does nothing now; `ready()` will answer `.abandon`.
        case waitForSetup
        /// Refused, and why. The reason is not decoration: a key that does
        /// nothing and explains nothing is the bug that made this type
        /// necessary.
        case ignored(String)

        public var isIgnored: Bool {
            if case .ignored = self { return true }
            return false
        }

        public var reason: String? {
            if case .ignored(let why) = self { return why }
            return nil
        }
    }

    public private(set) var state: State = .idle

    /// Set when the key comes up before setup has finished. The whole race
    /// turns on remembering this rather than discarding it.
    private var releasedWhileArming = false

    public init() {}

    /// The key went down.
    public mutating func press() -> Decision {
        switch state {
        case .idle:
            releasedWhileArming = false
            state = .arming
            return .begin
        case .arming:
            return .ignored("a session is already starting")
        case .listening:
            // Key repeat, or a modifier the system thinks is still down.
            return .ignored("already listening")
        }
    }

    /// Setup finished. Answers whether to go live or to stand down, which
    /// depends entirely on whether the finger is still there.
    public mutating func ready() -> Decision {
        guard state == .arming else {
            return .ignored("setup finished for a session that is no longer starting")
        }
        if releasedWhileArming {
            releasedWhileArming = false
            state = .idle
            return .abandon
        }
        state = .listening
        return .capture
    }

    /// Setup failed: no microphone grant, assets not ready, the transcriber
    /// refusing to begin. Always lands at idle. A failure that left the state
    /// anywhere else would be the original bug wearing a different hat.
    public mutating func setupFailed() {
        releasedWhileArming = false
        state = .idle
    }

    /// The key came up.
    public mutating func release() -> Decision {
        switch state {
        case .listening:
            state = .idle
            return .finish
        case .arming:
            // The window that cost the day. Remembered, never dropped.
            releasedWhileArming = true
            return .waitForSetup
        case .idle:
            return .ignored("nothing was listening")
        }
    }
}
