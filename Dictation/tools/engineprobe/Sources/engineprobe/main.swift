// engineprobe <manifest.jsonl|dir> <out.jsonl> --engine apple|parakeet|whisper
//             [--aggregation min|max|mean] [--limit N] [--deep] [--tokens]
//
// Three recognizers, the same recordings, the same scorer. This exists because
// `Dictation/CLAUDE.md` §0.12 ruled on Parakeet before it was built: its
// closest public lineage scores roughly twice the word error of Whisper on
// Indian-accented English, and "if Parakeet underperforms the Apple default on
// the corpus, cut its engine role". The founder's answer when asked was that
// the shipped default should follow the measurement. This is the measurement.
//
// The discipline is `tools/transcribe`'s and `tools/mergeprobe`'s: decode once,
// write the words and their confidences to disk, sweep offline. Re-decoding to
// move a threshold is how threshold work becomes unaffordable.

import AVFoundation
import ChalantDictationCore
import FluidAudio
import Foundation
import Speech
import WhisperKit

struct Word: Codable { let t: String; let c: Double? }

struct Row: Codable {
    var id: String
    var audio: String
    var raw: String
    var seconds: Double
    var engine: String
    var deep: String?
    var detail: [Word]?
}

// MARK: - Arguments

/// Top-level code is main-actor isolated, so the argument list lives in a
/// type rather than as a global `var` that nonisolated helpers cannot touch.
struct Arguments {
    var rest: [String]

    init(_ raw: [String]) { rest = raw }

    mutating func take(_ flag: String) -> String? {
        guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
        let value = rest[i + 1]
        rest.removeSubrange(i...(i + 1))
        return value
    }

    mutating func has(_ flag: String) -> Bool {
        guard let i = rest.firstIndex(of: flag) else { return false }
        rest.remove(at: i)
        return true
    }
}

var args = Arguments(Array(CommandLine.arguments.dropFirst()))

let engineName = args.take("--engine") ?? "apple"
let aggregationName = args.take("--aggregation") ?? "min"
let limit = args.take("--limit").flatMap(Int.init)
let deep = args.has("--deep")
let wantTokens = args.has("--tokens")

guard args.rest.count == 2 else {
    FileHandle.standardError.write(
        Data(
            """
            usage: engineprobe <manifest.jsonl|dir> <out.jsonl> --engine apple|parakeet|whisper
                               [--aggregation min|max|mean] [--limit N] [--deep] [--tokens]

            """.utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args.rest[0])
let output = URL(fileURLWithPath: args.rest[1])

let aggregation: SubwordAssembly.Aggregation =
    switch aggregationName {
    case "max": .maximum
    case "mean": .mean
    default: .minimum
    }

// MARK: - What to transcribe

/// Same two shapes `tools/transcribe` accepts, so a manifest or a bare folder
/// both work and the ids line up with `score.py`.
func recordings() throws -> [(id: String, url: URL, relative: String)] {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
        throw NSError(
            domain: "engineprobe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "no such path: \(input.path)"])
    }
    if isDirectory.boolValue {
        let kinds = ["caf", "wav", "m4a", "mp3", "flac"]
        let names = try manager.contentsOfDirectory(atPath: input.path)
            .filter { kinds.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        return names.map {
            (($0 as NSString).deletingPathExtension, input.appendingPathComponent($0), $0)
        }
    }
    let parent = input.deletingLastPathComponent()
    var out: [(String, URL, String)] = []
    for line in try String(contentsOf: input, encoding: .utf8).split(separator: "\n") {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let relative = object["audio"] as? String
        else { continue }
        let id = (object["id"] as? String) ?? (relative as NSString).lastPathComponent
        out.append((id, parent.appendingPathComponent(relative), relative))
    }
    return out
}

// MARK: - Apple

/// A fresh analyzer per file, because sample-rate conversion is stateful. This
/// is `tools/transcribe`'s path, copied deliberately rather than shared: that
/// tool's determinism gate (same audio twice, 4 of 4 identical) was measured
/// on exactly this code, and a probe that drifts from it is not comparable to
/// the numbers already in the EVAL-LOG.
func apple(_ url: URL) async throws -> (String, [Word]) {
    guard
        let supported = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en-US"))
    else { throw NSError(domain: "engineprobe", code: 2) }
    let module = SpeechTranscriber(
        locale: supported, transcriptionOptions: [], reportingOptions: [.fastResults],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    let analyzer = SpeechAnalyzer(modules: [module])

    let file = try AVAudioFile(forReading: url)
    let fileFormat = file.processingFormat
    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [module], considering: fileFormat)
    let converter =
        (analyzerFormat != nil && analyzerFormat != fileFormat)
        ? AVAudioConverter(from: fileFormat, to: analyzerFormat!) : nil

    let collected = Task<(String, [Word]), Error> {
        var text = ""
        var words: [Word] = []
        for try await result in module.results where result.isFinal {
            text += String(result.text.characters)
            for run in result.text.runs {
                let piece = String(result.text[run.range].characters)
                let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                for token in piece.split(separator: " ") {
                    words.append(Word(t: String(token), c: confidence.map { Double($0) }))
                }
            }
        }
        return (text, words)
    }

    let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: inputs)
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
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
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

// MARK: - Parakeet

/// Loaded once, used for every file, exactly as the app holds it.
actor ParakeetHarness {
    private var manager: AsrManager?
    private let converter = AudioConverter()

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)
        let live = AsrManager(config: .default)
        try await live.loadModels(models)
        manager = live
    }

    func hear(_ url: URL) async throws -> (String, [Word]) {
        guard let manager else { throw NSError(domain: "engineprobe", code: 3) }
        let samples = try converter.resampleAudioFile(url)
        // A fresh decoder state per recording. Reusing one would carry a
        // sentence's decoder history into the next, which is exactly the bug
        // the app avoids by making it a local `var`.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: .english)
        let pieces = (result.tokenTimings ?? []).map {
            SubwordAssembly.Piece(
                text: $0.token, confidence: Double($0.confidence), start: $0.startTime,
                end: $0.endTime)
        }
        // The app's own assembly, not the library's `buildWordTimings`, which
        // discards the confidence the vocabulary layer runs on.
        let heard =
            pieces.isEmpty
            ? result.text.split(whereSeparator: \.isWhitespace).map { Token(text: String($0)) }
            : SubwordAssembly.tokens(from: pieces, aggregation: aggregation)
        // The app's inverse text normalisation, so the arm measures the
        // shipping path rather than the raw decoder.
        let normalized = TextNormalizer.shared.normalizeSentence(result.text)
        let tokens =
            normalized != result.text
            ? TokenRealignment.carryingConfidence(from: heard, onto: normalized) : heard
        return (normalized, tokens.map { Word(t: $0.text, c: $0.confidence) })
    }
}

// MARK: - Whisper

actor WhisperHarness {
    private var pipe: WhisperKit?
    private let converter = AudioConverter()
    /// Where the app keeps it, so a machine that has used "Better hearing"
    /// downloads nothing.
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chalant/Models", isDirectory: true)
    }
    private static let variant = "large-v3-v20240930_626MB"

    func prepare() async throws {
        guard pipe == nil else { return }
        let models = try await WhisperKit.download(
            variant: Self.variant, downloadBase: Self.folder, progressCallback: { _ in })
        pipe = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: models.path, tokenizerFolder: Self.folder, verbose: false,
                logLevel: .error, prewarm: true, load: true, download: false))
    }

    /// The prompt the app would send: the standing names, chosen for this
    /// utterance. Empty here, because the probe has no access to the user's
    /// vocabulary and a prompt the app would not send makes the arm
    /// incomparable. Whisper's own name numbers live in
    /// `verification/NAMES_2026-08-18.md`.
    func hear(_ url: URL) async throws -> (String, [Word]) {
        guard let pipe else { throw NSError(domain: "engineprobe", code: 4) }
        let samples = try converter.resampleAudioFile(url)
        var options = DecodingOptions()
        options.language = "en"
        options.task = .transcribe
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.usePrefillPrompt = true
        options.temperatureFallbackCount = 2
        options.concurrentWorkerCount = 1
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // No per-word confidence exists on this engine; nil is unknown, never
        // zero, and `TermMatcher` correctly refuses to act on it.
        return (text, text.split(whereSeparator: \.isWhitespace).map { Word(t: String($0), c: nil) })
    }
}

