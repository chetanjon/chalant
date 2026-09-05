import Foundation

/// Two ears heard the same sentence. This decides, word by word, which one was
/// right.
///
/// **Why this exists (measured 2026-09-04, the founder's own week).** The
/// second ear disagreed with the words that landed 79 times and was allowed to
/// change them 21 times: 36 fixes were refused because the app they were
/// dictating into has no safe undo, and 21 more arrived after they had already
/// typed. So the app computed the right words on most of those rows, at a cost
/// of one to three seconds, and then threw them away. The corrections it lost
/// were not subtle ("a recruiter" landed as "agriculture", "option button" as
/// "auction button", "commas" as "commerce"), and one of them reversed the
/// meaning of the sentence: "I don't want the box" landed as "I want the box".
///
/// The fix is to decide BEFORE the words land, which means the two hearings
/// have to be reconciled rather than one of them replacing the other. That is
/// what this type does, and it is deliberately the only new idea in the change:
/// everything downstream (the deterministic chain, the vocabulary passes, the
/// insertion ladder) runs exactly as it does today, on the merged text.
///
/// **It is an adjudication between two engines, not a similarity repair, and
/// that distinction decides which guards apply.** `TermMatcher`'s shields
/// (`EverydayWords`, the system dictionary) exist to stop a NAME being
/// substituted into an ordinary word on phonetic resemblance alone; they are
/// right there and wrong here, because the corrections this recovers are
/// overwhelmingly ordinary word for ordinary word ("commerce" to "commas") and
/// a shield would refuse every one of them. The existing post-landing swap
/// path already works this way: no shields, only plausibility. What replaces
/// them is evidence: what the engine itself said about its confidence, what
/// the other engine said about its own, whether either side produced a word at
/// all, and whether the user has taught us the word in question.
///
/// **Nothing here decides anything on its own taste.** The rules that carry
/// real risk are expressed as named policies with tunable constants so the
/// choice between them is made by sweeping recorded audio (`tools/mergeprobe`)
/// rather than by argument. The rules that are NOT tunable are the refusals,
/// and they are the reason this is safe to put in front of the user's words.
public enum HearingMerge {

    // MARK: - What the caller supplies

    /// What the second ear says about its own hearing.
    ///
    /// Part 0 §0.18: the whisper.cpp community converged on exactly these three
    /// numbers as the guard against fabricated text on near-silence, and the
    /// failure class belongs to any decoder rather than to one model. The
    /// second ear has always returned them and the app has always discarded
    /// them; here they are the difference between a better hearing and an
    /// invention.
    public struct Quality: Sendable, Hashable {
        public var averageLogProbability: Double?
        public var noSpeechProbability: Double?
        public var compressionRatio: Double?

        public init(
            averageLogProbability: Double? = nil, noSpeechProbability: Double? = nil,
            compressionRatio: Double? = nil
        ) {
            self.averageLogProbability = averageLogProbability
            self.noSpeechProbability = noSpeechProbability
            self.compressionRatio = compressionRatio
        }
    }

    /// The evidence Core cannot gather for itself.
    ///
    /// `knownWords` is the shell's spell checker asked about every word in
    /// dispute, on BOTH sides. Core has no dictionary (Part 2 §2), and the
    /// answer is load-bearing in both directions here: a non-word on the ear's
    /// side is an invention, and a non-word on the engine's side is the single
    /// strongest sign that the ear is right.
    public struct Signals: Sendable {
        public var knownWords: Set<String>
        /// Everything the user has taught or typed: `dictationTerms`, the
        /// learned ledger, contact names. Lowercased by the initialiser.
        public var vocabulary: Set<String>
        public var quality: Quality

        public init(
            knownWords: Set<String> = [], vocabulary: [String] = [], quality: Quality = .init()
        ) {
            self.knownWords = Set(knownWords.map { $0.lowercased() })
            self.vocabulary = Set(vocabulary.map { $0.lowercased() })
            self.quality = quality
        }

