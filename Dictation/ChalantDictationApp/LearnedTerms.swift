import ChalantDictationCore
import Foundation
import os

/// The vocabulary Chalant built by watching, and the only thing in the app a
/// user creates simply by using it.
///
/// **What is on disk is word pairs and nothing else.** Not the sentence they
/// were in, not the document, not the app they were typed in. `Correction`
/// produces a pair or nothing, and only the pair is ever written. Part 1 §2
/// keeps transcripts out of logs; this keeps them off disk.
actor LearnedTerms {
    private static let log = Logger(subsystem: "com.cj.chalant.dictation", category: "learn")

    static let shared = LearnedTerms()

    private var ledger = Correction.Ledger()
    private var loaded = false

    /// Beside the app's other support files, not in the corpus folder: the
    /// corpus is a thing the founder built for testing and deletes at will,
    /// this is the user's own vocabulary and must outlive it.
    static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chalant", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("learned-terms.json")
    }

    /// Whole days since the epoch. `Correction` never calls `Date()` itself so
    /// its decay is deterministic under test (Part 2 §3); this is where real
    /// time enters.
    static func today(_ now: Date = Date()) -> Correction.Day {
        Correction.Day(day: Int(now.timeIntervalSince1970 / 86_400))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.file) else { return }
        guard let decoded = try? JSONDecoder().decode(Correction.Ledger.self, from: data) else {
            // A corrupt file must never take the app down or block dictation.
            // Starting empty costs the user their learned pairs, which is bad;
            // crashing on launch is worse.
            Self.log.error("learned terms could not be read; starting empty")
            return
        }
        ledger = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    /// What the matcher should apply before anything else.
    func aliases(on day: Correction.Day = LearnedTerms.today()) -> [String: String] {
        load()
        return ledger.aliases(at: day)
    }

    /// Everything trusted, for the vocabulary the phonetic passes draw on.
    func terms(on day: Correction.Day = LearnedTerms.today()) -> [String] {
        load()
        return ledger.trusted(at: day)
    }

    /// What the second ear taught: exact substitutions for words the engine
    /// doubted. Two hearings before anything fires; the matcher adds the
    /// confidence gate and the everyday-words shield on top.
    func earCorrections(on day: Correction.Day = LearnedTerms.today()) -> [String: String] {
        load()
        return ledger.earCorrections(at: day)
    }

    /// A lesson from a hearing the swap could not (or did not need to)
    /// deliver: the pair only, never the sentence it was in.
    func recordHeardByEar(_ pair: Correction.Pair) {
        load()
        ledger.record(pair, at: Self.today(), heardIsWord: true, source: .ear)
        save()
        Self.log.info("ear taught a pair (\(pair.heard.count, privacy: .public) -> \(pair.meant.count, privacy: .public) chars)")
    }

    /// `heardIsWord`: whether the misheard token is an ordinary dictionary
    /// word, which decides whether the exact rewrite is trusted from the first
    /// sighting or the second (`Correction.Ledger.sightingsBeforeAliasing`).
    func record(_ pair: Correction.Pair, heardIsWord: Bool, on day: Correction.Day = LearnedTerms.today()) {
        load()
        ledger.record(pair, at: day, heardIsWord: heardIsWord)
        save()
        // Lengths, never content. The pair IS the user's words.
        Self.log.info(
            """
            learned a correction: \(pair.heard.count, privacy: .public) chars -> \
            \(pair.meant.count, privacy: .public), heard is \(heardIsWord ? "a word" : "not a word", privacy: .public)
            """)
    }

    func forget(_ pair: Correction.Pair) {
        load()
        ledger.forget(pair)
        save()
    }

    /// For the settings screen that has to exist before anyone can trust this.
    func everything() -> [(pair: Correction.Pair, sightings: Int, lastSeen: Correction.Day)] {
        load()
        return ledger.all
    }
}
