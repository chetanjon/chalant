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
    private var transcriber: AppleTranscriber?
    private var pumpTask: Task<Void, Never>?
    /// The better ear's swap in flight after an insert, and what is currently
    /// in the document from this utterance, which is what the ear's version is
    /// compared against. A new key-down retires it: ⌘Z after a second insert
    /// would take the wrong paste.
    private var hearingTask: Task<Void, Never>?
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
    private var earRestTask: Task<Void, Never>?
    /// How often the hold hands the live text to the model. Only one tail
    /// speculation runs at a time, so a shorter tick does not mean more
    /// concurrent work; it means the next speculation starts sooner after the
    /// last one finishes, and the tail it starts on is fresher.
    private static let pretidyInterval: Duration = .milliseconds(400)
    /// How long the release waits for the refined text before landing the raw
    /// words instead. The on-device model needs ~0.45 s for a few leftover
    /// words with the plain prompt (measured 2026-08-17), so this catches the
    /// common case, a short tail after tidy-ahead, and gives up before the wait
    /// is felt.
    static let refineBudget: Duration = .milliseconds(650)
    private var swapGeneration = 0
    private let activity = UserActivityWatch()
    /// Turns a real day of dictating into the spontaneous half of the corpus.
    /// Off unless explicitly switched on; see `CorpusCapture`.
    private let corpus = CorpusCapture()
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
        if Cleanup.isEnabled() {
            await polisher.warmUp()
        }
        // The better ear, if the switch is on: download if needed, load, warm.
        // Nothing happens here when it is off, which is the default.
        if BetterHearing.isEnabled() {
            Task { await BetterHearing.shared.prepare() }
        }
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
        surface.show(into: target?.appName ?? target?.bundleID ?? "", mic: nil, on: targetDisplay)
        startMeter()
        onStateChange?()

        let transcriber = AppleTranscriber()
        self.transcriber = transcriber
        if BetterHearing.isEnabled(), await BetterHearing.shared.isReady {
            await transcriber.setKeepSamplesForHearing(true)
        }

        // A dead ear is rebuilt HERE, before the format below is read, so the
        // analyzer is prepared against the engine that will actually feed it.
        await audio.ensureAlive()
        // Capture opens the moment the engine runs, BEFORE the analyzer is
        // prepared and begun: the ring holds ~1.6 s, preparation takes ~0.25 s,
        // and the pump drains the backlog once the analyzer is live. What was
        // said during preparation is no longer lost; only the engine's own
        // start, when it was asleep, is still ahead of the first word.
        await audio.beginCapture()
        let format = await audio.currentFormat
        // Part 0 §0.5: preheat, measured at ~1.45s finalized versus ~2.2s cold.
        await transcriber.prepare(locale: locale, format: format)

        // Part 4 wants the corpus recorded while doing real work rather than
        // read from a script, and this is the only place that audio exists.
        if let url = await corpus.begin(bundleID: target?.bundleID) {
            await transcriber.setCapture(to: url)
        }

        do {
            try await transcriber.begin(locale: locale, bias: [])
        } catch {
            Self.log.error("could not begin transcription: \(error.localizedDescription, privacy: .public)")
            key.setupFailed()
            self.transcriber = nil
            await audio.endCapture()
            stopMeter()
            surface.hide()
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
        case .begin, .finish, .waitForSetup:
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
    private func startPretidy(_ transcriber: AppleTranscriber) {
        pretidyTask?.cancel()
        guard Cleanup.isEnabled() else { return }
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
            surface.hide()
            onStateChange?()
            return
        }

        let releasedAt = Date()
        pretidyTask?.cancel()
        pretidyTask = nil
        await audio.endCapture()
        stopMeter()
        surface.hide()
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
        if Cleanup.isEnabled() {
            let live = await transcriber.liveTokens
            if !live.isEmpty {
                let text = await deterministicText(from: live)
                await polisher.pretidy(text, urgent: true)
            }
        }

        // Close the corpus file before the transcript is asked for, so the
        // samples are on disk by the time the row naming them is written.
        await transcriber.endCapture()

        let transcript: Transcript
        do {
            transcript = try await transcriber.end()
        } catch {
            Self.log.error("finalization failed: \(error.localizedDescription, privacy: .public)")
            self.transcriber = nil
            return
        }
        // The utterance's audio for the better ear, before the transcriber
        // goes. Empty unless the ear was on and ready at key-down.
        let hearingSamples = await transcriber.takeUtteranceSamples()
        self.transcriber = nil

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
        let deterministic = await deterministicText(from: transcript.tokens)
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
        if Cleanup.isEnabled(), !shaped.isEmpty, let target {
            let waitStart = Date()
            if let refined = try? await polisher.polish(
                shaped, profile: AppProfile(bundleID: target.bundleID ?? ""), within: Self.refineBudget),
               !refined.isEmpty {
                text = refined
                refinedAtOnce = true
            }
            timings.polish = Date().timeIntervalSince(waitStart)
        }
        guard !text.isEmpty else {
            // Silence is not a corpus entry. Keeping it would pad the set with
            // rows nobody can label.
            await corpus.discard()
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

        // Now watch what they do to it. Only when the text actually landed in
        // the document: text left on the clipboard was never inserted, so
        // anything the focused field says next has nothing to do with us and
        // diffing against it would invent corrections out of the user's own
        // typing. Fire and forget, so nothing here is on the path they feel.
        if case .inserted = outcome {
            await CorrectionObserver.shared.watch(
                inserted: text, in: target.bundleID)
            let insertedAt = Date()
            lastLanded = text
            retirePendingSwap()
            if !hearingSamples.isEmpty {
                startHearingSwap(samples: hearingSamples, heard: raw, outcome: outcome, target: target, insertedAt: insertedAt)
            }
        }

        // Lengths and durations only. Part 1 §2: transcripts never enter logs.
        let overruns = await audio.overrunCount
        Self.log.info(
            """
            utterance: \(text.count, privacy: .public) chars, \
            finalize \(self.timings.finalization ?? -1, privacy: .public)s, \
            \(refinedAtOnce ? "refined at once" : "raw", privacy: .public) after \
            \(self.timings.polish ?? 0, privacy: .public)s wait, \
            insert \(self.timings.insertion ?? -1, privacy: .public)s, \
            outcome \(String(describing: outcome), privacy: .public), \
            ring overruns \(overruns, privacy: .public)
            """
        )

        // The corpus row goes out last, once the outcome is known, so a
        // captured utterance carries the same numbers the log line does.
        await corpus.finish(
            output: text,
            fedBuffers: fedBuffers,
            finalize: timings.finalization,
            insert: timings.insertion)

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
        }
    }

    /// The deterministic passes, in order, from the engine's tokens to text:
    /// aliases, then the phonetic vocabulary passes (spans before single
    /// words), then refuse what is not text, collapse what was said twice by
    /// accident, and remove the words nobody meant to say. All pure, all in
    /// Core, all measured. Used at release on the whole transcript and, during
    /// the hold, on the finalized prefix ("clean while you talk"), so the two
    /// agree word for word on the part they share.
    private func deterministicText(from tokens: [Token]) async -> String {

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
        let learned = await LearnedTerms.shared.aliases()
        let corrected = TermMatcher.applyingAliases(tokens: tokens, aliases: learned)

        // Then the phonetic passes, over the hand-kept list plus everything
        // learned, plus the contacts that sound like something in this
        // utterance (`Names`). Spans before single words, while every token
        // is present.
        let vocabulary = await Names.forMatching(heard: tokens.map(\.text).joined(separator: " "))
        let whole = TermMatcher.joiningSpans(tokens: corrected, terms: vocabulary)
        let resolved = TermMatcher.resolving(tokens: whole, terms: vocabulary)

        // Three stages, in order, all pure and all in Core: refuse what is not
        // text, collapse what was said twice by accident, then remove the words
        // nobody meant to say.
        let deterministic = Fillers.removing(
            Disfluency.collapsingRepetitions(
                Guardrail.trimmingPunctuationRun(
                    resolved.map(\.text).joined(separator: " "))))
        return deterministic
    }

    // MARK: - After the words have landed

    /// Whatever may still be running from the previous utterance stops here:
    /// a hearing that has not come back yet must not swap the sentence after
    /// this one. The activity watch is disarmed with it.
    private func retirePendingSwap() {
        swapGeneration += 1
        hearingTask?.cancel()
        hearingTask = nil
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
    private func startHearingSwap(samples: [Float], heard firstHearing: String, outcome: InsertionOutcome, target: InsertionTarget, insertedAt: Date) {
        hearingTask?.cancel()
        let generation = swapGeneration
        activity.arm()
        hearingTask = Task { [weak self] in
            guard let self else { return }
            let hints = await Names.forHearing(heard: firstHearing)
            let heard = await BetterHearing.shared.hear(samples, hints: hints)
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
                Self.log.info("hearing kept: implausible (\(heard.count, privacy: .public) vs \(landed.count, privacy: .public) chars)")
                self.activity.disarm()
                return
            }
            let cleaned = Listing.format(BetterHearing.deterministic(heard))
            let tidied = (try? await self.polisher.polish(cleaned, profile: AppProfile(bundleID: target.bundleID ?? "")))
                ?? cleaned
            guard !Task.isCancelled, generation == self.swapGeneration else { return }
            let front = NSWorkspace.shared.frontmostApplication
            let situation = SwapPolicy.Situation(
                inserted: landed, tidied: tidied, outcome: outcome,
                userActedSinceInsert: self.activity.sawActivity,
                frontIsStillTarget: front?.processIdentifier == target.processID,
                secondsSinceInsert: Date().timeIntervalSince(insertedAt),
                bundleID: target.bundleID, source: .hearing)
            self.activity.disarm()
            switch SwapPolicy.decide(situation) {
            case .keep(let reason):
                Self.log.info("hearing kept: \(reason.rawValue, privacy: .public) after \(Date().timeIntervalSince(insertedAt), privacy: .public)s")
            case .swap:
                self.activity.expectOwnKeystrokes()
                let swapped = await self.inserter.replaceLastInsertion(with: tidied, into: target)
                if swapped {
                    self.lastLanded = tidied
                    await CorrectionObserver.shared.watch(inserted: tidied, in: target.bundleID)
                }
                Self.log.info(
                    "hearing \(swapped ? "swapped" : "swap failed", privacy: .public): \(landed.count, privacy: .public) -> \(tidied.count, privacy: .public) chars after \(Date().timeIntervalSince(insertedAt), privacy: .public)s")
            }
            self.hearingTask = nil
        }
    }

    /// Tear down a session that was prepared but never captured, because the
    /// key came up during setup. Nothing was recorded, so there is nothing to
    /// transcribe and nothing to insert: this only has to leave nothing
    /// running. The key is already back at idle, so the next press works.
    private func standDown(_ transcriber: AppleTranscriber) async {
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
    private func abandonLiveSession(_ transcriber: AppleTranscriber) async {
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
    var lastLatency: TimeInterval? { timings.keyReleaseToVisible }
}