        func isWord(_ word: String) -> Bool {
            let bare = HearingMerge.bare(word)
            guard !bare.isEmpty else { return true }
            return knownWords.contains(bare) || vocabulary.contains(bare)
        }

        func isTaught(_ word: String) -> Bool {
            vocabulary.contains(HearingMerge.bare(word))
        }
    }

    /// The three candidate readings of the same evidence.
    ///
    /// They differ only in what they do with a dispute that every refusal has
    /// already allowed through, which is the one question the data has to
    /// answer rather than the author.
    public enum Policy: String, Sendable, CaseIterable {
        /// The ear leads: it is the better model (7.1% against 12.8% word
        /// error on the names set), so it wins a surviving dispute unless the
        /// engine was confident.
        case earLeads
        /// The engine leads: the ear wins only where the engine already
        /// doubted itself, which is the bar `TermMatcher` applies to a taught
        /// correction.
        case engineLeads
        /// The engine leads on ordinary words and the ear leads wherever the
        /// engine's own spelling is suspect.
        case hybrid
    }

    /// Everything with a number in it, so the sweep can move it.
    public struct Constants: Sendable, Hashable {
        /// Above this, the engine is taken at its word under `earLeads`.
        /// Measured on the 2026-08-15 corpus: words the engine got wrong
        /// averaged 0.757 confidence, words it got right averaged 0.909.
        public var engineSureFloor: Double = 0.85
        /// Below this the engine has doubted itself. Shared with
        /// `TermMatcher.confidenceFloor` on purpose.
        public var engineDoubtFloor: Double = 0.6
        /// A dispute wider than this is not a mishearing, it is two different
        /// sentences, and the safe reading of two different sentences is the
        /// one the user has already been shown nothing of.
        public var maximumSpanWords: Int = 4
        /// The ear may add this many words at once and no more.
        public var maximumInsertionWords: Int = 2
        public var allowsNegationInsertion: Bool = true
        /// A substitution that changes the sentence's negation count needs the
        /// engine to have doubted itself this badly first.
        public var negationConfidenceFloor: Double = 0.5
        /// Digits belong to the fidelity guard's world: a corrupted number is
        /// the worst thing either engine can produce, so by default the engine
        /// keeps them.
        public var digitsStayWithEngine: Bool = true
        /// Above this fraction of words in dispute, the two hearings are not
        /// the same sentence and nothing is merged.
        public var disputeCeiling: Double = 0.5
        public var noSpeechCeiling: Double = 0.6
        public var logProbabilityFloor: Double = -1.0
        public var compressionCeiling: Double = 2.4

        public init() {}
    }

    // MARK: - What it produces

    public struct Span: Sendable, Hashable {
        public enum Kind: String, Sendable {
            case agreed
            /// Both ears said something, and they said different things.
            case substitution
            /// Only the ear said it.
            case insertion
            /// Only the engine said it.
            case deletion
        }

        public var kind: Kind
        public var engine: [Token]
        public var ear: [String]
        public var choseEar: Bool
        /// Why, named. Every decision is reviewable in the row.
        public var reason: String
    }

    /// Named so a row can say what happened without holding the words.
    public enum Verdict: String, Sendable {
        case merged
        case agreed
        case earEmpty
        case implausible
        case qualityRejected
        case tooMuchDisagreement
    }

    public struct Outcome: Sendable {
        public var tokens: [Token]
        public var spans: [Span]
        public var verdict: Verdict
        public var disputedSpans: Int
        public var mergedSpans: Int
        public var negationChanges: Int

        public var changedAnything: Bool { mergedSpans > 0 }
    }

    // MARK: - The whole-hearing refusals

    /// Whether a hearing is plausibly the same utterance the engine heard.
    ///
    /// The same half-to-double bar the post-landing swap has used since
    /// 2026-08-17, restated here so Core can apply it and a test can pin it.
    /// The second ear on a starved microphone invents whole sentences
    /// ("Baddie wannabe.", measured), and an invention is usually the wrong
    /// length before it is anything else.
    public static func plausible(ear: String, against engine: String) -> Bool {
        let a = ear.count, b = engine.count
        guard a > 0, b > 0 else { return false }
        return a * 2 >= b && a <= b * 2
    }

