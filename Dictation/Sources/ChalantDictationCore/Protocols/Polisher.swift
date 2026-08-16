import Foundation

/// The Foundation Models cleanup pass (M7).
///
/// **NOT optional, and not behind a gesture. This docstring said both and the
/// founder reversed it on 2026-08-14, twice, in the same conversation:** cleaned
/// output is the DEFAULT, like Wispr, *"because people can just talk whatever
/// they want"*. Their objection was never to tidying, it was to being
/// MISREPRESENTED, which is why `FidelityGuard` exists and why a violation
/// silently ships the deterministic text instead.
///
/// What that reversal costs, and it is first-order rather than edge cases: the
/// 4,096-token wall now applies to ordinary use so long dictation needs
/// chunking; the injection preamble is mandatory rather than prudent; and the
/// measured 0.05-0.23s end-to-end no longer describes the shipping path.
/// **Speed is simultaneously one of the three launch claims and the thing this
/// pass puts at risk**, since Wispr and Willow clean in the cloud while this
/// cleans on device, so its latency is the first number to take.
///
/// Part 0 §0.5's `prewarm()` is currently specced onto the shift gesture, which
/// is now the WRONG TRIGGER: cleanup runs for every utterance, so the warm-up
/// belongs at launch beside the other first-use cliffs.
///
/// Part 2 §8: the system prompt opens with an injection defense because
/// dictated text is untrusted input, output is a `@Generable` struct with one
/// guided field so the model cannot emit conversational framing into the
/// user's document, and there is a 30 second timeout.
///
/// Part 0 §0.7: the context window is a hard 4,096 tokens input plus output,
/// so the caller token-budgets and chunks on sentence boundaries. Every
/// failure path returns the input unchanged, and that explicitly includes
/// guardrail refusals, which ship the raw transcript silently.
public protocol Polisher: Sendable {
    func polish(_ text: String, profile: AppProfile) async throws -> String
}
