import XCTest
@testable import Chalant

/// Claude Code publishes two things about a running agent that this app
/// has never read: what a background agent needs
/// (`~/.claude/jobs/<id>/state.json`) and what any agent is working
/// through (`~/.claude/tasks/<sessionId>/*.json`).
///
/// Both readers take their directory as an argument, so no test can
/// reach the real one, and both are driven here over files written in
/// the exact shape found on this machine on 2026-08-06. The 1.6.0 bugs
/// all came from fixtures that were tidier than the disk.
final class JobsReaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chalant-jobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeJob(_ short: String, _ json: String) throws {
        let dir = root.appendingPathComponent(short)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("state.json"),
                       atomically: true, encoding: .utf8)
    }

    private func writeTask(_ session: String, _ file: String, _ json: String) throws {
        let dir = root.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(file),
                       atomically: true, encoding: .utf8)
    }

    // MARK: Jobs

    /// The founder's own August 3 agent, verbatim off the disk. It sat
    /// blocked for three days behind the `needs` line, and the island
    /// could not show it because nothing here had ever opened this file.
    func testABlockedAgentIsReadWholeAndKeyedByItsSessionID() throws {
        try writeJob("b8827367", """
        {"state":"blocked","detail":"sessions tab fixed; awaiting release decision",
         "tempo":"blocked","tokens":384376,
         "needs":"say the word and I'll bump to 1.6.1 and do the proper release",
         "output":{"result":"fixed: stuck states, wrong times"},
         "suggestedReply":"bump to 1.6.1 and do the proper release",
         "sessionId":"b8827367-b0c8-4ee6-b5f7-c42e7f58916b",
         "name":"Push changes to PR and pull","cwd":"/Users/x/moai"}
        """)

        let jobs = JobsReader.jobs(in: root)
        let job = jobs["b8827367-b0c8-4ee6-b5f7-c42e7f58916b"]

        XCTAssertEqual(job?.state, .blocked)
        XCTAssertEqual(job?.needs, "say the word and I'll bump to 1.6.1 and do the proper release")
        XCTAssertEqual(job?.detail, "sessions tab fixed; awaiting release decision")
        XCTAssertEqual(job?.result, "fixed: stuck states, wrong times")
        XCTAssertEqual(job?.suggestedReply, "bump to 1.6.1 and do the proper release")
        XCTAssertEqual(job?.tokens, 384_376)
    }

    /// The directory name is a short id and the row is keyed by the full
    /// session id, so an entry that cannot name its session cannot be
    /// attached to anything and is dropped rather than guessed at.
    func testAJobWithNoSessionIDIsSkipped() throws {
        try writeJob("nameless", #"{"state":"done"}"#)

        XCTAssertTrue(JobsReader.jobs(in: root).isEmpty)
    }

    /// The 1.6.0 lesson, kept: an unrecognised value costs the field it
    /// is in, never the whole entry. `SessionRegistry.parse` discarded
    /// entries over `kind:"bg"` and disowned every background agent on
    /// the machine.
    func testAnUnknownStateCostsTheStateAndNothingElse() throws {
        try writeJob("odd", """
        {"state":"hibernating","needs":"a word from you","sessionId":"s-1"}
        """)

        let job = JobsReader.jobs(in: root)["s-1"]

        XCTAssertNotNil(job)
        XCTAssertNil(job?.state)
        XCTAssertEqual(job?.needs, "a word from you")
    }

    func testOneUnreadableFileDoesNotTakeTheOthersDown() throws {
        try writeJob("broken", "{ this is not json")
        try writeJob("fine", #"{"state":"done","sessionId":"s-2"}"#)

        let jobs = JobsReader.jobs(in: root)

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs["s-2"]?.state, .done)
    }

    func testADirectoryThatIsNotThereReadsAsNoJobs() {
        let missing = root.appendingPathComponent("no-such-place")

        XCTAssertTrue(JobsReader.jobs(in: missing).isEmpty)
    }

    /// Every finished agent on this machine writes `output.result`, and
    /// a row that has been alive for a week should still be able to say
    /// what it came back with.
    func testAFinishedAgentKeepsItsResult() throws {
        try writeJob("done-1", """
        {"state":"done","output":{"result":"appcast regenerated, cask updated"},
         "sessionId":"s-3"}
        """)

        XCTAssertEqual(JobsReader.jobs(in: root)["s-3"]?.result,
                       "appcast regenerated, cask updated")
    }

    // MARK: Plans

    func testThePlanIsTheStepInProgressAndHowManyAreBehindIt() throws {
        try writeTask("s-1", "1.json", #"{"id":"1","subject":"Explore","activeForm":"Exploring","status":"completed"}"#)
        try writeTask("s-1", "2.json", #"{"id":"2","subject":"Ask","activeForm":"Asking","status":"completed"}"#)
        try writeTask("s-1", "3.json", #"{"id":"3","subject":"Build the ladder","activeForm":"Building the ladder","status":"in_progress"}"#)
        try writeTask("s-1", "4.json", #"{"id":"4","subject":"Ship","activeForm":"Shipping","status":"pending"}"#)

        let plan = JobsReader.plan(forSession: "s-1", in: root)

        XCTAssertEqual(plan?.step, "Building the ladder")
        XCTAssertEqual(plan?.done, 2)
        XCTAssertEqual(plan?.total, 4)
    }

    /// `activeForm` is the present-tense line the agent wrote for
    /// exactly this purpose, but it is optional in the format. The
    /// subject is the fallback, because a step with no name is not a
    /// step anybody can read.
    func testAStepWithNoActiveFormFallsBackToItsSubject() throws {
        try writeTask("s-1", "1.json", #"{"id":"1","subject":"Run the release","status":"in_progress"}"#)

        XCTAssertEqual(JobsReader.plan(forSession: "s-1", in: root)?.step, "Run the release")
    }

    func testAPlanWithNothingInProgressStillCounts() throws {
        try writeTask("s-1", "1.json", #"{"id":"1","subject":"A","status":"completed"}"#)
        try writeTask("s-1", "2.json", #"{"id":"2","subject":"B","status":"pending"}"#)

        let plan = JobsReader.plan(forSession: "s-1", in: root)

        XCTAssertNil(plan?.step)
        XCTAssertEqual(plan?.done, 1)
        XCTAssertEqual(plan?.total, 2)
    }

    /// The real directory holds a `.lock` beside the numbered files.
    func testNonJSONFilesInTheTaskDirectoryAreIgnored() throws {
        try writeTask("s-1", "1.json", #"{"id":"1","subject":"A","status":"in_progress"}"#)
        try writeTask("s-1", ".lock", "")

        XCTAssertEqual(JobsReader.plan(forSession: "s-1", in: root)?.total, 1)
    }

    /// Measured on this machine: 18 of 22 task directories are empty,
    /// because the folder is created whether or not the agent ever
    /// reaches for the tool. An empty one is not a plan.
    func testAnEmptyTaskDirectoryIsNoPlanAtAll() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("s-1"), withIntermediateDirectories: true)

        XCTAssertNil(JobsReader.plan(forSession: "s-1", in: root))
    }

    func testASessionWithNoTaskDirectoryHasNoPlan() {
        XCTAssertNil(JobsReader.plan(forSession: "never-planned", in: root))
    }

    /// Steps are numbered, and 10 must not sort between 1 and 2, or the
    /// row names the wrong step the moment a plan passes nine.
    func testStepsAreCountedNotSortedAsStrings() throws {
        for index in 1...11 {
            let status = index < 10 ? "completed" : "pending"
            try writeTask("s-1", "\(index).json",
                          #"{"id":"\#(index)","subject":"S\#(index)","status":"\#(status)"}"#)
        }
        try writeTask("s-1", "10.json", #"{"id":"10","subject":"The tenth","status":"in_progress"}"#)

        let plan = JobsReader.plan(forSession: "s-1", in: root)

        XCTAssertEqual(plan?.step, "The tenth")
        XCTAssertEqual(plan?.done, 9)
        XCTAssertEqual(plan?.total, 11)
    }
}
