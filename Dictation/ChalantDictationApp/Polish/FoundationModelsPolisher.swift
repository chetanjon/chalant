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

        // One session per utterance, never shared: see `warmed`.
        let session = LanguageModelSession(instructions: CleanupPrompt.instructions)

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
        let pieces = CleanupPrompt.chunks(trimmed)
        let started = ContinuousClock.now
        var out: [String] = []
        var rejected = 0

        for piece in pieces {
            let reply: String
            do {
                reply = try await withTimeout(Self.timeout) {
                    try await session.respond(to: CleanupPrompt.framing(piece)).content
                }
            } catch {
                // Includes guardrail refusals, which Part 0 §0.7 makes an
                // ordinary outcome. This piece ships as dictated; the rest of
                // the paragraph still gets its chance. The framework's own
                // words are logged (token counts, refusal class), never the
                // transcript, because a failure that only says "failed" is
                // how the shared-session context overflow went unnoticed.
                Self.log.error(
                    "cleanup failed on a chunk, shipping that chunk as dictated: \(String(describing: error), privacy: .public)")
                out.append(piece)
                continue
            }

            let cleaned = CleanupPrompt.keepingEnding(of: piece, in: CleanupPrompt.unwrap(reply))

            // Lengths and reasons, never content. Part 1 §2: transcripts never
            // enter logs, and this path exists precisely when the model got the
            // content wrong.
            if case .violated(let reason) = FidelityGuard.check(raw: piece, cleaned: cleaned) {
                Self.log.error("cleanup rejected a chunk: \(reason, privacy: .public)")
                out.append(piece)
                rejected += 1
                continue
            }
            out.append(cleaned)
        }

        let elapsed = started.duration(to: .now)
        Self.log.info(
            """
            cleaned \(trimmed.count, privacy: .public) chars in \(pieces.count, privacy: .public) \
            chunk(s), \(rejected, privacy: .public) shipped raw, \(elapsed.seconds, privacy: .public)s
            """)
        return out.joined(separator: " ")
    }

    /// A timeout that actually abandons the work.
    ///
    /// `Task.sleep` alone would leave the generation running and still holding
    /// the session, so the next utterance would queue behind a request nobody
    /// is waiting for.
    private func withTimeout<T: Sendable>(
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
