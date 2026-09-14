import ChalantDictationCore
import FluidAudio
import Foundation
import os

/// Parakeet TDT v3, on this Mac, through FluidAudio.
///
/// **What it is, measured on this machine on 2026-09-14 rather than quoted
/// from anywhere:**
///
/// | | |
/// |---|---|
/// | Download | 471 MB on disk, once |
/// | First load after download | ~17 s, the Neural Engine compiling the model |
/// | Every load after that | 0.10 s, in a fresh process |
/// | Decode | 0.10 s for 9.4 s of speech, 86 to 98x faster than real time |
/// | Resident | ~87 MB peak, against the 626 MB Whisper holds |
///
/// Two of those numbers change the design. The model is **cheap to hold**, so
/// unlike the second ear it is not put down after a long silence: the reason
/// that rule exists is that macOS reclaimed Chalant twice in five days while
/// it sat on 626 MB, and 87 MB is not what RunningBoard reaches for. And the
/// first load is **expensive exactly once**, so it happens where the user is
/// already waiting on a progress bar, never behind a held key.
///
/// **It is a batch engine and is never described otherwise.** FluidAudio's
/// `StreamingAsrManager` is a protocol that TDT explicitly does not conform
/// to, and the sliding-window wrapper is chunked batch whose own
/// documentation says the "streaming" name was misleading. Audio goes in
/// whole when the key comes up. Above 15 s `AsrManager` splits it itself, in
/// ~14.96 s frame-aligned windows with 2 s of overlap, and reconciles the
/// seams itself; those figures are derived from the encoder's window and are
/// documented as not runtime-configurable, so nothing here second-guesses
/// them.
///
/// Nothing leaves the Mac. The model is fetched once from Hugging Face and
/// lives in Application Support.
actor ParakeetEngine {
    static let shared = ParakeetEngine()
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "parakeet")

    /// Roughly, for the Settings line. Measured at 471 MB on disk; the
    /// sentence a person reads should not pretend to three digits.
    static let downloadSizeDescription = "about 470 MB"

    private var manager: AsrManager?
    private var preparing: Task<Void, Never>?

    /// Where FluidAudio keeps it. Asked of the library rather than spelled
    /// out: a hand-written path was wrong in the research that preceded this
    /// file (it has no `-coreml` suffix), and `download(to:)` writes to the
    /// PARENT of whatever directory it is given, so a custom path quietly
    /// produces a sibling folder. Let the library own its own layout.
    static var modelsDirectory: URL { AsrModels.defaultCacheDirectory(for: .v3) }

    /// Whether the model is already on disk. Pure `FileManager`, no network,
    /// safe to ask at launch and on every Settings redraw.
    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: modelsDirectory, version: .v3, encoderPrecision: .int8)
    }

    var isReady: Bool { manager != nil }

    /// Load if the model is on disk; download first if it is not.
    ///
    /// Idempotent, and a second call while one is running joins it. Reports
    /// through `ParakeetStatus`. **Only ever called from a deliberate user
    /// action or from launch when the model is already present** — a held key
    /// must never start a 471 MB download.
    func prepare(allowingDownload: Bool) async {
        if manager != nil {
            await ParakeetStatus.shared.set(.ready)
            return
        }
        if let preparing {
            await preparing.value
            return
        }
        guard allowingDownload || Self.isDownloaded else {
            await ParakeetStatus.shared.set(.notDownloaded)
            return
        }
        let task = Task { await self.load() }
        preparing = task
        await task.value
        preparing = nil
    }

    private func load() async {
        let alreadyThere = Self.isDownloaded
        await ParakeetStatus.shared.set(alreadyThere ? .loading : .downloading(0))
        let started = Date()
        do {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                encoderPrecision: .int8,
                progressHandler: { progress in
                    // Documented as called on an unspecified queue.
                    Task { @MainActor in
                        switch progress.phase {
                        case .listing:
                            ParakeetStatus.shared.set(.downloading(0))
                        case .downloading:
                            ParakeetStatus.shared.set(.downloading(progress.fractionCompleted))
                        case .compiling:
                            // The ~17 s the Neural Engine spends on the first
                            // load. Part 0 §0.8: "15 s is an eternity against
                            // a spinner", so it gets its own word.
                            ParakeetStatus.shared.set(.compiling)
                        @unknown default:
                            ParakeetStatus.shared.set(.loading)
                        }
                    }
                })
            guard !Task.isCancelled else { return }
            await ParakeetStatus.shared.set(.loading)
            let live = AsrManager(config: .default)
            try await live.loadModels(models)
            guard !Task.isCancelled else { return }
            manager = live
            await ParakeetStatus.shared.set(.ready)
            Self.log.info(
                "parakeet ready in \(Date().timeIntervalSince(started), privacy: .public)s (downloaded already: \(alreadyThere, privacy: .public))")
        } catch {
            Self.log.error("parakeet could not load: \(String(describing: error), privacy: .public)")
            await ParakeetStatus.shared.set(.failed(error.localizedDescription))
        }
    }

    /// Let the model go. Only on a deliberate switch away from this engine:
    /// unlike the second ear there is no idle-sleep rule, because 87 MB is
    /// not worth the reload and is not what gets an app reclaimed.
    func stop() async {
        preparing?.cancel()
        preparing = nil
        if let manager { await manager.cleanup() }
        manager = nil
        await ParakeetStatus.shared.set(Self.isDownloaded ? .notLoaded : .notDownloaded)
    }

    /// What one decode produced, with what it cost.
    struct Hearing: Sendable {
        var tokens: [Token]
        var text: String
        var seconds: Double
    }

    enum Failure: Error {
        /// Not loaded. The caller falls back rather than waiting.
        case notReady
        /// The engine ran and threw. Carries the description for the row.
        case engine(String)
    }

    /// Decode one utterance. 16 kHz mono in.
    ///
    /// The decoder state is made fresh here and thrown away here. It is the
    /// caller-owned `inout` the library requires, and reusing one across
    /// independent utterances would carry one sentence's decoder history into
    /// the next.
    func hear(
        _ samples: [Float], aggregation: SubwordAssembly.Aggregation
    ) async throws -> Hearing {
        guard let manager else { throw Failure.notReady }
        let started = Date()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await manager.transcribe(samples, decoderState: &state, language: .english)
        } catch {
            throw Failure.engine(String(describing: error))
        }
        let seconds = Date().timeIntervalSince(started)

        // The pieces, with the confidence FluidAudio's own word helper drops.
        let pieces = (result.tokenTimings ?? []).map {
            SubwordAssembly.Piece(
                text: $0.token, confidence: Double($0.confidence),
                start: $0.startTime, end: $0.endTime)
        }
        // A decode with text but no timings is possible and must not become
        // an empty transcript: fall back to the text the engine returned,
        // unscored, which the vocabulary layer correctly refuses to touch.
        let tokens =
            pieces.isEmpty
            ? result.text.split(whereSeparator: \.isWhitespace).map { Token(text: String($0)) }
            : SubwordAssembly.tokens(from: pieces, aggregation: aggregation)

        Self.log.notice(
            """
            parakeet heard \(Int(Double(samples.count) / 16_000), privacy: .public)s of audio as \
            \(tokens.count, privacy: .public) words in \(seconds, privacy: .public)s \
            (utterance confidence \(result.confidence, privacy: .public))
            """)
        return Hearing(tokens: tokens, text: result.text, seconds: seconds)
    }
}

