import Foundation

/// The names both ears are handed for one utterance, chosen by what the first
/// ear heard.
///
/// **A long list of names makes Whisper worse, not better, and it is slow.**
/// Measured on Set E (30 sentences dense with the founder's names, the 626 MB
/// ear, `verification/NAMES_2026-08-18.md`): no names 29.9% word error at
/// 0.91 s; all 34 hand-kept names 18.6% at 2.17 s; the top 12 names 14.7% at
/// 1.42 s; the top 12 plus whatever in an 88-name tail SOUNDS LIKE a word the
/// first ear produced, 10.0% at 1.58 s. Every prompt token costs a decoder
/// step (~13 ms here), and past about twenty names the extra names dilute the
/// ones that matter.
///
/// So the list is built per utterance: whatever sounds like something just
/// heard, best first, from either list, then the standing names (typed by
/// hand, learned from corrections) to fill out the rest, and the whole thing
/// is capped. How many slots the standing names may fill unearned is the
/// caller's to set: the matching pass lets them fill to the cap because a long
/// list costs it nothing, and the second ear's prompt stops at
/// `promptStandingFloor` because every name in it is 0.05 s of the wait before
/// the words land. The same selection at a larger cap is what the
/// phonetic pass draws on, so a Contacts list of a thousand names never has
/// to be cut alphabetically: a name enters either ear only when the utterance
/// gives it a reason to.
///
/// Pure, Foundation only, tested in `NameHintsTests`.
public enum NameHints {

    /// Names in the second ear's prompt. Twenty measured as the knee: 12 and 20
    /// hear alike (14.7%), 34 hears worse (18.6%) and costs 0.75 s more.
    public static let promptLimit = 20

    /// How many sound-alikes the prompt makes room for. Eight, as measured.
    public static let promptCandidateLimit = 8

    /// How short the second ear's prompt is allowed to get.
    ///
    /// The prompt costs about 0.05 s per name and the ear now decodes before
    /// the words land, so the ideal prompt holds only the names this sentence
    /// might actually contain. **It cannot go all the way there, because
    /// Whisper reads the prompt as context and its LENGTH changes the decode
    /// on its own.** Measured 2026-09-13 on `cap-20260819-161321-326`, which
    /// opens "Hey Chalant": with Chalant named and nothing else the model drops
    /// the greeting entirely, at four names it still drops it, at eight it
    /// comes back. Over the 23 name-bearing recordings, a floor of eight keeps
    /// all ten of the names the full prompt rescued (1.37 s median decode
    /// against 1.78 s); with no floor it keeps nine (1.16 s).
    ///
    /// So this is the smallest prompt measured to lose nothing, not a
    /// principle. If the ear or the model changes, re-run `tools/nameprobe`
    /// and the recordings behind it before trusting the number.
    public static let promptStandingFloor = 8

    /// How alike a pool name must sound to a heard word to be offered.
    /// Measured at 0.60 and 0.75 on Set E: identical accuracy, and 0.75 offers
    /// fewer distractors, so it is 0.15 s cheaper.
    public static let similarityFloor = 0.75

    /// Heard words shorter than this are not evidence of a name. "and"
    /// reaches Amanda, Andrew and Ananya at 0.60; nothing that short does.
    public static let minimumProbeLength = 4

