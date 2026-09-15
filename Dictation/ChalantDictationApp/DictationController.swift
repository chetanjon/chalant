import AppKit
import AVFoundation
import CoreAudio
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

    /// While set, the words land HERE instead of in another app.
    ///
    /// **The first run's landing spot (2026-08-30).** The founder's own
    /// words: "the onboarding should be easy and they should be able to use
    /// voice dictation immediately without any issues." The issue that
    /// greets a new install is that the first hold happens with nothing
    /// focused to receive text: no field, no app, no landing, and a silence
    /// indistinguishable from a broken build. The tour's try-it card sets
    /// this, so the first sentence anyone dictates has somewhere to go, and
    /// the permission that lets Chalant type into OTHER apps is asked after
    /// they have seen it work rather than before (the risk register's
    /// "design onboarding around a single scripted success").
    var practiceLanding: ((String) -> Void)?
    /// Whatever shows that dictation is listening. Chalant hands in its
    /// island; the panel this used to own is gone.
    private let surface: any DictationSurface

    init(surface: any DictationSurface) {
        self.surface = surface
    }

    private var meterTimer: Timer?
    /// Polls the live microphone's health once a second, for the whole life of
    /// the app, so a deaf ear is found before a session is spent on it.
    private var healthTimer: Timer?
    private var transcriber: (any SpeechEngine)?
    /// Why the utterance in flight is not on the engine the user chose, if it
    /// is not. Empty when it is. Rides the corpus row, never the log's
    /// content rules.
    private var engineNote = ""

    /// Which utterance is current.
    ///
    /// **Generalises the guard that used to protect only the swap.** Every
    /// stage after the key comes up is `await`ed, and a second press, a
    /// cancellation or a conflicting shortcut can land in any of those gaps.
    /// Before this, the only thing checking was `swapGeneration`, and only
    /// for the post-landing swap; a session abandoned mid-finalize could
    /// still reach `inserter.insert` and type into whatever the user had
    /// moved on to. Bumped on every key-down and every cancel, and read at
    /// every point where the next thing would be visible to the user.
    private var sessionID = 0

    /// Whether the utterance that started as `id` is still the one in flight.
    private func isCurrent(_ id: Int) -> Bool { sessionID == id }
    private var pumpTask: Task<Void, Never>?
    /// The better ear's swap in flight after an insert, and what is currently
    /// in the document from this utterance, which is what the ear's version is
    /// compared against. A new key-down retires it: ⌘Z after a second insert
    /// would take the wrong paste.
    private var hearingTask: Task<Void, Never>?
    /// The Whisper listening itself. Retired with the swap task, and never
    /// started before the words have landed: the ANE is the tidy's first.
    private var hearingWorkTask: Task<BetterHearing.Hearing?, Never>?
    private var lastLanded: String = ""
    /// "Clean while you talk": during the hold, every chunk of the transcript
    /// that is already closed goes to the model early, so at release only the
    /// tail waits (spec 2026-08-17, track 3).
    private var pretidyTask: Task<Void, Never>?
    /// The ear stays warm this long after a dictation ends, then rests. Long
    /// enough that a burst of dictations never pays the ~100 ms start twice;
    /// short enough that a Mac left alone stops holding its microphone.
    /// Ten minutes, up from three (1.20.1). The 180 s rest saved the mic from
    /// running all day, which was the complaint; but a dictation ten minutes
    /// after the last one met a sleeping ear, and the founder felt the
    /// 0.5 s wake as lag (2026-08-19). Ten minutes covers a working burst and
    /// still lets the mic rest for the rest of the day.
    static let earWarmHold: Duration = .seconds(600)
    /// How long a silence has to run before the second ear puts the 626 MB
    /// model down. Half an hour, deliberately far longer than the microphone's
    /// ten minutes: closing the microphone costs the next dictation nothing,
    /// and unloading the model costs it the second ear entirely, so the two
    /// are not the same decision and do not share a timer.
    static let earSleepAfter: Duration = .seconds(1800)
    private var earRestTask: Task<Void, Never>?
    /// How often the hold hands the live text to the model. Only one tail
    /// speculation runs at a time, so a shorter tick does not mean more
    /// concurrent work; it means the next speculation starts sooner after the
    /// last one finishes, and the tail it starts on is fresher.
    private static let pretidyInterval: Duration = .milliseconds(400)
    /// How long the release waits for the refined text before landing the raw
    /// words instead. Was 650 ms on the 2026-08-17 measurement (~0.45 s for a
    /// few leftover words, plain prompt); the two live tests of 2026-08-27
    /// measured the shipping prompt warm at 0.45 to 0.65 s for a short tail
    /// and 0.90 to 1.00 s for a 16-to-20-word sentence, and 650 ms landed
    /// exactly nothing all night: the window expired by a hair on tails it
    /// should own. One second owns them. This is a CEILING, not a wait: the
    /// moment the polish is ready, the words land, and `worthWaiting` lands
    /// them at ONCE when the wait cannot be won at all: the ceiling is only
    /// ever paid when the polish is genuinely close.
    static let refineBudget: Duration = .milliseconds(1000)
    /// The caller's hard ceiling: the budget plus a small grace for the hop
    /// back. Kept beside `refineBudget` so the two can never drift apart.
    static let budgetWithGrace: Duration = .milliseconds(1080)
    private var swapGeneration = 0
    private let activity = UserActivityWatch()
    /// Turns a real day of dictating into the spontaneous half of the corpus.
    /// Off unless explicitly switched on; see `CorpusCapture`.
    private let corpus = CorpusCapture()
    /// macOS may nap a background app, and Chalant is background whenever
    /// the user dictates into their own app. On 2026-08-20 both budget
    /// timers fired ~0.7 s late IN UNISON, the signature of coalesced
    /// wake-ups rather than contention, and the words landed raw for it.
    /// The whole utterance runs latency-critical, key-down to landed; the
    /// hearing that may follow is deliberately nap-able.
    private var utteranceActivity: NSObjectProtocol?
    /// The on-device cleanup pass. Returns the input untouched on every failure
    /// path, so the worst case is the text that would have shipped anyway.
    private let polisher = FoundationModelsPolisher()

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
    /// The loudest meter reading of the hold, and whether the key-down mic
    /// proof heard anything: the quiet-speech instruments (campaign phase 0).
    /// Sampled off the 30 Hz meter, so it undercounts true peaks the same
    /// known way the meter does; good enough to separate a whisper from a
    /// normal voice, which is all it is for.
    private var holdPeak: Double = 0
    private var keyDownHeard = true

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

        // The ear used to start warm here and stay warm all day. It now
        // starts on the first hold (`AudioEngine.ensureAlive` at key-down,
        // ~100 ms once) and rests again a while after the last one
        // (`scheduleEarRest`), so an idle Chalant holds no microphone and no
        // sleep assertion. Founder, 2026-08-18: "consuming a lot of power in
        // the background".

        // The insertion path has a cold start too, and it is the biggest one
        // in the whole chain: 3.644s on the first insert against 0.007s on the
        // second, measured on the Release build. Warming the ear and the model
        // while leaving that in place would have left the very first dictation
        // the slowest thing the user ever sees.
        await AutomationPermission.warm()

        // The cleanup model has the same shape of cliff: 2.4s cold against a
        // 0.99s warm median, measured 2026-08-16. Part 0 §0.5 specced this
        // prewarm onto the shift gesture, which stopped being the trigger on
        // 2026-08-14 when cleanup became the default path, so it would never
        // have fired and the whole 1.4s would have landed on whichever sentence
        // the user happened to dictate first.
        if Cleanup.needsModel() {
            await polisher.warmUp()
        }
        // The chosen engine, loaded now rather than behind the first held
        // key. **Never downloaded here**, only loaded when the model is
        // already on disk: a launch that reaches for 470 MB unasked is not a
        // launch. Choosing the engine in Settings is what downloads it.
        Task { await Self.loadChosenEngine(allowingDownload: false) }
        // The names in Contacts, for both ears, read once now rather than on
        // the first utterance. Only when macOS already allows it; nothing is
        // asked here.
        Task { await ContactNames.shared.load() }

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
                await self?.inputTopologyChanged()
            }
        }
        // The engine's own notification fires only when ITS configuration
        // changes. A device the engine is not using can appear (the phone
        // at 14:28 on 2026-08-23) or the device it IS bound to can vanish
        // (the same phone, minutes later) without a word from AVFoundation,
        // and the ear stays bound to a ghost until the next hold. CoreAudio
        // says it straight away: listen to the device list and the default
        // input on the hardware object itself.
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var defaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                await self?.inputTopologyChanged()
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devices, .main, listener)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main, listener)

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
    private func inputTopologyChanged() async {
        await audio.devicesChanged()
        if let ear = await audio.currentDevice {
            Self.log.info("input devices changed; now on \(ear.name, privacy: .public)")
        }
        onStateChange?()
    }

    func liveInputName() async -> String? {
        await audio.currentDevice?.name
    }

    /// Bring the chosen engine's model up, and let the others go.
    ///
    /// `allowingDownload` is false at launch and true when somebody picks an
    /// engine in Settings: the one and only place a 470 MB fetch may start is
    /// a person choosing it, having read what it costs.
    ///
    /// Exactly one model is held at a time. Two would be 1.1 GB of speech
    /// models in a menu-bar app, which is how Chalant got reclaimed by macOS
    /// twice in five days.
    static func loadChosenEngine(allowingDownload: Bool) async {
        switch SpeechEngineChoice.current() {
        case .apple:
            await ParakeetEngine.shared.stop()
            await BetterHearing.shared.stop()
        case .parakeet:
            await BetterHearing.shared.stop()
            await ParakeetEngine.shared.prepare(allowingDownload: allowingDownload)
        case .whisper:
            await ParakeetEngine.shared.stop()
            if allowingDownload || BetterHearing.isDownloaded {
                await BetterHearing.shared.prepare()
            }
        }
    }

    /// One more attempt at typing text that could not be typed before.
    ///
    /// Aimed at whatever is in front NOW rather than at the app the user was
    /// in when they spoke: they have moved, the retry button is in their hand,
    /// and pasting into somewhere they left is the failure this is here to
    /// undo. Captures a fresh target for the same reason, so nothing stale can
    /// be pasted into.
    @MainActor
    private static func retryInsertion(of text: String, using inserter: InsertionChain) async {
        let front = NSWorkspace.shared.frontmostApplication
        let target = InsertionTarget(
            bundleID: front?.bundleIdentifier, processID: front?.processIdentifier,
            capturedAt: Date(), appName: front?.localizedName)
        let outcome = await inserter.insert(text, into: target)
        Self.log.notice("retry insertion: \(String(describing: outcome), privacy: .public)")
    }

    /// Apple hearing the same audio, once, because the chosen engine could
    /// not.
    ///
    /// A whole second engine run, deliberately: the alternative is losing the
    /// sentence, and Part 1 §2 does not trade a sentence for a tidy failure
    /// path. It goes through a file rather than the ring because the ring's
    /// buffers are gone by now and Apple's analyzer takes a stream; writing
    /// 16 kHz mono to a scratch file and feeding it back is the cheapest
    /// honest way to replay audio we already hold.
    ///
    /// Returns nil when Apple cannot answer either, which is the end of the
    /// road and is reported as such rather than retried.
    private static func fallback(on samples: [Float], locale: Locale) async -> Transcript? {
        guard samples.count >= UtteranceTee.minimumSamples else { return nil }
        let engine = AppleTranscriber()
        await engine.prepare(locale: locale, format: UtteranceTee.format)
        do {
            try await engine.begin(locale: locale, hints: [])
            await engine.feed(samples: samples, format: UtteranceTee.format)
            let transcript = try await engine.end()
            return transcript.tokens.isEmpty ? nil : transcript
        } catch {
            Self.log.error("the fallback could not run: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The engine for one utterance, and a note when it is not the one the
    /// user asked for.
    ///
    /// **A held key never starts a download and never waits for a load.** A
    /// chosen engine whose model is still arriving is simply not used for
    /// this utterance: Apple runs it, the row says so, and the next hold gets
    /// the real answer. The alternative was a first dictation that hangs for
    /// seventeen seconds behind a progress bar nobody can see.
    private static func engine(for choice: SpeechEngineChoice) async -> (any SpeechEngine, String) {
        switch choice {
        case .apple:
            return (AppleTranscriber(), "")
        case .parakeet:
            guard await ParakeetEngine.shared.isReady else {
                return (AppleTranscriber(), "parakeetNotReady")
            }
            return (ParakeetTranscriber(), "")
        case .whisper:
            guard await BetterHearing.shared.isReady else {
                return (AppleTranscriber(), "whisperNotReady")
            }
            return (WhisperTranscriber(), "")
        }
    }

    // MARK: - The chain

    func keyDown() async {
        // A new press retires everything the last one might still be doing.
        sessionID &+= 1
        beginUtteranceActivity()
        retirePendingSwap()
        earRestTask?.cancel()
        earRestTask = nil
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
        case .capture, .abandon, .finish, .waitForSetup, .cancel:
            Self.log.error("key down: a press cannot mean any of those")
            return
        }


        guard assetState.isReady else {
            Self.log.error("ignoring key: assets are not ready")
            // **Say why (2026-08-31).** This guard, and the microphone one
            // below, used to return in silence: the user held the key, and
            // nothing happened, with the reason known only to the log. On
            // this Mac that never showed, because everything has been
            // granted and downloaded for weeks. On a stranger's first run it
            // is the likeliest thing that happens, and a silence is
            // indistinguishable from a broken app.
            surface.say(Self.excuse(for: assetState))
            key.setupFailed()
            return
        }

        // Part 2 §5: lazily, on a real user action, never at launch. Starting
        // the engine does not prompt on its own for a background app; it just
        // hands back silence.
        micPermission = await MicPermission.ensure()
        guard micPermission == .granted else {
            Self.log.error("ignoring key: microphone not granted")
            // Pending means the prompt is on screen right now and answering
            // it is the whole job; saying "denied" over it would be a lie.
            surface.say(
                micPermission == .pending
                    ? "macOS is asking about the microphone. Say yes and hold the key again."
                    : "Chalant has no microphone. It is in System Settings, Privacy and Security, Microphone.")
            key.setupFailed()
            onStateChange?()
            return
        }

        startedAt = Date()
        timings = StageTimings()
        holdPeak = 0
        keyDownHeard = true

        let front = NSWorkspace.shared.frontmostApplication
        target = InsertionTarget(
            bundleID: front?.bundleIdentifier,
            processID: front?.processIdentifier,
            capturedAt: Date(),
            appName: front?.localizedName
        )
        // Where the strip opens: the display showing the app being dictated
        // into. Resolved here, at key-down, because that is when we know it.
        let targetDisplay = front.flatMap { installedDictationDisplayLookup?.displayShowing(pid: $0.processIdentifier) }

        // The strip opens NOW, at the press, not when the ear is ready. The
        // founder (2026-08-19): "when I press Option there's a lot of lag and
        // the popup seems slow." Measured that morning: press to capturing
        // 523 ms with the ear asleep, 83 ms warm, and the strip used to wait
        // for that. The mic name follows through the meter. Every way out of
        // the setup below hides it again.
        // **Nothing visible or expensive happens for `activationDelay`.**
        // The light, the music, the tidy model's prewarm: all of it waits,
        // because left Option is a real modifier and `Option+←`, `Option+e`
        // and `Option+Delete` are all a press of it. Before this, every one
        // of those flashed the aurora, woke the microphone, warmed a language
        // model and PAUSED whatever the user was listening to
        // (`NotchViewModel.quietTheRoom` calls `music.pause()`, not a volume
        // duck), then undid it a moment later.
        //
        // **Capture is not deferred, and that is the whole trick.** The audio
        // gate opens below exactly as it always has, before the analyzer is
        // even prepared: the ring holds ~1.6 s and the pump drains the
        // backlog, so a word spoken during the delay is still recorded and
        // still transcribed. The user loses nothing by the wait except a
        // light they did not want.
        scheduleReveal(
            into: target?.appName ?? target?.bundleID ?? "", on: targetDisplay, session: sessionID)
        onStateChange?()

        // Which ear hears this one, decided here and remembered for the
        // row: a chosen engine that is not loaded yet does not hold up the
        // hold and does not start a download, it simply is not used
        // (`engineForThisUtterance`).
        let chosen = SpeechEngineChoice.current()
        let (transcriber, engineNote) = await Self.engine(for: chosen)
        self.transcriber = transcriber
        self.engineNote = engineNote
        // The audio is kept for EVERY utterance now, not only when a second
        // ear was switched on. It is the primary engine's own input on two
        // of the three paths, and on all three it is what a fallback re-hears
        // when the chosen engine cannot answer. Gating it on readiness is
        // what silently lost most of a night on 2026-08-20 (74 utterances,
        // 5 hearings engaged), so it is not gated on anything.
        await transcriber.setKeepsSamples(true)

        // A dead ear is rebuilt HERE, before the format below is read, so the
        // analyzer is prepared against the engine that will actually feed it.
        await audio.ensureAlive()
        // Capture opens the moment the engine runs, BEFORE the analyzer is
        // prepared and begun: the ring holds ~1.6 s, preparation takes ~0.25 s,
        // and the pump drains the backlog once the analyzer is live. What was
        // said during preparation is no longer lost; only the engine's own
        // start, when it was asleep, is still ahead of the first word.
        await audio.beginCapture()
        // A device can flow buffers that are pure digital silence: the
        // founder's built-in mic did exactly that with wired earphones in
        // (2026-08-20, "working the second time... not the first"):
        // `ensureAlive` saw a healthy pulse, the silence-based hop is
        // forbidden mid-capture, and the whole first hold heard nothing. A
        // real microphone's noise floor lifts the peak off EXACT zero within
        // a buffer or two, so a peak still at zero this far into a capture
        // is a dead input: condemn it and rebuild on the next candidate
        // BEFORE the analyzer binds to its format. A healthy mic passes this
        // gate in one or two buffers.
        let heardAtKeyDown = await audio.confirmHearing(within: 0.9)
        // The first of the five numbers the release path is steered by, and
        // the only one measured from key-DOWN: how long it took before there
        // was a microphone worth speaking into.
        if let startedAt { timings.recordingReady = Date().timeIntervalSince(startedAt) }
        keyDownHeard = heardAtKeyDown
        if !heardAtKeyDown {
            await audio.condemnCurrentInput()
        }
        let format = await audio.currentFormat
        // Part 0 §0.5: preheat, measured at ~1.45s finalized versus ~2.2s cold.
        await transcriber.prepare(locale: locale, format: format)

        // Part 4 wants the corpus recorded while doing real work rather than
        // read from a script, and this is the only place that audio exists.
        if let url = await corpus.begin(bundleID: target?.bundleID) {
            await transcriber.setCapture(to: url)
        }

        // Names before it listens, but only for an engine that can be told:
        // Apple accepts them and ignores them (Part 0 §0.1), Parakeet's batch
        // API has no such parameter at all, and building the list costs a
        // phonetic pass over the standing vocabulary.
        let hints = transcriber.usesHints ? await Names.standing() : []
        do {
            try await transcriber.begin(locale: locale, hints: hints)
        } catch {
            Self.log.error("could not begin transcription: \(error.localizedDescription, privacy: .public)")
            key.setupFailed()
            self.transcriber = nil
            await audio.endCapture()
            stopMeter()
            surface.hide()
            endUtteranceActivity()
            onStateChange?()
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
        case .begin, .finish, .waitForSetup, .cancel:
            Self.log.error("ready: setup cannot mean any of those")
            await standDown(transcriber)
            return
        }

        // `ready()` is not the last word: a release landing in any await
        // above runs the whole of `keyUp` before this line resumes. That
        // `keyUp` hides the strip and is finalizing this transcriber; the
        // session the key has already ended is not a session to go live for,
        // and standing it down a second time here would race that finalize
        // and could cost the user the words they just spoke.
        guard key.state == .listening else {
            Self.log.info("released while going live; keyUp owns the stand-down")
            surface.hide()
            return
        }

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
        startPretidy(transcriber)
    }

    /// While the key is held, hand every closed chunk of what has been said so
    /// far to the model, through the same deterministic passes the release
    /// path uses, so the pieces match exactly at release and are already done.
    private func startPretidy(_ transcriber: any SpeechEngine) {
        pretidyTask?.cancel()
        // Tidy-ahead exists to shorten a wait the release will make; in
        // shadow there is no wait, so nothing runs during the hold.
        guard Cleanup.mode() == .live else { return }
        pretidyTask = Task { [weak self, transcriber] in
            guard let self else { return }
            await self.polisher.beginUtterance()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pretidyInterval)
                guard !Task.isCancelled else { return }
                let tokens = await transcriber.liveTokens
                guard !tokens.isEmpty else { continue }
                let text = await self.deterministicText(from: tokens)
                await self.polisher.pretidy(text)
            }
        }
    }

    func keyUp() async {
        Self.log.info("keyUp entered, listening=\(self.isListening, privacy: .public)")
        // Whatever way this release ends, the latency-critical window ends
        // with it; the hearing that may follow is deliberately nap-able.
        defer { endUtteranceActivity() }
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
            // A release after a cancelled hold is expected, not a refusal:
            // `Option+←` arrives dozens of times a minute in an editor, and
            // an error line for each would bury the refusals that matter.
            if why == PushToTalk.cancelledReason {
                Self.log.info("key up after a cancelled hold")
            } else {
                Self.log.error("key up refused: \(why, privacy: .public)")
            }
            return
        case .begin, .capture, .abandon, .cancel:
            Self.log.error("key up: a release cannot mean any of those")
            return
        }

        guard let transcriber else {
            // The state machine makes this unreachable. If it ever happens
            // anyway, it says so rather than leaving the app quietly deaf,
            // which is precisely how the original bug hid.
            Self.log.error("key up with a live session but no transcriber; session dropped")
            stopMeter()
            surface.hide()
            onStateChange?()
            return
        }

        let releasedAt = Date()
        // A reveal that has not fired yet never fires: a hold that ends a
        // hair past the threshold should not flash the light on its way out.
        cancelReveal()
        // Read once, checked at every point below where the next step would
        // be visible to the user. Everything from here on is awaited, and a
        // second press or a cancellation can land in any of those gaps.
        let session = sessionID
        pretidyTask?.cancel()
        pretidyTask = nil
        await audio.endCapture()
        stopMeter()
        // **The light stays, still, until the words are actually somewhere.**
        // `hide()` used to be called here, before draining, finalization,
        // cleanup and insertion, so everything expensive happened in the dark
        // and `restAfterDictation` then enforced 1.4 s of quiet on top. That
        // was invisible while the gap was 0.4 s at p50; it is not reliably
        // that small any more, and a user looking at nothing cannot tell
        // "working" from "broken".
        surface.finishListening()
        // Every way out of this function from here ends the session, and
        // there are eight of them. A `defer` is the only way to be sure the
        // light goes out on all eight: forgetting one would strand the island
        // in `.dictating`, which makes the next key-up a no-op and leaves the
        // user's music paused for good (`NotchViewModel` line 109).
        defer { surface.hide() }
        // Whatever happens below, the hold is over: the ear may rest in a while.
        scheduleEarRest()

        // Drain whatever is left before finalizing, so the tail of the
        // utterance is not cut off. Part 1 §2: never lose the user's text.
        if let ring = await audio.ringHandle() {
            fedBuffers += await transcriber.drainAndFeed(from: ring)
        }
        Self.log.info("fed \(self.fedBuffers, privacy: .public) buffers")
        pumpTask?.cancel()
        pumpTask = nil
        onStateChange?()

        // One last tidy-ahead on the live text as it stands right now, before
        // finalization: the finalized text is very often these same words, so
        // the model gets finalization's 0.05 to 0.4 s as a head start on the
        // very piece the release will wait for.
        if Cleanup.mode() == .live {
            let live = await transcriber.liveTokens
            if !live.isEmpty {
                let text = await deterministicText(from: live)
                await polisher.pretidy(text, urgent: true)
            }
        }

        // Close the corpus file before the transcript is asked for, so the
        // samples are on disk by the time the row naming them is written.
        await transcriber.endCapture()

        // **The one fallback hop.** A chosen engine that throws does not cost
        // the user their sentence and does not get a second try of its own:
        // Apple hears the same audio, once, and the row records why. Never
        // two recognizers on a healthy utterance, which is the whole point of
        // the change above.
        //
        // The distinction that matters is what counts as a failure. Too
        // little audio, or a microphone that delivered digital silence, is
        // NOT an engine failure and must not start a fallback: it is silence,
        // and the user is told so in those words. `SpeechEngine.end()`
        // returns an empty transcript for that and throws only when the
        // engine itself could not answer.
        let samples = await transcriber.utteranceSamples()
        var transcript: Transcript
        do {
            transcript = try await transcriber.end()
        } catch {
            Self.log.error(
                "\(transcriber.engineName, privacy: .public) could not finalize: \(error.localizedDescription, privacy: .public)")
            engineNote = "\(transcriber.engineName)Failed"
            if let rescued = await Self.fallback(on: samples, locale: locale) {
                transcript = rescued
                Self.log.notice("apple answered instead, \(rescued.tokens.count, privacy: .public) words")
            } else {
                // Both ears are out. The words are gone whatever happens
                // next, so say nothing here and let the empty-text path
                // below tell the user, which it now does.
                engineNote += "+appleFailed"
                transcript = Transcript(tokens: [], locale: locale.identifier)
            }
        }
        await transcriber.releaseSamples()
        // Which engine's numbers the vocabulary layer is about to read. After
        // a fallback the tokens are Apple's, so the floor must be Apple's
        // too: carrying Parakeet's across to Apple's distribution would be
        // the same unmeasured transfer in the other direction.
        let fellBack = !engineNote.isEmpty && engineNote.hasSuffix("Failed")
        let engineUsed = fellBack ? "apple" : transcriber.engineName
        let engineFloor = fellBack ? TermMatcher.confidenceFloor : transcriber.confidenceFloor
        self.transcriber = nil

        guard isCurrent(session) else {
            Self.log.info("a newer hold retired this one during finalization; nothing lands")
            return
        }

        // Part 0 §0.5 makes this the number M0 exists to measure. No latency
        // claim is made anywhere until it has been read off real hardware.
        timings.finalization = Date().timeIntervalSince(releasedAt)

        // Part 0 §0.18: a post-ASR guardrail, regardless of engine. Observed
        // 2026-08-15 on a Telugu utterance against an en-US engine: seven mush
        // words followed by forty-one bare commas, mean confidence 0.253 where
        // ordinary English runs 0.5 to 0.99. The words are wrong because the
        // locale is wrong, which is a different problem; the comma run is not
        // text at all. Trimming it cannot lose a word because there are none in
        // it, so Part 1 §2 is untouched.
        // The deterministic pass, in order: refuse what is not text, then
        // collapse what was said twice by accident. Both are pure, both are in
        // Core, and both are measured. Part 0 §0.16 keeps them narrow on
        // purpose: mis-deleting a meaning-bearing token is worse than leaving
        // a stutter in, so anything ambiguous ships verbatim.
        //
        // Measured on the 2026-08-15 baseline: 20.00 corrections per 100 words
        // before, 18.22 after, with exactly three utterances changed and no
        // other output touched.
        let raw = transcript.rawText

        // **One ear, and the wait goes with the second one (2026-09-14).**
        // From 1.40.0 two engines heard every sentence and `HearingMerge`
        // adjudicated them word by word before the words landed. It was the
        // right idea and it bought real corrections: over the founder's own
        // week the second ear disagreed 79 times and was allowed to fix 21 of
        // them, and "I don't want the box" stopped landing as "I want the
        // box".
        //
        // It also cost the whole wait. The only measurement of it is two rows
        // at 3.48 s and 3.11 s from key release to words, against a p50 of
        // 0.40 s on 178 rows of the build before, and 45% of those waits were
        // spent on utterances where the two ears wrote identical words.
        // Nothing tells you which half you are in beforehand.
        //
        // So the choice moves to the user, one engine runs, and this block is
        // where the second one used to be. `HearingMerge` stays compiled and
        // tested rather than deleted: `tools/mergeprobe` still sweeps it, and
        // nothing about it was wrong except the price.
        let prepareStart = Date()
        let tokens = transcript.tokens

        let deterministic = await deterministicText(from: tokens, confidenceFloor: engineFloor)
        if deterministic != raw {
            Self.log.error(
                "guardrail trimmed \(raw.count - deterministic.count, privacy: .public) chars of punctuation run")
        }

        // The model pass no longer stands between the speaker and their words.
        // It used to (2026-08-14 to 1.17.0), at ~1 s per sentence, and the
        // founder felt every one of them. 1.18.0 landed the raw words at once
        // and swapped the tidied ones in place a moment later; 1.19.0 waited a
        // short budget so most sentences land tidied once. A spoken list is
        // shaped without the model, so it lands as a list at once even when
        // the model is not ready in time (`Listing`).
        let shaped = Listing.format(deterministic)
        // The stretch between finalize and the tidy wait (aliases, names,
        // the deterministic passes, list shaping) was the last untimed gap
        // on the release path; the founder feels the whole path, so every
        // piece of it gets a number (2026-08-20).
        let prepareSeconds = Date().timeIntervalSince(prepareStart)
        // Filled in for the first time (2026-09-14). `StageTimings` has
        // carried this field since M0 and nothing ever set it, so the
        // deterministic chain was the one stage on the release path with no
        // number against it.
        timings.textPipeline = prepareSeconds

        // Refined at once, or as said: wait a short, fixed budget for the
        // tidied text and land it once. Tidy-ahead during the hold usually
        // leaves the model only the last few words. If it is not ready in
        // time, the words land as said AND STAY: no in-place tidy swap after
        // the fact. The founder, 2026-08-18: "the text is coming first and
        // then it is refining and changing. The user should not see that
        // because it feels slow." Measured on 37 real utterances that day:
        // 16 landed raw and were then swapped, every one of them a visible
        // change. The tidy is worth less than a still page; the second ear
        // (Better hearing) is the one later change left, and it is a switch.
        var text = shaped
        var refinedAtOnce = false
        // The facts behind the row (campaign phase 0): why the polish landed
        // or didn't, and the counters the speed work steers by.
        // Off: nothing runs. Shadow: nothing waits; the model runs after
        // the words land and reaches only the corpus row (below). Live: the
        // release waits for it.
        let mode = Cleanup.mode()
        var polishOutcomeName = shaped.isEmpty ? "empty" : (mode == .live ? "" : mode.rawValue)
        var chunkCount = 0
        var warmChunks = 0
        var failedChunks = 0
        var polishColdStart = false
        var sinceLastPolish: Double = -1
        // The texts of the path (schema 3): what the model gave back, or
        // why it gave nothing, in the row's own words.
        var modelOutput: String?
        var modelReason = shaped.isEmpty
            ? "skipped:empty"
            : (mode == .live ? "skipped:noTarget" : (mode == .shadow ? "shadow:pending" : "skipped:off"))
        var modelChunks: [String] = []
        if mode == .live, !shaped.isEmpty, let target {
            let waitStart = Date()
            // The budget is enforced HERE, not only inside the polisher, and
            // for three days it was not enforced anywhere: both waits were
            // task groups, and a task group does not return until every
            // child is done, so the "deadline" fired on time and the group
            // then sat on the polish child until the model replied. Every
            // release wait from 2026-08-18 to 08-21 ended within microseconds
            // of the model's reply (2.46 s for a 0.73 s cap on 08-20, 1.697 s
            // on 08-21) and it read as executor starvation; six deadline
            // variants were aimed at timers that had never been late. See
            // `Deadline`. The polish runs as its own task that nobody waits
            // for past the cap: pieces that finish late still land in the
            // polisher's cache for the hearing pass to reuse.
            let polisher = self.polisher
            let bundleID = target.bundleID ?? ""
            // Known since key-down, and taken now so a budget miss cannot
            // erase them from the row: the first schema-2 row reported a
            // never-polished process as warm because the outcome that
            // carries these never arrived.
            let facts = await polisher.coldStartFacts
            polishColdStart = facts.coldStart
            sinceLastPolish = facts.secondsSinceLastPolish ?? -1
            let polishTask = Task {
                await polisher.polish(
                    shaped, profile: AppProfile(bundleID: bundleID),
                    within: Self.refineBudget)
            }
            if let outcome = await Deadline.value(of: polishTask, within: Self.budgetWithGrace) {
                polishOutcomeName = outcome.result.rawValue
                chunkCount = outcome.chunks
                warmChunks = outcome.warmChunks
                failedChunks = outcome.failedChunks
                modelChunks = outcome.chunkReasons
                modelOutput = outcome.modelText
                modelReason = outcome.modelReason
                if let refined = outcome.text, !refined.isEmpty {
                    text = refined
                    // Honest now (phase 0): landed AND at least one chunk
                    // actually came back from the model. An unavailable
                    // model and a run where every chunk failed both used
                    // to count, which inflated the rate the whole speed
                    // campaign steers by.
                    refinedAtOnce = outcome.refinedAtOnce
                } else if outcome.result == .budgetExpiredInner {
                    // Used to land raw in complete silence; the polisher's
                    // own notice says where the time went.
                    Self.log.notice("cleanup missed its inner budget; the words land as said")
                }
            } else {
                polishOutcomeName = "budgetExpiredCaller"
                modelReason = "budgetExpired:caller"
                Self.log.notice("budget expired at the caller; the words land as said")
            }
            timings.polish = Date().timeIntervalSince(waitStart)
        }
        let refinedChanged = text != shaped
        guard !text.isEmpty else {
            // Silence is not a corpus entry. Keeping it would pad the set with
            // rows nobody can label.
            await corpus.discard()
            Self.log.info("nothing heard")
            // **And it says so now.** This was the commonest way a dictation
            // ended in silence: the light went out, nothing appeared, and the
            // reason lived only in the log. It is indistinguishable from a
            // broken app, which is the failure every other guard in this file
            // was taught to speak up about.
            //
            // There is nothing to put on the clipboard, so this is a sentence
            // rather than a recovery. It says which of the two silences it was,
            // because "I heard nothing" and "your microphone heard nothing"
            // have different answers and the instruments to tell them apart
            // are already here.
            if engineNote.hasSuffix("appleFailed") {
                surface.say("Neither ear could make that out. Nothing was typed.")
            } else if !keyDownHeard || holdPeak == 0 {
                let ear = await liveInputName() ?? "your microphone"
                surface.say("\(ear) heard nothing. Check it is not muted.")
            } else {
                surface.say("I didn't catch that.")
            }
            return
        }

        // The tour is holding the landing spot: the words go to the card,
        // nothing is inserted anywhere, and no app is touched. The corpus
        // keeps nothing either, because a practice sentence has no app and
        // no document to be right or wrong in.
        if let practiceLanding {
            await corpus.discard()
            Self.log.info("practice landing: \(text.count, privacy: .public) chars")
            practiceLanding(text)
            return
        }

        guard let target else {
            // Nothing was in front at key-down, so there is nowhere to aim.
            // The words still exist and are the user's.
            Self.log.error("no target was captured; handing the words back")
            await inserter.leaveOnClipboard(text)
            surface.offerRecovery(
                text: text, reason: "Nowhere to type it", retry: nil)
            return
        }

        // The last gate before anything is typed. A session that has been
        // superseded or cancelled since the key came up stops here, which is
        // the difference between "nothing happened" and "words appeared in
        // whatever you moved on to".
        guard isCurrent(session) else {
            Self.log.info("this hold was retired before it could land; nothing is typed")
            return
        }

        // Re-validate: if focus moved between key-down and now, the paste
        // would land in the wrong app.
        //
        // **This used to return in silence, and it was the sharpest of the
        // four.** `InsertionChain` already has a `.targetChanged` path that
        // saves the words and says so, and this earlier guard short-circuited
        // before reaching it: switch app before letting go and the sentence
        // was simply gone, with no message and nothing on the clipboard.
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier == target.processID else {
            Self.log.error("focus moved during dictation; refusing to insert")
            await inserter.leaveOnClipboard(text)
            let inserter = self.inserter
            surface.offerRecovery(text: text, reason: "Focus moved while you spoke") {
                // Retry aims at whatever is in front NOW, which is where the
                // user went, and captures its own target so nothing stale can
                // be pasted into.
                Task { await Self.retryInsertion(of: text, using: inserter) }
            }
            return
        }

        let insertStart = Date()
        let outcome = await inserter.insert(text, into: target)
        timings.insertion = Date().timeIntervalSince(insertStart)

        // What actually reached the app, and if nothing did, why.
        let insertOutcomeName: String
        var inserted: String?
        switch outcome {
        case .inserted(let tier, let landing):
            inserted = text
            insertOutcomeName = "inserted:\(tier):\(landing.rawValue)"
            // The one number allowed to say the words are on screen, and only
            // where the focused field answered both before and after and had
            // grown. Nil the rest of the time, which is most of the time,
            // because Electron and web views answer nothing.
            if landing == .confirmed {
                timings.visibleConfirmed = Date().timeIntervalSince(releasedAt)
            }
        case .leftOnClipboard(let reason):
            insertOutcomeName = "leftOnClipboard:\(reason)"
        case .refused(let reason):
            insertOutcomeName = "refused:\(reason)"
        }

        // The row goes out the moment the outcome is known, BEFORE the
        // hearing starts, so the hearing's decision seconds later can be
        // appended against this row's id (`CorpusCapture.annotate`).
        let holdSeconds = startedAt.map { releasedAt.timeIntervalSince($0) } ?? 0
        let corpusRow = await corpus.finish(
            output: text,
            fedBuffers: fedBuffers,
            finalize: timings.finalization,
            insert: timings.insertion,
            polish: timings.polish,
            prepare: prepareSeconds,
            refinedAtOnce: refinedAtOnce,
            holdSeconds: holdSeconds,
            inputPeak: holdPeak,
            keyDownHeard: keyDownHeard,
            polishOutcome: polishOutcomeName,
            chunkCount: chunkCount,
            warmChunks: warmChunks,
            failedChunks: failedChunks,
            refinedChanged: refinedChanged,
            polishColdStart: polishColdStart,
            secondsSinceLastPolish: sinceLastPolish,
            merge: nil,
            texts: CorpusCapture.Texts(
                asrRaw: raw,
                afterDeterministic: shaped,
                modelOutput: modelOutput,
                modelReason: modelReason,
                modelChunks: modelChunks,
                inserted: inserted,
                insertOutcome: insertOutcomeName))

        // Now watch what they do to it. Only when the text actually landed in
        // the document: text left on the clipboard was never inserted, so
        // anything the focused field says next has nothing to do with us and
        // diffing against it would invent corrections out of the user's own
        // typing. Fire and forget, so nothing here is on the path they feel.
        // The paste "succeeded", but did it have anywhere to land? Part 1 §1
        // stands: accessibility never REFUSES an insertion. It is allowed to
        // notice, afterwards and only on affirmative evidence, that focus was
        // somewhere that takes no text (the desktop, a button): there the ⌘V
        // was a no-op, the words would be silently lost, and worse, arming
        // the swap machinery would send a later ⌘Z into an app like Finder,
        // where undo moves files. The words go back on the clipboard and the
        // island says so ("if the user forget to pick a place to speak... it
        // should record and give them what they spoke", the founder,
        // 2026-08-20). Electron and web apps report nothing affirmative and
        // keep today's path untouched.
        var landed = false
        if case .inserted = outcome {
            let role = LandingProbe.focusedRole()
            if LandingRoles.verdict(role: role) == .doesNot {
                await inserter.leaveOnClipboard(text)
                let inserter = self.inserter
                surface.offerRecovery(text: text, reason: "Nowhere to type it") {
                    Task { await Self.retryInsertion(of: text, using: inserter) }
                }
                Self.log.notice(
                    "no landing spot (role \(role ?? "none", privacy: .public)); words left on the clipboard")
            } else {
                landed = true
            }
        }

        if landed {
            await CorrectionObserver.shared.watch(
                inserted: text, in: target.bundleID)
            lastLanded = text
            retirePendingSwap()
            // **Nothing changes the page after the words land any more.**
            // The in-place swap was the second ear's only door once the merge
            // could not be reached in time, and with one engine there is no
            // second hearing to swap in. `startHearingSwap`, `SwapPolicy` and
            // `replaceLastInsertion` stay compiled and tested rather than
            // deleted: the machinery is sound, its tests pin real rules, and
            // the day something earns a post-landing correction again it
            // should not have to be rebuilt from the commit log.
        } else if case .inserted = outcome {
            // Rescued above; the toast has already spoken.
        } else {
            // Nothing landed, so there is nothing for the second ear to swap,
            // and the words are already on the clipboard (the chain places
            // them there on every refusal that gets this far). Until tonight
            // nothing SAID so, and a refusal read as words vanishing.
            let inserter = self.inserter
            let retry: @MainActor () -> Void = {
                Task { await Self.retryInsertion(of: text, using: inserter) }
            }
            switch outcome {
            case .refused(reason: .secureInputActive(let holder)):
                // No retry offered: while secure input is held the system
                // drops synthetic keystrokes, so a second attempt would fail
                // the same way. The words stay out of visible history too.
                let who = holder.map { " (\($0))" } ?? ""
                surface.say("A password field has the keyboard\(who). Your words are on the clipboard.")
            case .refused(reason: .targetChanged):
                surface.offerRecovery(
                    text: text, reason: "Focus moved while you spoke", retry: retry)
            case .refused(reason: .noTarget):
                // Said nothing at all before this.
                surface.offerRecovery(text: text, reason: "Nowhere to type it", retry: retry)
            case .leftOnClipboard:
                surface.offerRecovery(text: text, reason: "Couldn't type there", retry: retry)
            case .inserted:
                break
            }
        }

        // Shadow: the model runs now, once, over the text that landed, and
        // its reply reaches the corpus row and nothing else. After the second
        // hearing, when there is one, so the two models never share the ANE
        // and the time recorded is the model's own. Utility priority: nothing
        // the user feels is behind it.
        if mode == .shadow, !shaped.isEmpty, let corpusRow {
            startShadowPolish(of: shaped, bundleID: target.bundleID ?? "", corpusRow: corpusRow, after: hearingTask)
        }

        // Lengths and durations only. Part 1 §2: transcripts never enter logs.
        let overruns = await audio.overrunCount
        Self.log.notice(
            """
            utterance on \(engineUsed, privacy: .public)\(self.engineNote.isEmpty ? "" : " (\(self.engineNote))", privacy: .public): \(text.count, privacy: .public) chars, \
            finalize \(self.timings.finalization ?? -1, privacy: .public)s, \
            \(refinedAtOnce ? "refined at once" : "raw", privacy: .public) after \
            \(self.timings.polish ?? 0, privacy: .public)s wait, \
            dispatch \(self.timings.insertion ?? -1, privacy: .public)s, \
            \(self.timings.visibleConfirmed.map { "seen after \($0)s" } ?? "arrival unconfirmed", privacy: .public), \
            outcome \(String(describing: outcome), privacy: .public), \
            ring overruns \(overruns, privacy: .public)
            """
        )

        onStateChange?()
    }

    /// How long the key must be held before anything is shown, paused or
    /// loaded.
    ///
    /// **Not a gate on recording, only on spending.** 180 ms is long enough
    /// that a shortcut is over before it costs anything and short enough that
    /// a real hold feels immediate: the founder's own complaint about the
    /// press feeling slow (2026-08-19) was measured at 523 ms with the ear
    /// asleep, and this is a third of that. A hold shorter than this produces
    /// well under the half second any engine here will accept, so it was
    /// never going to become text.
    static let activationDelay: Duration = .milliseconds(180)

    private var revealTask: Task<Void, Never>?

    /// Show the light, start the meter, and pay for the model, once the hold
    /// has lasted long enough to mean something.
    private func scheduleReveal(into name: String, on display: CGDirectDisplayID?, session: Int) {
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.activationDelay)
            guard let self, !Task.isCancelled, self.isCurrent(session), self.key.state != .idle
            else { return }
            // **Said out loud because it is the assertion of manual row 1.**
            // "No light" is otherwise only checkable by eye, and the whole
            // point of the threshold is that an Option+arrow never gets here.
            // A line at the moment the aurora opens, and the absence of one,
            // is what makes that row provable by a harness rather than a
            // person: it is also the moment the music is paused
            // (`beginDictating` is the only caller of `quietTheRoom`).
            Self.log.info("revealing: the hold lasted long enough to be one")
            self.surface.show(into: name, mic: nil, on: display)
            self.startMeter()
            self.onStateChange?()
            // Behind the light rather than in front of it, for the same
            // reason: an abandoned shortcut must not cost a model load. The
            // system unloads the tidy model five minutes after its last use
            // (measured 2026-08-21), so a hold after a longer pause would
            // otherwise pay 2.49 s against 0.9 s at the one moment the user
            // is waiting. A no-op when already warm.
            if Cleanup.needsModel() {
                Task { await self.polisher.warmUp() }
            }
            self.onStateChange?()
        }
    }

    private func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
    }

    /// Another key arrived while the hold key was down, so this was a
    /// shortcut and not a sentence.
    ///
    /// Everything recorded is discarded, nothing is transcribed, nothing is
    /// typed, and nothing is said: the user pressed `Option+←` and expects
    /// their cursor to move, not to be told anything about dictation.
    func otherKeyPressed() async {
        switch key.otherKeyPressed() {
        case .cancel(let why):
            Self.log.info("hold cancelled: \(why, privacy: .public)")
            await discardUtterance()
        case .ignored:
            // The overwhelming majority: an ordinary keystroke with no hold
            // in flight. Not logged, or the log would be every key of the day.
            return
        case .begin, .capture, .abandon, .finish, .waitForSetup:
            Self.log.error("a conflicting key cannot mean any of those")
        }
    }

    /// Stand a live or arming session down and keep nothing from it.
    private func discardUtterance() async {
        // Retire anything already in flight from this hold, so a finalize or
        // an insert that has not reached its next `await` can never land.
        sessionID &+= 1
        cancelReveal()
        pretidyTask?.cancel()
        pretidyTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        await audio.endCapture()
        stopMeter()
        surface.hide()
        endUtteranceActivity()
        scheduleEarRest()
        if let engine = transcriber {
            await engine.releaseSamples()
            // Closed rather than abandoned: an engine left mid-stream holds
            // its analyzer and would queue the next hold behind it. Its text
            // is deliberately dropped on the floor.
            _ = try? await engine.end()
            transcriber = nil
        }
        await corpus.discard()
        onStateChange?()
    }

    /// A while after the last dictation, close the microphone. Any key-down
    /// cancels this; a hold in progress is never interrupted (`rest` refuses
    /// while capturing).
    private func scheduleEarRest() {
        earRestTask?.cancel()
        earRestTask = Task { [weak self] in
            try? await Task.sleep(for: Self.earWarmHold)
            guard let self, !Task.isCancelled, !self.isListening else { return }
            await self.audio.rest()
            self.onStateChange?()
            // Then, much later, the model itself. Twice in five days
            // (2026-09-05 and 09-10) macOS terminated Chalant while nobody
            // was looking, both times on a machine at 88% swap, and a
            // menu-bar app holding 626 MB of speech model is what
            // RunningBoard reaches for first. An idle Chalant should not be
            // the biggest thing on the system.
            try? await Task.sleep(for: Self.earSleepAfter - Self.earWarmHold)
            guard !Task.isCancelled, !self.isListening else { return }
            await BetterHearing.shared.sleep()
            self.onStateChange?()
        }
    }

    /// The deterministic passes, in order, from the engine's tokens to text:
    /// aliases, then the phonetic vocabulary passes (spans before single
    /// words), then refuse what is not text, collapse what was said twice by
    /// accident, and remove the words nobody meant to say. All pure, all in
    /// Core, all measured. Used at release on the whole transcript and, during
    /// the hold, on the finalized prefix ("clean while you talk"), so the two
    /// agree word for word on the part they share.
    /// The asset state in one sentence a person can act on. Every branch
    /// says what is true and, where there is one, the next move.
    nonisolated static func excuse(for state: SpeechAssetState) -> String {
        switch state {
        case .checking:
            return "Still getting ready. Try the key again in a moment."
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded())
            return percent > 0
                ? "macOS is still downloading the words for your language, \(percent)%."
                : "macOS is downloading the words for your language."
        case .unsupported(let requested):
            return "macOS has no dictation model for \(requested) yet."
        case .failed:
            return "The language model did not load. Try the key again in a moment."
        case .available:
            return "Ready."
        }
    }

    private func deterministicText(from tokens: [Token], confidenceFloor: Double = TermMatcher.confidenceFloor) async -> String {

        // **The vocabulary pass runs FIRST, and on tokens rather than text.**
        // It is the only stage that needs per-word confidence, and confidence
        // exists only on tokens; the three stages after it delete words, after
        // which nothing aligns back to the engine's own scoring. Substitution
        // is strictly one word for one word, so running it first cannot disturb
        // them.
        //
        // Measured on the 90-utterance corpus 2026-08-15: 8 repairs, 0
        // corruptions (`Challant` → `Chalant`, `Jonalagata` → `Jonnalagadda`,
        // `versal` → `Vercel`, `Kisu` → `Kizu`). It does nothing at all until
        // the vocabulary is non-empty, which today means until someone sets it
        // by hand or M5's learner fills it.
        // Spans first, while every token is still present. A name the engine
        // broke in half needs all its pieces, and joining can only shorten the
        // sequence the single-word pass then walks.
        //
        // It is a separate pass because the evidence is different: a split name
        // is made of CONFIDENTLY heard real words (`friction` and `lens` both
        // came back at 0.98), so the single-word gate, which fires only on
        // uncertainty, can never see it.
        // Aliases FIRST, and they are the only stage that ignores confidence.
        // A pair the user typed themselves, twice, over a word Chalant had just
        // put in their document is not a guess needing acoustic verification.
        // It also has to ignore confidence to work at all: proper-noun errors
        // are confident errors, and `Chalan` for `Chalant` measured 0.87.
        // What macOS itself calls a word, for the tokens that could be
        // substituted at all (2026-08-31). The hand-written everyday list is
        // a floor and cannot cover English: it lacked "chart", so "can you
        // read this chart" landed as "can you read this Sharat", a contact
        // eating an ordinary word. Only unsure tokens are asked about, which
        // is a handful per utterance, and the rule this buys is the honest
        // one: if the engine wrote a word the system knows, believe it.
        let unsure = tokens
            .filter { ($0.confidence ?? 1) < confidenceFloor }
            .map { $0.text.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
        var knownWords: Set<String> = []
        for word in Set(unsure) where CorrectionObserver.isDictionaryWord(word) {
            knownWords.insert(word)
        }

        let learned = await LearnedTerms.shared.aliases()
        let corrected = TermMatcher.applyingAliases(tokens: tokens, aliases: learned)

        // Then what the second ear taught (2026-08-28): exact substitutions
        // for words the engine doubted, earned by two hearings of the same
        // pair. This is the ear's real door into the text: the swap it is
        // refused in VS Code (and everywhere else, eventually) it delivers
        // here instead, BEFORE the words land, in every app.
        let earTaught = await LearnedTerms.shared.earCorrections()
        let earFixed = TermMatcher.applyingEarCorrections(
            tokens: corrected, corrections: earTaught, confidenceFloor: confidenceFloor,
            knownWords: knownWords)

        // Then the phonetic passes, over the hand-kept list plus everything
        // learned, plus the contacts that sound like something in this
        // utterance (`Names`). Spans before single words, while every token
        // is present.
        let vocabulary = await Names.forMatching(heard: tokens.map(\.text).joined(separator: " "))
        let whole = TermMatcher.joiningSpans(tokens: earFixed, terms: vocabulary)
        let resolved = TermMatcher.resolving(
            tokens: whole, terms: vocabulary, confidenceFloor: confidenceFloor,
            knownWords: knownWords)

        // Three stages, in order, all pure and all in Core: refuse what is not
        // text, collapse what was said twice by accident, then remove the words
        // nobody meant to say.
        // Restatement runs LAST, on the cleanest text, so a repeated
        // sentence matches its twin even when only one copy carried an um.
        // Repair runs BEFORE Fillers (it needs "I mean" as a marker and
        // treats fillers as transparent) and before Restatement, whose
        // prefix rule then sees a clean restart. Contrast runs after the
        // fillers are gone, so "153 um not 135" still reads as a value
        // against a value (2026-08-22).
        // Breaks runs OUTERMOST, on finished clean text: a run-on's pause
        // commas become full stops only after fillers and repairs are gone,
        // so "and, you know, everybody" has already become "and everybody"
        // by the time the joint is judged (2026-08-28).
        // Paragraphs runs LAST, outside Breaks and after it. A spoken cue is
        // only recognised where punctuation shows it stood alone, and
        // `Breaks` is what turns a run-on's pause commas into the full stops
        // that show it (2026-09-14).
        let deterministic = Paragraphs.applying(
            Breaks.sentencing(Contrast.commaBeforeNot(
                Restatement.collapsing(
                    Fillers.removing(
                        Repair.repairing(
                            Disfluency.collapsingRepetitions(
                                Guardrail.settlingEllipses(
                                    Guardrail.trimmingPunctuationRun(
                                        resolved.map(\.text).joined(separator: " "))))))))))
        return deterministic
    }

    // MARK: - After the words have landed

    /// Whatever may still be running from the previous utterance stops here:
    /// a hearing that has not come back yet must not swap the sentence after
    /// this one. The activity watch is disarmed with it.
    /// A deadline no Swift executor can starve on the way in: a raw dispatch
    /// timer on a userInteractive global queue fires the continuation. Only
    /// the resume still travels through the awaiting task's executor, which
    /// is exactly what the paired "deadline wake starved" lines measure.
    /// The timer keeps itself alive through its own handler and fires once.
    private func beginUtteranceActivity() {
        endUtteranceActivity()
        utteranceActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "dictation hold in flight")
    }

    private func endUtteranceActivity() {
        if let utteranceActivity {
            ProcessInfo.processInfo.endActivity(utteranceActivity)
            self.utteranceActivity = nil
        }
    }

    private func retirePendingSwap() {
        swapGeneration += 1
        hearingTask?.cancel()
        hearingTask = nil
        hearingWorkTask?.cancel()
        hearingWorkTask = nil
        activity.disarm()
    }

    // MARK: - Better hearing

    /// The second ear, after the words have landed: Whisper hears the same
    /// audio, its text goes through the plain deterministic passes and the
    /// same tidy, and if it is plausibly the same utterance, differs from what
    /// is in the document, and the policy allows (6 s ceiling, nothing typed,
    /// focus stayed, an app with undo), the words are replaced in place. The
    /// one change a page may still see after the words land, and it is behind
    /// the Better hearing switch. Lengths and timings only in the log.
    ///
    /// `heard` is the first ear's raw text: it picks the names the second ear
    /// reads before it listens (`Names.forHearing`), which is what took the
    /// names set from 29.9% to 10.0% word error on this Mac.
    /// The shadow run: `polish` with no budget over the whole text, as
    /// `tools/textpath` does it, so the row carries exactly what a live
    /// release would have landed had it waited. Never inserted, never
    /// swapped, never shown; the row line it appends is the only trace.
    private func startShadowPolish(of shaped: String, bundleID: String, corpusRow: String, after hearing: Task<Void, Never>?) {
        let polisher = self.polisher
        let corpus = self.corpus
        Task(priority: .utility) {
            if let hearing { _ = await hearing.value }
            await polisher.beginUtterance()
            let facts = await polisher.coldStartFacts
            let started = Date()
            let outcome = await polisher.polish(shaped, profile: AppProfile(bundleID: bundleID), within: nil)
            let seconds = Date().timeIntervalSince(started)
            await corpus.annotateShadow(
                id: corpusRow, output: outcome.modelText, reason: outcome.modelReason,
                chunks: outcome.chunkReasons, seconds: seconds,
                coldStart: facts.coldStart, secondsSinceLastPolish: facts.secondsSinceLastPolish)
            Self.log.notice(
                "shadow: \(outcome.modelReason, privacy: .public) in \(seconds, privacy: .public)s over \(shaped.count, privacy: .public) chars")
        }
    }

    private func startHearingSwap(samples: [Float], heard firstHearing: String, outcome: InsertionOutcome, target: InsertionTarget, insertedAt: Date, utteranceSeconds: TimeInterval, corpusRow: String? = nil, mode: Cleanup.Mode, alreadyRunning: Task<BetterHearing.Hearing?, Never>? = nil) {
        hearingTask?.cancel()
        let generation = swapGeneration
        activity.arm()
        // Utility priority, and only AFTER the words landed: the three
        // models share one Neural Engine, and a Whisper that runs during
        // the release window serializes the tidy behind it (measured
        // 2026-08-20, twice: every real utterance landed raw). The scaled
        // ceiling in SwapPolicy absorbs the later start.
        let work =
            alreadyRunning
            ?? Task<BetterHearing.Hearing?, Never>(priority: .utility) {
                let hints = await Names.forHearing(heard: firstHearing)
                return await BetterHearing.shared.hearFully(samples, hints: hints)
            }
        hearingWorkTask = work
        hearingTask = Task { [weak self] in
            guard let self else { return }
            let heard = await work.value?.text
            // A retired hearing leaves the watch alone: a newer utterance
            // owns it now. Only a hearing that is still current and came
            // back empty stands the watch down itself.
            guard !Task.isCancelled, generation == self.swapGeneration else { return }
            guard let heard else {
                self.activity.disarm()
                return
            }
            let landed = self.lastLanded
            guard BetterHearing.plausible(hearing: heard, against: landed) else {
                Self.log.notice("hearing kept: implausible (\(heard.count, privacy: .public) vs \(landed.count, privacy: .public) chars)")
                if let corpusRow {
                    await self.corpus.annotate(
                        id: corpusRow, decision: "implausible",
                        seconds: Date().timeIntervalSince(insertedAt),
                        charsBefore: landed.count, charsAfter: heard.count)
                }
                self.activity.disarm()
                return
            }
            let cleaned = Listing.format(BetterHearing.deterministic(heard))
            // The model touches the second hearing only in live. In shadow
            // and off it is never shown, and that includes the swap.
            let tidied = mode == .live
                ? ((try? await self.polisher.polish(cleaned, profile: AppProfile(bundleID: target.bundleID ?? ""))) ?? cleaned)
                : cleaned
            guard !Task.isCancelled, generation == self.swapGeneration else { return }
            let front = NSWorkspace.shared.frontmostApplication
            let situation = SwapPolicy.Situation(
                inserted: landed, tidied: tidied, outcome: outcome,
                userActedSinceInsert: self.activity.sawActivity,
                frontIsStillTarget: front?.processIdentifier == target.processID,
                secondsSinceInsert: Date().timeIntervalSince(insertedAt),
                bundleID: target.bundleID, source: .hearing,
                utteranceSeconds: utteranceSeconds)
            self.activity.disarm()
            // Whatever the swap decides, the lesson is kept (2026-08-28):
            // 46 hearings had produced 28 refused swaps, all in VS Code,
            // 25 carrying a real correction the app then threw away. The
            // ear's pre-polish text against what landed, through the same
            // word-pair guards the user's own edits go through; after two
            // hearings of a pair, the fix fires at landing instead
            // (`applyingEarCorrections`), and no swap is needed at all.
            for pair in Correction.earLearnings(inserted: landed, nowReads: cleaned) {
                await LearnedTerms.shared.recordHeardByEar(
                    pair,
                    heardIsWord: CorrectionObserver.isDictionaryWord(pair.heard),
                    meantIsWord: CorrectionObserver.isDictionaryWord(pair.meant))
            }
            switch SwapPolicy.decide(situation) {
            case .keep(let reason):
                Self.log.notice("hearing kept: \(reason.rawValue, privacy: .public) after \(Date().timeIntervalSince(insertedAt), privacy: .public)s")
                if let corpusRow {
                    await self.corpus.annotate(
                        id: corpusRow, decision: reason.rawValue,
                        seconds: Date().timeIntervalSince(insertedAt),
                        charsBefore: landed.count, charsAfter: tidied.count,
                        heard: cleaned)
                }
            case .swap:
                self.activity.expectOwnKeystrokes()
                let swapped = await self.inserter.replaceLastInsertion(with: tidied, into: target)
                if swapped {
                    self.lastLanded = tidied
                    await CorrectionObserver.shared.watch(inserted: tidied, in: target.bundleID)
                }
                Self.log.notice(
                    "hearing \(swapped ? "swapped" : "swap failed", privacy: .public): \(landed.count, privacy: .public) -> \(tidied.count, privacy: .public) chars after \(Date().timeIntervalSince(insertedAt), privacy: .public)s")
                if let corpusRow {
                    await self.corpus.annotate(
                        id: corpusRow, decision: swapped ? "swapped" : "swapFailed",
                        seconds: Date().timeIntervalSince(insertedAt),
                        charsBefore: landed.count, charsAfter: tidied.count,
                        heard: cleaned)
                }
            }
            self.hearingTask = nil
        }
    }

    /// The evidence Core cannot gather for itself: the spell checker's verdict
    /// on every word either ear produced, and everything the user has taught.
    ///
    /// Asked about both sides, unlike the landing chain's `knownWords`, which
    /// asks only about words the engine doubted. The merge needs the answer in
    /// both directions: a non-word on the ear's side is an invention to
    /// refuse, and a non-word on the engine's side is the strongest sign the
    /// ear is right.
    private func mergeSignals(engine tokens: [Token], ear: String) async -> HearingMerge.Signals {
        var known: Set<String> = []
        let candidates =
            Set(tokens.map(\.text)).union(ear.split(whereSeparator: \.isWhitespace).map(String.init))
        for word in candidates {
            let bare = String(word.filter { $0.isLetter || $0.isNumber || $0 == "'" })
            guard !bare.isEmpty else { continue }
            if CorrectionObserver.isDictionaryWord(bare) { known.insert(bare) }
        }
        return HearingMerge.Signals(
            knownWords: known, vocabulary: await Names.forMatching(heard: ear))
    }

    /// Tear down a session that was prepared but never captured, because the
    /// key came up during setup. Nothing was recorded, so there is nothing to
    /// transcribe and nothing to insert: this only has to leave nothing
    /// running. The key is already back at idle, so the next press works.
    private func standDown(_ transcriber: any SpeechEngine) async {
        cancelReveal()
        endUtteranceActivity()
        scheduleEarRest()
        // The strip opens and capture begins at the press now, so a session
        // stood down during setup has both to close.
        await audio.endCapture()
        stopMeter()
        surface.hide()
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
    /// and the surface the live path had already opened.
    private func abandonLiveSession(_ transcriber: any SpeechEngine) async {
        cancelReveal()
        endUtteranceActivity()
        _ = key.release()
        await audio.endCapture()
        stopMeter()
        surface.hide()
        pumpTask?.cancel()
        pumpTask = nil
        pretidyTask?.cancel()
        pretidyTask = nil
        await standDown(transcriber)
    }

    /// Drive the surface while the key is held.
    private func startMeter() {
        meterTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.transcriber != nil else { return }
                // `AudioRing.peak` holds the last buffer's loudest sample, not
                // the loudest since this timer last looked, so a 30Hz poll over
                // ~100Hz of buffers samples some peaks away. Left as is on
                // purpose: the surface smooths it, and widening the ring's API
                // means touching a real-time producer (Part 1 §2) for a
                // cosmetic gain. The scaling this number needs is applied by
                // the surface, which can see the strip's formulas.
                let level = await self.audio.peak
                let mic = await self.audio.currentDevice?.name
                self.holdPeak = max(self.holdPeak, Double(level))
                self.surface.update(level: CGFloat(level), mic: mic)
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
    /// Latest measured key-release-to-paste-dispatch, for the menu bar
    /// readout. Not "to visible": see `StageTimings`.
    var lastLatency: TimeInterval? { timings.keyReleaseToInsertDispatch }
}
