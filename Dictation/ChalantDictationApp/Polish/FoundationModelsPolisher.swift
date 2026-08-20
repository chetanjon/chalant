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

    /// Warm the model at launch rather than on first use.
    ///
    /// **Part 0 §0.5 puts `prewarm()` on the shift gesture, and that has been
    /// the wrong trigger since 2026-08-14**, when cleanup stopped being an
    /// optional gesture and became the default path. Nobody had noticed. It
    /// belongs beside the other first-use cliffs: the measured cold call is
    /// 2.4s against a 0.99s warm median, and that difference lands entirely on
    /// whichever sentence the user happens to dictate first.
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
    /// use to the next, and the cache must never grow all day.
    private var tidiedPieces: [String: String] = [:]
    private var piecesInFlight: [String: Task<String, Never>] = [:]

    func beginUtterance() {
        for task in piecesInFlight.values { task.cancel() }
        piecesInFlight.removeAll()
        tidiedPieces.removeAll()
        tailInFlight = nil
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
        guard Cleanup.isEnabled(), case .available = SystemLanguageModel.default.availability else { return }
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

    private func finished(piece: String, result: String) {
        tidiedPieces[piece] = result
        piecesInFlight[piece] = nil
        if tailInFlight == piece { tailInFlight = nil }
    }

    func polish(_ text: String, profile: AppProfile) async throws -> String {
        try await polish(text, profile: profile, within: nil) ?? text
    }

    /// The tidied text if every piece is ready within `budget`, else nil.
    ///
    /// "Refined at once" (spec 2026-08-17, late): at release the caller waits
    /// this long for the refined text and lands it once; if it is not ready,
    /// the raw words land and the swap takes over. Pieces started here keep
    /// running past the budget and land in the cache, so the swap's own call
    /// picks them up rather than starting over.
    func polish(_ text: String, profile: AppProfile, within budget: Duration?) async throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Option B (founder, 2026-08-16): short utterances ship as dictated.
        // The model does nothing useful under 40 characters and costs half a
        // second there; the measured case is on `CleanupPrompt.worthCleaning`.
        guard CleanupPrompt.worthCleaning(trimmed) else {
            Self.log.info("cleanup skipped: \(trimmed.count, privacy: .public) chars, under the line")
            return text
        }

        guard case .available = SystemLanguageModel.default.availability else { return text }

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
        let started = ContinuousClock.now
        let deadline = budget.map { started.advanced(by: $0) }
        var out: [String] = []
        var warm = 0

        for piece in pieces {
            if let done = tidiedPieces[piece] {
                out.append(done)
                warm += 1
                continue
            }
            let task: Task<String, Never>
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
                guard remaining > .zero, let value = await Self.value(of: task, within: remaining) else {
                    // The elapsed figure is the point: the caller measured
                    // waits of 0.9 to 2.5 s against a 0.65 s budget (log,
                    // 2026-08-18), and this says whether the overshoot is in
                    // here or on the way back to the caller.
                    Self.log.notice(
                        "cleanup not ready within budget: \(trimmed.count, privacy: .public) chars, \(pieces.count, privacy: .public) chunk(s), \(warm, privacy: .public) warm, \(started.duration(to: .now).seconds, privacy: .public)s elapsed here")
                    return nil
                }
                out.append(value)
            } else {
                out.append(await task.value)
            }
        }

        let elapsed = started.duration(to: .now)
        Self.log.info(
            """
            cleaned \(trimmed.count, privacy: .public) chars in \(pieces.count, privacy: .public) \
            chunk(s), \(warm, privacy: .public) tidied while talking, \(elapsed.seconds, privacy: .public)s\
            \(budget == nil ? "" : " (within budget)")
            """)
        return out.joined(separator: " ")
    }

    /// The task's value if it finishes within `limit`, else nil; the task
    /// itself keeps running.
    private static func value(of task: Task<String, Never>, within limit: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await task.value }
            // Explicit zero tolerance: the default lets the system coalesce
            // the wake, and this timer IS the budget.
            group.addTask { try? await Task.sleep(for: limit, tolerance: .zero); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// One piece through the model, unwrapped, ending kept, guarded. Every
    /// failure returns the piece as dictated. One session per piece, never
    /// shared: see `warmed`.
    private static func tidy(piece: String) async -> String {
        let session = LanguageModelSession(instructions: CleanupPrompt.instructions(for: piece))
        let reply: String
        do {
            reply = try await withTimeout(timeout) {
                try await session.respond(to: CleanupPrompt.framing(piece)).content
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
            return piece
        }

        let cleaned = CleanupPrompt.keepingEnding(of: piece, in: CleanupPrompt.unwrap(reply))

        // Lengths and reasons, never content. Part 1 §2: transcripts never
        // enter logs, and this path exists precisely when the model got the
        // content wrong.
        if case .violated(let reason) = FidelityGuard.check(raw: piece, cleaned: cleaned) {
            log.error("cleanup rejected a chunk: \(reason, privacy: .public)")
            return piece
        }
        return cleaned
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