/// What Settings shows under the recognizer. Main-actor, observable, tiny.
/// Same shape as `HearingStatus`, because the page already knows how to read
/// one of these and a second vocabulary would be a second thing to learn.
@MainActor
final class ParakeetStatus: ObservableObject {
    static let shared = ParakeetStatus()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case compiling
        case loading
        case ready
        case notLoaded
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded

    func set(_ state: State) { self.state = state }

    var line: String {
        switch state {
        case .notDownloaded:
            return
                "Not downloaded yet. Choosing it fetches the model once (\(ParakeetEngine.downloadSizeDescription)). Until then, Apple's recognizer is used."
        case .downloading(let fraction):
            return "Downloading the model… \(Int(fraction * 100))%"
        case .compiling:
            // Said plainly because it takes about fifteen seconds and a
            // silent bar for fifteen seconds reads as a hang.
            return "Preparing the model for this Mac. This happens once and takes a few seconds."
        case .loading:
            return "Loading…"
        case .ready:
            return "Ready. Your words are recognised on this Mac, and nothing is uploaded."
        case .notLoaded:
            return "Downloaded, not loaded. It loads when you choose it."
        case .failed(let why):
            return "Could not load: \(why). Apple's recognizer is being used instead."
        }
    }

    /// Whether the Settings row should offer a retry.
    var canRetry: Bool {
        if case .failed = state { return true }
        return false
    }
}
