import Foundation

/// Learning the user's vocabulary by watching what they fix.
///
/// **This is the moat, and Part 0 §0.15 says nobody has published a solution
/// to the problem at the heart of it:** separating "the engine was wrong" edits
/// from "I changed my mind" edits. The nearest transferable idea is token-delta
/// classification, and the disfluency literature warns the revision class is
/// intrinsically hard (BERT F1 43-66%, Romana et al., Interspeech 2022).
///
/// **The one signal that separates them is SOUND.** `Chalan` becoming
/// `Chalant` is a correction: they sound alike, so the engine plausibly
/// misheard. `Tuesday` becoming `Wednesday` is a revision: nobody mishears one
/// as the other, so the speaker simply changed their mind. Everything here is
/// built on that single distinction, and everything else is a refusal.
///
/// **It would rather learn nothing than learn a lie**, because a learned lie is
/// not one bad utterance, it is every future utterance containing that word.
/// Hence: one changed word only, sounding close, comparable in length, no
/// numbers, no function words, and seen twice before it may act.
///
/// Every competitor makes the user type these by hand. Each hand-typed alias is
/// a mistake they already suffered, noticed, diagnosed, and then went into
/// settings to record. Same data structure, entirely different product.
public enum Correction {

    /// What the engine wrote, and what the user replaced it with.
    public struct Pair: Sendable, Hashable {
        public let heard: String
        public let meant: String

        public init(heard: String, meant: String) {
            self.heard = heard
            self.meant = meant
        }
    }

    /// Whole days since an arbitrary epoch.
    ///
    /// Part 2 §3 exists for exactly this: recency decay must be deterministic
    /// in tests, so Core never calls `Date()` and the caller supplies the day.
    public struct Day: Sendable, Hashable, Comparable {
        public let day: Int
        public init(day: Int) { self.day = day }
        public static func < (a: Day, b: Day) -> Bool { a.day < b.day }
    }

    /// How alike two words must sound before an edit counts as a mishearing
    /// rather than a change of mind.
    ///
    /// Looser than `TermMatcher.provisionalFloor` on purpose: there the machine
    /// is deciding to overwrite a word on its own, here the user has already
    /// typed the answer, so the evidence is far stronger and the bar can be
    /// lower without the risk being higher.
    public static let soundFloor = 0.75

    /// A pair must be seen this many times before it may change anything. One
    /// sighting can be a typo, a slip, or an edit made for reasons that have
    /// nothing to do with what was said.
    public static let sightingsBeforeTrust = 2

    /// **Names in one shot (2026-08-16).** A name is misheard differently
    /// every time (Chalant arrived as Shalan, Chalawant and Chalant inside five
    /// minutes; Kizu as Kizu, Pisu and Kisu), so "the same pair twice" almost
    /// never happens for exactly the words the learner exists for. A word the
    /// user typed with a capital letter, which is what a name looks like, is
    /// trusted the first time. An ordinary lowercase word still needs
    /// `sightingsBeforeTrust`, because "effect" typed over "affect" once can be
    /// a slip, and learning it would rewrite ordinary English.
    public static func sightingsBeforeTrusting(_ pair: Pair) -> Int {
        pair.meant.first?.isUppercase == true ? 1 : sightingsBeforeTrust
    }

    /// The exact alias is stricter than the vocabulary term, because it
    /// rewrites blind: no sound check, no confidence check, every time. Met on
    /// the first live run (2026-08-16): "challenge" heard for Chalant, and a
    /// one-shot alias would have rewritten every ordinary "challenge" into
    /// "Chalant" forever. So a name misheard as a REAL WORD still needs two
    /// sightings before the exact rewrite; a name misheard as a non-word
    /// ("Kisu", "Shalan", "Kiesel") is rewritten from the first, because
    /// nothing else was ever going to be meant by it.
    static func sightingsBeforeAliasing(_ pair: Pair, heardIsWord: Bool) -> Int {
        heardIsWord ? sightingsBeforeTrust : sightingsBeforeTrusting(pair)
    }

