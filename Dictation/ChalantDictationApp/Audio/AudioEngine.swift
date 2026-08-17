import AVFoundation
import ChalantDictationCore
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

    /// **Recreated on every warm start, never reused across one.** An
    /// `AVAudioEngine` binds its `inputNode` to the hardware configuration that
    /// existed when the node was first touched. When a microphone is plugged in
    /// or pulled out, `AVAudioEngineConfigurationChange` fires; stopping and
    /// restarting the SAME engine leaves the input node tied to the old
    /// configuration, so the tap installs, reports success, and the render
    /// callback pulls nothing. Measured live 2026-08-16: a device change landed
    /// mid-session and every hold after it fed 0 buffers until relaunch, exactly
    /// the 0-buffer death CLAUDE.md line 1389 warns about. A fresh engine per
    /// warm start is the fix: `startWarm` assigns a new one before it binds.
    private var engine = AVAudioEngine()
    private var ring: AudioRing?
    private var format: AVAudioFormat?

    /// Read from the real-time tap, so it is atomic rather than
    /// actor-isolated: the tap cannot `await`.
    private let capturing = CaptureGate()

    private(set) var isRunning = false

    /// Which ear is live, and which ears have been proven deaf this launch.
    ///
    /// The founder's requirement is that dictation works "even when lid closed
    /// or open or wired or not or wireless", and the reason it did not is that
    /// this engine inherited the system default and never questioned it. With
    /// the lid shut, that default delivers exactly 0.0 forever.
    private(set) var currentDevice: InputChoice.Device?
    private var silentUIDs: Set<String> = []
    /// Which devices were attached last time we looked, so a notification
    /// caused by our own restart can be told from somebody plugging in a
    /// headset.
    private var knownUIDs: Set<String> = []
    /// When the live device last produced a sample above zero. Compared
    /// against `InputChoice.isDead` to decide whether to move on.
    private var lastSoundAt = Date()
    /// Whether the tap is still delivering buffers at all. Reset with every
    /// warm start, because every warm start makes a new ring whose count
    /// begins at zero.
    private var pulse = TapPulse(count: 0, at: Date())
    /// When a start was last attempted while the engine was down, so the
    /// poll can retry without retrying every tick.
    private var lastStartAttempt = Date.distantPast
    private static let downRetryInterval: TimeInterval = 5

    /// Choose the best ear available and start on it. Preference decides the
    /// order, evidence overrules it (`InputChoice`).
    func startWarm() throws {
        try startWarm(avoiding: silentUIDs)
    }

    private func startWarm(avoiding silent: Set<String>) throws {
        guard !isRunning else { return }
        lastStartAttempt = Date()

        // A brand-new engine, tied to the hardware as it is right now. The old
        // one may have been bound to a device that is gone, or to a
        // configuration a plug/unplug just invalidated; reusing it is what fed
        // 0 buffers after a device change. See the note on `engine`.
        engine = AVAudioEngine()

        let attached = AudioDevices.all()
        // Recorded before the engine opens anything, so the private aggregate
        // CoreAudio creates for us can never look like a device that arrived.
        knownUIDs = Set(attached.map(\.device.uid))
        let ordered = InputChoice.order(
            attached.map(\.device), pinnedUID: nil, silent: silent)
        // Bind before the tap is installed, or the tap belongs to whatever
        // device the engine inherited.
        if let choice = ordered.first,
           let picked = attached.first(where: { $0.device.uid == choice.uid }),
           let unit = engine.inputNode.audioUnit {
            if AudioDevices.bind(unit, to: picked.id) {
                currentDevice = picked.device
            } else {
                Self.log.error("could not bind to \(picked.device.name, privacy: .public)")
                currentDevice = nil
            }
        }

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
        // Both of these RAISE rather than throw when the graph disagrees
        // with them, and a raised NSException ends the process where it
        // stands. It did, 2026-08-16 17:07:45: the founder connected a
        // Bluetooth headset, the tap on the built-in mic stalled, the
        // watchdog rebuilt the engine, and `installTap` raised "Failed to
        // create tap due to format mismatch, 1 ch, 16000 Hz". The input
        // node's format lags the device it was just bound to (the AUHAL
        // logged its stream-format change 1.3s after the bind), so a
        // restart inside that window reads a stale format. `AudioGuard`
        // is what the parent project already uses for exactly this; a
        // caught raise means the engine is torn down and the next poll
        // tries again, by which time the formats have settled.
        do {
            try AudioGuard.attempt("dictation installTap") {
                input.installTap(onBus: 0, bufferSize: 4800, format: inputFormat) { buffer, time in
                    // ---- REAL-TIME THREAD. Part 1 §2 governs absolutely. ----
                    // No await, no allocation, no locks, no logging, no concurrency.
                    // Health first, and unconditionally: a mic that is delivering
                    // nothing has to be knowable before a session is spent on it.
                    ring.observe(buffer)
                    guard gate.isOpen else { return }
                    ring.write(buffer, hostTime: time.hostTime)
                    // ---------------------------------------------------------
                }
            }
            engine.prepare()
            var startError: Error?
            try AudioGuard.attempt("dictation engine start") {
                do { try engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        } catch {
            // Whatever the framework left behind is not to be trusted. Drop
            // the tap if one landed, and let go of the engine entirely: the
            // next start makes a new one.
            AudioGuard.succeeds("dictation removeTap after a failed start") {
                input.removeTap(onBus: 0)
            }
            engine.stop()
            self.ring = nil
            self.format = nil
            isRunning = false
            throw error
        }
        isRunning = true
        lastSoundAt = Date()
        pulse = TapPulse(count: ring.observedBufferCount, at: Date())
        Self.log.info(
            """
            warm engine running at \(inputFormat.sampleRate, privacy: .public) Hz \
            on \(self.currentDevice?.name ?? "the system default", privacy: .public)
            """
        )
    }

    /// Move to the next ear when this one has stopped being a microphone, or
    /// restart on this one when the tap has stopped being a tap.
    ///
    /// Polled from outside rather than timed in here, so the actor owns no
    /// timer and the policy stays in testable places (`TapPulse`,
    /// `InputChoice`). Returns the device now live if anything was restarted,
    /// or nil if nothing changed.
    ///
    /// The two checks answer different failures and must stay in this order.
    /// A stalled tap delivers NO buffers, so `peak` is stale, frozen at
    /// whatever the last buffer held; a silence verdict read off it would be
    /// wrong in both directions. Measured 2026-08-16: a sample-rate change on
    /// the live device left the engine believing it was running and fed
    /// 0 buffers to every hold after, with no notification to act on. The
    /// microphone was fine, so it is NOT marked silent; the engine is simply
    /// rebuilt on the device it already had.
    @discardableResult
    func hopIfDeaf() -> InputChoice.Device? {
        guard !capturing.isOpen else { return nil }

        // Down, for whatever reason: a start that raised, a device that
        // reported 0 Hz, nothing attached at launch. While this poll exists
        // the engine is meant to be up, so keep trying, but not every second
        // for hours on a Mac with no microphone: a start attempt is a fresh
        // engine plus a device scan, and a failure logs.
        guard isRunning else {
            guard Date().timeIntervalSince(lastStartAttempt) >= Self.downRetryInterval else { return nil }
            lastStartAttempt = Date()
            try? startWarm(avoiding: silentUIDs)
            return isRunning ? currentDevice : nil
        }

        if let ring, pulse.observe(count: ring.observedBufferCount, at: Date()) {
            Self.log.error(
                """
                tap on \(self.currentDevice?.name ?? "the system default", privacy: .public) \
                delivered no buffers for \(Int(TapPulse.threshold), privacy: .public)s; restarting the engine
                """
            )
            stop()
            try? startWarm(avoiding: silentUIDs)
            return currentDevice
        }

        if peak > 0 {
            lastSoundAt = Date()
            return nil
        }
        let silentFor = Date().timeIntervalSince(lastSoundAt)
        guard InputChoice.isDead(peak: Float(peak), silentFor: silentFor) else { return nil }

        // Nowhere to go is not a reason to keep re-deciding every second.
        let attached = AudioDevices.all()
        var candidates = silentUIDs
        if let current = currentDevice { candidates.insert(current.uid) }
        let ordered = InputChoice.order(
            attached.map(\.device), pinnedUID: nil, silent: candidates)
        guard let next = ordered.first, !candidates.contains(next.uid) else {
            lastSoundAt = Date()
            return nil
        }

        if let current = currentDevice {
            Self.log.error(
                """
                \(current.name, privacy: .public) delivered nothing for \
                \(Int(silentFor), privacy: .public)s; moving to \(next.name, privacy: .public)
                """
            )
            silentUIDs.insert(current.uid)
        }
        stop()
        try? startWarm(avoiding: silentUIDs)
        return currentDevice
    }

    /// The device list changed under us: something was plugged in, unplugged,
    /// or woke up. Without this the tap dies silently, which CLAUDE.md line
    /// 1389 warns about and which was measured doing exactly that (0 buffers
    /// fed after the default input changed beneath a running engine).
    ///
    /// Two things here are load-bearing, and both were learned by watching
    /// this thrash:
    ///
    /// 1. **Only a real change counts.** Restarting the engine itself fires
    ///    this notification, so acting on every one is an infinite loop:
    ///    restart, notify, restart. Nothing happens unless the set of attached
    ///    devices actually differs.
    /// 2. **Only devices that just APPEARED get forgiven.** Clearing every
    ///    silent verdict resurrected the dead built-in mic on every cycle. A
    ///    device that has been present and silent all along stays written off;
    ///    one that was just plugged in has earned a fresh hearing, because the
    ///    reason it could not hear may have just been removed.
    func devicesChanged() {
        // The engine stops ITSELF when it posts a configuration change (that
        // is what the notification means), and it says so: `engine.isRunning`
        // goes false while this actor still believes otherwise. Measured
        // 2026-08-16 17:15: default input flipped from a headset back to the
        // built-in mic, the device SET was unchanged so the guard below
        // returned, and the tap sat dead until the watchdog noticed 2.7s
        // later. On 1.15.0 nothing noticed at all. So before asking whether
        // the SET changed, ask the engine whether it is still running, and
        // if not, rebuild now rather than in two seconds. Loop-safe: the
        // rebuild's own notification arrives with a running engine.
        if isRunning, !engine.isRunning, !capturing.isOpen {
            Self.log.error(
                """
                engine stopped itself on a configuration change while on \
                \(self.currentDevice?.name ?? "the system default", privacy: .public); restarting
                """
            )
            stop()
            try? startWarm(avoiding: silentUIDs)
            return
        }

        let attached = AudioDevices.all()
        let present = Set(attached.map(\.device.uid))
        guard present != knownUIDs else { return }

        let appeared = present.subtracting(knownUIDs)
        knownUIDs = present
        silentUIDs.subtract(appeared)
        silentUIDs.formIntersection(present)

        // Still hearing fine on a device that is still attached: leave it be.
        if let current = currentDevice, present.contains(current.uid), peak > 0, appeared.isEmpty {
            return
        }
        stop()
        try? startWarm(avoiding: silentUIDs)
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
    var peak: Double { ring?.peak ?? 0 }

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
