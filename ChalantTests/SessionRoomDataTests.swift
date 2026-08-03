import XCTest
@testable import Chalant

/// The data the room stands on: when a session entered the state it is
/// in, which band it belongs to, and the bounded record of what ended
/// while this app was watching.
///
/// Its own file rather than more of `SessionStoreTests`, which is
/// already 2700 lines. Nothing here touches a real install: the store's
/// `defaults` seam takes a scratch suite exactly the way `outboxDir`
/// takes a scratch directory.
@MainActor
final class SessionRoomDataTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "chalant.tests.room.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> SessionStore {
        SessionStore(defaults: defaults)
    }

    private func live(_ store: SessionStore, _ id: String, _ state: SessionStore.State = .working) {
        store.upsert(id: id, title: id, cwd: "/a/\(id)", branch: nil,
                     lastPrompt: nil, state: state)
    }

    // MARK: stateSince, the number that used to mean nothing

    /// The row's trailing column read `RelativeAge.short(updatedAt)`,
    /// and discovery rewrites `updatedAt` on every sweep, so every live
    /// row said "now" forever. This is the timestamp that only moves
    /// when something happens.
    func testStateSinceMovesWhenTheStateActuallyChanges() {
        let store = store()
        live(store, "s", .working)
        let before = store.sessions[0].stateSince
        live(store, "s", .idle)
        XCTAssertGreaterThan(store.sessions[0].stateSince, before)
    }

    /// The whole bug, in one assertion: a rescan re-asserting the same
    /// state is not an event, and must not restart the clock.
    func testStateSinceHoldsWhenARescanReassertsTheSameState() {
        let store = store()
        live(store, "s", .working)
        let before = store.sessions[0].stateSince
        live(store, "s", .working)
        live(store, "s", .working)
        XCTAssertEqual(store.sessions[0].stateSince, before)
    }

    /// `updatedAt` is a testing seam and `stateSince` deliberately is
    /// not: it measures elapsed wall time in front of a person, so a
    /// test faking discovery's clock into the past must not be able to
    /// make a session claim it has been working for an hour.
    func testStateSinceIgnoresAFakedDiscoveryClock() {
        let store = store()
        store.upsert(id: "s", title: "s", cwd: "/a", branch: nil, lastPrompt: nil,
                     state: .working, updatedAt: Date().addingTimeInterval(-3600))
        XCTAssertGreaterThan(store.sessions[0].stateSince, Date().addingTimeInterval(-5))
    }

    // MARK: The record

    func testTheRegistryLosingASessionPutsItInTheRecordAsLost() {
        let store = store()
        live(store, "s", .working)
        store.markGone(["s"])
        XCTAssertEqual(store.finished.map(\.id), ["s"])
        XCTAssertEqual(store.finished.first?.outcome, .lost)
    }

    func testALiveSessionFinishingIsRecordedWithItsRealOutcome() {
        let store = store()
        live(store, "a", .working)
        live(store, "a", .done)
        live(store, "b", .working)
        live(store, "b", .failed)
        XCTAssertEqual(Set(store.finished.map(\.id)), ["a", "b"])
        XCTAssertEqual(store.finished.first(where: { $0.id == "a" })?.outcome, .done)
        XCTAssertEqual(store.finished.first(where: { $0.id == "b" })?.outcome, .failed)
    }

    /// The bound that does the real work. A developer's machine carries
    /// months of transcripts; none of them were watched ending, so none
    /// of them may appear.
    func testASessionFirstSeenAlreadyDeadNeverEntersTheRecord() {
        let store = store()
        live(store, "cold", .done)
        live(store, "colder", .failed)
        live(store, "quiet", .stale)
        XCTAssertTrue(store.finished.isEmpty)
    }

    /// `markGone` is not private, so the live check belongs inside it
    /// rather than in the one caller that happens to do it today.
    func testMarkGoneOnAnAlreadyDeadSessionAddsNothing() {
        let store = store()
        live(store, "s", .working)
        store.markGone(["s"])
        store.markGone(["s"])
        XCTAssertEqual(store.finished.count, 1)
    }

    func testTheRecordIsDedupedByID() {
        let store = store()
        live(store, "s", .working)
        live(store, "s", .done)
        live(store, "s", .working)
        live(store, "s", .done)
        XCTAssertEqual(store.finished.count, 1)
    }

    func testTheRecordIsCappedAndNewestFirst() {
        let store = store()
        for index in 0..<(SessionStore.historyCap + 4) {
            live(store, "s\(index)", .working)
            live(store, "s\(index)", .done)
        }
        XCTAssertEqual(store.finished.count, SessionStore.historyCap)
        XCTAssertEqual(store.finished.first?.id, "s\(SessionStore.historyCap + 3)")
    }

    /// The window is what "catch up" means. An hour ago is not this
    /// morning, and a room left open overnight must not still be
    /// showing yesterday.
    func testTheRecordDropsRowsPastTheChosenWindow() {
        defaults.set("hour", forKey: SessionStore.historyWindowKey)
        let store = store()
        live(store, "s", .working)
        live(store, "s", .done)
        XCTAssertEqual(store.history.count, 1)
        // Reach past the API to age the row, which is the one thing a
        // test cannot do by waiting.
        store.ageFinishedForTesting(id: "s", to: Date().addingTimeInterval(-3700))
        XCTAssertTrue(store.history.isEmpty)
    }

    /// Off means not kept, not merely not shown. A record nobody can
    /// reach is not a record, it is a leak.
    func testHistoryOffKeepsNothingAtAll() {
        defaults.set("off", forKey: SessionStore.historyWindowKey)
        let store = store()
        live(store, "s", .working)
        live(store, "s", .done)
        XCTAssertTrue(store.finished.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
    }

    /// The reason the record is its own array: `clear(id:)` is exactly
    /// the call that would delete it.
    func testTheRecordSurvivesTheSessionBeingCleared() {
        let store = store()
        live(store, "s", .working)
        live(store, "s", .done)
        store.clear(id: "s")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.finished.map(\.id), ["s"])
    }

    func testTheRecordRemembersWhatTheSessionLastSaid() {
        let store = store()
        store.upsert(id: "s", title: "s", cwd: "/a", branch: "main", lastPrompt: nil,
                     state: .working, lastMessage: "rebased clean", transcriptPath: "/t/s.jsonl")
        store.markGone(["s"])
        XCTAssertEqual(store.finished.first?.lastMessage, "rebased clean")
        XCTAssertEqual(store.finished.first?.transcriptPath, "/t/s.jsonl")
        XCTAssertEqual(store.finished.first?.branch, "main")
    }

    /// The registry loses a session through a long quiet turn and finds
    /// it again on the next sweep. Before this the room drew the same
    /// session in Working and in Finished at once, four rows apart
    /// (caught in pixels, 2026-08-03).
    func testASessionThatComesBackToLifeLeavesTheRecord() {
        let store = store()
        live(store, "s", .working)
        store.markGone(["s"])
        XCTAssertEqual(store.finished.map(\.id), ["s"])
        live(store, "s", .working)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testTheRegistryVouchingForALostSessionAlsoRevivesIt() {
        let store = store()
        live(store, "s", .working)
        store.markGone(["s"])
        XCTAssertEqual(store.finished.count, 1)
        store.markLive(id: "s", name: "s", cwd: "/a", pid: 4242, kind: .interactive, status: .idle)
        XCTAssertTrue(store.finished.isEmpty)
    }

    /// Reviving is for the living only. A row arriving already done must
    /// not clear the record entry that was just written for it.
    func testFinishingDoesNotReviveTheRowItJustWrote() {
        let store = store()
        live(store, "s", .working)
        live(store, "s", .done)
        XCTAssertEqual(store.finished.map(\.id), ["s"])
    }

    // MARK: Grouping

    func testEachLiveStateLandsInItsOwnBand() {
        XCTAssertEqual(SessionStore.group(for: session(state: .needsInput)), .needsYou)
        XCTAssertEqual(SessionStore.group(for: session(state: .working)), .working)
        XCTAssertEqual(SessionStore.group(for: session(state: .idle)), .atPrompt)
    }

    /// A session can be mid-turn and still be the thing standing still
    /// waiting for a human. That row is the whole reason the rail
    /// exists, so the hold outranks the state.
    func testAHeldApprovalPullsAWorkingSessionIntoNeedsYou() {
        let store = store()
        live(store, "s", .working)
        XCTAssertTrue(
            store.holdForApproval(sessionID: "s", id: "call-1", tool: "Bash",
                                  detail: "rm -rf build", rules: ["Bash(rm *)"]))
        XCTAssertEqual(SessionStore.group(for: store.sessions[0]), .needsYou)
    }

    func testAnUnansweredQuestionPullsASessionIntoNeedsYou() {
        let store = store()
        live(store, "s", .working)
        XCTAssertTrue(
            store.attach(askID: "ask-1", to: "s", header: "Pick", question: "Which?",
                         options: ["a", "b"], multiSelect: false))
        XCTAssertEqual(SessionStore.group(for: store.sessions[0]), .needsYou)
    }

    func testGroupsOmitsEmptyBands() {
        let store = store()
        live(store, "w", .working)
        let bands = store.groups().map(\.group)
        XCTAssertEqual(bands, [.working])
    }

    func testGroupsOrdersBandsNeedsYouFirstAndFinishedLast() {
        let store = store()
        live(store, "idle", .idle)
        live(store, "gone", .working)
        live(store, "gone", .done)
        live(store, "work", .working)
        live(store, "want", .needsInput)
        XCTAssertEqual(store.groups().map(\.group), [.needsYou, .working, .atPrompt, .finished])
    }

    /// Dead rows discovery still has in hand are not the record. Showing
    /// them beside rows this app watched end would break the one bound
    /// that makes the record honest.
    func testAStaleRowInSessionsIsNotDrawnAsFinished() {
        let store = store()
        live(store, "cold", .stale)
        XCTAssertTrue(store.groups().isEmpty)
    }

    func testABandTheUserSwitchedOffIsNotDrawn() {
        defaults.set(false, forKey: SessionStore.Group.atPrompt.settingKey)
        let store = store()
        live(store, "idle", .idle)
        live(store, "work", .working)
        XCTAssertEqual(store.groups().map(\.group), [.working])
    }

    /// A band whose entire purpose is "something is blocked on you"
    /// being switchable off is a way to make this app quietly fail at
    /// its one job.
    func testNeedsYouCannotBeSwitchedOff() {
        defaults.set(false, forKey: SessionStore.Group.needsYou.settingKey)
        let store = store()
        live(store, "want", .needsInput)
        XCTAssertFalse(SessionStore.Group.needsYou.canBeHidden)
        XCTAssertEqual(store.groups().map(\.group), [.needsYou])
    }

    private func session(state: SessionStore.State) -> SessionStore.Session {
        SessionStore.Session(
            id: "s", title: "s", cwd: "/a", branch: nil, lastPrompt: nil,
            activity: nil, agent: .claude, state: state, ask: nil,
            startedAt: Date(), updatedAt: Date()
        )
    }
}

