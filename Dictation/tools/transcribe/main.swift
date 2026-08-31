import AVFoundation
import ChalantDictationCore
import CoreMedia
import Foundation
import Speech

// transcribe <dir|jsonl> <out.jsonl> [--limit N] [--deep]
//
// **E0, the harness.** The build brief of 2026-08-27 calls this the blocking
// prerequisite for every accuracy claim the product intends to make, and it
// was the one piece missing: the app can only hear a microphone, so no
// recording, ours or anyone's, could be scored without a person speaking it
// again. This feeds a FILE through the same engine the app ships
// (`SpeechTranscriber` + `SpeechAnalyzer`, the explicit initialiser
// AppleTranscriber uses, same locale resolution, same format negotiation),
// so a corpus row, a public test set, or a competitor's audio all become
// numbers on one machine.
//
// `--deep` adds the architecture arm: the engine's words through Core's
// deterministic chain (guardrail, ellipses, disfluency, repair, fillers,
// restatement, contrast, breaks, listing) with an EMPTY vocabulary, because
// learned terms are per-machine state and a number that depends on them is
// not reproducible from a checkout. Engine-raw is the shallow arm.
//
// Output: one JSON object per line, {id, audio, raw, deep?, seconds}, which
// `corpus-kit/score.py` reads when a `desired` is joined onto it.

let args = CommandLine.arguments
guard args.count > 2 else {
    FileHandle.standardError.write(Data("usage: transcribe <dir|jsonl> <out.jsonl> [--limit N] [--deep]\n".utf8))
    exit(2)
}
let input = args[1]
let outPath = args[2]
let deep = args.contains("--deep")
var limit = Int.max
if let i = args.firstIndex(of: "--limit"), i + 1 < args.count, let n = Int(args[i + 1]) { limit = n }

/// The shipping deterministic chain, minus the vocabulary passes (empty
/// offline). Kept in the same order `DictationController.deterministicText`
/// applies it, so the deep arm is the product rather than an approximation.
func deterministic(_ raw: String) -> String {
    Listing.format(
        Breaks.sentencing(
            Contrast.commaBeforeNot(
                Restatement.collapsing(
                    Fillers.removing(
                        Repair.repairing(
                            Disfluency.collapsingRepetitions(
                                Guardrail.settlingEllipses(
                                    Guardrail.trimmingPunctuationRun(raw)))))))))
}

func audioFiles() -> [(id: String, url: URL)] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: input, isDirectory: &isDir) else { return [] }
    if isDir.boolValue {
        let names = ((try? fm.contentsOfDirectory(atPath: input)) ?? [])
            .filter { ["caf", "wav", "m4a", "mp3", "flac"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        return names.map { (($0 as NSString).deletingPathExtension, URL(fileURLWithPath: input).appendingPathComponent($0)) }
    }
    // A jsonl of rows carrying an `audio` path, relative to the file's parent.
    let base = URL(fileURLWithPath: input).deletingLastPathComponent()
    var out: [(String, URL)] = []
    for line in (try? String(contentsOfFile: input, encoding: .utf8))?.split(separator: "\n") ?? [] {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let audio = o["audio"] as? String else { continue }
        let id = (o["id"] as? String) ?? (audio as NSString).lastPathComponent
        out.append((id, base.appendingPathComponent(audio)))
    }
    return out
}

/// One file through the engine, finalized text only. A fresh analyzer per
/// file: sample-rate conversion is stateful and a shared one would carry a
/// previous recording's tail into the next row's numbers.
func transcribe(_ url: URL) async throws -> String {
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
        throw NSError(domain: "transcribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no supported en-US locale"])
    }
    let module = SpeechTranscriber(
        locale: supported,
        transcriptionOptions: [],
        reportingOptions: [.fastResults],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    let analyzer = SpeechAnalyzer(modules: [module])

    let file = try AVAudioFile(forReading: url)
    let fileFormat = file.processingFormat
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [module], considering: fileFormat)
    let converter = (analyzerFormat != nil && analyzerFormat != fileFormat)
        ? AVAudioConverter(from: fileFormat, to: analyzerFormat!) : nil

    let collected = Task<String, Error> {
        var text = ""
        for try await result in module.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }

    let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: inputs)

    // Quarter-second slices: small enough that the engine streams the way it
    // does live, large enough that a 90 s recording is not 5,000 hops.
    let slice = AVAudioFrameCount(fileFormat.sampleRate / 4)
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: slice) else { break }
        try file.read(into: buffer, frameCount: slice)
        guard buffer.frameLength > 0 else { break }
        if let converter, let target = analyzerFormat {
            let ratio = target.sampleRate / fileFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        } else {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return try await collected.value
}

let files = Array(audioFiles().prefix(limit))
guard !files.isEmpty else {
    FileHandle.standardError.write(Data("no audio found at \(input)\n".utf8))
    exit(1)
}
var lines: [String] = []
var failed = 0
for (n, item) in files.enumerated() {
    let started = ContinuousClock.now
    do {
        let raw = try await transcribe(item.url)
        let seconds = Double(started.duration(to: .now).components.seconds)
            + Double(started.duration(to: .now).components.attoseconds) * 1e-18
        var row: [String: Any] = [
            "id": item.id,
            "audio": item.url.lastPathComponent,
            "raw": raw.trimmingCharacters(in: .whitespacesAndNewlines),
            "seconds": seconds,
        ]
        if deep { row["deep"] = deterministic(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        lines.append(String(decoding: data, as: UTF8.self))
        print("\(n + 1)/\(files.count) \(item.id) \(raw.split(separator: " ").count) words")
    } catch {
        failed += 1
        print("\(n + 1)/\(files.count) \(item.id) FAILED: \(error.localizedDescription)")
    }
}
try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
print("wrote \(lines.count) rows to \(outPath)\(failed > 0 ? ", \(failed) failed" : "")")