// MARK: - The deterministic chain

/// The shipping order from `DictationController.deterministicText`, with an
/// empty vocabulary, so an engine's raw words and its cleaned words can both
/// be scored. Kept in step by eye; `tools/textpath` is the one that compiles
/// the app's own file.
func deterministic(_ text: String) -> String {
    Paragraphs.applying(
        Breaks.sentencing(
            Contrast.commaBeforeNot(
                Restatement.collapsing(
                    Fillers.removing(
                        Repair.repairing(
                            Disfluency.collapsingRepetitions(
                                Guardrail.settlingEllipses(
                                    Guardrail.trimmingPunctuationRun(text)))))))))
}

// MARK: - Run

let all = try recordings()
let chosen = limit.map { Array(all.prefix($0)) } ?? all
FileHandle.standardError.write(
    Data("engineprobe: \(chosen.count) recordings through \(engineName)\n".utf8))

let parakeet = ParakeetHarness()
let whisper = WhisperHarness()
switch engineName {
case "parakeet": try await parakeet.prepare()
case "whisper": try await whisper.prepare()
default: break
}

var rows: [Row] = []
var failures = 0
for (index, item) in chosen.enumerated() {
    let started = Date()
    do {
        let (text, words): (String, [Word]) =
            switch engineName {
            case "parakeet": try await parakeet.hear(item.url)
            case "whisper": try await whisper.hear(item.url)
            default: try await apple(item.url)
            }
        let seconds = Date().timeIntervalSince(started)
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rows.append(
            Row(
                id: item.id, audio: item.relative, raw: raw, seconds: seconds, engine: engineName,
                deep: deep ? deterministic(raw) : nil, detail: wantTokens ? words : nil))
        print("[\(index + 1)/\(chosen.count)] \(item.id) \(String(format: "%.2fs", seconds))")
    } catch {
        failures += 1
        FileHandle.standardError.write(
            Data("  \(item.id): \(error.localizedDescription)\n".utf8))
    }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
var out = ""
for row in rows {
    out += String(data: try encoder.encode(row), encoding: .utf8)! + "\n"
}
try out.write(to: output, atomically: true, encoding: .utf8)

let total = rows.map(\.seconds).reduce(0, +)
let sorted = rows.map(\.seconds).sorted()
let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
FileHandle.standardError.write(
    Data(
        """
        engineprobe: wrote \(rows.count) rows to \(output.path)\
        \(failures > 0 ? ", \(failures) failed" : "")
        decode: \(String(format: "%.2f", total))s total, \(String(format: "%.3f", median))s median

        """.utf8))
