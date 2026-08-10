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

    // MARK: A pid makes a session real, a file does not

    /// The rail used to be a list of recently-touched files, and a
    /// developer's machine is full of files nobody asked about. On the
    /// founder's Mac, eight of the twelve freshest transcripts belonged to
    /// claude-mem's observer bot (2026-08-03), so eight of twelve rows
    /// were another program's leftovers.
    ///
    /// While the registry is answering, it is the list. Discovery still
    /// says everything it knows about a session; it may no longer invent
    /// one.
    func testWhileTheRegistryIsAnsweringAWarmFileCannotInventASession() {
        let store = store()
        store.noteRegistryIsAuthoritative()
        store.upsert(id: "observer", title: "observer-sessions", cwd: "/a/observer-sessions",
                     branch: nil, lastPrompt: nil, state: .working)
        XCTAssertTrue(store.sessions.isEmpty, "no process vouched for this, so there is no session")
    }

    /// And having refused it, it must not have quietly filed it as a
    /// session that ended either. That was the same bug wearing the
    /// record's clothes: a bot transcript went cold and turned into a
    /// "lost" row, so the eight-row record filled with them.
    func testAFileTheRegistryNeverVouchedForNeverReachesTheRecord() {
        let store = store()
        store.noteRegistryIsAuthoritative()
        store.upsert(id: "observer", title: "observer-sessions", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        store.reconcileLive(against: ["someone-real"])
        XCTAssertTrue(store.finished.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
    }

    /// The other half: a vouched session still takes everything the
    /// transcript knows. The registry says who exists; discovery says what
    /// they are called and what they are doing, and that division is the
    /// whole point of keeping both.
    func testAVouchedSessionStillTakesEverythingTheTranscriptKnows() {
        let store = store()
        store.noteRegistryIsAuthoritative()
        store.markLive(id: "real", name: "roll-out-echo-mark", cwd: "/a", pid: 1,
                       kind: .interactive, status: .idle)
        store.upsert(id: "real", title: "Fix the sessions tab", cwd: "/a", branch: "main",
                     lastPrompt: "go", state: .working, activity: "Editing",
                     transcriptPath: "/t/real.jsonl")

        XCTAssertEqual(store.sessions.first?.title, "Fix the sessions tab")
        XCTAssertEqual(store.sessions.first?.branch, "main")
        XCTAssertEqual(store.sessions.first?.activity, "Editing")
        XCTAssertEqual(store.sessions.first?.transcriptPath, "/t/real.jsonl")
    }

    /// The standing law this overlay was written under: the registry
    /// directory is undocumented, and a Claude Code release that moves it
    /// must cost a badge rather than the whole list. So when nothing has
    /// vouched for the directory existing, transcripts are the list again,
    /// exactly as they were before any of this.
    func testWithNoRegistryAtAllTheTranscriptsAreStillTheList() {
        let store = store()
        store.upsert(id: "s", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .working)
        XCTAssertEqual(store.sessions.map(\.id), ["s"])
    }

    /// Cursor keeps no registry of its own, so `~/.claude/sessions` has no
    /// standing to say a Cursor chat does not exist. The same carve-out
    /// `reconcileLive` already makes, in the one other place that now
    /// decides whether a session is real.
    func testAClaudeRegistryHasNoSayOverCursorChats() {
        let store = store()
        store.noteRegistryIsAuthoritative()
        store.upsert(id: "cursor-chat", title: "t", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, agent: .cursor)
        XCTAssertEqual(store.sessions.map(\.id), ["cursor-chat"])
    }

    // MARK: One authority, so the row stops blinking

    /// The blink, in three lines.
    ///
    /// The founder's own session sat in a VS Code terminal with a registry
    /// file that had said `busy` for twenty-one hours and a transcript
    /// last written an hour ago. The registry sweep set `.working` every
    /// five seconds; the discovery rescan set `.stale` every twenty. A
    /// `.stale` row is filtered out of `groups()`, so the row vanished
    /// from the rail and came back, forever, and `stateSince` reset on
    /// every flip so the age column read nonsense.
    ///
    /// A pid outranks an mtime. Discovery may add what it knows; it may
    /// not declare a vouched-for process gone.
    func testAQuietFileCannotDeclareAVouchedProcessGone() {
        let store = store()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        store.upsert(id: "s", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .stale)

        XCTAssertEqual(store.sessions.first?.state, .working)
        XCTAssertEqual(store.groups().first?.group, .working,
                       "and so it never leaves the rail")
    }

    /// The clock the age column reads must survive the rescan that used
    /// to reset it.
    func testTheAgeSurvivesARescanOfAQuietTranscript() {
        let store = store()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        let before = store.sessions[0].stateSince
        store.upsert(id: "s", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .stale)
        store.upsert(id: "s", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .stale)
        XCTAssertEqual(store.sessions[0].stateSince, before)
    }

    /// The rule is about a process the registry vouches for, not about
    /// `.stale` being unsayable. Once the registry has disowned a session,
    /// its pid is gone and discovery is trusted again.
    func testADisownedSessionCanStillGoQuiet() {
        let store = store()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        store.reconcileLive(against: ["somebody-else"])
        XCTAssertEqual(store.sessions.first?.state, .stale)
        XCTAssertNil(store.sessions.first?.pid)
    }

    /// A twenty-one hour old `busy` is not evidence of work.
    ///
    /// Claude Code stops rewriting the status file when a session parks a
    /// background job, so the founder's own session claimed to be working
    /// from 03:18 until the next morning. Alive is known, because this app
    /// holds the pid and asked the kernel. Working is a claim, and a claim
    /// no moving transcript agrees with settles at rest instead.
    func testABusyClaimNothingCorroboratesSettlesAtRest() {
        let store = store()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .idle)
        store.upsert(id: "s", title: "t", cwd: "/a", branch: nil, lastPrompt: nil,
                     state: .stale, updatedAt: Date().addingTimeInterval(-3600))

        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)

        XCTAssertEqual(store.sessions.first?.state, .idle,
                       "alive, and nothing says it is doing anything")
    }

    /// A real turn goes minutes at a time without touching its
    /// transcript, so the window has to be generous enough that ordinary
    /// work is never demoted mid-thought.
    func testABusyClaimAMovingTranscriptAgreesWithIsBelieved() {
        let store = store()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .idle)
        store.upsert(id: "s", title: "t", cwd: "/a", branch: nil, lastPrompt: nil,
                     state: .working, updatedAt: Date().addingTimeInterval(-120))

        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)

        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    /// Nothing to corroborate against is not the same as being
    /// contradicted. A session the registry has just found, whose
    /// transcript this app has not read yet, is believed.
    func testABusyClaimWithNoTranscriptYetIsBelieved() {
        let store = store()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        XCTAssertEqual(store.sessions.first?.state, .working)
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
                     state: .working, transcriptPath: "/t/s.jsonl")
        // What the Stop hook's own payload delivers at the turn
        // boundary — the record's summary is made of this, not of a
        // transcript scrape.
        store.noteLastWords(sessionID: "s", "rebased clean")
        store.markGone(["s"])
        XCTAssertEqual(store.finished.first?.lastMessage, "rebased clean")
        XCTAssertEqual(store.finished.first?.transcriptPath, "/t/s.jsonl")
        XCTAssertEqual(store.finished.first?.branch, "main")
    }

    /// The Stop payload's words are bounded and trimmed on the way in,
    /// like everything else that arrives over the local API, and blank
    /// words never blank what the row already shows.
    func testLastWordsAreBoundedAndNeverBlankTheRow() {
        let store = store()
        store.upsert(id: "s", title: "s", cwd: "/a", branch: nil, lastPrompt: nil,
                     state: .working)
        store.noteLastWords(sessionID: "s", "  done.  ")
        XCTAssertEqual(store.sessions.first?.lastMessage, "done.")

        store.noteLastWords(sessionID: "s", "   ")
        XCTAssertEqual(store.sessions.first?.lastMessage, "done.",
                       "a Stop with nothing to say must not erase the last real words")

        store.noteLastWords(sessionID: "s", String(repeating: "a", count: 1000))
        XCTAssertEqual(store.sessions.first?.lastMessage?.count, ActivityServer.maxDetail)
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

    /// The one a real hold caught: the registry had lost the process,
    /// the row was stale, and an agent stood at the door with its
    /// approval card nowhere on screen (observed 2026-08-03). A
    /// PreToolUse hook waiting on an answer is the strongest proof of
    /// life this store ever gets.
    func testAHeldCallIsNeverInvisible() {
        let store = store()
        live(store, "s", .working)
        store.markGone(["s"])
        XCTAssertEqual(store.groups().map(\.group), [.finished])
        XCTAssertTrue(
            store.holdForApproval(sessionID: "s", id: "call-1", tool: "Bash",
                                  detail: "rm -rf build", rules: ["Bash(rm *)"]))
        XCTAssertEqual(store.groups().map(\.group), [.needsYou])
        XCTAssertTrue(store.finished.isEmpty)
    }

    /// A row cannot be running and finished in the same rail. Anything
    /// showing as live wins over a record entry an earlier sweep wrote.
    func testARowIsNeverInTwoBandsAtOnce() {
        let store = store()
        live(store, "s", .working)
        store.markGone(["s"])
        live(store, "s", .working)
        let bands = store.groups()
        XCTAssertEqual(bands.map(\.group), [.working])
        XCTAssertTrue(bands.flatMap(\.ended).isEmpty)
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
