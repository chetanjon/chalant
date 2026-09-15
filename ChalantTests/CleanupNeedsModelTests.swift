import XCTest

@testable import Chalant

/// Whether the on-device model is worth warming.
///
/// **This exists because the answer was wrong for a month and cost battery
/// on every key-down.** The prewarm was gated on `mode != .off`, but in
/// `shadow` the model only ever runs inside `startShadowPolish`, which needs
/// a corpus row to write its answer into, and corpus capture is off by
/// default. So the default install warmed a model that was never called:
/// once at launch, and again on every single hold.
@MainActor
final class CleanupNeedsModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "com.cj.chalant.tests.needsmodel"

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

    /// The default install. Shadow mode, recordings off: nothing will ever
    /// ask the model anything, so nothing should be warmed for it.
    func testTheDefaultInstallWarmsNothing() {
        XCTAssertEqual(Cleanup.mode(in: defaults), .shadow)
        XCTAssertFalse(CorpusCapture.isEnabled(in: defaults))
        XCTAssertFalse(Cleanup.needsModel(in: defaults))
    }

    /// Shadow's whole purpose is the corpus row. With recordings on, the
    /// model does run, so warming it is right.
    func testShadowNeedsTheModelOnceRecordingsAreOn() {
        CorpusCapture.setEnabled(true, in: defaults)
        XCTAssertTrue(Cleanup.needsModel(in: defaults))
    }

    /// Live always waits on it, recordings or not.
    func testLiveAlwaysNeedsIt() {
        Cleanup.setMode(.live, in: defaults)
        XCTAssertTrue(Cleanup.needsModel(in: defaults))
        CorpusCapture.setEnabled(true, in: defaults)
        XCTAssertTrue(Cleanup.needsModel(in: defaults))
    }

    /// Off means off, whatever else is switched on.
    func testOffNeverNeedsIt() {
        Cleanup.setMode(.off, in: defaults)
        CorpusCapture.setEnabled(true, in: defaults)
        XCTAssertFalse(Cleanup.needsModel(in: defaults))
    }

    /// The old Bool switch still decides the mode for a profile that never
    /// saw the picker, and `needsModel` has to agree with it rather than
    /// reading the newer key alone.
    func testAnOldProfileWithCleanupOffStillWarmsNothing() {
        defaults.set(false, forKey: Cleanup.enabledKey)
        XCTAssertEqual(Cleanup.mode(in: defaults), .off)
        XCTAssertFalse(Cleanup.needsModel(in: defaults))
    }
}