    static func qualityRefusal(_ quality: Quality, _ constants: Constants) -> Bool {
        if let silence = quality.noSpeechProbability, silence > constants.noSpeechCeiling {
            return true
        }
        if let logProbability = quality.averageLogProbability,
            logProbability < constants.logProbabilityFloor
        {
            return true
        }
        if let compression = quality.compressionRatio, compression > constants.compressionCeiling {
            return true
        }
        return false
    }

    // MARK: - The merge

    public static func merge(
        engine: [Token], ear: String, signals: Signals = .init(),
        policy: Policy = .earLeads, constants: Constants = .init()
    ) -> Outcome {
        let engineText = engine.map(\.text).joined(separator: " ")
        let earWords = words(ear)

        func keepEverything(_ verdict: Verdict) -> Outcome {
            Outcome(
                tokens: engine, spans: [], verdict: verdict, disputedSpans: 0, mergedSpans: 0,
                negationChanges: 0)
        }

        guard !engine.isEmpty else { return keepEverything(.earEmpty) }
        guard !earWords.isEmpty else { return keepEverything(.earEmpty) }
        guard plausible(ear: ear, against: engineText) else { return keepEverything(.implausible) }
        guard !qualityRefusal(signals.quality, constants) else {
            return keepEverything(.qualityRejected)
        }

        var spans = align(engine: engine, ear: earWords)

        let disputedWords = spans.filter { $0.kind != .agreed }.reduce(0) {
            $0 + max($1.engine.count, $1.ear.count)
        }
        let widest = max(engine.count, earWords.count)
        if widest > 0, Double(disputedWords) / Double(widest) > constants.disputeCeiling {
            return keepEverything(.tooMuchDisagreement)
        }

        let engineNegations = negationCount(engine.map(\.text))
        var merged: [Token] = []
        var mergedSpans = 0

        for index in spans.indices {
            let span = spans[index]
            switch span.kind {
            case .agreed:
                merged.append(contentsOf: span.engine)
            case .deletion:
                // The ear's silence is never evidence. Part 1 §2: nothing this
                // subsystem does may lose a word the user said.
                spans[index].reason = "theEngineHeardMore"
                merged.append(contentsOf: span.engine)
            case .insertion:
                let verdict = judgeInsertion(span, signals: signals, constants: constants)
                spans[index].choseEar = verdict.take
                spans[index].reason = verdict.reason
                if verdict.take {
                    mergedSpans += 1
                    merged.append(contentsOf: span.ear.map { Token(text: $0, confidence: nil) })
                }
            case .substitution:
                let verdict = judgeSubstitution(
                    span, signals: signals, policy: policy, constants: constants)
                spans[index].choseEar = verdict.take
                spans[index].reason = verdict.reason
                if verdict.take {
                    mergedSpans += 1
                    merged.append(
                        contentsOf: rewrite(
                            span, opensASentence: opensASentence(merged, whole: index == 0),
                            signals: signals))
                } else {
                    merged.append(contentsOf: span.engine)
                }
            }
        }

        // The last refusal, taken over the finished sentence rather than one
        // span: a merge may not change how many negations the user said unless
        // an insertion rule that names itself did it deliberately.
        let mergedNegations = negationCount(merged.map(\.text))
        let deliberate = spans.contains { $0.kind == .insertion && $0.choseEar }
        if mergedNegations != engineNegations, !deliberate {
            return keepEverything(.tooMuchDisagreement)
        }

        let disputed = spans.filter { $0.kind != .agreed }.count
        return Outcome(
            tokens: mergedSpans > 0 ? merged : engine,
            spans: spans,
            verdict: mergedSpans > 0 ? .merged : .agreed,
            disputedSpans: disputed,
            mergedSpans: mergedSpans,
            negationChanges: abs(mergedNegations - engineNegations))
    }

    // MARK: - One dispute at a time

