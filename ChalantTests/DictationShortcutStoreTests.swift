import XCTest

@testable import Chalant
@testable import ChalantDictationCore

/// Where the hold key is remembered, and what a bad stored value does.
@MainActor
final class DictationShortcutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.cj.chalant.tests.holdkey"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    /// Nothing stored is left Option, which is what every existing install
    /// has been holding since 1.13.0.
    func testAFreshProfileHoldsLeftOption() {
        XCTAssertEqual(DictationShortcutStore.current(in: defaults), .leftOption)
    }

    func testAChoiceSurvives() {
        DictationShortcutStore.set(.rightOption, in: defaults)
        XCTAssertEqual(DictationShortcutStore.current(in: defaults), .rightOption)
    }

    /// **A stored key that no longer exists must not cost dictation its
    /// hotkey.** The tap reads this once when it installs; a pair matching no
    /// real key would install a tap that never fires, which looks exactly
    /// like a refused permission.
    func testRubbishFallsBackToTheDefault() {
        defaults.set("not-a-key", forKey: DictationShortcutStore.key)
        XCTAssertEqual(DictationShortcutStore.current(in: defaults), .leftOption)

        defaults.set("58:1", forKey: DictationShortcutStore.key)
        XCTAssertEqual(DictationShortcutStore.current(in: defaults), .leftOption)
    }

    /// The one sentence that names the gesture has to name the key the user
    /// actually chose. It used to say "left Option" unconditionally.
    func testTheCopyNamesTheChosenKey() throws {
        DictationShortcutStore.set(.function, in: defaults)
        let key = DictationShortcutStore.current(in: defaults)
        let line = try XCTUnwrap(VoiceDoor.dictationLine(available: true, keyName: key.label))
        XCTAssertTrue(line.contains("Fn"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("option"))
    }
}
