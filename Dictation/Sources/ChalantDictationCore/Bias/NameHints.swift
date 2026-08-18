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
/// So the list is built per utterance: the standing names (typed by hand,
/// learned from corrections) go every time, then the names from the wider
/// pool (Contacts) that sound like something just heard, best first, and the
/// whole thing is capped. The same selection at a larger cap is what the
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
    ///   then learned). Offered every time, until the cap.
    /// - pool: the wider list (Contacts). Offered only when a name sounds like
    ///   something in `heard`.
    /// - limit: the cap on the whole list.
    /// - candidateLimit: the cap on sound-alikes; they are never the part the
    ///   cap cuts, because they are the part that earns the slot.
    public static func select(
        heard: String,
        always: [String],
        pool: [String],
        limit: Int = promptLimit,
        candidateLimit: Int = promptCandidateLimit
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
        let standingBudget = max(0, limit - candidates.count)
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
    /// `minimumProbeLength` letters, and every adjacent pair of such words run
    /// together, because the engine breaks an unknown name into two known
    /// words ("friction lens", "super whisper") and only the pair sounds like
    /// the name.
    static func probes(from heard: String) -> [String] {
        let words = heard.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        var probes: [String] = []
        for word in words where word.count >= minimumProbeLength { probes.append(word) }
        if words.count >= 2 {
            for i in 0..<(words.count - 1)
            where words[i].count >= minimumProbeLength && words[i + 1].count >= minimumProbeLength {
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