    private struct Judgement {
        var take: Bool
        var reason: String
    }

    private static func judgeSubstitution(
        _ span: Span, signals: Signals, policy: Policy, constants: Constants
    ) -> Judgement {
        let engineWords = span.engine.map(\.text)

        // 1. Numbers. A changed digit is the most dangerous edit either engine
        //    can make, and neither of them is trustworthy about it: the
        //    2026-08-15 baseline has the engine turning "9:30 to 10:15" into
        //    "93, 932, 1015", and no reading of that is worth risking a
        //    correct amount of money.
        if constants.digitsStayWithEngine,
            (engineWords + span.ear).contains(where: { $0.contains(where: \.isNumber) })
        {
            return Judgement(take: false, reason: "digitsStayWithEngine")
        }

        // 2. Width. Past a few words this is not one misheard word, it is two
        //    engines telling different stories.
        if max(span.engine.count, span.ear.count) > constants.maximumSpanWords {
            return Judgement(take: false, reason: "disputeTooWide")
        }

        // 3. The ear invented a word. "strongly agree" came back as
        //    "strong-legry" on 2026-09-02, and no confidence number should be
        //    able to let that through.
        if let invented = span.ear.first(where: { !signals.isWord($0) }), !invented.isEmpty {
            return Judgement(take: false, reason: "theEarInventedAWord")
        }

        // 4. Negations, before any policy gets a say. A substitution that
        //    changes whether the sentence is a denial needs the engine to have
        //    doubted itself badly.
        if negationCount(engineWords) != negationCount(span.ear),
            minimumConfidence(span.engine) ?? 1 >= constants.negationConfidenceFloor
        {
            return Judgement(take: false, reason: "wouldChangeANegation")
        }

        // 5. The user's own vocabulary outranks both engines and every
        //    confidence number, in whichever direction it points.
        //
        //    The engine's side first, and this is the 2026-08-16 lesson
        //    restated: the engine writing a word the user taught us is the
        //    engine being right, and if the ear could win that dispute then
        //    "Chalant" would come back as "challenge" whenever the microphone
        //    was unkind. A taught word is not a candidate for correction.
        if engineWords.contains(where: { signals.isTaught($0) }) {
            return Judgement(take: false, reason: "theUserTaughtTheEngineWord")
        }
        if span.ear.contains(where: { signals.isTaught($0) }) {
            return Judgement(take: true, reason: "theUserTaughtThisWord")
        }

        // 6. The engine wrote something that is not a word and the ear wrote
        //    English. This is the strongest evidence in the whole type and it
        //    outranks confidence, because the engine is regularly confident
        //    about gibberish: "ergonomics" landed as "agronics", ".md file" as
        //    "dotem defile", the founder's own surname as "Journalagada".
        //    Guarded by the vocabulary, so a name the user taught us is never
        //    "gibberish" to be corrected away ("Chalant" into "challenge").
        if engineWords.contains(where: { !signals.isWord($0) && !signals.isTaught($0) }) {
            return Judgement(take: true, reason: "theEngineWroteANonWord")
        }

        // 7. Everything that survives is a real word against a real word, and
        //    which one to believe is the question the sweep answers.
        let doubt = minimumConfidence(span.engine)
        switch policy {
        case .earLeads:
            if let doubt, doubt >= constants.engineSureFloor {
                return Judgement(take: false, reason: "theEngineWasSure")
            }
            return Judgement(take: true, reason: "theEarLeads")
        case .engineLeads:
            if let doubt, doubt < constants.engineDoubtFloor {
                return Judgement(take: true, reason: "theEngineDoubtedItself")
            }
            return Judgement(take: false, reason: "theEngineLeads")
        case .hybrid:
            // The engine leads, except where its own spelling is suspect: a
            // capitalised word mid-sentence is how a contact name eats an
            // ordinary one, and that is the engine at its least reliable.
            if let doubt, doubt < constants.engineDoubtFloor {
                return Judgement(take: true, reason: "theEngineDoubtedItself")
            }
            if engineWords.dropFirst().contains(where: { $0.first?.isUppercase == true }) {
                return Judgement(take: true, reason: "theEngineWroteAStrayName")
            }
            return Judgement(take: false, reason: "theEngineLeads")
        }
    }

