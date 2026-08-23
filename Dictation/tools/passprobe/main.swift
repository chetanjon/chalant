import ChalantDictationCore
import Foundation

// passprobe <jsonl> <field> <pass>
//
// Dry-runs one deterministic pass over a text field of every row in a
// corpus file (read-only) and prints each row it would change, before and
// after. Scripted sets cannot say whether a pass is tight enough; the
// founder's real dictations can (2026-08-22, prompt 5 task 2).
//   pass: contrast | fillers | repair | restatement | repair+restatement
let args = CommandLine.arguments
guard args.count > 3 else {
    FileHandle.standardError.write(Data("usage: passprobe <jsonl> <field> <contrast|fillers>\n".utf8))
    exit(2)
}
let field = args[2]
let pass = args[3]
var rows = 0, changed = 0
for line in try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n") {
    guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          object["kind"] == nil, let text = object[field] as? String else { continue }
    rows += 1
    let after: String
    switch pass {
    case "contrast": after = Contrast.commaBeforeNot(text)
    case "fillers": after = Fillers.removing(text)
    case "repair": after = Repair.repairing(text)
    case "restatement": after = Restatement.collapsing(text)
    // The two new passes in their shipping order, on text that already
    // went through the old pipeline when it was captured.
    case "repair+restatement": after = Restatement.collapsing(Repair.repairing(text))
    case "repair-trace":
        // Which shape fired, per row, with what it removed.
        let fired = Repair.trace(text)
        after = Repair.repairing(text)
        if !fired.isEmpty {
            print("\(object["id"] ?? "?") \(fired.map { "\($0.shape)[\($0.removed)]" }.joined(separator: " "))")
        }
        continue
    default: after = text
    }
    if after != text {
        changed += 1
        print("\(object["id"] ?? "?") [\(object["app"] ?? "")]")
        print("  before: \(text)")
        print("  after : \(after)")
    }
}
print("rows \(rows), changed \(changed)")