    /// The names for one utterance.
    ///
    /// - heard: what the first ear produced, as text.
    /// - always: the standing names, in priority order (typed by hand first,
    ///   then learned). Offered whether or not they sound like anything, but
    ///   only up to `standingFills` slots.
    /// - pool: the wider list (Contacts). Offered only when a name sounds like
    ///   something in `heard`.
    /// - limit: the cap on the whole list.
    /// - candidateLimit: the cap on sound-alikes; they are never the part the
    ///   cap cuts, because they are the part that earns the slot.
    /// - standingFills: how many slots the standing names may take WITHOUT
    ///   sounding like anything in `heard`. `limit` is the old behaviour, and
    ///   is right for the matching pass, which pays nothing for a long list.
    ///   The second ear's prompt pays 0.05 s per name (2026-09-13: 0 names
    ///   0.94 s, 8 names 1.35 s, 16 names 1.76 s over 40 of the founder's own
    ///   recordings) and passes `promptStandingFloor`. A name left out here
    ///   only loses the ear its warning: `forMatching` still holds the whole
    ///   standing list and can repair the word afterwards.
    public static func select(
        heard: String,
        always: [String],
        pool: [String],
        limit: Int = promptLimit,
        candidateLimit: Int = promptCandidateLimit,
        standingFills: Int = promptLimit
    ) -> [String] {
        let probes = probes(from: heard)

        // Score every name once, whichever list it came from, keeping the
        // first spelling seen.
        var scored: [(name: String, similarity: Double, order: Int)] = []
        var seen = Set<String>()
        for (order, name) in (always + pool).enumerated() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            guard !probes.isEmpty else { continue }
            let best = similarity(of: trimmed, toAnyOf: probes)
            if best >= similarityFloor { scored.append((trimmed, best, order)) }
        }
        scored.sort { a, b in
            if a.similarity != b.similarity { return a.similarity > b.similarity }
            return a.order < b.order
        }
        let candidates = scored.prefix(max(0, candidateLimit)).map(\.name)
        let candidateKeys = Set(candidates.map { $0.lowercased() })

        // Standing names fill what the sound-alikes leave, in their own order.
        // A standing name that is also a sound-alike takes a sound-alike slot,
        // so the total never passes the cap.
        let standingBudget = max(0, min(limit, standingFills) - candidates.count)
        var out: [String] = []
        var used = Set<String>()
        var standing = 0
        for name in always {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !used.contains(key) else { continue }
            if candidateKeys.contains(key) {
                out.append(trimmed)
                used.insert(key)
            } else if standing < standingBudget {
                out.append(trimmed)
                used.insert(key)
                standing += 1
            }
        }
        for candidate in candidates where !used.contains(candidate.lowercased()) {
            out.append(candidate)
            used.insert(candidate.lowercased())
        }
        return Array(out.prefix(max(0, limit)))
    }

    /// The prompt Whisper reads: a comma list with one closing period. The
    /// period matched the ear's own punctuation on Set E and cost nothing.
    public static func prompt(_ names: [String]) -> String {
        names.isEmpty ? "" : names.joined(separator: ", ") + "."
    }

    /// The heard words worth comparing names against: every word of at least
    /// `minimumProbeLength` letters, and every adjacent pair run together,
    /// because the engine breaks an unknown name into two known words
    /// ("friction lens", "super whisper") and only the pair sounds like the
    /// name.
    ///
    /// **A pair needs ONE half long enough, not both.** The old rule demanded
    /// `minimumProbeLength` from both, and the cost was measured on
    /// 2026-09-13: the first ear writes Capgemini as "cap Gemini", "cap" is
    /// three letters, so "capgemini" was never built and the name it matches
    /// exactly was never offered to either ear. Requiring both halves also
    /// never made sense for a split name, where the whole point is that one
    /// half is a fragment.
    ///
    /// It may not go further than that. Building a pair from two short words
    /// puts function words back in play through the side door: "and the one
    /// at ten" reaches Andrew and Amanda on the joins alone, which is the
    /// exact hazard `minimumProbeLength` exists to stop, and
    /// `shortHeardWordsAreNotProbes` catches it.
    static func probes(from heard: String) -> [String] {
        let words = heard.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        var probes: [String] = []
        for word in words where word.count >= minimumProbeLength { probes.append(word) }
        if words.count >= 2 {
            for i in 0..<(words.count - 1)
            where words[i].count >= minimumProbeLength || words[i + 1].count >= minimumProbeLength {
                probes.append(words[i] + words[i + 1])
            }
        }
        return probes
    }

    /// A name is compared whole (spaces removed, so "Chetan Jonnalagadda"
    /// meets "chetanjonnalagadda") and by each of its words, so the surname
    /// alone is enough.
    private static func similarity(of name: String, toAnyOf probes: [String]) -> Double {
        var pieces = name.split(separator: " ").map(String.init)
        if pieces.count > 1 { pieces.append(pieces.joined()) }
        var best = 0.0
        for piece in pieces {
            for probe in probes {
                best = max(best, PhoneticKey.similarity(probe, piece))
                if best == 1 { return 1 }
            }
        }
        return best
    }
}
