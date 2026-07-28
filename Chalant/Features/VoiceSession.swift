import Foundation

/// The half of a voice session that has nothing to do with audio.
///
/// Both of the crashes this month lived here rather than in the audio
/// framework, and neither could be reached by a test, because the
/// decisions were tangled up with `AVAudioEngine` and a live
/// microphone. Nothing in this type touches either.
///
/// What it answers is exactly what went wrong:
///
/// - May work that started a moment ago still open the microphone? A
///   permission dialog is answered on the user's own schedule, so a
///   grant routinely lands after the hold it belongs to was released.
///   Following it into capture left the mic live with nobody listening,
///   and the next hold installed a second tap and killed the app.
/// - Did starting this session abandon a finalize? If it did, whoever
///   was waiting on that finalize must be told, because its completion
///   is the only thing that would ever have released them. Left
///   unreleased, the island refused every later question in silence.
/// - Do we currently own the tap? Installing a second one on the same
///   bus raises an Objective-C exception, which Swift cannot catch.
@MainActor
struct VoiceSession {
    enum Phase: Equatable {
        /// Nothing is wanted. Late arrivals stand down.
        case idle
        /// The user is holding, or a session is warming up.
        case listening
        /// The hold ended and a transcript is still settling.
        case finalizing
    }

    private(set) var phase: Phase = .idle
    /// Bumped by every transition that ends the previous session, so
    /// anything holding an older number is holding a stale intent.
    private(set) var generation = 0
    private(set) var ownsTap = false

    /// A finalize is outstanding and its completion has not run.
    var awaitingFinalize: Bool { phase == .finalizing }

    /// Start a session.
    ///
    /// Returns the number this session runs under, and whether starting
    /// it abandoned a finalize that will now never complete.
    @discardableResult
    mutating func begin() -> (generation: Int, abandonedFinalize: Bool) {
        let abandoned = phase == .finalizing
        generation += 1
        phase = .listening
        return (generation, abandoned)
    }

    /// Whether work that started under `generation` may still open the
    /// microphone. False once the session it belonged to has ended, been
    /// cancelled, or been replaced.
    func stillWanted(_ generation: Int) -> Bool {
        phase == .listening && generation == self.generation
    }

    /// The hold is over. A transcript may still arrive.
    @discardableResult
    mutating func end() -> Int {
        generation += 1
        phase = .finalizing
        return generation
    }

    /// Torn down without delivering anything.
    @discardableResult
    mutating func cancel() -> Int {
        generation += 1
        phase = .idle
        return generation
    }

    /// Take the outstanding finalize, exactly once. False when there is
    /// none, which is what keeps a completion from running twice.
    mutating func claimFinalize() -> Bool {
        guard phase == .finalizing else { return false }
        phase = .idle
        return true
    }

    /// A device hop tears the capture chain down and builds it again
    /// inside the same session, so the number must not move.
    mutating func tapInstalled() { ownsTap = true }
    mutating func tapRemoved() { ownsTap = false }
}
