import Foundation

/// Text was rewritten; carry the per-word confidence across to it.
///
/// **Needed because inverse text normalisation works on sentences and the
/// vocabulary layer works on words.** Parakeet writes numbers the way they are
/// said: "one hundred and twenty dollars", "three fifteen", "version one point
/// four two". FluidAudio's `TextNormalizer` turns those into "$120", "03:15",
/// "1.42", which is what the speaker meant and what every other engine here
/// produces. It also collapses five words into one, so the confidences the
/// decoder gave per sub-word no longer line up with anything.
///
/// Throwing them away would silence the whole vocabulary layer, which is the
/// 2026-08-15 bug in a new coat (`TokenAssembly` line 5). Keeping them by
/// position would attach a number's confidence to whatever word happened to
/// land in that slot, which is worse than nothing: `TermMatcher` would gate a
/// real decision on a score belonging to a different word.
///
/// So the two token sequences are aligned, and a word carries its confidence
/// only where it is unchanged. Everything the rewrite touched arrives with
/// `nil`, which `TermMatcher` reads as "no evidence to act on" and refuses to
/// substitute — the conservative answer, and the correct one: a word the
/// normaliser just rewrote is not a word to second-guess on sound.
public enum TokenRealignment {

    public static func carryingConfidence(from original: [Token], onto rewritten: String) -> [Token] {
        let words = rewritten.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        guard !original.isEmpty else { return words.map { Token(text: $0) } }

        // Same alignment `HearingMerge` uses to reconcile two hearings. Reused
        // rather than rewritten: it already handles a word being added or
        // removed, which a positional walk cannot express, and that is exactly
        // what "one hundred and twenty dollars" becoming "$120" is.
        var out: [Token] = []
        for span in HearingMerge.align(engine: original, ear: words) {
            switch span.kind {
            case .agreed:
                out.append(contentsOf: span.engine)
            case .deletion:
                // The rewrite dropped these words. They are not in the new
                // text, so they are not tokens any more.
                continue
            case .insertion:
                out.append(contentsOf: span.ear.map { Token(text: $0) })
            case .substitution:
                out.append(contentsOf: span.ear.map { Token(text: $0) })
            }
        }
        return out
    }
}
