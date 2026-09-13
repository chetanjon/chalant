import ChalantDictationCore
import Foundation

// Does gating the standing names by sound still hand the ear the name it
// needs? Answered on the FIRST ear's own transcripts, because that is the text
// `Names.forHearing` scores against in the app, not the ear's own output.
//
// A name that survives is a name the ear will still be warned about. A name
// that does not is one the ear must now get right unaided, or leave to the
// matching pass afterwards.
//
// usage: nameprobe <cases.json> [--dump]

struct Case: Codable {
    let id: String
    let heard: String
    let need: [String]
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: nameprobe <cases.json> [--dump]\n".utf8))
    exit(2)
}
let dump = arguments.contains("--dump")
let emitPrompts = arguments.contains("--prompts")
let cases = try JSONDecoder().decode(
    [Case].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))

/// The founder's own typed terms, in their order (`defaults read
/// com.cj.chalant dictationTerms` on 2026-09-13).
let standing = [
    "Ultrathink", "Jonnalagadda", "Chetan", "Overleaf", "Capgemini",
    "LaTeX", "Chalant", "Kizu", "Aatram", "PostHog",
]

/// A stand-in for Contacts: the names that actually appear in these
/// recordings, so the pool is not empty and the caps behave as they do live.
let pool = ["Aiden", "Aidan", "Priya", "Sharat", "Satyadev", "Paola", "Gangothri"]

/// The standing list is the typed terms PLUS whatever the ledger has learned
/// and trusts, and the learned half is private to a machine. `--learned N`
/// stands in for it so the prompt sizes here match a real one: the founder's
/// own log read "16 names (65 prompt tokens)" on 2026-09-10, against ten typed
/// terms, so six is the number that reproduces their Mac.
let learnedCount: Int = {
    guard let flag = arguments.firstIndex(of: "--learned"), flag + 1 < arguments.count,
        let n = Int(arguments[flag + 1])
    else { return 0 }
    return max(0, n)
}()
let always = standing + (0..<learnedCount).map { "Learned\($0 + 1)" }

var keptBoth = 0
var lostByGate: [(String, String, String)] = []
var sizeToday = 0
var sizeGated = 0

for row in cases {
    let today = NameHints.select(heard: row.heard, always: always, pool: pool)
    let gated = NameHints.select(
        heard: row.heard, always: always, pool: pool,
        standingFills: NameHints.promptStandingFloor)
    sizeToday += today.count
    sizeGated += gated.count

    let todaySet = Set(today.map { $0.lowercased() })
    let gatedSet = Set(gated.map { $0.lowercased() })
    for name in row.need {
        let key = name.lowercased()
        let hadIt = todaySet.contains(key)
        let keepsIt = gatedSet.contains(key)
        if hadIt && keepsIt { keptBoth += 1 }
        if hadIt && !keepsIt { lostByGate.append((row.id, name, row.heard)) }
    }
    if emitPrompts {
        print("\(row.id)\t\(NameHints.prompt(gated))")
    }
    if dump {
        print("\(row.id)\n  heard: \(row.heard)")
        print("  today (\(today.count)): \(today.joined(separator: ", "))")
        print("  gated (\(gated.count)): \(gated.joined(separator: ", "))")
    }
}

if emitPrompts { exit(0) }
let n = max(1, cases.count)
print("")
print("cases:                    \(cases.count)")
print("names kept by both:       \(keptBoth)")
print("names the gate drops:     \(lostByGate.count)")
print(String(format: "prompt size today:        %.1f names", Double(sizeToday) / Double(n)))
print(String(format: "prompt size gated:        %.1f names", Double(sizeGated) / Double(n)))
print(String(format: "at 0.05 s per name:       %.2f s saved per sentence",
             Double(sizeToday - sizeGated) / Double(n) * 0.05))
if !lostByGate.isEmpty {
    print("\nDROPPED BY THE GATE:")
    for (id, name, heard) in lostByGate { print("  \(name) <- \(id)\n    \(heard)") }
}
