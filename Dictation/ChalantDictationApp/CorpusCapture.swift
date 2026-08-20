import AVFoundation
import Foundation
import os

/// Turns a real day of dictating into an eval corpus.
///
/// **Why this exists.** Part 4 names the single biggest trap in building the
/// corpus: *"Do not read from a script. Read-aloud speech and spontaneous
/// speech are different acoustic phenomena... A corpus of read sentences will
/// make your app look excellent and tell you nothing about how it performs
/// when you're actually working."*
///
/// Sets C and D can be prompted, because you cannot produce "do not deploy to
/// production" or say the same sentence three times on demand. Sets A, B and E
/// cannot. The only honest way to collect them is to keep the audio from
/// dictation you were going to do anyway, which is what this does.
///
/// **Off unless explicitly switched on, and it says so.** Every other part of
/// this app is careful never to persist what you said: Part 1 §2 keeps
/// transcripts out of logs entirely, and `VoiceController.sweepRecordings()`
/// deletes the last session's audio on launch and on quit. This deliberately
/// does the opposite, so it is not something to leave running by accident.
/// Nothing leaves the machine either way.
actor CorpusCapture {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "corpus")

    /// Off by default. On is a decision, not a setting somebody drifts into.
    static let enabledKey = "dictationCaptureCorpus"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    /// `~/Desktop/chalant-corpus/captured`, beside the prompted sets, so the
    /// whole corpus is one folder a human can see and delete.
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/chalant-corpus/captured")
    }

    private var pending: (id: String, audio: URL, startedAt: Date, bundleID: String?)?

    /// Begin an utterance. Returns where the audio should be written, or nil
    /// when capture is off, which is the normal case.
    func begin(bundleID: String?, at now: Date = Date()) -> URL? {
        guard Self.isEnabled() else { return nil }
        try? FileManager.default.createDirectory(
            at: Self.folder, withIntermediateDirectories: true)

        // Sortable, unique, and readable in a Finder window without a tool.
        let stamp = Self.stampFormatter.string(from: now)
        let id = "cap-\(stamp)"
        let audio = Self.folder.appendingPathComponent("\(id).caf")
        pending = (id: id, audio: audio, startedAt: now, bundleID: bundleID)
        return audio
    }

    /// Close the utterance out with what the app actually produced.
    ///
    /// `output` is the app's own text, which becomes the thing to score. The
    /// `desired` column stays empty on purpose: only the person who spoke can
    /// say what they meant, and Part 4 is firm that a corpus labelled from the
    /// machine's own guess is a story you tell yourself.
    func finish(
        output: String, fedBuffers: Int, finalize: TimeInterval?, insert: TimeInterval?,
        polish: TimeInterval? = nil, refinedAtOnce: Bool = false
    ) {
        guard let p = pending else { return }
        pending = nil

        // A row per utterance, appended, so an interrupted day loses nothing.
        // The polish wait and whether the words landed refined ride along
        // because the log's info retention is minutes and the standing
        // overshoot question needs numbers that survive a night
        // (2026-08-20; the "elapsed here" line kept purging before anyone
        // could read it).
        let row: [String: Any] = [
            "id": p.id,
            "audio": "captured/\(p.id).caf",
            "recorded": ISO8601DateFormatter().string(from: p.startedAt),
            "app": p.bundleID ?? "unknown",
            "output": output,
            "desired": "",            // you fill this in; nothing else may
            "verbatim": "",           // only where it differs from desired
            "context": "",            // short | longform | technical | rambling | propernoun
            "split": "",
            "fedBuffers": fedBuffers,
            "finalizeSeconds": finalize ?? 0,
            "insertSeconds": insert ?? 0,
            "polishSeconds": polish ?? 0,
            "refinedAtOnce": refinedAtOnce,
            "note": "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let manifest = Self.folder.appendingPathComponent("captured.jsonl")
        if let handle = try? FileHandle(forWritingTo: manifest) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: manifest)
        }
        Self.log.info("captured \(p.id, privacy: .public) (\(output.count, privacy: .public) chars)")
    }

    /// Drop a started utterance that produced nothing worth keeping.
    func discard() {
        guard let p = pending else { return }
        pending = nil
        try? FileManager.default.removeItem(at: p.audio)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.timeZone = .current
        return f
    }()
}
