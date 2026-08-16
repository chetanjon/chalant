import Testing

@testable import ChalantDictationCore

/// Every pair here is a real substitution the engine made on 2026-08-15, or a
/// pair that must never be confused with one.
@Suite("PhoneticKey")
struct PhoneticKeyTests {

    /// The two most embarrassing errors in the whole baseline: the founder's
    /// own first name and surname, both misheard, both in the locked set.
    @Test("his own name sounds like his own name")
    func catchesTheNames() {
        #expect(PhoneticKey.similarity("Chatan", "Chetan") > 0.8)
        #expect(PhoneticKey.similarity("Junalagadda", "Jonnalagadda") > 0.8)
    }

    /// The product name, missed twice by two different speakers: once by
    /// synthesized speech, once by the founder.
    @Test("the product name is reachable from what was actually heard")
    func catchesTheProductName() {
        #expect(PhoneticKey.similarity("Shalan", "Chalant") > 0.6)
        #expect(PhoneticKey.similarity("challenge", "Chalant") > 0.6)
    }

    /// **The most important test in this file, and it asserts a limitation.**
    ///
    /// The key collides on ordinary words. `cat`, `cut` and `kite` all reduce
    /// to `KT`; `production` and `protection` both to `PRTKXN`. That is not a
    /// defect, it is how Double Metaphone works: it exists to match names
    /// across spelling variants, and it drops the vowels that separate these.
    ///
    /// So a matcher built on this alone would replace "cat" with "cut" the
    /// moment "cut" was in the vocabulary. **This is the whole reason Part 1
    /// §1 forbids substituting on resemblance**, and why the decision needs
    /// acoustic evidence rather than a similarity score. The key generates
    /// candidates. It must never choose one.
    @Test("the key collides on real words, which is why it cannot decide alone")
    func admitsItsOwnCollisions() {
        #expect(PhoneticKey.similarity("cat", "cut") == 1)
        #expect(PhoneticKey.similarity("production", "protection") == 1)
        // Words that sound genuinely different do stay apart.
        #expect(PhoneticKey.similarity("Sarah", "staging") < 0.5)
        #expect(PhoneticKey.similarity("Chalant", "production") < 0.5)
    }

    /// A name collapse the locked set caught. These two really do sound almost
    /// identical, which is why this one needs evidence beyond sound to resolve
    /// and cannot be fixed by the matcher alone.
    @Test("Sara and Sarah are genuinely hard, and the key says so")
    func admitsWhatItCannotSeparate() {
        #expect(PhoneticKey.similarity("Sarah", "Sara") > 0.8)
    }

    @Test("identical words are identical")
    func isReflexive() {
        #expect(PhoneticKey.similarity("Chalant", "Chalant") == 1)
        #expect(PhoneticKey.similarity("chalant", "CHALANT") == 1)
    }

    @Test("nothing sounds like nothing")
    func handlesEmpty() {
        #expect(PhoneticKey.of("") == "")
        #expect(PhoneticKey.similarity("", "Chalant") == 0)
        #expect(PhoneticKey.similarity("472", "153") == 0)
    }
}
