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

    private var session: LanguageModelSession?

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
        let session = session ?? LanguageModelSession(instructions: CleanupPrompt.instructions)
        self.session = session
        session.prewarm()
    }

    func polish(_ text: String, profile: AppProfile) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        guard case .available = SystemLanguageModel.default.availability else { return text }

        // Part 0 §0.7: the window throws rather than truncating, so refusing to
        // start is better than a failure mid-utterance. Chunking on sentence
        // boundaries is the refinement; shipping the user's text is the floor.
        guard CleanupPrompt.fitsInOnePass(trimmed) else {
            Self.log.info("too long to clean in one pass, shipping as dictated")
            return text
        }

        let session = session ?? LanguageModelSession(instructions: CleanupPrompt.instructions)
        self.session = session

        let started = ContinuousClock.now
        let reply: String
        do {
            reply = try await withTimeout(Self.timeout) {
                try await session.respond(to: CleanupPrompt.framing(trimmed)).content
            }
        } catch {
            // Includes guardrail refusals, which Part 0 §0.7 makes an ordinary
            // outcome rather than an error to surface.
            Self.log.error("cleanup failed, shipping as dictated")
            return text
        }

        let cleaned = CleanupPrompt.unwrap(reply)
        let elapsed = started.duration(to: .now)

        // Lengths and reasons, never content. Part 1 §2: transcripts never
        // enter logs, and this path exists precisely when the model got the
        // content wrong.
        if case .violated(let reason) = FidelityGuard.check(raw: trimmed, cleaned: cleaned) {
            Self.log.error("cleanup rejected: \(reason, privacy: .public)")
            return text
        }

        Self.log.info(
            "cleaned \(trimmed.count, privacy: .public) chars in \(elapsed.seconds, privacy: .public)s")
        return cleaned
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
