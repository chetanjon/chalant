import AVFoundation
import Synchronization
import os

/// The capture gate, as a reference type so the real-time tap can hold it.
///
/// `Atomic` is non-copyable in Swift 6, so it cannot be captured by value into
/// the tap closure. Wrapping it in a final class gives the tap one object to
/// hold by reference, which is also what keeps the read on the audio thread a
/// single relaxed load with no bridging.
final class CaptureGate: @unchecked Sendable {
    private let flag = Atomic<Bool>(false)
    var isOpen: Bool { flag.load(ordering: .relaxed) }
    func open() { flag.store(true, ordering: .relaxed) }
    func close() { flag.store(false, ordering: .relaxed) }
}

/// The persistent warm engine.
///
/// Part 1 §1 replaced the original spec's 400ms pre-roll ring with this, and
/// Part 6 §2 explains why: FluidVoice deliberately *removed* their pre-roll
/// buffer and gate a permanently running engine with a flag plus host-time
/// markers instead, slicing a continuous stream by timestamp. That kills
/// engine spin-up latency and clipped onsets at the same time, because capture
/// was never off.
///
/// **The claim this creates, per Part 6 §2:** a persistently running engine
/// means the mic is technically live between dictations. Samples outside a
/// session are discarded and never written anywhere, and the privacy page has
/// to say so plainly. Getting caught not mentioning it is the story; saying it
/// first is a non-issue.
actor AudioEngine {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "audio")

    private let engine = AVAudioEngine()
    private var ring: AudioRing?
    private var format: AVAudioFormat?

    /// Read from the real-time tap, so it is atomic rather than
    /// actor-isolated: the tap cannot `await`.
    private let capturing = CaptureGate()

    private(set) var isRunning = false

    /// Start the engine and leave it running. Called once, early.
    func startWarm() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Part 2 §6 in the Chalant parent project learned this the hard way:
        // a dead device reports 0 Hz and installing a tap on it raises an
        // NSException rather than returning an error.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioEngineError.deadInputDevice
        }

        let ring = AudioRing(format: inputFormat, frameCapacity: 4800)
        self.ring = ring
        self.format = inputFormat

        let gate = capturing
        input.installTap(onBus: 0, bufferSize: 4800, format: inputFormat) { buffer, time in
            // ---- REAL-TIME THREAD. Part 1 §2 governs absolutely. ----
            // No await, no allocation, no locks, no logging, no concurrency.
            guard gate.isOpen else { return }
            ring.write(buffer, hostTime: time.hostTime)
            // ---------------------------------------------------------
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        Self.log.info("warm engine running at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    /// Open the gate. Cheap by design: no engine start, so no spin-up latency
    /// and no clipped onset.
    func beginCapture() {
        capturing.open()
    }

    /// Close the gate. Samples stop being forwarded; the engine keeps running.
    func endCapture() {
        capturing.close()
    }

    var currentFormat: AVAudioFormat? { format }

    /// The consumer end of the ring, handed to whoever is draining it.
    ///
    /// `AVAudioPCMBuffer` is not `Sendable`, so buffers must never cross an
    /// actor boundary. Part 1 §3 says to fix the design rather than reach for
    /// `@unchecked Sendable`, so the ring itself travels instead of the
    /// buffers: it is a reference type whose safety is the SPSC discipline,
    /// and the consumer drains it inside its own isolation.
    func ringHandle() -> AudioRing? { ring }

    var overrunCount: UInt64 { ring?.overrunCount ?? 0 }

    func stop() {
        guard isRunning else { return }
        capturing.close()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}

enum AudioEngineError: Error, LocalizedError {
    case deadInputDevice

    var errorDescription: String? {
        switch self {
        case .deadInputDevice:
            return "The input device reports no channels. Pick another microphone in System Settings."
        }
    }
}
