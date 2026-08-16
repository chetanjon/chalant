import Foundation

/// The optional Foundation Models pass (M7), behind the shift-on-release
/// gesture rather than on by default.
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
