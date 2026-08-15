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
///
/// Gated to macOS 26 because it owns `SpeechAssets` and `AppleTranscriber`, and
/// `SpeechTranscriber` has no backport. Everything below it, the audio engine,
/// the event tap and the insertion ladder, is ungated and reachable at Chalant's
/// own macOS 15 floor, which is what lets the command flow share the same ear.
@available(macOS 26, *)
@MainActor
final class DictationController {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "session")

    private let audio = AudioEngine()
    private let assets = SpeechAssets()
    private let inserter = InsertionChain()
    private let panel = ListeningPanel()
    private var meterTimer: Timer?
    /// Polls the live microphone's health once a second, for the whole life of
    /// the app, so a deaf ear is found before a session is spent on it.
    private var healthTimer: Timer?
    private var transcriber: AppleTranscriber?
    private var pumpTask: Task<Void, Never>?

    private(set) var assetState: SpeechAssetState = .checking
    private(set) var micPermission: MicPermission.Outcome = .pending

    /// The key's own state, which used to be a lone `isListening` flag set
    /// after ~180ms of setup. A release landing inside that window was dropped
    /// and the app went live behind the user, permanently deaf until relaunch.
    /// `PushToTalk` holds the decision instead, and its tests hold the race.
    private var key = PushToTalk()

    /// Read by the menu bar (`App.swift`). Derived now, so there is exactly
    /// one place the answer lives.
    var isListening: Bool { key.state == .listening }

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
    /// Exposed so the debug-only insertion test hook can drive the same
    /// ladder the dictation path uses.
    var insertionChain: InsertionChain { inserter }

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

        // The insertion path has a cold start too, and it is the biggest one
        // in the whole chain: 3.644s on the first insert against 0.007s on the
        // second, measured on the Release build. Warming the ear and the model
        // while leaving that in place would have left the very first dictation
        // the slowest thing the user ever sees.
        await AutomationPermission.warm()

        watchInputDevices()
    }

    /// Keep the engine on an ear that can actually hear, for the whole life of
    /// the app rather than only at launch.
    ///
    /// Two halves, because they answer different failures. The notification
    /// covers a device arriving or leaving, which CLAUDE.md line 1389 warns
    /// kills the tap silently, and which was measured doing exactly that: after
    /// the default input changed under a running engine, the next session fed
    /// **0 buffers**. The poll covers the quieter case that has no event at
    /// all, a device that is attached and selected and simply produces
    /// nothing, which is what a closed lid does to the built-in microphone.
    private func watchInputDevices() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.audio.devicesChanged()
                if let ear = await self.audio.currentDevice {
                    Self.log.info("input devices changed; now on \(ear.name, privacy: .public)")
                }
                self.onStateChange?()
            }
        }

        healthTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await self.audio.hopIfDeaf() != nil { self.onStateChange?() }
            }
        }
        timer.tolerance = 0.25
        healthTimer = timer
    }

    /// The name of the ear currently live, for the panel and the menu bar. A
    /// wrong microphone must never be a mystery: that mystery cost an evening.
    func liveInputName() async -> String? {
        await audio.currentDevice?.name
    }

    // MARK: - The chain

    func keyDown() async {
        Self.log.info("keyDown entered")
        switch key.press() {
        case .begin:
            break
        case .ignored(let why):
            // Never silent. A key that does nothing and explains nothing is
            // half of the bug this state machine exists to end: the app
            // refused every press for three hours and never said so once.
            Self.log.error("key down refused: \(why, privacy: .public)")
            return
        case .capture, .abandon, .finish, .waitForSetup:
            Self.log.error("key down: a press cannot mean any of those")
            return
        }

        guard assetState.isReady else {
            Self.log.error("ignoring key: assets are not ready")
            key.setupFailed()
            return
        }

        // Part 2 §5: lazily, on a real user action, never at launch. Starting
        // the engine does not prompt on its own for a background app; it just
        // hands back silence.
        micPermission = await MicPermission.ensure()
        guard micPermission == .granted else {
            Self.log.error("ignoring key: microphone not granted")
            key.setupFailed()
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
            key.setupFailed()
            self.transcriber = nil
            return
        }

        // Every line above this one was async, and the finger may have come up
        // during any of them. This is the moment that used to go live
        // regardless, with the key already released and nothing able to
        // clear it.
        switch key.ready() {
        case .capture:
            break
        case .abandon:
            Self.log.info("released while still starting; standing down without capturing")
            await standDown(transcriber)
            return
        case .ignored(let why):
            Self.log.error("setup finished but \(why, privacy: .public)")
            await standDown(transcriber)
            return
        case .begin, .finish, .waitForSetup:
            Self.log.error("ready: setup cannot mean any of those")
            await standDown(transcriber)
            return
        }

        await audio.beginCapture()
        panel.show()
        startMeter()
        onStateChange?()

        // Drain the lock-free ring into the analyzer. The ring is polled
        // because its producer is a real-time thread that may not resume a
        // continuation (Part 1 §2).
        guard let ring = await audio.ringHandle() else {
            // This used to return with the app still listening, which is the
            // second way it could be left permanently deaf. Now the session
            // it cannot run is the session it ends.
            Self.log.error("no ring handle; capture cannot be drained")
            await abandonLiveSession(transcriber)
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
        switch key.release() {
        case .finish:
            break
        case .waitForSetup:
            // The window that used to cost the session. The release is
            // remembered rather than dropped, and `ready()` stands the setup
            // down the moment it finishes.
            Self.log.info("released while still starting; setup will stand down")
            return
        case .ignored(let why):
            Self.log.error("key up refused: \(why, privacy: .public)")
            return
        case .begin, .capture, .abandon:
            Self.log.error("key up: a release cannot mean any of those")
            return
        }

        guard let transcriber else {
            // The state machine makes this unreachable. If it ever happens
            // anyway, it says so rather than leaving the app quietly deaf,
            // which is precisely how the original bug hid.
            Self.log.error("key up with a live session but no transcriber; session dropped")
            stopMeter()
            panel.hide()
            onStateChange?()
            return
        }

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

    /// Tear down a session that was prepared but never captured, because the
    /// key came up during setup. Nothing was recorded, so there is nothing to
    /// transcribe and nothing to insert: this only has to leave nothing
    /// running. The key is already back at idle, so the next press works.
    private func standDown(_ transcriber: AppleTranscriber) async {
        do {
            _ = try await transcriber.end()
        } catch {
            // Not swallowed (Part 1 §3): a transcriber that will not close is
            // worth knowing about even when nobody is waiting on its text.
            Self.log.error("stand-down finalize failed: \(error.localizedDescription, privacy: .public)")
        }
        self.transcriber = nil
        onStateChange?()
    }

    /// End a session that went live and then could not run, closing the gate
    /// and the panel the live path had already opened.
    private func abandonLiveSession(_ transcriber: AppleTranscriber) async {
        _ = key.release()
        await audio.endCapture()
        stopMeter()
        panel.hide()
        pumpTask?.cancel()
        pumpTask = nil
        await standDown(transcriber)
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