    private static func judgeInsertion(
        _ span: Span, signals: Signals, constants: Constants
    ) -> Judgement {
        guard span.ear.count <= constants.maximumInsertionWords else {
            return Judgement(take: false, reason: "theEarAddedTooMuch")
        }
        // The one thing the ear may add. On 2026-09-03 the founder said "I
        // don't want the box" and "I want the box" landed: the ear had it
        // right and the fix was thrown away. A dropped negation is the only
        // single-word loss that reverses a sentence, so it is the only
        // single-word gain worth the risk.
        if constants.allowsNegationInsertion, span.ear.allSatisfy(isNegation) {
            return Judgement(take: true, reason: "theEngineDroppedANegation")
        }
        // Everything else the ear adds is dropped. A hearing that adds content
        // is how "Shut up, guys" arrived in a sentence nobody said it in.
        return Judgement(take: false, reason: "theEarAddedWords")
    }

    // MARK: - Rebuilding the sentence

    /// The ear's words, wearing the engine's punctuation.
    ///
    /// The engine owns the shape of the sentence and the ear owns the words
    /// inside it. That split is deliberate: `Breaks`, `Listing` and the rest of
    /// the deterministic chain run after this and are tuned against the
    /// engine's punctuation, and letting a second opinion move the full stops
    /// would change two things at once.
    private static func rewrite(_ span: Span, opensASentence: Bool, signals: Signals) -> [Token] {
        let (leading, _, _) = split(span.engine.first?.text ?? "")
        let (_, _, trailing) = split(span.engine.last?.text ?? "")
        // The ear's own punctuation at the edges of the span goes: the engine
        // owns the shape, and keeping both is how "JP Morgan" became
        // "JPMorgan..". Punctuation BETWEEN the ear's words is inside the span
        // and survives, which is the ear's to give.
        var words = span.ear
        if let first = words.first {
            words[0] = String(first.drop(while: { !$0.isLetter && !$0.isNumber }))
        }
        if var last = words.last {
            while let final = last.last, !final.isLetter, !final.isNumber, final != "'" {
                last = String(last.dropLast())
            }
            words[words.count - 1] = last
        }
        words = words.filter { !$0.isEmpty }
        guard !words.isEmpty else { return span.engine }

        // Case follows the sentence, not the ear. The ear capitalises where it
        // hears a new sentence begin, and dropping its capital into the middle
        // of the engine's sentence reads as a mistake ("right, That is very
        // good"). A name is exempt in both directions: a word the user taught
        // us, or one the dictionary does not know, keeps whatever the ear gave
        // it, which is what saves "Capgemini" from becoming "capgemini".
        let ordinary = !signals.isTaught(words[0]) && signals.isWord(words[0])
        if let initial = words[0].first {
            if opensASentence, initial.isLowercase {
                words[0] = initial.uppercased() + words[0].dropFirst()
            } else if !opensASentence, initial.isUppercase, ordinary,
                span.engine.first?.text.first?.isUppercase != true
            {
                words[0] = initial.lowercased() + words[0].dropFirst()
            }
        }

        return words.enumerated().map { index, word in
            var text = word
            if index == 0 { text = leading + text }
            if index == words.count - 1 { text += trailing }
            return Token(text: text, confidence: nil)
        }
    }

    /// Whether the next word starts a sentence, so a replacement does not
    /// silently lowercase one.
    private static func opensASentence(_ soFar: [Token], whole: Bool) -> Bool {
        if whole || soFar.isEmpty { return true }
        guard let previous = soFar.last?.text.last else { return true }
        return previous == "." || previous == "?" || previous == "!"
    }

    // MARK: - Alignment

