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

    /// Where this instance writes, and which defaults hold its switch.
    /// The app uses the Desktop folder and standard defaults; a test hands
    /// in a temporary folder and its own suite so a row can be written and
    /// read back without touching the founder's corpus (2026-08-21).
    private let folder: URL
    private let defaults: UserDefaults

    init(folder: URL = CorpusCapture.folder, defaults: UserDefaults = .standard) {
        self.folder = folder
        self.defaults = defaults
    }

    private var pending: (id: String, audio: URL, startedAt: Date, bundleID: String?)?

    /// Begin an utterance. Returns where the audio should be written, or nil
    /// when capture is off, which is the normal case.
    func begin(bundleID: String?, at now: Date = Date()) -> URL? {
        guard Self.isEnabled(in: defaults) else { return nil }
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)

        // Sortable, unique, and readable in a Finder window without a tool.
        let stamp = Self.stampFormatter.string(from: now)
        let id = "cap-\(stamp)"
        let audio = folder.appendingPathComponent("\(id).caf")
        pending = (id: id, audio: audio, startedAt: now, bundleID: bundleID)
        return audio
    }

    /// Close the utterance out with what the app actually produced. Returns
    /// the row's id so later facts (the hearing decision, seconds after this
    /// row is written) can be appended against it, or nil when capture is off.
    ///
    /// `output` is the app's own text, which becomes the thing to score. The
    /// `desired` column stays empty on purpose: only the person who spoke can
    /// say what they meant, and Part 4 is firm that a corpus labelled from the
    /// machine's own guess is a story you tell yourself.
    /// The four texts of the path (schema 3, 2026-08-21): `asrRaw` is the
    /// transcriber's own text, `afterDeterministic` the text after the
    /// deterministic passes and list shaping (what the model is shown, and
    /// what lands when it is not), `modelOutput` the model's text when any
    /// chunk came back from it (nil otherwise, and `modelReason` says why:
    /// "gated", "skipped:<why>", "rejected:<rule>", "failed:<error>",
    /// "budgetExpired:<inner|caller>"), `inserted` the string actually
    /// handed to the target app (nil when nothing was, and `insertOutcome`
    /// says why). `output` stays as the legacy alias of `inserted` that
    /// the scoring tools already read.
    struct Texts {
        var asrRaw: String
        var afterDeterministic: String
        var modelOutput: String?
        var modelReason: String
        var modelChunks: [String]
        var inserted: String?
        var insertOutcome: String
    }

    /// What the two ears did with each other, when the merge ran in front of
    /// the landing.
    struct Merge {
        var outcome: String
        var waitSeconds: Double
        var earSeconds: Double
        var disputedSpans: Int
        var mergedSpans: Int
        var earOutput: String?
    }

    @discardableResult
    func finish(
        output: String, fedBuffers: Int, finalize: TimeInterval?, insert: TimeInterval?,
        polish: TimeInterval? = nil, prepare: TimeInterval? = nil, refinedAtOnce: Bool = false,
        holdSeconds: TimeInterval = 0, inputPeak: Double = 0, keyDownHeard: Bool = true,
        polishOutcome: String = "", chunkCount: Int = 0, warmChunks: Int = 0,
        failedChunks: Int = 0, refinedChanged: Bool = false, polishColdStart: Bool = false,
        secondsSinceLastPolish: Double = -1, merge: Merge? = nil, texts: Texts? = nil
    ) -> String? {
        guard let p = pending else { return nil }
        pending = nil

        // A row per utterance, appended, so an interrupted day loses nothing.
        // The polish wait and whether the words landed refined ride along
        // because the log's info retention is minutes and the standing
        // overshoot question needs numbers that survive a night
        // (2026-08-20; the "elapsed here" line kept purging before anyone
        // could read it). schema 2 (2026-08-21): the campaign fields joined
        // and `refinedAtOnce` became honest, so rows before and after must
        // be tellable apart when rates are computed across the seam.
        // schema 3 (2026-08-21, later): the four texts of the path joined
        // (`Texts`), so the protected-span mutation rate can be read off
        // real dictations rather than only off Set C.
        // schema 4 (2026-09-04): the second ear moved in FRONT of the
        // landing, so what it decided is now part of what the user was
        // shown rather than a swap they could watch happen. A merge that
        // gets a word wrong is invisible: nobody sees the version it
        // replaced. These fields are how it stays reviewable.
        var row: [String: Any] = [
            "schema": 4,
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
            "prepareSeconds": prepare ?? 0,
            "refinedAtOnce": refinedAtOnce,
            "holdSeconds": holdSeconds,
            "inputPeak": inputPeak,
            "keyDownHeard": keyDownHeard,
            "polishOutcome": polishOutcome,
            "chunkCount": chunkCount,
            "warmChunks": warmChunks,
            "failedChunks": failedChunks,
            "refinedChanged": refinedChanged,
            "polishColdStart": polishColdStart,
            "secondsSinceLastPolish": secondsSinceLastPolish,
            "note": "",
        ]
        if let merge {
            row["mergeOutcome"] = merge.outcome
            row["mergeWaitSeconds"] = merge.waitSeconds
            row["earSecondsAtRelease"] = merge.earSeconds
            row["disputedSpans"] = merge.disputedSpans
            row["mergedSpans"] = merge.mergedSpans
            // The ear's own words, so a merge can be judged against what it
            // was choosing between rather than only by its verdict.
            row["hearingOutput"] = merge.earOutput ?? NSNull()
        }
        if let texts {
            row["asrRaw"] = texts.asrRaw
            row["afterDeterministic"] = texts.afterDeterministic
            row["modelOutput"] = texts.modelOutput ?? NSNull()
            row["modelReason"] = texts.modelReason
            row["modelChunks"] = texts.modelChunks
            row["inserted"] = texts.inserted ?? NSNull()
            row["insertOutcome"] = texts.insertOutcome
        }
        append(row)
        Self.log.info("captured \(p.id, privacy: .public) (\(output.count, privacy: .public) chars)")
        return p.id
    }

    /// A later fact about a row already written: the hearing decision lands
    /// seconds after `finish`, so it rides its own appended line, joined on
    /// the row's id by the scoring tools. Counts and durations only.
    func annotate(
        id: String, decision: String, seconds: TimeInterval, charsBefore: Int, charsAfter: Int,
        heard: String? = nil
    ) {
        guard Self.isEnabled(in: defaults) else { return }
        var row: [String: Any] = [
            "id": id,
            "kind": "hearing",
            "decision": decision,
            "seconds": seconds,
            "charsBefore": charsBefore,
            "charsAfter": charsAfter,
        ]
        // What the ear actually heard (2026-08-28), so the teaching can be
        // audited row by row. A corpus row is the founder's own opt-in
        // record, not a log; Part 1 §2 still keeps transcripts out of logs.
        if let heard { row["hearingOutput"] = heard }
        append(row)
    }

    /// The shadow run's reply, appended against the row it belongs to (the
    /// row itself was written at insertion with `modelReason` "shadow:pending",
    /// because the words are already on the page by the time the model
    /// answers). The scorers merge this line into its row by id: the
    /// output, the reason, the chunk reasons and the model's own time
    /// become the row's `modelOutput`, `modelReason`, `modelChunks` and
    /// `polishSeconds`; the path's own wait was zero by construction.
    func annotateShadow(
        id: String, output: String?, reason: String, chunks: [String], seconds: TimeInterval,
        coldStart: Bool, secondsSinceLastPolish: Double?
    ) {
        guard Self.isEnabled(in: defaults) else { return }
        append([
            "id": id,
            "kind": "shadow",
            "modelOutput": output ?? NSNull(),
            "modelReason": reason,
            "modelChunks": chunks,
            "polishSeconds": seconds,
            "polishColdStart": coldStart,
            "secondsSinceLastPolish": secondsSinceLastPolish ?? -1,
        ])
    }

    private func append(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let manifest = folder.appendingPathComponent("captured.jsonl")
        if let handle = try? FileHandle(forWritingTo: manifest) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: manifest)
        }
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
