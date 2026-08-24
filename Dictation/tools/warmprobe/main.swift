import Foundation
import FoundationModels

// Does a `prewarm()` fired at key-down make the polish at key-up warm?
//
// Campaign phase 1a (2026-08-21) wants `keyDown` to call the polisher's
// `warmUp()` so the hold gives the model its load time for free. The evidence
// behind it (EVAL-LOG 2026-08-16: first call 2.4 s, warm p50 0.99 s) measured a
// first call with NO prewarm at all, so it never showed that a prewarm on one
// session warms the FRESH session the shipping path actually responds on, nor
// how long after the prewarm that holds. Part 1 §3 bans optimising before
// measuring, so this is the measurement. Every mode is one fresh process; run
// them from a shell loop so "cold" means cold.
//
//   warmprobe cold                 respond at once on a fresh session (the 1.26.0 first utterance)
//   warmprobe prewarm <seconds>    prewarm a SEPARATE session, wait, respond on a fresh one (the 1a shape)
//   warmprobe idle <min> [<min>…]  warm the model, then respond after each gap (the eviction horizon, phase 1b)
//
// Timings only, never content. The passage is synthetic filler-laden speech of
// the length the founder really dictates (~30 words), not a corpus row.

let passage = "so um I was thinking that we should probably, like, move the review to Thursday because, you know, the draft is not going to be ready and, uh, Priya said she needs one more day for the numbers"

func respondFresh() async -> (seconds: Double, changed: Bool, failed: Bool) {
    // Exactly `FoundationModelsPolisher.tidy(piece:)`: fresh session, the
    // shipping instructions for this piece, the shipping framing.
    let session = LanguageModelSession(instructions: CleanupPrompt.instructions(for: passage))
    let started = ContinuousClock.now
    do {
        let reply = try await session.respond(to: CleanupPrompt.framing(passage)).content
        let elapsed = started.duration(to: .now)
        let cleaned = CleanupPrompt.keepingEnding(of: passage, in: CleanupPrompt.unwrap(reply))
        return (elapsed.probeSeconds, cleaned != passage, false)
    } catch {
        return (started.duration(to: .now).probeSeconds, false, true)
    }
}

extension Duration {
    var probeSeconds: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}

func fmt(_ s: Double) -> String { String(format: "%.3f", s) }

guard case .available = SystemLanguageModel.default.availability else {
    print("model unavailable: \(SystemLanguageModel.default.availability)")
    exit(1)
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "cold"

switch mode {
case "cold":
    let first = await respondFresh()
    let second = await respondFresh()
    let third = await respondFresh()
    print("cold  first=\(fmt(first.seconds))  second=\(fmt(second.seconds))  third=\(fmt(third.seconds))  changed=\(first.changed) failed=\(first.failed)")

case "prewarm":
    let wait = args.count > 2 ? Double(args[2]) ?? 2 : 2
    // The app's `warmUp()`: a held session with the plain instructions,
    // prewarmed, never used to respond.
    let warmed = LanguageModelSession(instructions: CleanupPrompt.instructionsPlain)
    let prewarmStarted = ContinuousClock.now
    warmed.prewarm()
    let prewarmCall = prewarmStarted.duration(to: .now).probeSeconds
    try? await Task.sleep(for: .seconds(wait))
    let first = await respondFresh()
    let second = await respondFresh()
    print("prewarm wait=\(fmt(wait))s  prewarmCall=\(fmt(prewarmCall))  first=\(fmt(first.seconds))  second=\(fmt(second.seconds))  changed=\(first.changed) failed=\(first.failed)")

case "idle":
    let gaps = args.dropFirst(2).compactMap { Double($0) }
    let warm1 = await respondFresh()
    let warm2 = await respondFresh()
    print("idle  warm=\(fmt(warm1.seconds))/\(fmt(warm2.seconds))")
    for gap in gaps {
        try? await Task.sleep(for: .seconds(gap * 60))
        let after = await respondFresh()
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("idle  after=\(fmt(gap))min  respond=\(fmt(after.seconds))  failed=\(after.failed)  at=\(stamp)")
        fflush(stdout)
    }

default:
    print("usage: warmprobe cold | prewarm <seconds> | idle <min> [<min>…]")
    exit(2)
}
