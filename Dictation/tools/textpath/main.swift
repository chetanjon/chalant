import ChalantDictationCore
import CryptoKit
import Foundation
import FoundationModels

// textpath <raw.jsonl> <out.jsonl> [--ungated] [--label <text>]
//
// Runs each raw ASR string through the CURRENT shipping text path, in the
// controller's own order (DictationController.deterministicText, then the
// release-time polish): the vocabulary passes (with an EMPTY vocabulary:
// the app's learned aliases and Contacts pool are per-machine state, and a
// number that depends on them is not reproducible from a checkout),
// Guardrail.trimmingPunctuationRun, Disfluency, Fillers, Restatement,
// Listing.format, then FoundationModelsPolisher.polish: the shipping
// instructions and framing, a fresh session per chunk, FidelityGuard, the
// 40-character gate unless --ungated. No release budget: the model's answer
// is what is measured here, not the race to land it.
//
// Input lines: {"id", "raw"} (Dictation/corpus/setC-asr-en_US.jsonl). Output
// lines use the corpus row's schema-3 names (asrRaw, afterDeterministic,
// modelOutput, modelReason, modelChunks, inserted, output) so
// corpus-kit/span-score.py runs unchanged on this file and on captured.jsonl.
// The first line is the run's stamp: commit, prompt SHA-256, the model the
// daemon loaded. Runs under different stamps are different experiments.

struct Raw: Decodable { let id: String; let raw: String }

let args = CommandLine.arguments
guard args.count > 2 else {
    FileHandle.standardError.write(Data("usage: textpath <raw.jsonl> <out.jsonl> [--ungated] [--live] [--label <text>]\n".utf8))
    exit(2)
}
let ungated = args.contains("--ungated")
// --live waits the release budget the way DictationController does in live
// mode (0.65 s, its `refineBudget`); without it the call has no budget,
// which is the shadow run. Used to confirm the two modes produce the same
// model text, and to count how often live would have landed raw instead.
let live = args.contains("--live")
let liveBudget: Duration = .milliseconds(650)
var label = ""
if let i = args.firstIndex(of: "--label"), i + 1 < args.count { label = args[i + 1] }

