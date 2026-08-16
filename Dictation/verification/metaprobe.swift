import Foundation
import Speech
import AVFoundation
import CoreMedia

// Phase 0 / V2 / V3. Answers, against the installed SDK rather than a forum post:
//   - what the preset the app actually ships is asking for
//   - whether SpeechDetector composes with a transcriber (SDK 26.5 vs the 26.x reports)
//   - whether transcriptionConfidence is populated, and whether it varies
//   - whether alternatives arrive per result or per span, and how many
//   - whether finalized token time ranges conceal real silence
// Writes raw JSON so conclusions can cite a file.

@available(macOS 26.0, *)
func dumpPresets() {
    print("## Presets, as the SDK actually defines them")
    let presets: [(String, SpeechTranscriber.Preset)] = [
        ("transcription", .transcription),
        ("transcriptionWithAlternatives", .transcriptionWithAlternatives),
        ("timeIndexedTranscriptionWithAlternatives", .timeIndexedTranscriptionWithAlternatives),
        ("progressiveTranscription", .progressiveTranscription),
        ("timeIndexedProgressiveTranscription", .timeIndexedProgressiveTranscription),
    ]
    for (name, p) in presets {
        let t = p.transcriptionOptions.map { "\($0)" }.sorted().joined(separator: ",")
        let r = p.reportingOptions.map { "\($0)" }.sorted().joined(separator: ",")
        let a = p.attributeOptions.map { "\($0)" }.sorted().joined(separator: ",")
        let mark = name == "progressiveTranscription" ? "   <-- WHAT THE APP SHIPS" : ""
        print("  \(name)\(mark)")
        print("     transcription: [\(t)]  reporting: [\(r)]  attributes: [\(a)]")
    }
}

@available(macOS 26.0, *)
func detectorCompositionTest() async {
    print("\n## Does SpeechDetector compose with a transcriber?")
    let t = SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .progressiveTranscription)
    let d = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
    let modules: [any SpeechModule] = [t, d]
    let analyzer = SpeechAnalyzer(modules: modules)
    let count = await analyzer.modules.count
    print("  CONSTRUCTED analyzer with \(count) modules: composition WORKS on this SDK")
}

struct RunRecord: Codable {
    let text: String
    let confidence: Double?
    let start: Double?
    let end: Double?
}
struct ResultRecord: Codable {
    let isFinal: Bool
    let rangeStart: Double
    let rangeEnd: Double
    let text: String
    let alternativeCount: Int
    let alternatives: [String]
    let runs: [RunRecord]
}

@available(macOS 26.0, *)
func fullMetadata(path: String, localeID: String) async throws -> [ResultRecord] {
    let loc = Locale(identifier: localeID)
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: loc) else {
        print("  \(localeID): supportedLocale(equivalentTo:) returned NIL"); return []
    }
    let t = SpeechTranscriber(
        locale: supported,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .alternativeTranscriptions],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence])

    let analyzer = SpeechAnalyzer(modules: [t])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))

    let collector = Task { () -> [ResultRecord] in
        var out: [ResultRecord] = []
        for try await r in t.results {
            var runs: [RunRecord] = []
            for run in r.text.runs {
                let conf = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                let tr = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
                runs.append(RunRecord(
                    text: String(r.text[run.range].characters),
                    confidence: conf,
                    start: tr.map { CMTimeGetSeconds($0.start) },
                    end: tr.map { CMTimeGetSeconds($0.end) }))
            }
            out.append(ResultRecord(
                isFinal: r.isFinal,
                rangeStart: CMTimeGetSeconds(r.range.start),
                rangeEnd: CMTimeGetSeconds(r.range.end),
                text: String(r.text.characters),
                alternativeCount: r.alternatives.count,
                alternatives: r.alternatives.map { String($0.characters) },
                runs: runs))
        }
        return out
    }

    _ = try await analyzer.analyzeSequence(from: file)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return try await collector.value
}

@available(macOS 26.0, *)
func report(_ records: [ResultRecord], label: String) {
    print("\n### \(label)")
    let finals = records.filter { $0.isFinal }
    let volatiles = records.filter { !$0.isFinal }
    let allRuns = records.flatMap { $0.runs }
    let finalRuns = finals.flatMap { $0.runs }
    let volatileRuns = volatiles.flatMap { $0.runs }
    let withConf = allRuns.compactMap { $0.confidence }
    let withTime = allRuns.filter { $0.start != nil }

    print("  results: \(records.count) (\(finals.count) final, \(volatiles.count) volatile), runs: \(allRuns.count)")
    print("  V2 CONFIDENCE: \(withConf.count)/\(allRuns.count) runs carry a value")
    print("     on FINAL runs:    \(finalRuns.compactMap { $0.confidence }.count)/\(finalRuns.count)")
    print("     on VOLATILE runs: \(volatileRuns.compactMap { $0.confidence }.count)/\(volatileRuns.count)")
    if withConf.isEmpty {
        print("     -> ABSENT. Risk routing has no input from this signal.")
    } else {
        let uniq = Set(withConf)
        print("     values: min \(withConf.min()!), max \(withConf.max()!), distinct \(uniq.count)")
        if uniq.count == 1 { print("     -> DEGENERATE (constant \(withConf[0])). Unusable for routing.") }
    }

    // alternatives INCLUDE the primary, so count 1 means zero real alternatives
    let realAlts = records.map { max(0, $0.alternativeCount - 1) }
    print("  V3 ALTERNATIVES (excluding the primary, which is always alternatives[0]):")
    print("     per final result:    \(finals.map { max(0, $0.alternativeCount - 1) })")
    print("     results with any:    \(realAlts.filter { $0 > 0 }.count)/\(records.count)")
    print("     -> alternatives live on the RESULT (whole span), never per token")

    print("  TIMING: \(withTime.count)/\(allRuns.count) runs carry audioTimeRange")
    var zeroGaps = 0, gaps = 0
    for rec in records {
        let ordered = rec.runs.compactMap { r -> (Double, Double)? in
            guard let s = r.start, let e = r.end else { return nil }
            return (s, e)
        }
        for i in 1..<max(ordered.count, 1) where ordered.count > 1 {
            let gap = ordered[i].0 - ordered[i-1].1
            gaps += 1
            if abs(gap) < 0.0005 { zeroGaps += 1 }
        }
    }
    if gaps > 0 {
        print("     inter-word gaps: \(gaps), of which EXACTLY ZERO: \(zeroGaps) (\(zeroGaps * 100 / gaps)%)")
        print("     -> a high zero-gap rate means token ranges cannot detect pauses")
    }
}

@available(macOS 26.0, *)
func run() async {
    dumpPresets()
    await detectorCompositionTest()

    let args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { print("\n(no audio given)"); return }
    let locale = args.count > 1 ? args[1] : "en_IN"
    do {
        let recs = try await fullMetadata(path: args[0], localeID: locale)
        report(recs, label: "\((args[0] as NSString).lastPathComponent) @ \(locale)")
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        let name = (args[0] as NSString).lastPathComponent.replacingOccurrences(of: ".", with: "_")
        let out = "verification/raw/meta_\(name)_\(locale).json"
        try enc.encode(recs).write(to: URL(fileURLWithPath: out))
        print("  raw: \(out)")
    } catch {
        print("  ERROR: \(error)")
    }
}

await run()
