import Foundation

/// Whether the audio tap is still delivering buffers at all.
///
/// A different question from whether the microphone is delivering sound, and
/// the silence watchdog (`InputChoice.isDead`) structurally cannot ask it:
/// `peak` is the loudness of the LAST buffer, so when buffers stop arriving
/// it freezes at whatever the room sounded like, above zero, and reads as
/// alive forever.
///
/// Measured 2026-08-16, on the shipped 1.15.0 AND on the fresh-engine fix:
/// change the built-in microphone's sample rate under the running engine and
/// every hold after it feeds **0 buffers**. No `AVAudioEngineConfigurationChange`
/// reaches the app, so nothing restarts the engine, and the mic is fine, so
/// nothing hops away from it. Restoring the rate brings the tap straight
/// back. The only honest signal is the buffer count standing still, which is
/// what this watches.
///
/// Pure and clock-free, like `PushToTalk`: the caller hands in the count and
/// the time, so the stall can be tested without an engine and without waiting.
public struct TapPulse: Sendable, Equatable {
    /// How long the count may stand still before the tap is called stalled.
    /// The engine delivers roughly ten buffers a second, so two seconds of
    /// nothing is not a slow tap, it is a dead one.
    public static let threshold: TimeInterval = 2.0

    private var lastCount: UInt64
    private var lastProgressAt: Date

    public init(count: UInt64, at now: Date) {
        lastCount = count
        lastProgressAt = now
    }

    /// Record the tap's buffer count as of `now`. Returns true when the count
    /// has not moved for at least `threshold`.
    public mutating func observe(
        count: UInt64, at now: Date, threshold: TimeInterval = TapPulse.threshold
    ) -> Bool {
        if count != lastCount {
            lastCount = count
            lastProgressAt = now
            return false
        }
        return now.timeIntervalSince(lastProgressAt) >= threshold
    }
}
