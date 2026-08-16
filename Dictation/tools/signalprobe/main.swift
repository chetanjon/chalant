import AVFoundation
import CoreMedia
import Foundation
import Speech

// Two questions in one pass over the corpus, because both need the same 240
// analyzer runs and neither is worth paying for twice.
//
// **Q1, the evidence for the signal layer.** `AppleTranscriber` used to flatten
// the engine's `AttributedString` to a plain String, so every `Token` arrived
// with `confidence == nil` and `TermMatcher` refused to act on any of them.
// This compiles the SHIPPING `TokenAssembly` and reports how many tokens come
// back carrying confidence. Compiling the real source is the point: a number
// measured against a copy of the code can drift away from the code.
//
// **Q2, the Part 0 §0.1 deciding experiment, on real audio at last.** The
// smoke test (EVAL-LOG 2026-08-12) ran ONE synthesized file and found
// `contextualStrings` does nothing on `SpeechTranscriber` and moves
// `DictationTranscriber` from 0/5 terms to 3/5. §0.1 says the decision belongs
// to the founder's own corpus, because §0.12 shows engine rankings INVERT on
// accented speech. That run never happened. Until it does, the whole vocabulary
// layer is being built on one recording of a synthetic voice.
//
// Emits JSONL on stdout, one row per (utterance x module x biased), shaped so
// `score.py` can read it directly.

struct Row: Codable {
    let id: String
    let context: String
    let split: String
    let audio: String
    let desired: String
    let verbatim: String?
}

struct TokenDetail: Codable {
    let t: String
    let c: Double?
}

struct Out: Codable {
    let id: String
    let context: String
    let split: String
    let audio: String
    let desired: String
    let config: String
    let biased: Bool
    let output: String
    /// The same utterance after the FULL shipping text pipeline, so the
    /// vocabulary layer's effect is measured against the code that runs, not
    /// against a description of it.
    let piped: String
    let tokens: Int
    let withConfidence: Int
    let meanConfidence: Double?
    let minConfidence: Double?
    let alternatives: Int
    let seconds: Double
    let detail: [TokenDetail]
}

/// The shipping order, and the reason for it. `TermMatcher` runs FIRST because
/// it is the only stage that needs per-word confidence, and confidence exists
/// only on tokens; the three deterministic stages delete words, after which no
/// alignment back to the engine's own scoring survives. Substitution is one
/// word for one word, so running it first cannot disturb the stages behind it.
func pipeline(_ tokens: [Token], terms: [String]) -> String {
    // Spans first, while every token is still present: joining a name the
    // engine split needs all its pieces, and it can only ever shorten the
    // sequence the single-word pass then walks.
    let whole = TermMatcher.joiningSpans(tokens: tokens, terms: terms)
    let resolved = TermMatcher.resolving(tokens: whole, terms: terms)
    let raw = resolved.map(\.text).joined(separator: " ")
    return Fillers.removing(Disfluency.collapsingRepetitions(Guardrail.trimmingPunctuationRun(raw)))
}

let args = CommandLine.arguments
guard args.count > 4 else {
    FileHandle.standardError.write(
        "usage: signalprobe <corpusdir> <manifest.jsonl> <terms.txt> <locale>\n".data(using: .utf8)!)
    exit(2)
}
let corpusDir = URL(fileURLWithPath: args[1])
let manifestPath = args[2]
let termsPath = args[3]
let localeID = args[4]

let debug = ProcessInfo.processInfo.environment["SIGNALPROBE_DEBUG"] != nil

let terms = (try? String(contentsOfFile: termsPath, encoding: .utf8))?
    .split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty } ?? []

let rows: [Row] = (try! String(contentsOfFile: manifestPath, encoding: .utf8))
    .split(separator: "\n")
    .compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Row.self, from: data)
    }

FileHandle.standardError.write(
    "\(rows.count) utterances, \(terms.count) terms, locale \(localeID)\n".data(using: .utf8)!)

/// What one configuration made of one file.
struct Reading {
    var text = ""
    var tokens: [Token] = []
    var alternatives = 0
    var seconds = 0.0
}