    /// The ear's standing bar: two hearings of the same pair before a
    /// correction may fire. A model hearing a model is weaker evidence than a
    /// person typing over our word, so nothing it says is trusted blind.
    public static let earSightingsBeforeTrust = 2

    /// **One hearing is enough when the engine wrote gibberish and the ear
    /// wrote English (2026-09-04).** Measured over the founder's own week: the
    /// ear disagreed with the landed text 79 times and was allowed to change
    /// it 21 times, so 57 correct hearings were computed and thrown away, and
    /// the two-sighting bar meant most of them taught nothing either, because
    /// a name is misheard differently every time ("Journalagada", "Journal
    /// Agadda", "Jonalagadda" inside one minute). The same reasoning
    /// `sightingsBeforeAliasing` already applies to the user's own edits
    /// applies here, and it is the pair's SHAPE that carries it rather than
    /// the ear's authority: when the word we wrote is not a word at all and
    /// the word the ear heard is, nothing else was ever going to be meant by
    /// it. Both facts come from the shell's spell checker; Core only
    /// remembers them.
    ///
    /// Everything else keeps the two-hearing bar, and that is the important
    /// half. Real word to real word ("career" for "carrier") is exactly where
    /// a model hearing a model goes wrong, and a non-word heard as another
    /// non-word ("Abit" for "O'PIT", live on 2026-09-04) is two engines
    /// failing together rather than one correcting the other.
    public static func earSightingsBeforeTrusting(heardIsWord: Bool, meantIsWord: Bool) -> Int {
        (!heardIsWord && meantIsWord) ? 1 : earSightingsBeforeTrust
    }

    /// Part 3 M5. A term from a project that ended stops competing for the 100
    /// active slots §0.13 allows.
    public static let trustLifetimeInDays = 90

    // MARK: - Reading one edit

    /// Compare what was inserted against what the field says now.
    ///
    /// The field holds the user's whole document, so the inserted span has to
    /// be found inside it first. Words are compared bare, so punctuation the
    /// user never touched is not mistaken for an edit, but CASE-SENSITIVELY,
    /// because `posthog` becoming `PostHog` is exactly the kind of fix worth
    /// learning.
    /// The single-pair door, kept for callers that want one answer: the first
    /// of `learnings`.
    public static func learning(inserted: String, nowReads field: String) -> Pair? {
        learnings(inserted: inserted, nowReads: field).first
    }

    /// Every correction the user made to our span, each judged on its own.
    ///
    /// **Was "exactly one word changed, or nothing" until 2026-08-16.** The
    /// founder's first live try in Chrome came out "Send the Chalawant bill to
    /// Pisu and tell it and it is ready", three words wrong, and a person fixes
    /// all three in one pass. Refusing that sentence outright refuses exactly
    /// the sentences the learner exists for. So: slide our span across their
    /// document, take the alignment with the fewest changed words, and put
    /// each changed word through the same guards as before. The ones that
    /// sound like what they replaced are corrections; the rest is the user
    /// editing and is ignored. Changing more than a few words is a rewrite,
    /// and a rewrite teaches nothing.
    public static func learnings(inserted: String, nowReads field: String) -> [Pair] {
        let ours = words(inserted)
        let theirs = words(field)
        guard !ours.isEmpty, theirs.count >= ours.count else { return [] }

        var best: (differences: Int, start: Int)?
        for start in 0...(theirs.count - ours.count) {
            var differences = 0
            for offset in 0..<ours.count where ours[offset] != theirs[start + offset] {
                differences += 1
                if differences > maxCorrectionsPerSpan { break }
            }
            if differences == 0 { return [] }  // untouched: nothing to learn
            if differences < (best?.differences ?? Int.max) {
                best = (differences, start)
            }
        }

        guard let best, best.differences <= maxCorrectionsPerSpan else { return [] }

        var pairs: [Pair] = []
        for offset in 0..<ours.count where ours[offset] != theirs[best.start + offset] {
            if let pair = pair(heard: ours[offset], meant: theirs[best.start + offset]) {
                pairs.append(pair)
            }
        }
        return pairs
    }

