import AppKit
import AVFoundation
import ChalantDictationCore
import Foundation
import os

/// One dictation, start to finish.
///
/// Part 2 §4: this is a sequential async chain rather than a task group,
/// because stage ordering is semantic. Parallelising it would be a correctness
/// bug dressed as an optimisation.
@MainActor
final class DictationController {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "session")

    private let audio = AudioEngine()
    private let assets = SpeechAssets()
    private let inserter = InsertionChain()
    private let panel = ListeningPanel()
    private var meterTimer: Timer?
    private var transcriber: AppleTranscriber?
    private var pumpTask: Task<Void, Never>?

    private(set) var assetState: SpeechAssetState = .checking
    private(set) var micPermission: MicPermission.Outcome = .pending
    private(set) var isListening = false

    /// M0 runs one locale. The en-IN versus en-US experiment that Part 2 §6
    /// calls the cheapest possible accuracy win belongs to M2, once the corpus
    /// exists to score it with.
    private let locale = Locale(identifier: "en-US")

    /// Where the text is aimed, captured at key-down. Re-checked at key-up so
    /// a notification stealing focus mid-utterance cannot redirect the paste.
    private var target: InsertionTarget?
    private var startedAt: Date?
    private var timings = StageTimings()
    /// How many audio buffers actually reached the analyzer this utterance.
    /// Zero with a healthy engine means the microphone is delivering silence.
    private(set) var fedBuffers = 0

    var onStateChange: (@MainActor () -> Void)?

    /// Bring the engine up and resolve the language model. Called once at
    /// launch. Never throws outward: a failure here has to render as a state
    /// the menu bar can show, not a dead app.
    func warmUp() async {
        assetState = await assets.ensure(locale: locale)
        onStateChange?()

        do {
            try await audio.startWarm()
        } catch {
            assetState = .failed(reason: error.localizedDescription)
            Self.log.error("warm engine failed: \(error.localizedDescription, privacy: .public)")
            onStateChange?()
        }
    }

    // MARK: - The chain

    func keyDown() async {
        Self.log.info("keyDown entered")
        guard !isListening else { return }
        guard assetState.isReady else {
            Self.log.error("ignoring key: assets are not ready")
            return
        }

        // Part 2 §5: lazily, on a real user action, never at launch. Starting
        // the engine does not prompt on its own for a background app; it just
        // hands back silence.
        micPermission = await MicPermission.ensure()
        guard micPermission == .granted else {
            Self.log.error("ignoring key: microphone not granted")
            onStateChange?()
            return
        }

        startedAt = Date()
        timings = StageTimings()

        let front = NSWorkspace.shared.frontmostApplication
        target = InsertionTarget(
            bundleID: front?.bundleIdentifier,
            processID: front?.processIdentifier,
            capturedAt: Date()
        )

        let transcriber = AppleTranscriber()
        self.transcriber = transcriber

        let format = await audio.currentFormat
        // Part 0 §0.5: preheat, measured at ~1.45s finalized versus ~2.2s cold.
        await transcriber.prepare(locale: locale, format: format)

        do {
            try await transcriber.begin(locale: locale, bias: [])
        } catch {
            Self.log.error("could not begin transcription: \(error.localizedDescription, privacy: .public)")
            return
        }

        await audio.beginCapture()
        isListening = true
        panel.show()
        startMeter()
        onStateChange?()

        // Drain the lock-free ring into the analyzer. The ring is polled
        // because its producer is a real-time thread that may not resume a
        // continuation (Part 1 §2).
        guard let ring = await audio.ringHandle() else {
            Self.log.error("no ring handle; capture cannot be drained")
            return
        }
        Self.log.info("capturing")
        fedBuffers = 0
        pumpTask = Task { [transcriber] in
            var total = 0
            while !Task.isCancelled {
                total += await transcriber.drainAndFeed(from: ring)
                await MainActor.run { self.fedBuffers = total }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func keyUp() async {
        Self.log.info("keyUp entered, listening=\(self.isListening, privacy: .public)")
        guard isListening, let transcriber else { return }
        isListening = false

        let releasedAt = Date()
        await audio.endCapture()
        stopMeter()
        panel.hide()

        // Drain whatever is left before finalizing, so the tail of the
        // utterance is not cut off. Part 1 §2: never lose the user's text.
        if let ring = await audio.ringHandle() {
            fedBuffers += await transcriber.drainAndFeed(from: ring)
        }
        Self.log.info("fed \(self.fedBuffers, privacy: .public) buffers")
        pumpTask?.cancel()
        pumpTask = nil
        onStateChange?()

        let transcript: Transcript
        do {
            transcript = try await transcriber.end()
        } catch {
            Self.log.error("finalization failed: \(error.localizedDescription, privacy: .public)")
            self.transcriber = nil
            return
        }
        self.transcriber = nil

        // Part 0 §0.5 makes this the number M0 exists to measure. No latency
        // claim is made anywhere until it has been read off real hardware.
        timings.finalization = Date().timeIntervalSince(releasedAt)

        let text = transcript.rawText
        guard !text.isEmpty else {
            Self.log.info("nothing heard")
            return
        }

        guard let target else { return }

        // Re-validate: if focus moved between key-down and now, the paste
        // would land in the wrong app.
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == target.processID else {
            Self.log.error("focus moved during dictation; refusing to insert")
            return
        }

        let insertStart = Date()
        let outcome = await inserter.insert(text, into: target)
        timings.insertion = Date().timeIntervalSince(insertStart)

        // Lengths and durations only. Part 1 §2: transcripts never enter logs.
        let overruns = await audio.overrunCount
        Self.log.info(
            """
            utterance: \(text.count, privacy: .public) chars, \
            finalize \(self.timings.finalization ?? -1, privacy: .public)s, \
            insert \(self.timings.insertion ?? -1, privacy: .public)s, \
            outcome \(String(describing: outcome), privacy: .public), \
            ring overruns \(overruns, privacy: .public)
            """
        )
        onStateChange?()
    }

    /// Drive the listening panel while the key is held.
    private func startMeter() {
        meterTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let transcriber = self.transcriber else { return }
                let level = await self.audio.peak
                let text = await transcriber.liveText
                self.panel.update(level: level, text: text)
            }
        }
        timer.tolerance = 0.01
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// Latest measured key-release-to-visible, for the menu bar readout.
    var lastLatency: TimeInterval? { timings.keyReleaseToVisible }
}