/// The room's arithmetic. Every input is a user dial, so the interesting
/// cases are the ends of the ranges rather than the middle, and the one
/// that matters is that no dialable combination overflows the panel the
/// island is drawn in.
@MainActor
final class RoomGeometryTests: XCTestCase {
    private typealias Panel = Theme.Panel

    func testAnOrdinaryMacGetsTheFullRoom() {
        // A real built-in notch at the default padding.
        XCTAssertEqual(Panel.room(topReserve: 32, padding: 20), 620)
    }

    /// The check the flat 480 could never pass: the worst combination
    /// anyone can dial in still fits inside the window.
    func testNoDialableCombinationOverflowsThePanel() {
        let notch = DisplayConfigStore.Config.heightRange
        let padding = DisplayConfigStore.Config.paddingRange
        for top in [notch.lowerBound, notch.upperBound] {
            for pad in [padding.lowerBound, padding.upperBound] {
                let room = Panel.room(topReserve: top, padding: pad)
                let chrome = top + Theme.Space.notchClearance + Panel.roomHeader + pad
                XCTAssertLessThanOrEqual(
                    room + chrome, Panel.panel,
                    "notch \(top), padding \(pad) overflows the panel")
            }
        }
    }

    func testTheWorstConfigurationStillBeatsTheOldFlatNumber() {
        let worst = Panel.room(
            topReserve: DisplayConfigStore.Config.heightRange.upperBound,
            padding: DisplayConfigStore.Config.paddingRange.upperBound)
        XCTAssertEqual(worst, 578)
        XCTAssertGreaterThan(worst, 480)
    }

    func testTheRoomIsClampedAtBothEnds() {
        XCTAssertEqual(Panel.room(topReserve: 0, padding: 0), 620)
        XCTAssertEqual(Panel.room(topReserve: 900, padding: 900), 420)
    }

    // MARK: Width

    func testTheRoomPutsAFloorUnderTheWidthDial() {
        let narrow = NotchViewModel.expandedWidth(
            configWidth: 520, tab: .sessions, pane: .none, chatFull: false, focused: true)
        XCTAssertEqual(narrow, 820)
    }

    /// A floor, never an override. Somebody already running wider keeps
    /// their width and the conversation column simply gets longer.
    func testAWiderDialIsNeverShrunkByTheFloor() {
        let wide = NotchViewModel.expandedWidth(
            configWidth: 840, tab: .sessions, pane: .none, chatFull: false, focused: true)
        XCTAssertEqual(wide, 840)
    }

    func testTheGlanceIsUntouchedByTheRoomFloor() {
        let glance = NotchViewModel.expandedWidth(
            configWidth: 520, tab: .sessions, pane: .none, chatFull: false, focused: false)
        XCTAssertEqual(glance, 520)
    }
}
