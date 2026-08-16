import Foundation
import Testing

@testable import ChalantDictationCore

/// When the tap has stopped delivering buffers at all.
///
/// This is a different failure from a microphone delivering silence, and the
/// silence watchdog cannot see it: `peak` is the last buffer's loudness, so
/// when buffers stop arriving it freezes at whatever the room sounded like,
/// which is above zero, which reads as "alive". Measured 2026-08-16 on the
/// shipped 1.15.0 and on the fresh-engine fix: change the built-in mic's
/// sample rate under the running engine and every hold after it feeds
/// **0 buffers**, no notification arrives, and nothing ever restarts the
/// engine. The only honest signal is the buffer count standing still.
@Suite("TapPulse: noticing that the tap has gone quiet")
struct TapPulseTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    /// `#expect` cannot call a mutating member inline, so every observation
    /// goes through here.
    private func stalled(_ pulse: inout TapPulse, count: UInt64, after seconds: TimeInterval) -> Bool {
        pulse.observe(count: count, at: t0 + seconds)
    }

    @Test("buffers arriving means the tap is alive, however slowly it is polled")
    func advancingCountNeverTrips() {
        var pulse = TapPulse(count: 0, at: t0)
        #expect(!stalled(&pulse, count: 10, after: 1))
        #expect(!stalled(&pulse, count: 20, after: 2))
        // A long gap between polls is the poller's problem, not the tap's.
        #expect(!stalled(&pulse, count: 21, after: 60))
    }

    @Test("a frozen count trips only once it has been frozen for the threshold")
    func frozenCountTripsAfterThreshold() {
        var pulse = TapPulse(count: 0, at: t0)
        #expect(!stalled(&pulse, count: 10, after: 1))
        // Frozen at 10 from here on.
        #expect(!stalled(&pulse, count: 10, after: 2))
        #expect(!stalled(&pulse, count: 10, after: 2.9))
        #expect(stalled(&pulse, count: 10, after: 3))
    }

    @Test("progress after a stall starts the clock again")
    func progressResetsTheClock() {
        var pulse = TapPulse(count: 0, at: t0)
        #expect(!stalled(&pulse, count: 0, after: 1.5))
        #expect(!stalled(&pulse, count: 1, after: 1.9))
        // Frozen again, but only since t0 + 1.9.
        #expect(!stalled(&pulse, count: 1, after: 3.5))
        #expect(stalled(&pulse, count: 1, after: 3.9))
    }

    @Test("a fresh engine starts with a fresh pulse: no buffers yet is not a stall")
    func freshStartIsNotAStall() {
        var pulse = TapPulse(count: 0, at: t0)
        #expect(!stalled(&pulse, count: 0, after: 1))
    }
}
