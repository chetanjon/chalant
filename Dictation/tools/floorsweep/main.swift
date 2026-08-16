import Foundation

// Sweep the two floors `TermMatcher` gates on, the way Part 0 §0.13 swept
// FluidAudio's: on real data, with the result written down, rather than by
// picking a number that sounds careful.
//
// Reads `signalprobe` output, so it costs no transcription: the tokens and
// their confidences are already on disk. That means the whole grid is seconds
// rather than an hour, which is the only reason a grid is affordable at all.
//
// Counts what matters for a repair layer, which is NOT accuracy. A substitution
// that fixes a wrong word is a WIN. A substitution that changes a word that was
// already right is a LOSS, and Part 0 §0.14 plus M4's acceptance criterion both
// say losses are the failure mode that decides whether this ships.
//
// usage: floorsweep <probe.jsonl> <terms.txt>

struct TokenDetail: Codable {
    let t: String
    let c: Double?
}

struct Row: Codable {
    let id: String
    let split: String
    let desired: String
    let detail: [TokenDetail]
}

let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: floorsweep <probe.jsonl> <terms.txt>")
    exit(2)
}

let terms = (try! String(contentsOfFile: args[2], encoding: .utf8))
    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }

let rows: [Row] = (try! String(contentsOfFile: args[1], encoding: .utf8))
    .split(separator: "\n")
    .compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Row.self, from: data)
    }

func bare(_ s: String) -> String {
    s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
}

/// Was this word present in what the speaker meant? Word-level and
/// order-free on purpose: the question here is only "was this token a real
/// word of the utterance", which is what decides win from loss.
func wanted(_ row: Row) -> Set<String> {
    Set(row.desired.split(whereSeparator: { $0 == " " }).map { bare(String($0)) })
}

struct Tally {
    var wins = 0        // a wrong word became the right one
    var losses = 0      // a right word was changed into a wrong one
    var neutral = 0     // wrong before, wrong after: no worse, no better
}

print("similarity  confidence     wins   losses  neutral   verdict")
print(String(repeating: "-", count: 66))

for similarity in [0.65, 0.70, 0.75, 0.80, 0.85, 0.90] {
    for confidence in [0.3, 0.4, 0.5, 0.6] {
        var tally = Tally()
        for row in rows {
            let truth = wanted(row)
            let tokens = row.detail.map { Token(text: $0.t, confidence: $0.c) }
            let after = TermMatcher.resolving(
                tokens: tokens, terms: terms,
                confidenceFloor: confidence, similarityFloor: similarity)

            for (before, now) in zip(tokens, after) where before.text != now.text {
                let wasRight = truth.contains(bare(before.text))
                let isRight = truth.contains(bare(now.text))
                if !wasRight && isRight { tally.wins += 1 }
                else if wasRight && !isRight { tally.losses += 1 }
                else { tally.neutral += 1 }
            }
        }
        let verdict: String
        if tally.wins == 0 && tally.losses == 0 { verdict = "does nothing" }
        else if tally.losses == 0 { verdict = "SAFE" }
        else if tally.wins > tally.losses { verdict = "net positive, still lossy" }
        else { verdict = "net harmful" }
        print(
            String(format: "%10.2f  %10.2f   %6d   %6d   %6d   %@",
                   similarity, confidence, tally.wins, tally.losses, tally.neutral, verdict))
    }
}
