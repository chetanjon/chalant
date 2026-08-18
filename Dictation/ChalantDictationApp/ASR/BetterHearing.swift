import ChalantDictationCore
import Foundation
import os
import WhisperKit

/// The second ear: Whisper, on this Mac, listening to the utterance AFTER the
/// words have landed, so a better hearing can replace them in place.
///
/// Measured before it was built (`verification/EAR_2026-08-17.md`): on the
/// founder's own voice the 626 MB large-v3-turbo build hears Kizu, Priya,
/// Gangotri, "tidy pass" and "no red flags" where Apple's recognizer does
/// not, at 7.1% word error on the torture set against Apple's 12.8%, and it
/// costs about 1.2 s per utterance after the audio ends. Too slow to be the
/// ear that lands words instantly; right for the one whose better version
/// arrives a second or two later, through the same in-place swap the tidy
/// pass uses.
///
/// **Off unless switched on, and nothing is downloaded until it is.** The
/// switch's note says what it costs: a one-time 606 MB download to this Mac,
/// memory while it is loaded, more battery per sentence. Nothing leaves the
/// Mac; the model is fetched once from Hugging Face and lives in Application
/// Support.
actor BetterHearing {
    static let shared = BetterHearing()
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "hearing")

    static let enabledKey = "dictationBetterHearing"
    /// The variant measured. Turbo, compressed: hears as well as the 1.6 GB
    /// build on this voice (better on the torture set), a third of the size,
    /// a third of the time.
    static let modelVariant = "large-v3-v20240930_626MB"
    static let downloadSizeDescription = "606 MB"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    /// Where the model lives: Application Support, beside everything else
    /// Chalant keeps, never the Documents folder Hugging Face would pick.
    static var modelsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Chalant/Models", isDirectory: true)
    }

    private var pipe: WhisperKit?
    private var preparing: Task<Void, Never>?

    /// Download if needed, load, warm. Idempotent; a second call while one is
    /// running joins it. Reports through `HearingStatus`.
    func prepare() async {
        if pipe != nil { await HearingStatus.shared.set(.ready); return }
        if let preparing { await preparing.value; return }
        let task = Task { await self.load() }
        preparing = task
        await task.value
        preparing = nil
    }

    private func load() async {
        do {
            await HearingStatus.shared.set(.downloading(0))
            let folder = try await WhisperKit.download(
                variant: Self.modelVariant,
                downloadBase: Self.modelsFolder,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    Task { await HearingStatus.shared.set(.downloading(fraction)) }
                })
            guard !Task.isCancelled else { return }
            await HearingStatus.shared.set(.loading)
            // The tokenizer is fetched once too, and it must go under the same
            // folder: left nil, WhisperKit's hub cache defaults to ~/Documents
            // and macOS asks "Chalant would like to access files in your
            // Documents folder" (seen live 2026-08-18). Chalant never touches
            // Documents.
            let config = WhisperKitConfig(
                modelFolder: folder.path, tokenizerFolder: Self.modelsFolder,
                verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
            let loaded = try await WhisperKit(config)
            guard !Task.isCancelled else { return }
            pipe = loaded
            await HearingStatus.shared.set(.ready)
            Self.log.info("better hearing ready: \(Self.modelVariant, privacy: .public)")
        } catch {
            Self.log.error("better hearing could not load: \(String(describing: error), privacy: .public)")
            await HearingStatus.shared.set(.failed(error.localizedDescription))
        }
    }

    /// Switched off: forget the model so its memory goes back.
    func stop() async {
        preparing?.cancel()
        preparing = nil
        pipe = nil
        await HearingStatus.shared.set(.off)
    }

    var isReady: Bool { pipe != nil }

    /// Whisper's hearing of the utterance, or nil when there is nothing to
    /// say (not loaded, too little audio, failure). 16 kHz mono Float32 in.
    /// Lengths and timings are logged, never content.
    ///
    /// `hints` are the names it reads before it listens (`Names.forHearing`),
    /// as Whisper's previous-text prompt. Every prompt token is a decoder step
    /// (~13 ms on this Mac), which is why the list arrives already capped and
    /// chosen for this utterance; the encoder is unaffected.
    func hear(_ samples: [Float], hints: [String] = []) async -> String? {
        guard let pipe else { return nil }
        guard samples.count >= 16_000 / 2 else { return nil }
        var options = DecodingOptions()
        options.language = "en"
        options.task = .transcribe
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.usePrefillPrompt = true
        options.temperatureFallbackCount = 2
        options.concurrentWorkerCount = 1
        var promptTokenCount = 0
        if !hints.isEmpty, let tokenizer = pipe.tokenizer {
            // The same encoding WhisperKit's own CLI uses for `--prompt`: a
            // leading space, and no special tokens the text might spell.
            let tokens = tokenizer.encode(text: " " + NameHints.prompt(hints))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                promptTokenCount = tokens.count
            }
        }
        let started = ContinuousClock.now
        do {
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = Double(started.duration(to: .now).components.seconds)
                + Double(started.duration(to: .now).components.attoseconds) * 1e-18
            Self.log.info(
                "heard \(samples.count / 16_000, privacy: .public)s of audio as \(text.count, privacy: .public) chars in \(seconds, privacy: .public)s with \(hints.count, privacy: .public) names (\(promptTokenCount, privacy: .public) prompt tokens)")
            return text.isEmpty ? nil : text
        } catch {
            Self.log.error("hearing failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The plain-text deterministic passes, for a hearing that comes as text
    /// rather than tokens (the vocabulary passes need per-word confidence and
    /// are skipped): refuse what is not text, collapse what was said twice,
    /// remove the words nobody meant to say.
    static func deterministic(_ text: String) -> String {
        Fillers.removing(Disfluency.collapsingRepetitions(Guardrail.trimmingPunctuationRun(text)))
    }

    /// Whether a hearing is plausibly the same utterance as what landed.
    /// Whisper on a starved microphone invents whole sentences ("Baddie
    /// wannabe.", measured), and a hearing wildly longer or shorter than
    /// Apple's is more likely that than a better ear. Same-order-of-length is
    /// the bar: half to double.
    static func plausible(hearing: String, against landed: String) -> Bool {
        let h = hearing.count, l = landed.count
        guard h > 0, l > 0 else { return false }
        return h * 2 >= l && h <= l * 2
    }
}

/// What Settings shows under the switch. Main-actor, observable, tiny.
@MainActor
final class HearingStatus: ObservableObject {
    static let shared = HearingStatus()
    enum State: Equatable {
        case off, downloading(Double), loading, ready, failed(String)
    }
    @Published private(set) var state: State = .off

    func set(_ state: State) { self.state = state }

    var line: String {
        switch state {
        case .off: return "Off. Turning it on downloads the model once (\(BetterHearing.downloadSizeDescription))."
        case .downloading(let f): return "Downloading the better ear… \(Int(f * 100))%"
        case .loading: return "Loading…"
        case .ready: return "Ready. Your words are corrected in place a second or two after they land, when it heard better."
        case .failed(let why): return "Could not download: \(why). It will try again next launch."
        }
    }
}