    /// The same reading, for what the SECOND EAR heard rather than what the
    /// user typed, and it drops one class the user's own edits keep: a pair
    /// that differs only in capitalisation.
    ///
    /// **Why the ear needs its own door (2026-09-04).** `pair` deliberately
    /// lets a pure change of casing through, because `posthog` becoming
    /// `PostHog` under a person's hands is exactly the fix worth learning. The
    /// two ears capitalise differently on every utterance, so through the ear
    /// the same rule taught "yeah" to "Yeah", "one" to "One", "how" to "How"
    /// and "tame" to "Tame", and that last one reached two sightings and
    /// became live: the ledger on the founder's Mac was mostly this noise, and
    /// lowering the bar to one hearing would have poured it in faster.
    /// Capitalisation is the deterministic chain's job and nobody has to learn
    /// it.
    public static func earLearnings(inserted: String, nowReads field: String) -> [Pair] {
        learnings(inserted: inserted, nowReads: field)
            .filter { $0.heard.lowercased() != $0.meant.lowercased() }
    }

    /// More changed words than this is a rewrite, not a set of fixes.
    private static let maxCorrectionsPerSpan = 3

    /// The guards, in the order they are cheapest to check.
    private static func pair(heard: String, meant: String) -> Pair? {
        guard !heard.isEmpty, !meant.isEmpty, heard != meant else { return nil }

        // A changed number belongs to the fidelity guard, never here. A learned
        // pair that rewrites digits is the most dangerous thing this subsystem
        // could produce.
        guard !heard.contains(where: \.isNumber), !meant.contains(where: \.isNumber) else {
            return nil
        }

        // Function words in either direction. "on" becoming "in" is the user
        // writing; learning it would corrupt every sentence after.
        guard !TermMatcher.stopwords.contains(heard.lowercased()),
            !TermMatcher.stopwords.contains(meant.lowercased())
        else { return nil }

        // Today's lesson, applied here too: `review` and `ravi` are
        // phonetically IDENTICAL, so sound alone would accept that swap and
        // teach Chalant to rewrite a common English word into a name forever.
        guard TermMatcher.withinLength(heard, meant) else { return nil }

        // The distinction the whole type rests on. A pure change of casing
        // sails through, which is correct: it sounds identical because it IS
        // the same word, spelled the way the user wants it spelled.
        guard PhoneticKey.similarity(heard, meant) >= soundFloor else { return nil }

        return Pair(heard: heard, meant: meant)
    }