func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func run(_ command: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// What modelmanagerd last loaded for the 3B model: asset id and version,
/// read off its own log after the run has made it load (or kept it loaded).
func modelIdentity() -> (asset: String, version: String, loadedAt: String) {
    let lines = run("/usr/bin/log", [
        "show", "--last", "24h", "--info",
        "--predicate", "process == \"modelmanagerd\" AND eventMessage CONTAINS \"Finished loading asset <com.apple.fm.language.instruct_3b\"",
    ]).split(separator: "\n")
    // The generation asset itself (`fm_api_generic_3b`), not the tokenizer,
    // draft or image encoder the same load brings in, and not the 300M
    // guard models loaded beside it.
    guard let last = lines.last(where: { $0.contains("Finished loading asset") && $0.contains("fm_api_generic_3b") }) else {
        return ("unknown", "unknown", "")
    }
    let line = String(last)
    var asset = "unknown", version = "unknown"
    if let open = line.range(of: "<com.apple.fm.language."), let comma = line[open.upperBound...].firstIndex(of: ",") {
        asset = String(line[open.upperBound..<comma])
    }
    if let v = line.range(of: "version: "), let end = line[v.upperBound...].firstIndex(of: ",") {
        version = String(line[v.upperBound..<end])
    }
    return (asset, version, String(line.prefix(26)))
}

/// DictationController.deterministicText with an empty vocabulary, then
/// Listing.format: the text the model is shown.
func deterministic(_ raw: String) -> String {
    let tokens = raw.split(separator: " ").map { Token(text: String($0)) }
    let corrected = TermMatcher.applyingAliases(tokens: tokens, aliases: [:])
    let whole = TermMatcher.joiningSpans(tokens: corrected, terms: [])
    let resolved = TermMatcher.resolving(tokens: whole, terms: [])
    let text = Restatement.collapsing(
        Fillers.removing(
            Disfluency.collapsingRepetitions(
                Guardrail.trimmingPunctuationRun(
                    resolved.map(\.text).joined(separator: " ")))))
    return Listing.format(text)
}

let rows: [Raw] = try String(contentsOfFile: args[1], encoding: .utf8)
    .split(separator: "\n")
    .map { try JSONDecoder().decode(Raw.self, from: Data($0.utf8)) }

guard case .available = SystemLanguageModel.default.availability else {
    FileHandle.standardError.write(Data("model unavailable: \(SystemLanguageModel.default.availability)\n".utf8))
    exit(1)
}

let polisher = FoundationModelsPolisher(gateCharacters: ungated ? -1 : CleanupPrompt.minimumCharactersForCleanup)
let startedAt = ISO8601DateFormatter().string(from: Date())
var out: [String] = []
var landed = 0, gated = 0, rejected = 0, failed = 0

for (n, row) in rows.enumerated() {
    let shaped = deterministic(row.raw)
    await polisher.beginUtterance()
    let started = ContinuousClock.now
    let outcome = await polisher.polish(shaped, profile: AppProfile(bundleID: "com.apple.TextEdit"), within: live ? liveBudget : nil)
    let seconds = started.duration(to: .now)
    // The controller lands `outcome.text` whenever it is non-empty and the
    // result landed, else the shaped text; same here.
    var final = shaped
    if outcome.result == .landed, let refined = outcome.text, !refined.isEmpty { final = refined }
    let reason = outcome.modelReason
    switch reason {
    case "landed": landed += 1
    case "gated": gated += 1
    default: if reason.hasPrefix("rejected") { rejected += 1 } else { failed += 1 }
    }
    let record: [String: Any] = [
        "id": row.id,
        "asrRaw": row.raw,
        "afterDeterministic": shaped,
        "modelOutput": outcome.modelText ?? NSNull(),
        "modelReason": reason,
        "modelChunks": outcome.chunkReasons,
        // The model's reply per chunk even when the guard rejected it, so a
        // rejection can be judged beside its source. Offline only: the
        // corpus row stores null for a rejected chunk.
        "modelReplies": outcome.chunkReplies,
        "inserted": final,
        "output": final,
        "polishOutcome": outcome.result.rawValue,
        "chunkCount": outcome.chunks,
        "failedChunks": outcome.failedChunks,
        "polishSeconds": Double(seconds.components.seconds) + Double(seconds.components.attoseconds) * 1e-18,
    ]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    out.append(String(decoding: data, as: UTF8.self))
    FileHandle.standardError.write(Data("\(n + 1)/\(rows.count) \(row.id) \(reason)\n".utf8))
}

let model = modelIdentity()
let meta: [String: Any] = [
    "kind": "meta",
    "tool": "textpath",
    "label": label,
    "commit": run("/usr/bin/git", ["-C", FileManager.default.currentDirectoryPath, "rev-parse", "--short", "HEAD"]),
    "promptPlainSHA256": sha256(CleanupPrompt.instructionsPlain),
    "promptWithListsSHA256": sha256(CleanupPrompt.instructions),
    "framingSHA256": sha256(CleanupPrompt.framing("X")),
    "modelAsset": model.asset,
    "modelVersion": model.version,
    "modelLoadedAt": model.loadedAt,
    "gated": !ungated,
    "gateCharacters": ungated ? -1 : CleanupPrompt.minimumCharactersForCleanup,
    "vocabulary": "empty",
    "budget": live ? "live (650 ms)" : "none (shadow)",
    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
    "startedAt": startedAt,
    "rows": rows.count,
    "landed": landed, "gated_rows": gated, "rejected": rejected, "failed": failed,
]
let metaLine = String(decoding: try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]), as: UTF8.self)
try (metaLine + "\n" + out.joined(separator: "\n") + "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
print("wrote \(rows.count) rows to \(args[2]): landed \(landed), gated \(gated), rejected \(rejected), failed \(failed); model \(model.asset) \(model.version)")
