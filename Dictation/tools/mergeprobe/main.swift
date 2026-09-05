import AppKit
import ChalantDictationCore
import Foundation

// What would landing the merged hearing have done to words that already
// landed? Answered on recorded audio, with the losses counted separately from
// the wins, the way `floorsweep` answers the same shape of question for the
// vocabulary floors.
//
// It costs no transcription of its own. Both hearings are already on disk: the
// engine's from `transcribe --tokens` (which carries the per-word confidence
// the policies turn on) and the ear's from the `kind:"hearing"` lines the app
// has been writing since 2026-08-28. That is the whole reason a grid is
// affordable.
//
// A merge that fixes a wrong word is a WIN. A merge that changes a word that
// was already right is a LOSS, and losses decide whether this ships: the user
// never sees the version a wrong merge replaced, so a loss is invisible in a
// way the old post-landing swap's mistakes were not.
//
// usage: mergeprobe <engine-tokens.jsonl> <pairs.jsonl> [labels.jsonl] [--dump]

struct TokenDetail: Codable {
    let t: String
    let c: Double?
}

struct EngineRow: Codable {
    let id: String
    let raw: String
    let detail: [TokenDetail]?
}

struct PairRow: Codable {
    let id: String
    let ear: String
    let landed: String
    let app: String?
    let decision: String?
}

struct LabelRow: Codable {
    let id: String
    let desired: String
}

let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let dump = CommandLine.arguments.contains("--dump")
guard args.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: mergeprobe <engine-tokens.jsonl> <pairs.jsonl> [labels.jsonl] [--dump]\n".utf8)
    )
    exit(2)
}

func read<T: Decodable>(_ path: String, _ type: T.Type) -> [T] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}

let engineRows = read(args[0], EngineRow.self)
let pairRows = read(args[1], PairRow.self)
let labels: [String: String] =
    args.count >= 3
    ? Dictionary(read(args[2], LabelRow.self).map { ($0.id, $0.desired) }, uniquingKeysWith: { a, _ in a })
    : [:]

let pairsByID = Dictionary(pairRows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

// The user's own vocabulary, read the way the app reads it, so the probe is
// protected by exactly what protects the product.
let vocabulary = (UserDefaults(suiteName: "com.cj.chalant")?
    .array(forKey: "dictationTerms") as? [String]) ?? []

/// The shell's half of the evidence. Core has no dictionary, so the probe asks
/// the same spell checker the app asks, about every word on both sides.
func dictionaryWords(_ texts: [String]) -> Set<String> {
    let checker = NSSpellChecker.shared
    var known: Set<String> = []
    for text in texts {
        for token in text.split(whereSeparator: \.isWhitespace) {
            let bare = String(token.filter { $0.isLetter || $0.isNumber || $0 == "'" })
            guard !bare.isEmpty else { continue }
            let range = checker.checkSpelling(
                of: bare, startingAt: 0, language: "en", wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil)
            if range.location == NSNotFound {
                known.insert(String(bare.filter { $0.isLetter || $0.isNumber }).lowercased())
            }
        }
    }
    return known
}

/// Words, bared the way the scorers bare them, so a full stop is not a
/// difference.
func compareWords(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map {
        String($0.filter { $0.isLetter || $0.isNumber }).lowercased()
    }.filter { !$0.isEmpty }
}

/// Which of two candidates is nearer the truth, counted in word edits.
func distance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = previous
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            current[j] =
                a[i - 1] == b[j - 1]
                ? previous[j - 1]
                : 1 + min(previous[j - 1], min(previous[j], current[j - 1]))
        }
        previous = current
    }
    return previous[b.count]
}

struct Tally {
    var rows = 0
    var merged = 0
    var refusedWhole = 0
    var spansTaken = 0
    var spansRefused = 0
    // Only where a label exists.
    var labelled = 0
    var better = 0
    var worse = 0
    var same = 0
    var engineEdits = 0
    var mergedEdits = 0
}

