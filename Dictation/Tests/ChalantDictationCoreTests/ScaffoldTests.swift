import Testing

@testable import ChalantDictationCore

/// Setup step 8 stops at "swift build and swift test pass on an empty test
/// suite". This is that empty suite: it asserts the module imports and nothing
/// about behaviour, because no milestone is implemented yet.
@Suite("Scaffold")
struct ScaffoldTests {
    @Test("the core module builds and is importable")
    func moduleLoads() {
        #expect(InsertionTier.systemEvents.rawValue == 1)
    }
}