    /// Word-level alignment, coalesced into spans.
    ///
    /// **`Correction.learnings` could not be reused for this and it is worth
    /// saying why.** That alignment slides one span across another of equal or
    /// greater length and compares position by position, which cannot express
    /// a word being ADDED or REMOVED. The single most valuable disagreement in
    /// the whole measured week was exactly that shape: the ear heard a "don't"
    /// the engine never wrote.
    static func align(engine: [Token], ear: [String]) -> [Span] {
        let a = engine.map { bare($0.text) }
        let b = ear.map { bare($0) }

        var cost = Array(
            repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { cost[i][0] = i }
        for j in 0...b.count { cost[0][j] = j }
        for i in 1...max(a.count, 1) where a.count > 0 {
            for j in 1...max(b.count, 1) where b.count > 0 {
                cost[i][j] =
                    a[i - 1] == b[j - 1]
                    ? cost[i - 1][j - 1]
                    : 1 + min(cost[i - 1][j - 1], min(cost[i - 1][j], cost[i][j - 1]))
            }
        }

        enum Operation { case match, substitute, deleteFromEngine, insertFromEar }
        var trail: [Operation] = []
        var i = a.count
        var j = b.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                trail.append(.match)
                i -= 1
                j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                trail.append(.substitute)
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                trail.append(.deleteFromEngine)
                i -= 1
            } else {
                trail.append(.insertFromEar)
                j -= 1
            }
        }
        trail.reverse()

        var spans: [Span] = []
        var engineIndex = 0
        var earIndex = 0
        var pendingEngine: [Token] = []
        var pendingEar: [String] = []

        func flushDispute() {
            guard !pendingEngine.isEmpty || !pendingEar.isEmpty else { return }
            let kind: Span.Kind =
                pendingEngine.isEmpty
                ? .insertion : (pendingEar.isEmpty ? .deletion : .substitution)
            spans.append(
                Span(
                    kind: kind, engine: pendingEngine, ear: pendingEar, choseEar: false,
                    reason: ""))
            pendingEngine = []
            pendingEar = []
        }

        for operation in trail {
            switch operation {
            case .match:
                flushDispute()
                if let last = spans.last, last.kind == .agreed {
                    spans[spans.count - 1].engine.append(engine[engineIndex])
                } else {
                    spans.append(
                        Span(
                            kind: .agreed, engine: [engine[engineIndex]], ear: [], choseEar: false,
                            reason: "bothEarsAgreed"))
                }
                engineIndex += 1
                earIndex += 1
            case .substitute:
                pendingEngine.append(engine[engineIndex])
                pendingEar.append(ear[earIndex])
                engineIndex += 1
                earIndex += 1
            case .deleteFromEngine:
                pendingEngine.append(engine[engineIndex])
                engineIndex += 1
            case .insertFromEar:
                pendingEar.append(ear[earIndex])
                earIndex += 1
            }
        }
        flushDispute()
        return spans
    }

    // MARK: - Small shared pieces

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The word itself, lowercased, with the punctuation and the apostrophes
    /// taken off, so "Don't," and "dont" compare equal.
    static func bare(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static func split(_ text: String) -> (String, String, String) {
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" }
        guard let first = text.firstIndex(where: isWord),
            let last = text.lastIndex(where: isWord)
        else { return ("", text, "") }
        return (
            String(text[text.startIndex..<first]),
            String(text[first...last]),
            String(text[text.index(after: last)...])
        )
    }

    private static func minimumConfidence(_ tokens: [Token]) -> Double? {
        tokens.compactMap(\.confidence).min()
    }

    /// The same negation lexicon the fidelity guard counts with, bared the same
    /// way so a capitalised contraction is not invisible.
    static let negationWords: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither",
        "nor", "cannot", "cant", "dont", "doesnt", "didnt", "wont", "wouldnt",
        "shouldnt", "couldnt", "isnt", "arent", "wasnt", "werent", "hasnt",
        "havent", "hadnt", "aint", "without",
    ]

    private static func isNegation(_ word: String) -> Bool {
        negationWords.contains(bare(word))
    }

    private static func negationCount(_ words: [String]) -> Int {
        words.filter(isNegation).count
    }
}
