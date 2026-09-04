import ChalantDictationCore
import Foundation
import FoundationModels
import os

/// Apple's on-device model, tidying what was dictated.
///
/// **Every failure path returns the input unchanged**, and Part 1 §2 means that
/// literally: a slow model, a refused generation, a context overflow, an
/// unavailable model or a fidelity violation all ship the deterministic text
/// the user would have got anyway. They never learn a model was involved, which
/// is the only honest way to run something that is right most of the time.
///
/// **Measured before it was written** (EVAL-LOG 2026-08-16), on 42 real
/// spontaneous utterances: 2/42 rejected by the guard, 0 refusals, p50 0.99s,
/// p95 2.10s. It does nothing to half of real speech and removes roughly half
/// the fillers in the rest. That is the honest size of it.
@available(macOS 26, *)
actor FoundationModelsPolisher: Polisher {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "polish")

    /// Part 2 §8. Thirty seconds is a ceiling, not a budget: the measured p95 is
    /// 2.1s, so anything near this is a hung request rather than a slow one, and
    /// post-processing sits between transcription and insertion where a hang
    /// costs the user their words.
    private static let timeout: Duration = .seconds(30)

    /// Held only so the warm-up has something to prewarm. **Never used to
    /// respond.** A `LanguageModelSession` keeps a transcript of every turn,
    /// and 1.14.0 through 1.15.1 reused ONE session for every utterance ever
    /// dictated, so the context grew all day: each call carried everything
    /// said before it, got slower for it, and past ~8k tokens every cleanup
    /// failed on context size until relaunch. Measured 2026-08-16 on 92 of the
    /// founder's real utterances through the shipping path: shared session
    /// p50 2.2 to 2.7s and 17 to 26 utterances changed, then context-overflow
    /// failures; a fresh session per utterance p50 0.55s, p95 1.9s, 50
    /// changed, none failed. The model stays resident across sessions, so a
    /// new one costs nothing worth measuring.
    private var warmed: LanguageModelSession?

    /// The 40-character line under which the model is not asked
    /// (`CleanupPrompt.minimumCharactersForCleanup`). An instance value so
    /// an offline run (`tools/textpath --ungated`) can send every Set C row
    /// to the model through this exact path; the app never changes it.
    private let gateCharacters: Int

    init(gateCharacters: Int = CleanupPrompt.minimumCharactersForCleanup) {
        self.gateCharacters = gateCharacters
    }

    /// Warm the model at launch, and again at every key-down.
    ///
    /// **Part 0 §0.5 puts `prewarm()` on the shift gesture, and that has been
    /// the wrong trigger since 2026-08-14**, when cleanup stopped being an
    /// optional gesture and became the default path. Nobody had noticed. It
    /// belongs beside the other first-use cliffs: the measured cold call is
    /// 2.4s against a 0.99s warm median, and that difference lands entirely on
    /// whichever sentence the user happens to dictate first.
    ///
    /// **Launch is not enough, measured 2026-08-21 (EVAL-LOG):** the model is
    /// loaded by the system's `modelmanagerd`, shared by every process, and
    /// **unloaded five minutes after its last use**. A launch prewarm buys
    /// five minutes; after any longer pause the next polish pays the cold
    /// load again (2.49 s against 0.9 s, fresh process, shipping prompt).
    /// So `keyDown` calls this too: the hold is the load's hiding place, a
    /// polish-worthy utterance is over 40 characters and so over ~3 s of
    /// speech, and the cached reload takes 0.9 s. A prewarm on one session
    /// warms the fresh session each piece actually responds on, because the
    /// warmth lives in the system, not the session. When the model is
    /// already loaded the request is a no-op in the daemon ("Not loading
    /// asset"), so every key-down can afford it.
    func warmUp() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = warmed ?? LanguageModelSession(instructions: CleanupPrompt.instructionsPlain)
        warmed = session
        session.prewarm()
    }

    // MARK: - Clean while you talk

    /// Pieces already tidied, by their exact text, and pieces in flight. Filled
    /// by `pretidy` while the key is still held (every chunk of the transcript
    /// that is closed, see `CleanupPrompt.closedChunks`) and read by `polish`
    /// at release, so a long paragraph waits for its tail chunk, not for all
    /// of them. Cleared for each new utterance: the pieces of one hold are no
    /// use to the next, and the cache must never grow all day. Each piece
    /// carries whether it FAILED (shipped as dictated), because the honest
    /// refined-at-once flag needs to know when the reply is the input rejoined.
    private var tidiedPieces: [String: Piece] = [:]
    private var piecesInFlight: [String: Task<Piece, Never>] = [:]

    /// One chunk back from the model: its text (the input itself when it
    /// failed), whether it failed, and why in the corpus row's words:
    /// "landed", "rejected:<rule>", "failed:<error>".
    struct Piece: Sendable {
        let text: String
        let failed: Bool
        let reason: String
        /// The model's unwrapped reply, even when rejected; empty when the
        /// call failed. For the offline measurement only.
        let reply: String

        init(text: String, failed: Bool, reason: String, reply: String) {
            self.text = text
            self.failed = failed
            self.reason = reason
            self.reply = reply
        }

        /// A chunk that ships as dictated, with why.
        init(piece: String, failed reason: String, reply: String = "") {
            self.init(text: piece, failed: true, reason: reason, reply: reply)
        }
    }

    /// When the last model reply completed, ever, in this process. Set in
    /// `finished`, so pretidy replies count too. Nil until the first reply:
    /// that is the cold-start population the speed campaign hunts, and the
    /// gap since is the eviction-horizon instrument (phase 0, 2026-08-21).
    private var lastRespondCompletedAt: Date?
    private var utteranceStartedCold = true
    private var gapAtUtteranceStart: Double?

    func beginUtterance() {
        for task in piecesInFlight.values { task.cancel() }
        piecesInFlight.removeAll()
        tidiedPieces.removeAll()
        tailInFlight = nil
        utteranceStartedCold = lastRespondCompletedAt == nil
        gapAtUtteranceStart = lastRespondCompletedAt.map { Date().timeIntervalSince($0) }
    }

    /// The cold-start facts of the utterance in progress, as fixed at
    /// `beginUtterance`. The same two values ride every `PolishOutcome`,
    /// but an outcome only reaches the caller when the polish beats the
    /// budget, and the first schema-2 row (2026-08-21 18:11) showed what
    /// that costs: a process that had never polished landed raw after a
    /// budget miss and its row said `polishColdStart: false`, the default.
    /// The rows that miss the budget are the ones the speed work reads,
    /// so the caller takes these before it starts waiting.
    var coldStartFacts: (coldStart: Bool, secondsSinceLastPolish: Double?) {
        (utteranceStartedCold, gapAtUtteranceStart)
    }

    /// Tidy, in the background, every chunk of `text` so far: the closed
    /// chunks, which will not change as the speaker goes on, and the tail
    /// chunk as it stands right now, speculatively. Called on a timer during
    /// the hold with the deterministic text of the live transcript. The tail
    /// changes with every few words, so at most one tail speculation runs at
    /// a time; whichever tail text the release actually ends on is then
    /// often already tidied, and the words can land refined at once.
    ///
    /// `urgent` is the key-up call: the last live text before finalization,
    /// started even while an older tail is still in flight, because that older
    /// tail is by definition not the one the release will ask for, and this
    /// one often is. It buys the model the finalization time (0.05 to 0.4 s
    /// measured) as a head start.
    func pretidy(_ text: String, urgent: Bool = false) {
        guard Cleanup.mode() == .live, case .available = SystemLanguageModel.default.availability else { return }
        let all = CleanupPrompt.chunks(text)
        guard !all.isEmpty else { return }
        let closed = Array(all.dropLast())
        var fresh = closed.filter { tidiedPieces[$0] == nil && piecesInFlight[$0] == nil }
        let tail = all[all.count - 1]
        if tidiedPieces[tail] == nil, piecesInFlight[tail] == nil, urgent || tailInFlight == nil,
           CleanupPrompt.worthCleaning(tail) || all.count > 1 {
            fresh.append(tail)
            tailInFlight = tail
        }
        if !fresh.isEmpty {
            // Counts only, never content.
            Self.log.info(
                "pretidy: \(text.count, privacy: .public) chars so far, \(closed.count, privacy: .public) closed chunk(s), \(fresh.count, privacy: .public) started")
        }
        for piece in fresh {
            piecesInFlight[piece] = Task { [weak self] in
                let result = await Self.tidy(piece: piece)
                await self?.finished(piece: piece, result: result)
                return result
            }
        }
    }

    /// The tail speculation in flight, if any: only one at a time.
    private var tailInFlight: String?

    private func finished(piece: String, result: Piece) {
        tidiedPieces[piece] = result
        piecesInFlight[piece] = nil
        if tailInFlight == piece { tailInFlight = nil }
        lastRespondCompletedAt = Date()
    }

    func polish(_ text: String, profile: AppProfile) async throws -> String {
        await polish(text, profile: profile, within: nil).text ?? text
    }

    /// The outcome of one release-time cleanup: the tidied text when every
    /// piece is ready within `budget`, and always the facts (chunk counts,
    /// warm hits, failures, cold start) the corpus row keeps.
    ///
    /// "Refined at once" (spec 2026-08-17, late): at release the caller waits
    /// this long for the refined text and lands it once; if it is not ready,
    /// the raw words land and the swap takes over. Pieces started here keep
    /// running past the budget and land in the cache, so the swap's own call
    /// picks them up rather than starting over.
    func polish(_ text: String, profile: AppProfile, within budget: Duration?) async -> PolishOutcome {
        func outcome(_ result: PolishOutcome.Result, text: String? = nil, chunks: Int = 0, warm: Int = 0, failed: Int = 0, reasons: [String] = [], replies: [String] = []) -> PolishOutcome {
            PolishOutcome(
                result: result, text: text, chunks: chunks, warmChunks: warm,
                failedChunks: failed, coldStart: utteranceStartedCold,
                secondsSinceLastPolish: gapAtUtteranceStart, chunkReasons: reasons, chunkReplies: replies)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return outcome(.empty) }

        // Option B (founder, 2026-08-16): short utterances ship as dictated.
        // The model does nothing useful under 40 characters and costs half a
        // second there; the measured case is on `CleanupPrompt.worthCleaning`.
        guard trimmed.count > gateCharacters else {
            Self.log.info("cleanup skipped: \(trimmed.count, privacy: .public) chars, under the line")
            return outcome(.belowMinimum)
        }

        guard case .available = SystemLanguageModel.default.availability else {
            return outcome(.modelUnavailable)
        }

        // A few sentences at a time, and the reason is reliability rather than
        // the context window. Measured on the founder's own long paragraph
        // (2026-08-16): whole, the model dropped a negation, invented a
        // fragment, or rewrote "I" as "he" in 2 to 3 of 5 runs. In ~40-word
        // pieces, 11 runs and none of those. Same model; small enough pieces.
        //
        // Every chunk stands alone. A chunk the guard rejects ships raw ON ITS
        // OWN, so one bad piece costs a sentence rather than the paragraph.
        // Before this, one rejected phrase anywhere threw away the whole
        // cleanup, which is what the founder saw on 1.14.0.
        //
        // Pieces tidied while the key was still held (see `pretidy`) are taken
        // from the cache, or awaited if still in flight; only the rest go to
        // the model now. That is what keeps a long paragraph's wait at release
        // to about one chunk.
        let pieces = CleanupPrompt.chunks(trimmed)

        // The wait only when it can be won (founder, 2026-08-27: "as fast
        // as possible and it should polish very well"). A budgeted release
        // lands the raw words IMMEDIATELY when more than one piece is
        // missing, or the one missing piece is too long for the window:
        // the second live test paid the full window on four utterances and
        // landed none. The missing pieces still start now and land in the
        // cache, so the record and the hearing pass get them; nobody waits.
        if budget != nil {
            let fresh = pieces.filter { tidiedPieces[$0] == nil && piecesInFlight[$0] == nil }
            if !CleanupPrompt.worthWaiting(freshPieces: fresh) {
                for piece in fresh {
                    let task = Task { [weak self] in
                        let result = await Self.tidy(piece: piece)
                        await self?.finished(piece: piece, result: result)
                        return result
                    }
                    piecesInFlight[piece] = task
                }
                Self.log.notice(
                    "cleanup lands as said at once: \(fresh.count, privacy: .public) piece(s) missing, wait unwinnable")
                return outcome(.notWorthTheWait, chunks: pieces.count, warm: pieces.count - fresh.count)
            }
        }
        let started = ContinuousClock.now
        let deadline = budget.map { started.advanced(by: $0) }
        var out: [String] = []
        var warm = 0
        var failed = 0
        var reasons: [String] = []
        var replies: [String] = []

        for piece in pieces {
            if let done = tidiedPieces[piece] {
                out.append(done.text)
                if done.failed { failed += 1 }
                reasons.append(done.reason)
                replies.append(done.reply)
                warm += 1
                continue
            }
            let task: Task<Piece, Never>
            if let running = piecesInFlight[piece] {
                task = running
                warm += 1
            } else {
                task = Task { [weak self] in
                    let result = await Self.tidy(piece: piece)
                    await self?.finished(piece: piece, result: result)
                    return result
                }
                piecesInFlight[piece] = task
            }
            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                // `Deadline.value` gives up on WAITING, never on the work:
                // the piece keeps running and lands in `tidiedPieces` for
                // the hearing pass. The wait this replaced (a task group of
                // {await task.value, sleep}) could not return before the
                // piece finished, whatever the budget said: see `Deadline`.
                guard remaining > .zero, let value = await Deadline.value(of: task, within: remaining) else {
                    // The elapsed figure is the point: the caller measured
                    // waits of 0.9 to 2.5 s against a 0.65 s budget (log,
                    // 2026-08-18), and this says whether the overshoot is in
                    // here or on the way back to the caller.
                    Self.log.notice(
                        "cleanup not ready within budget: \(trimmed.count, privacy: .public) chars, \(pieces.count, privacy: .public) chunk(s), \(warm, privacy: .public) warm, \(started.duration(to: .now).seconds, privacy: .public)s elapsed here")
                    return outcome(.budgetExpiredInner, chunks: pieces.count, warm: warm, failed: failed, reasons: reasons, replies: replies)
                }
                out.append(value.text)
                if value.failed { failed += 1 }
                reasons.append(value.reason)
                replies.append(value.reply)
            } else {
                let value = await task.value
                out.append(value.text)
                if value.failed { failed += 1 }
                reasons.append(value.reason)
                replies.append(value.reply)
            }
        }

        let elapsed = started.duration(to: .now)
        Self.log.info(
            """
            cleaned \(trimmed.count, privacy: .public) chars in \(pieces.count, privacy: .public) \
            chunk(s), \(warm, privacy: .public) tidied while talking, \(failed, privacy: .public) \
            failed, \(elapsed.seconds, privacy: .public)s\(budget == nil ? "" : " (within budget)")
            """)
        return outcome(
            .landed, text: out.joined(separator: " "),
            chunks: pieces.count, warm: warm, failed: failed, reasons: reasons, replies: replies)
    }

    /// One piece through the model, unwrapped, ending kept, guarded. Every
    /// failure returns the piece as dictated, marked `failed` so the honest
    /// refined-at-once flag can tell a cleaned reply from the input handed
    /// back. One session per piece, never shared: see `warmed`.
    /// Greedy decoding for every polish call. The default sampling is
    /// random: on 2026-08-21 the same Set C row came back as said twice and
    /// expanded once ("can't" to "cannot") in three passes of the shipping
    /// path, so the protected-span mutation rate was a range rather than a
    /// number and no corpus run could be reproduced. Greedy takes the most
    /// likely token every step: the same input gives the same reply, which
    /// is what a cleanup pass measured by a corpus has to do.
    private static let decoding = GenerationOptions(sampling: .greedy)

    /// The opt-in rewrite: the whole utterance reflowed into clean writing.
    ///
    /// Not chunked (a rewrite needs the whole thought to reorder it), a fresh
    /// session (no growing transcript), and it returns nil on ANY failure so
    /// the caller falls back to the safe cleanup: a guardrail refusal (Part 0
    /// Â§0.7, measured reproducible on ordinary sentences), a timeout, or a
    /// rewrite that dropped a number, negation or name. Never leaves the user
    /// with nothing (2026-09-04).
    func rewrite(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > CleanupPrompt.minimumCharactersForCleanup else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: RewritePrompt.instructions)
        let reply: String
        do {
            reply = try await Self.withTimeout(.seconds(6)) {
                try await session.respond(to: RewritePrompt.framing(trimmed), options: Self.decoding).content
            }
        } catch {
            Self.log.notice("rewrite failed, falling back to cleanup: \(Self.errorClass(error), privacy: .public)")
            return nil
        }
        let out = RewritePrompt.unwrap(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = FidelityGuard.checkRewrite(raw: trimmed, rewritten: out)
        if case .violated(let reason) = verdict {
            Self.log.notice("rewrite rejected, falling back: \(reason, privacy: .public)")
            return nil
        }
        return out.isEmpty ? nil : out
    }

    private static func tidy(piece: String) async -> Piece {
        let session = LanguageModelSession(instructions: CleanupPrompt.instructions(for: piece))
        let reply: String
        do {
            reply = try await withTimeout(timeout) {
                try await session.respond(to: CleanupPrompt.framing(piece), options: decoding).content
            }
        } catch {
            // Includes guardrail refusals, which Part 0 §0.7 makes an
            // ordinary outcome. This piece ships as dictated; the rest of
            // the paragraph still gets its chance. The framework's own
            // words are logged (token counts, refusal class), never the
            // transcript, because a failure that only says "failed" is
            // how the shared-session context overflow went unnoticed.
            log.error(
                "cleanup failed on a chunk, shipping that chunk as dictated: \(String(describing: error), privacy: .public)")
            return Piece(piece: piece, failed: "failed:\(errorClass(error))")
        }

        let cleaned = CleanupPrompt.keepingEnding(of: piece, in: CleanupPrompt.unwrap(reply))

        // Lengths and reasons, never content. Part 1 §2: transcripts never
        // enter logs, and this path exists precisely when the model got the
        // content wrong.
        let verdict = FidelityGuard.check(raw: piece, cleaned: cleaned)
        if case .violated(let reason) = verdict {
            log.error("cleanup rejected a chunk: \(reason, privacy: .public)")
            return Piece(piece: piece, failed: "rejected:\(verdict.rule ?? "unknown")", reply: cleaned)
        }
        return Piece(text: cleaned, failed: false, reason: "landed", reply: cleaned)
    }

    /// The error's case name without its payload ("guardrailViolation",
    /// "exceededContextWindowSize"), or "timeout" for the ceiling above.
    private static func errorClass(_ error: Error) -> String {
        if error is CancellationError { return "timeout" }
        let described = String(describing: error)
        return String(described.prefix { $0 != "(" && $0 != ":" })
    }

    /// A timeout that actually abandons the work.
    ///
    /// `Task.sleep` alone would leave the generation running and still holding
    /// the session, so the next utterance would queue behind a request nobody
    /// is waiting for.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
