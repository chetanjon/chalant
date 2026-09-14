
import XCTest
@testable import Chalant
@testable import ChalantDictationCore

@MainActor
final class FreshInstallAuditTests: XCTestCase {
    /// A brand-new profile, read through every default the dictation path
    /// consults. This is the row a stranger gets.
    func testWhatAFreshInstallActuallyGets() {
        let suite = "com.cj.chalant.tests.freshaudit"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertFalse(Dictation.isEnabled(in: d), "hold-to-dictate off until asked for")
        XCTAssertEqual(SpeechEngineChoice.current(in: d), .apple)
        XCTAssertEqual(DictationShortcutStore.current(in: d), .leftOption)
        XCTAssertEqual(Cleanup.mode(in: d), .shadow)
        XCTAssertFalse(Cleanup.needsModel(in: d), "nothing warms a model nothing will call")
        XCTAssertFalse(CorpusCapture.isEnabled(in: d), "recordings off")
        XCTAssertTrue(CorrectionObserver.isEnabled(in: d), "learning names on")
        XCTAssertTrue(Vocabulary.terms(in: d).isEmpty)
    }

    /// The founder's own profile, as it stands on this machine today:
    /// `dictationBetterHearing = 1`, no engine chosen, cleanup live, corpus on.
    func testWhatThisMachinesProfileGets() {
        let suite = "com.cj.chalant.tests.migrateaudit"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let d = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        d.set(true, forKey: "dictationEnabled")
        d.set(true, forKey: "dictationBetterHearing")
        d.set("live", forKey: "dictationCleanupMode")
        d.set(true, forKey: "dictationCaptureCorpus")

        XCTAssertEqual(SpeechEngineChoice.current(in: d), .whisper, "the ear they chose stays theirs")
        XCTAssertEqual(DictationShortcutStore.current(in: d), .leftOption, "the key does not move under them")
        XCTAssertTrue(Cleanup.needsModel(in: d), "live plus recordings really does call the model")
    }
}