func feed(_ path: URL, into analyzer: SpeechAnalyzer, format: AVAudioFormat) async throws {
    let file = try AVAudioFile(forReading: path)
    let converter = AVAudioConverter(from: file.processingFormat, to: format)
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

    Task {
        let chunk: AVAudioFrameCount = 4096
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try? file.read(into: input, frameCount: chunk)
            if input.frameLength == 0 { break }

            var out = input
            if let converter, file.processingFormat != format {
                let ratio = format.sampleRate / file.processingFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
                if let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) {
                    var supplied = false
                    var err: NSError?
                    converter.convert(to: converted, error: &err) { _, status in
                        if supplied { status.pointee = .noDataNow; return nil }
                        supplied = true
                        status.pointee = .haveData
                        return input
                    }
                    if err == nil, converted.frameLength > 0 { out = converted }
                }
            }
            continuation.yield(AnalyzerInput(buffer: out))
        }
        continuation.finish()
    }

    _ = try await analyzer.analyzeSequence(stream)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
}

/// Runs to `TokenAssembly.Run`, so the probe and the app agree by construction.
func runs(of text: AttributedString) -> [TokenAssembly.Run] {
    text.runs.map { run in
        let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
        return TokenAssembly.Run(
            text: String(text[run.range].characters),
            confidence: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self],
            start: range.map { CMTimeGetSeconds($0.start) },
            end: range.map { CMTimeGetSeconds($0.end) })
    }
}