    /// Words, stripped of the punctuation around them but not of their case.
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { token in
                String(token.drop(while: { !$0.isLetter && !$0.isNumber })
                    .reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Remembering across edits

    /// What has been seen, how often, and how recently.
    ///
    /// A value type on purpose: Part 2 §4 keeps Core stateless and `Sendable`,
    /// so persistence is the shell's problem and this stays testable without a
    /// database.
    ///
    /// **`Codable` deliberately, over Part 2 §1's GRDB.** That decision was
    /// taken for `utterances`, which is append-only telemetry that grows without
    /// bound. This is a few hundred pairs read once at launch and written when
    /// one changes, and adding a dependency for it would need an
    /// `ARCHITECTURE.md` entry justifying a database to hold a dictionary.
    /// Revisit when the term store grows past what fits comfortably in memory.
    public struct Ledger: Sendable, Equatable, Codable {
        private struct Record: Sendable, Equatable {
            var sightings: Int
            var lastSeen: Day
            /// Whether the misheard word is an ordinary dictionary word. The
            /// shell decides (it has the spell checker; Core has no
            /// dictionary); Core only remembers. Missing in files written before
            /// 2026-08-16 and read back as true, the careful answer.
            var heardIsWord: Bool
            /// Times the SECOND EAR heard this pair (2026-08-28): the swap it
            /// could not make became a lesson instead. Counted apart from the
            /// user's own sightings, because a model hearing a model is
            /// weaker evidence than a person typing over our word.
            var earSightings: Int = 0
            /// Whether the word the correction puts IN is an ordinary
            /// dictionary word, decided by the shell the same way
            /// `heardIsWord` is. Only the ear reads it, to tell "the engine
            /// wrote gibberish and the ear wrote English" from two engines
            /// failing together. Missing in files written before 2026-09-04
            /// and read back as false, which holds every pair already on disk
            /// at the two-hearing bar: the careful answer.
            var meantIsWord: Bool = false
        }

        /// A dictionary keyed by a struct cannot be JSON, so the wire form is a
        /// list. Written out explicitly rather than left to a synthesised
        /// conformance, because the file outlives the type and a silent shape
        /// change would lose everything the user taught it.
        private struct Entry: Codable {
            var heard: String
            var meant: String
            var sightings: Int
            var lastSeen: Int
            var heardIsWord: Bool?
            /// Missing in files written before 2026-08-28, read back as zero.
            var earSightings: Int?
            /// Missing in files written before 2026-09-04, read back as false.
            var meantIsWord: Bool?
        }

        private enum CodingKeys: String, CodingKey {
            case entries
            case forgotten
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
            for entry in entries {
                records[Pair(heard: entry.heard, meant: entry.meant)] =
                    Record(
                        sightings: entry.sightings, lastSeen: Day(day: entry.lastSeen),
                        heardIsWord: entry.heardIsWord ?? true,
                        earSightings: entry.earSightings ?? 0,
                        meantIsWord: entry.meantIsWord ?? false)
            }
            let gone = try container.decodeIfPresent([Entry].self, forKey: .forgotten) ?? []
            forgotten = Set(gone.map { Pair(heard: $0.heard, meant: $0.meant) })
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                records.map {
                    Entry(
                        heard: $0.key.heard, meant: $0.key.meant,
                        sightings: $0.value.sightings, lastSeen: $0.value.lastSeen.day,
                        heardIsWord: $0.value.heardIsWord,
                        earSightings: $0.value.earSightings,
                        meantIsWord: $0.value.meantIsWord)
                }.sorted { $0.heard < $1.heard },
                forKey: .entries)
            try container.encode(
                forgotten.map { Entry(heard: $0.heard, meant: $0.meant, sightings: 0, lastSeen: 0, heardIsWord: nil) }
                    .sorted { $0.heard < $1.heard },
                forKey: .forgotten)
        }

        private var records: [Pair: Record] = [:]

        /// **Pairs the user deleted, remembered forever.** Part 0 §0.15
        /// requires every learned pair to be inspectable and reversible, and a
        /// deletion that quietly undoes itself the next time the user makes the
        /// same edit is not reversible, it is a nag. Deleting is a decision,
        /// so it outranks any amount of later evidence.
        private var forgotten: Set<Pair> = []

        public init() {}

        /// `heardIsWord`: whether the misheard token is an ordinary dictionary
        /// word, decided by the shell's spell checker. Defaults to the careful
        /// answer. It gates only the exact alias (see `aliases`), never the
        /// vocabulary term.
        /// Who saw the pair: the user's own typed correction, or the
        /// second ear hearing the audio again. The counters stay apart.
        public enum Source: Sendable {
            case user
            case ear
        }

        public mutating func record(
            _ pair: Pair, at day: Day, heardIsWord: Bool = true, meantIsWord: Bool = false,
            source: Source = .user
        ) {
            guard !forgotten.contains(pair) else { return }
            let existing = records[pair]
            records[pair] = Record(
                sightings: (existing?.sightings ?? 0) + (source == .user ? 1 : 0),
                lastSeen: day,
                // Once known to be a real word, always treated as one.
                heardIsWord: (existing?.heardIsWord ?? false) || heardIsWord,
                earSightings: (existing?.earSightings ?? 0) + (source == .ear ? 1 : 0),
                // Ratcheted the same way, and for the same reason: the two
                // calls that see this pair may not both have asked the spell
                // checker, and a yes is the answer that was actually measured.
                meantIsWord: (existing?.meantIsWord ?? false) || meantIsWord)
        }

        /// What the ear taught, as exact confidence-gated substitutions:
        /// heard (lowercased) to meant. Two ear sightings, or one where the
        /// engine wrote a non-word and the ear wrote a real one, per
        /// `earSightingsBeforeTrusting`. Never an alias: aliases rewrite
        /// blind, and only a person earns that. Applied by
        /// `TermMatcher.applyingEarCorrections`, which adds the engine's
        /// own doubt and the everyday-words shield on top.
        public func earCorrections(at day: Day) -> [String: String] {
            var out: [String: String] = [:]
            let qualified = records
                .filter { _, record in
                    record.earSightings
                        >= earSightingsBeforeTrusting(
                            heardIsWord: record.heardIsWord, meantIsWord: record.meantIsWord)
                        && day.day - record.lastSeen.day < trustLifetimeInDays
                }
                .sorted { a, b in
                    if a.value.lastSeen != b.value.lastSeen { return a.value.lastSeen > b.value.lastSeen }
                    return a.key.meant < b.key.meant
                }
                .prefix(Vocabulary.activeLimit)
            for (pair, _) in qualified {
                out[pair.heard.lowercased()] = pair.meant
            }
            return out
        }

        public mutating func forget(_ pair: Pair) {
            records[pair] = nil
            forgotten.insert(pair)
        }

        /// Everything seen enough times, recently enough, capped.
        ///
        /// §0.13 is a locked constant rather than an API limit: biasing gains
        /// peak near 100 terms and degrade beyond, with a documented case of
        /// overall WER going 2.42 to 5.99 when a list grew 100 to 500. The
        /// ledger may REMEMBER more than this; it may not OFFER more.
        public func trusted(at day: Day) -> [String] {
            records
                .filter { pair, record in
                    record.sightings >= sightingsBeforeTrusting(pair)
                        && day.day - record.lastSeen.day < trustLifetimeInDays
                }
                // Deterministic: most recent first, then most seen, then
                // alphabetical, so the cap never depends on dictionary order.
                .sorted { a, b in
                    if a.value.lastSeen != b.value.lastSeen { return a.value.lastSeen > b.value.lastSeen }
                    if a.value.sightings != b.value.sightings { return a.value.sightings > b.value.sightings }
                    return a.key.meant < b.key.meant
                }
                .prefix(Vocabulary.activeLimit)
                .map(\.key.meant)
        }

        /// The learned mishearings, as exact replacements.
        ///
        /// **This is the important half, and an end-to-end test is what
        /// revealed it.** `trusted` hands the matcher a vocabulary, and the
        /// matcher then has to rediscover phonetically what the user already
        /// told it explicitly. It cannot: `Chalan` and `Chalant` sit below the
        /// 0.90 similarity floor that the 2026-08-15 sweep set to keep the
        /// matcher from corrupting ordinary words. So the learner would learn
        /// the pair and the matcher would refuse to use it, and the loop that
        /// is the entire product would quietly do nothing.
        ///
        /// A pair the user typed themselves, twice, is not a guess that needs
        /// phonetic verification. It is a fact about their vocabulary. It gets
        /// applied by exact match, and `TermMatcher.applyingAliases` does not
        /// consult confidence at all, because proper-noun errors are CONFIDENT
        /// errors: `Chalan` arrived at 0.87.
        public func aliases(at day: Day) -> [String: String] {
            var out: [String: String] = [:]
            for (pair, record) in records
            where record.sightings >= sightingsBeforeAliasing(pair, heardIsWord: record.heardIsWord)
                && day.day - record.lastSeen.day < trustLifetimeInDays {
                out[pair.heard.lowercased()] = pair.meant
            }
            return out
        }

        /// Everything remembered, for the settings screen that has to exist
        /// before this can be trusted by anyone.
        public var all: [(pair: Pair, sightings: Int, lastSeen: Day)] {
            records
                .map { (pair: $0.key, sightings: $0.value.sightings, lastSeen: $0.value.lastSeen) }
                .sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    /// §0.13's cap, named here so Core does not depend on the app shell.
    public enum Vocabulary {
        public static let activeLimit = 100
    }
}