var reasons: [String: Int] = [:]
var verdicts: [String: Int] = [:]

@MainActor
func run(policy: HearingMerge.Policy, constants: HearingMerge.Constants, dumping: Bool) -> Tally {
    var tally = Tally()
    for engineRow in engineRows {
        guard let pair = pairsByID[engineRow.id] else { continue }
        let detail = engineRow.detail ?? []
        guard !detail.isEmpty else { continue }
        let tokens = detail.map { Token(text: $0.t, confidence: $0.c) }
        let signals = HearingMerge.Signals(
            knownWords: dictionaryWords([engineRow.raw, pair.ear]),
            vocabulary: vocabulary)

        let outcome = HearingMerge.merge(
            engine: tokens, ear: pair.ear, signals: signals, policy: policy,
            constants: constants)

        tally.rows += 1
        verdicts[outcome.verdict.rawValue, default: 0] += 1
        for span in outcome.spans where span.kind != .agreed {
            reasons[span.reason, default: 0] += 1
            if span.choseEar { tally.spansTaken += 1 } else { tally.spansRefused += 1 }
        }
        if outcome.verdict == .merged { tally.merged += 1 }
        if outcome.verdict == .implausible || outcome.verdict == .qualityRejected
            || outcome.verdict == .tooMuchDisagreement
        {
            tally.refusedWhole += 1
        }

        let mergedText = outcome.tokens.map(\.text).joined(separator: " ")
        if let truth = labels[engineRow.id] {
            let reference = compareWords(truth)
            let before = distance(compareWords(engineRow.raw), reference)
            let after = distance(compareWords(mergedText), reference)
            tally.labelled += 1
            tally.engineEdits += before
            tally.mergedEdits += after
            if after < before {
                tally.better += 1
            } else if after > before {
                tally.worse += 1
            } else {
                tally.same += 1
            }
            if dumping, after != before {
                print("\(after < before ? "WIN " : "LOSS") \(engineRow.id)")
                print("   engine: \(engineRow.raw)")
                print("   merged: \(mergedText)")
                print("   truth : \(truth)")
            }
        } else if dumping, outcome.verdict == .merged {
            print("MERGED \(engineRow.id) [\(pair.app ?? "")] was \(pair.decision ?? "")")
            print("   engine: \(engineRow.raw)")
            print("   merged: \(mergedText)")
            print("   ear   : \(pair.ear)")
        }
    }
    return tally
}

print("mergeprobe: \(engineRows.count) engine rows, \(pairRows.count) pairs, \(labels.count) labelled")
print("vocabulary: \(vocabulary.count) terms\n")

print("policy         rows  merged  refused  taken  refusedSpans   labelled  better  worse  same   edits")
for policy in HearingMerge.Policy.allCases {
    reasons = [:]
    verdicts = [:]
    let tally = run(policy: policy, constants: HearingMerge.Constants(), dumping: false)
    let edits =
        tally.labelled > 0 ? "\(tally.engineEdits) -> \(tally.mergedEdits)" : "no labels"
    print(
        String(
            format: "%-13@ %5d  %6d  %7d  %5d  %12d   %8d  %6d  %5d  %4d   %@",
            policy.rawValue as NSString, tally.rows, tally.merged, tally.refusedWhole,
            tally.spansTaken, tally.spansRefused, tally.labelled, tally.better, tally.worse,
            tally.same, edits as NSString))
}

// The winner's reasons, so the refusals can be read rather than trusted.
print("\nwhy each dispute went the way it did (earLeads):")
reasons = [:]
verdicts = [:]
_ = run(policy: .earLeads, constants: HearingMerge.Constants(), dumping: dump)
for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) {
    print(String(format: "  %-28@ %4d", reason as NSString, count))
}
print("\nwhole-hearing verdicts:")
for (verdict, count) in verdicts.sorted(by: { $0.value > $1.value }) {
    print(String(format: "  %-28@ %4d", verdict as NSString, count))
}