func read(audio: URL, speech: Bool, biased: Bool, locale: Locale) async -> Reading {
    var reading = Reading()
    let started = Date()
    do {
        // Assets are per-module: SpeechTranscriber being installed says nothing
        // about DictationTranscriber (EVAL-LOG 2026-08-12).
        let module: any SpeechModule
        if speech {
            module = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .alternativeTranscriptions, .fastResults],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        } else {
            module = DictationTranscriber(
                locale: locale,
                contentHints: [.shortForm],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .alternativeTranscriptions],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }

        if await AssetInventory.status(forModules: [module]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                FileHandle.standardError.write("  installing assets…\n".data(using: .utf8)!)
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        if biased {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        else { return reading }

        // Finalized spans append; volatile spans replace. Two traps here, both
        // paid for once already:
        //
        // 1. DictationTranscriber on short input emits a volatile result and
        //    never finalizes (EVAL-LOG 2026-08-12), so filtering on isFinal
        //    reports a working module as empty. Keep both, prefer finalized.
        // 2. **Measured 2026-08-15 on C01:** DictationTranscriber emits the
        //    SAME full span finalized TWICE, so blind concatenation returns
        //    "Do not apply this to production until Monday Do not apply this to
        //    production until Monday" and every score doubles its error count.
        //    This is Part 1 §3's banned pattern wearing a different hat: a
        //    finalized result is not automatically an increment. Reconcile by
        //    prefix, so a cumulative re-emission replaces and a genuine
        //    continuation appends.
        let collector = Task { () -> Reading in
            var r = Reading()
            var finalRuns: [TokenAssembly.Run] = []
            var lastVolatile: [TokenAssembly.Run] = []
            var finalText = ""
            var volatileText = ""

            // Keyed by the span of AUDIO the result describes, which is the
            // only thing that says whether two finals are the same words twice
            // or two different stretches of speech. Text-prefix reconciliation
            // was tried first and it is not reliable: the module's emission
            // pattern varies between identical runs of identical audio.
            var finals: [(start: Double, end: Double, text: String, runs: [TokenAssembly.Run])] = []

            func absorb(
                _ text: AttributedString, isFinal: Bool, alternatives: Int, range: CMTimeRange
            ) {
                guard isFinal else {
                    volatileText = String(text.characters)
                    lastVolatile = runs(of: text)
                    return
                }
                r.alternatives += alternatives
                let start = CMTimeGetSeconds(range.start)
                let end = CMTimeGetSeconds(range.end)
                if debug {
                    FileHandle.standardError.write(
                        "    final [\(start)…\(end)] \(String(text.characters).count) chars\n"
                            .data(using: .utf8)!)
                }
                // A final covering a span already seen REPLACES it. Same span,
                // same words: the later reading is the module's better one.
                if let i = finals.firstIndex(where: { abs($0.start - start) < 0.001 }) {
                    finals[i] = (start, end, String(text.characters), runs(of: text))
                } else {
                    finals.append((start, end, String(text.characters), runs(of: text)))
                }
            }

            do {
                if let t = module as? SpeechTranscriber {
                    for try await result in t.results {
                        absorb(
                            result.text, isFinal: result.isFinal,
                            alternatives: result.alternatives.count, range: result.range)
                    }
                } else if let d = module as? DictationTranscriber {
                    for try await result in d.results {
                        absorb(
                            result.text, isFinal: result.isFinal,
                            alternatives: result.alternatives.count, range: result.range)
                    }
                }
            } catch {
                FileHandle.standardError.write(
                    "  stream error: \(error.localizedDescription)\n".data(using: .utf8)!)
            }

            finals.sort { $0.start < $1.start }
            finalText = finals.map(\.text).joined()
            finalRuns = finals.flatMap(\.runs)

            let useFinal = !finalText.trimmingCharacters(in: .whitespaces).isEmpty
            r.text = (useFinal ? finalText : volatileText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            r.tokens = TokenAssembly.tokens(from: useFinal ? finalRuns : lastVolatile)
            return r
        }

        try await feed(audio, into: analyzer, format: format)
        reading = try await collector.value
    } catch {
        FileHandle.standardError.write(
            "  error: \(error.localizedDescription)\n".data(using: .utf8)!)
    }
    reading.seconds = Date().timeIntervalSince(started)
    return reading
}

let requested = Locale(identifier: localeID)
let speechLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: requested)

if speechLocale == nil {
    FileHandle.standardError.write("SpeechTranscriber: locale unsupported\n".data(using: .utf8)!)
}
if dictationLocale == nil {
    FileHandle.standardError.write("DictationTranscriber: locale unsupported\n".data(using: .utf8)!)
}

let encoder = JSONEncoder()
var done = 0

// **The control run is not padding.** On C01 the unbiased dictation run said
// "apply" and the biased one said "deploy", and "deploy" is not in the term
// list. Either biasing has effects beyond its own terms, or the module is
// simply not deterministic. Repeating one configuration unchanged is the only
// way to tell an effect from noise, and without it every difference below would
// be read as bias.
var configs: [(label: String, speech: Bool, biased: Bool)] = [
    ("speech", true, false),
    ("speech-biased", true, true),
    ("speech-control", true, false),
    ("dictation", false, false),
    ("dictation-biased", false, true),
    ("dictation-control", false, false),
]

// Optional 5th argument: a comma-separated subset, so a re-run that only needs
// one configuration does not pay for all six.
if args.count > 5 {
    let wanted = Set(args[5].split(separator: ",").map(String.init))
    configs = configs.filter { wanted.contains($0.label) }
}

for row in rows {
    let audio = corpusDir.appendingPathComponent(row.audio)
    for config in configs {
        let locale = config.speech ? speechLocale : dictationLocale
        if let locale {
            let reading = await read(
                audio: audio, speech: config.speech, biased: config.biased, locale: locale)
            let confidences = reading.tokens.compactMap(\.confidence)
            let out = Out(
                id: row.id, context: row.context, split: row.split, audio: row.audio,
                desired: row.desired,
                config: config.label,
                biased: config.biased,
                output: reading.text,
                piped: pipeline(reading.tokens, terms: terms),
                tokens: reading.tokens.count,
                withConfidence: confidences.count,
                meanConfidence: confidences.isEmpty
                    ? nil : confidences.reduce(0, +) / Double(confidences.count),
                minConfidence: confidences.min(),
                alternatives: reading.alternatives,
                seconds: reading.seconds,
                detail: reading.tokens.map { TokenDetail(t: $0.text, c: $0.confidence) })
            if let data = try? encoder.encode(out), let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }
    }
    done += 1
    FileHandle.standardError.write("\(done)/\(rows.count) \(row.id)\n".data(using: .utf8)!)
}
