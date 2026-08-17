import Foundation
import FoundationModels

// The SHIPPING cleanup path (CleanupPrompt.chunks / framing / unwrap and
// FidelityGuard, compiled from Core so nothing can drift) run over captured
// utterances, so "how clean is the output on real speech" is a number and a
// list, not a feeling.
//
//   shipclean <captured.jsonl> <out.jsonl> [--before <ISO-8601 recorded cutoff>] [--limit N] [--fresh]
//
// `--fresh` makes a NEW LanguageModelSession per utterance (the model stays
// resident, so this costs almost nothing). Without it, one session is shared
// across every row, which is what the app shipped in 1.14.0 through 1.15.1:
// the session's transcript grows with everything ever dictated, each call
// gets slower, and past ~8k tokens every cleanup fails on context size.
//
// Only rows recorded BEFORE the cutoff are raw deterministic text (after
// cleanup shipped, `output` is already cleaned). Writes one JSON object per
// row with input, output, whether it changed, the guard's verdict and the
// wall-clock cost. Transcripts go to the out file only, never to a log.

struct Row: Decodable { let id: String; let output: String; let recorded: String; let app: String? }

let a = CommandLine.arguments
guard a.count > 2 else { print("usage: shipclean <captured.jsonl> <out.jsonl> [--before ISO] [--limit N]"); exit(2) }
var cutoff = "9999"
var limit = Int.max
let fresh = a.contains("--fresh")
// `--tight` used to select an experimental smallest-edit wording; that wording
// is now Core's, so the flag is a no-op kept for old command lines.
let tight = a.contains("--tight")
let instructionsInUse = CleanupPrompt.instructions
func framingInUse(_ t: String) -> String { CleanupPrompt.framing(t) }
var i = 3
while i < a.count {
    if a[i] == "--before", i + 1 < a.count { cutoff = a[i + 1]; i += 2; continue }
    if a[i] == "--limit", i + 1 < a.count { limit = Int(a[i + 1]) ?? .max; i += 2; continue }
    i += 1
}

let lines = try! String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n")
let dec = JSONDecoder()
var rows: [Row] = []
for l in lines {
    if let r = try? dec.decode(Row.self, from: Data(l.utf8)), r.recorded < cutoff, !r.output.trimmingCharacters(in: .whitespaces).isEmpty {
        rows.append(r)
    }
}
rows = Array(rows.prefix(limit))
print("rows: \(rows.count)")

guard case .available = SystemLanguageModel.default.availability else { print("model unavailable"); exit(1) }
var session = LanguageModelSession(instructions: instructionsInUse)
session.prewarm()

var out = FileHandle(forWritingAtPath: a[2]) ?? { FileManager.default.createFile(atPath: a[2], contents: nil); return FileHandle(forWritingAtPath: a[2])! }()
try? out.truncate(atOffset: 0)
let enc = JSONEncoder()
struct Result: Encodable { let id: String; let app: String?; let input: String; let output: String; let changed: Bool; let chunks: Int; let rejected: [String]; let seconds: Double }

var changedCount = 0, rejectedCount = 0
var times: [Double] = []
for (n, r) in rows.enumerated() {
    let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let pieces = CleanupPrompt.chunks(text)
    if fresh, n > 0 { session = LanguageModelSession(instructions: instructionsInUse) }
    let started = ContinuousClock.now
    var parts: [String] = []
    var rejected: [String] = []
    for piece in pieces {
        do {
            let reply = try await session.respond(to: framingInUse(piece)).content
            let cleaned = CleanupPrompt.keepingEnding(of: piece, in: CleanupPrompt.unwrap(reply))
            if case .violated(let why) = FidelityGuard.check(raw: piece, cleaned: cleaned) {
                rejected.append(why); parts.append(piece)
            } else { parts.append(cleaned) }
        } catch {
            rejected.append("error: \(error)"); parts.append(piece)
        }
    }
    let el = started.duration(to: .now)
    let s = Double(el.components.seconds) + Double(el.components.attoseconds) * 1e-18
    times.append(s)
    let joined = parts.joined(separator: " ")
    let changed = joined != text
    if changed { changedCount += 1 }
    if !rejected.isEmpty { rejectedCount += 1 }
    let res = Result(id: r.id, app: r.app, input: text, output: joined, changed: changed, chunks: pieces.count, rejected: rejected, seconds: s)
    out.write(try! enc.encode(res)); out.write(Data("\n".utf8))
    print("\(n + 1)/\(rows.count) \(String(format: "%.2f", s))s \(changed ? "changed" : "same") \(rejected.isEmpty ? "" : "REJECTED")")
}
let sorted = times.sorted()
func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
print("changed \(changedCount)/\(rows.count), rejected \(rejectedCount)/\(rows.count), p50 \(String(format: "%.2f", pct(0.5)))s p95 \(String(format: "%.2f", pct(0.95)))s")
