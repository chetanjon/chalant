import AVFoundation
import Synchronization

/// A single-producer single-consumer ring of preallocated audio buffers.
///
/// This exists to satisfy the hardest invariant in Part 1 §2: the
/// `AVAudioEngine` tap callback runs on a real-time thread, and inside it
/// there may be no `await`, no allocation, no locks, no logging and no Swift
/// concurrency of any kind. Violating that "produces audio glitches that look
/// like model bugs", which is the worst kind of bug to chase because it points
/// at the wrong component.
///
/// So the tap does exactly one thing: `memcpy` into a slot that already
/// exists, publish an index, return. Everything else happens on the consumer.
///
/// **On `@unchecked Sendable`:** Part 1 §3 says to fix the design rather than
/// reach for it. This is the exception the rule is for. A lock-free SPSC ring
/// cannot be expressed as checked-`Sendable` in Swift, and the safety here is
/// real rather than assumed: exactly one thread writes, exactly one reads, and
/// the handoff is an acquire/release pair on the indices. Adding a lock to
/// satisfy the checker would violate a hard invariant to satisfy a soft one.
final class AudioRing: @unchecked Sendable {
    /// Slot count. Each slot holds `frameCapacity` frames, so at 48kHz with
    /// 4800-frame slots this is ~1.6s of cushion before the consumer must
    /// catch up. The consumer runs far faster than that; the depth is here so
    /// a scheduling hiccup drops nothing.
    private static let slotCount = 16

    private let slots: [AVAudioPCMBuffer]
    /// Host time of the first frame in each slot, for the timestamp slicing
    /// that replaces the old pre-roll buffer (Part 1 §1, Part 6 §2).
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let frameCounts: UnsafeMutablePointer<UInt32>

    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)
    /// Incremented when the producer laps the consumer. Surfaced as a warning
    /// rather than silently swallowed: a dropped buffer is lost speech, and
    /// Part 0 §0.9 names losing the utterance as the category's worst failure.
    private let overruns = Atomic<UInt64>(0)
    /// Loudest sample seen since the last read, as a millionth, so the UI can
    /// show that the microphone is actually hearing something. Stored as an
    /// integer because `Atomic` needs a fixed-width type, and computed in the
    /// real-time callback because it is arithmetic over samples already in
    /// registers: no allocation, no locking, nothing that can block.
    private let peakMillionths = Atomic<UInt64>(0)

    init(format: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
        var built: [AVAudioPCMBuffer] = []
        built.reserveCapacity(Self.slotCount)
        for _ in 0..<Self.slotCount {
            // Force-unwrap is confined to init, which runs long before any
            // user action, and a nil here means the format is unusable at all.
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                preconditionFailure("could not preallocate audio slot")
            }
            built.append(b)
        }
        self.slots = built
        self.hostTimes = .allocate(capacity: Self.slotCount)
        self.hostTimes.initialize(repeating: 0, count: Self.slotCount)
        self.frameCounts = .allocate(capacity: Self.slotCount)
        self.frameCounts.initialize(repeating: 0, count: Self.slotCount)
    }

    deinit {
        hostTimes.deallocate()
        frameCounts.deallocate()
    }

    var overrunCount: UInt64 { overruns.load(ordering: .relaxed) }

    /// 0...1. The signal the UI needs to prove the microphone is live, and the
    /// first thing to check when a transcript comes back empty: buffers
    /// arriving with a peak of zero means silence reached the engine, not that
    /// the engine failed.
    var peak: Double { Double(peakMillionths.load(ordering: .relaxed)) / 1_000_000 }

    // MARK: - Producer (real-time thread, nothing may block here)

    /// Copy one tap buffer into the ring. Called from the audio thread only.
    func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)

        if w &- r >= UInt64(Self.slotCount) {
            overruns.add(1, ordering: .relaxed)
            return
        }

        let slot = slots[Int(w % UInt64(Self.slotCount))]
        let frames = min(buffer.frameLength, slot.frameCapacity)

        guard let src = buffer.floatChannelData, let dst = slot.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        for ch in 0..<channels {
            // memcpy only. No allocation, no locking, no logging.
            dst[ch].update(from: src[ch], count: Int(frames))
            if ch == 0 {
                for i in 0..<Int(frames) {
                    let magnitude = abs(src[ch][i])
                    if magnitude > peak { peak = magnitude }
                }
            }
        }
        peakMillionths.store(UInt64(min(peak, 1) * 1_000_000), ordering: .relaxed)
        slot.frameLength = frames
        hostTimes[Int(w % UInt64(Self.slotCount))] = hostTime
        frameCounts[Int(w % UInt64(Self.slotCount))] = frames

        // Release so the consumer sees the samples before it sees the index.
        writeIndex.store(w &+ 1, ordering: .releasing)
    }

    // MARK: - Consumer

    /// Take the next filled slot, or nil when the ring is empty.
    ///
    /// The returned buffer is a *copy*, because the slot it came from is
    /// immediately reusable by the producer.
    func read() -> (buffer: AVAudioPCMBuffer, hostTime: UInt64)? {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        guard r < w else { return nil }

        let index = Int(r % UInt64(Self.slotCount))
        let slot = slots[index]
        let frames = frameCounts[index]
        let hostTime = hostTimes[index]

        guard
            let copy = AVAudioPCMBuffer(pcmFormat: slot.format, frameCapacity: frames),
            let src = slot.floatChannelData,
            let dst = copy.floatChannelData
        else {
            readIndex.store(r &+ 1, ordering: .releasing)
            return nil
        }
        for ch in 0..<Int(slot.format.channelCount) {
            dst[ch].update(from: src[ch], count: Int(frames))
        }
        copy.frameLength = frames

        readIndex.store(r &+ 1, ordering: .releasing)
        return (copy, hostTime)
    }
}
