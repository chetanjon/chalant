import AVFoundation
import Foundation
import Speech

// The Part 0 §0.1 smoke test.
//
// §0.1 reports, CONFIRMED by two independent research passes, that
// `AnalysisContext.contextualStrings` does NOT bias `SpeechTranscriber`: the
// API accepts the strings and silently ignores them on that module, and only
// `DictationTranscriber` honours them. The whole vocabulary design (M4, M5)
// forks on whether that is true here.
//
// §0.1: "a tiny CLI that transcribes one recording of unusual names through
// both modules, with and without contextual strings. This settles on-machine
// what forum archaeology cannot. If Path A's biasing also fails on this
// hardware, both paths reduce to B and the decision is made."
//
// Reads a file rather than the microphone, deliberately: identical audio for
// all four runs is the only way the comparison means anything.

let terms = ["Chalant", "Kizu", "Aatram", "FrictionLens", "Gangothri"]

guard CommandLine.arguments.count > 1 else {
    print("usage: biasprobe <audio-file> [locale]")
    exit(2)
}
let path = CommandLine.arguments[1]
let localeID = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "en-US"

/// Feed one file through one configuration and return what came back.
func run(module: any SpeechModule, biased: Bool, label: String) async -> String {
    do {
        // Assets are per-module, not per-locale: SpeechTranscriber being ready
        // says nothing about DictationTranscriber. Install before asking.
        if await AssetInventory.status(forModules: [module]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                FileHandle.standardError.write("  installing assets for \(label)…\n".data(using: .utf8)!)
                try await request.downloadAndInstall()
            }
        }

        let analyzer = SpeechAnalyzer(modules: [module])

        if biased {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else { return "<no compatible format>" }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat)

        // Collect finalized spans while the analyzer works.
        // Finalized spans append; volatile spans replace. DictationTranscriber
        // on `.shortDictation` was observed emitting ONE volatile result and
        // never finalizing even after finalizeAndFinishThroughEndOfInput(), so
        // filtering on isFinal silently returned nothing and made the module
        // look broken. Keep both and prefer the finalized text when it exists.
        let collected = Task { () -> String in
            var finalized = ""
            var lastVolatile = ""
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await r in transcriber.results {
                        if r.isFinal { finalized += String(r.text.characters) }
                        else { lastVolatile = String(r.text.characters) }
                    }
                } else if let dictation = module as? DictationTranscriber {
                    for try await r in dictation.results {
                        if r.isFinal { finalized += String(r.text.characters) }
                        else { lastVolatile = String(r.text.characters) }
                    }
                }
            } catch {
                return "<stream error: \(error.localizedDescription)>"
            }
            return finalized.isEmpty ? lastVolatile : finalized
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        Task {
            let chunk: AVAudioFrameCount = 4096
            while file.framePosition < file.length {
                guard let input = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: chunk
                ) else { break }
                try? file.read(into: input, frameCount: chunk)
                if input.frameLength == 0 { break }

                var out = input
                if let converter, file.processingFormat != analyzerFormat {
                    let ratio = analyzerFormat.sampleRate / file.processingFormat.sampleRate
                    let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
                    if let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) {
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
        return try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return "<error: \(error.localizedDescription)>"
    }
}

/// Which of the five terms survived, so the eye does not have to diff prose.
func hits(_ text: String) -> String {
    let found = terms.filter { text.localizedCaseInsensitiveContains($0) }
    return "\(found.count)/\(terms.count)" + (found.isEmpty ? "" : "  [\(found.joined(separator: ", "))]")
}

let requested = Locale(identifier: localeID)
print("file:   \(path)")
print("locale: \(localeID)")
print("terms:  \(terms.joined(separator: ", "))\n")

if let loc = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
    for biased in [false, true] {
        let m = SpeechTranscriber(locale: loc, preset: .transcription)
        let text = await run(module: m, biased: biased, label: "SpeechTranscriber")
        print("SpeechTranscriber   \(biased ? "WITH bias   " : "no bias     ") \(hits(text))")
        print("   \(text)\n")
    }
} else {
    print("SpeechTranscriber: locale unsupported\n")
}

if let loc = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
    for biased in [false, true] {
        let m = DictationTranscriber(locale: loc, preset: .shortDictation)
        let text = await run(module: m, biased: biased, label: "DictationTranscriber")
        print("DictationTranscriber \(biased ? "WITH bias  " : "no bias    ") \(hits(text))")
        print("   \(text)\n")
    }
} else {
    print("DictationTranscriber: locale unsupported\n")
}
