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
        let session = warmed ?? LanguageModelSession(instructions: CleanupPrompt.instructions)
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
    }

    /// Tidy, in the background, every chunk of `text` that will not change as
    /// the speaker goes on. Called on a timer during the hold with the
    /// deterministic text of the finalized transcript so far.
    func pretidy(_ text: String) {
        guard Cleanup.isEnabled(), case .available = SystemLanguageModel.default.availability else { return }
        let closed = CleanupPrompt.closedChunks(text)
        let fresh = closed.filter { tidiedPieces[$0] == nil && piecesInFlight[$0] == nil }
        if !fresh.isEmpty {
            // Counts only, never content.
            Self.log.info(
                "pretidy: \(text.count, privacy: .public) chars finalized, \(closed.count, privacy: .public) closed chunk(s), \(fresh.count, privacy: .public) new")
        }
        for piece in fresh {
            piecesInFlight[piece] = Task { [weak self] in
                let result = await Self.tidy(piece: piece)
                await self?.finished(piece: piece, result: result)
                return result
            }
        }
    }

    private func finished(piece: String, result: String) {
        tidiedPieces[piece] = result
        piecesInFlight[piece] = nil
    }

    func polish(_ text: String, profile: AppProfile) async throws -> String {
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
        var out: [String] = []
        var warm = 0

        for piece in pieces {
            if let done = tidiedPieces[piece] {
                out.append(done)
                warm += 1
            } else if let running = piecesInFlight[piece] {
                out.append(await running.value)
                warm += 1
            } else {
                out.append(await Self.tidy(piece: piece))
            }
        }

        let elapsed = started.duration(to: .now)
        Self.log.info(
            """
            cleaned \(trimmed.count, privacy: .public) chars in \(pieces.count, privacy: .public) \
            chunk(s), \(warm, privacy: .public) tidied while talking, \(elapsed.seconds, privacy: .public)s
            """)
        return out.joined(separator: " ")
    }

    /// One piece through the model, unwrapped, ending kept, guarded. Every
    /// failure returns the piece as dictated. One session per piece, never
    /// shared: see `warmed`.
    private static func tidy(piece: String) async -> String {
        let session = LanguageModelSession(instructions: CleanupPrompt.instructions)
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
