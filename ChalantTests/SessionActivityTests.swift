import XCTest
@testable import Chalant

/// The rail used to print a folder name and a clock, and cover the gap
/// with mood words: Working, Needs you, At its prompt. The founder's
/// verdict was that those are "vague ones that pretend" (2026-08-06).
///
/// The ladder replaces them. It returns one line about a session, taken
/// from the first rung that holds a fact, and every rung is evidence
/// read off disk rather than a state inferred from a timestamp. These
/// tests pin the rungs and, more importantly, the order between them:
/// what an agent is asking for always outranks what it is doing.
final class SessionActivityTests: XCTestCase {

    // MARK: Helpers

    private func session(
        state: SessionStore.State = .working,
        activity: String? = nil,
        lastMessage: String? = nil,
        startedAt: Date = Date()
    ) -> SessionStore.Session {
        var session = SessionStore.Session(
            id: "s", title: "moai", cwd: "/a/moai", branch: nil, lastPrompt: nil,
            activity: activity, agent: .claude, state: state, ask: nil, pid: 1,
            kind: .interactive, startedAt: startedAt, updatedAt: startedAt
        )
        session.lastMessage = lastMessage
        return session
    }

    // MARK: Rung 1, a call held at the door

    func testAHeldCallShowsTheCommandItself() {
        var subject = session()
        subject.approval = SessionStore.Approval(
            id: "call-1", tool: "Bash", detail: "rm -rf build", askedAt: Date()
        )

        let line = SessionActivity.line(for: subject)

        XCTAssertEqual(line.text, "rm -rf build")
        XCTAssertEqual(line.source, .heldCall)
    }

    /// The verbatim rule the approval card already holds: a summary of a
    /// command you are being asked to authorise is a summary of the
    /// wrong thing.
    func testAHeldCallIsNeverSummarised() {
        var subject = session()
        subject.approval = SessionStore.Approval(
            id: "call-1", tool: "Bash",
            detail: "git push --force origin main", askedAt: Date()
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text,
                       "git push --force origin main")
    }

    // MARK: Rung 2, a question

    func testAnUnansweredQuestionShowsTheQuestion() {
        var subject = session()
        subject.ask = SessionStore.Ask(
            id: "ask-1",
            questions: [.init(header: "Cleanup", question: "Which strategy should I keep?",
                              options: ["TTL sweep", "Owner driven"], multiSelect: false)],
            askedAt: Date()
        )

        let line = SessionActivity.line(for: subject)

        XCTAssertEqual(line.text, "Which strategy should I keep?")
        XCTAssertEqual(line.source, .question)
    }

    func testAnAnsweredQuestionStopsBeingTheLine() {
        var subject = session(activity: "Editing SessionStore.swift")
        subject.ask = SessionStore.Ask(
            id: "ask-1",
            questions: [.init(header: "Cleanup", question: "Which strategy should I keep?",
                              options: ["TTL sweep", "Owner driven"], multiSelect: false,
                              answer: ["TTL sweep"])],
            askedAt: Date()
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text, "Editing SessionStore.swift")
    }

    /// A bundle asks two to four things at once. The row has one line,
    /// so it shows the first one still outstanding rather than the first
    /// one in the bundle.
    func testABundleShowsTheFirstQuestionStillWaiting() {
        var subject = session()
        subject.ask = SessionStore.Ask(
            id: "ask-1",
            questions: [
                .init(header: "One", question: "Ship it?", options: ["Yes", "No"],
                      multiSelect: false, answer: ["Yes"]),
                .init(header: "Two", question: "Bump the version?", options: ["Yes", "No"],
                      multiSelect: false),
            ],
            askedAt: Date()
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text, "Bump the version?")
    }

    // MARK: Rung 3, a background agent that stopped for you

    /// Read verbatim from `~/.claude/jobs/<id>/state.json`. The founder's
    /// own August 3 agent sat blocked for three days behind a line the
    /// island never showed.
    func testABlockedBackgroundAgentShowsWhatItNeeds() {
        var subject = session(state: .idle)
        subject.job = SessionStore.JobState(
            state: .blocked,
            needs: "say the word and I'll bump to 1.6.1 and do the proper release",
            detail: "sessions tab fixed; awaiting release decision",
            result: nil, tokens: 384_376
        )

        let line = SessionActivity.line(for: subject)

        XCTAssertEqual(line.text,
                       "say the word and I'll bump to 1.6.1 and do the proper release")
        XCTAssertEqual(line.source, .needs)
    }

    /// `needs` is the ask; `detail` is the note it left about itself.
    /// With no `needs` the note is still a fact worth showing.
    func testABlockedAgentWithoutANeedsLineFallsBackToItsDetail() {
        var subject = session(state: .idle)
        subject.job = SessionStore.JobState(
            state: .blocked, needs: nil,
            detail: "waiting on the release decision", result: nil, tokens: nil
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text,
                       "waiting on the release decision")
    }

    /// A working background agent is not asking for anything, so its
    /// `needs` line, if it left a stale one, must not outrank what it is
    /// doing right now.
    func testAWorkingBackgroundAgentIsNotTreatedAsAsking() {
        var subject = session(activity: "Running the test suite")
        subject.job = SessionStore.JobState(
            state: .working, needs: "an old question nobody cleared",
            detail: nil, result: nil, tokens: nil
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text, "Running the test suite")
    }

    // MARK: Rung 4, a step in flight

    func testAStepInFlightShowsWhatItIsDoing() {
        let line = SessionActivity.line(for: session(activity: "Editing SessionStore.swift"))

        XCTAssertEqual(line.text, "Editing SessionStore.swift")
        XCTAssertEqual(line.source, .doing)
    }

    // MARK: Rung 5, a plan in flight

    func testAPlanInFlightShowsTheStepAndHowFarThrough() {
        var subject = session()
        subject.plan = SessionStore.PlanProgress(
            step: "Running the test suite", done: 2, total: 6
        )

        let line = SessionActivity.line(for: subject)

        XCTAssertEqual(line.text, "Running the test suite · 3 of 6")
        XCTAssertEqual(line.source, .plan)
    }

    /// The transcript is a better witness than the plan: a to-do list
    /// says what the agent means to do, a live tool call says what it is
    /// actually doing.
    func testAStepInFlightOutranksThePlan() {
        var subject = session(activity: "Editing SessionStore.swift")
        subject.plan = SessionStore.PlanProgress(
            step: "Running the test suite", done: 2, total: 6
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text, "Editing SessionStore.swift")
    }

    // MARK: Rung 6, its last words

    func testWithNothingInFlightItShowsWhatTheAgentLastSaid() {
        let subject = session(state: .idle, lastMessage: "Suite is green, 391 tests.")

        let line = SessionActivity.line(for: subject)

        XCTAssertEqual(line.text, "Suite is green, 391 tests.")
        XCTAssertEqual(line.source, .said)
    }

    func testOnlyTheFirstLineOfALongAnswerIsShown() {
        let subject = session(
            state: .idle,
            lastMessage: "Suite is green, 391 tests.\n\nThe flaky focus test still fails."
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text, "Suite is green, 391 tests.")
    }

    // MARK: Rung 7, nothing at all

    /// The floor is a fact, never a mood. "Started 18:46" is checkable
    /// against the clock; "Working" is not checkable against anything.
    func testASessionWithNothingToSayReportsWhenItStarted() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 6
        components.hour = 18; components.minute = 46
        let started = Calendar.current.date(from: components)!

        let line = SessionActivity.line(for: session(state: .idle, startedAt: started))

        XCTAssertEqual(line.text, "Started 18:46")
        XCTAssertEqual(line.source, .started)
    }

    func testNoRungEverReturnsAMoodWord() {
        let moods = ["Working", "Needs you", "At its prompt", "Idle", "Finished"]
        for state in [SessionStore.State.working, .idle, .needsInput, .done, .stale] {
            let text = SessionActivity.line(for: session(state: state)).text
            XCTAssertFalse(moods.contains(text),
                           "\(state) fell back to the mood word \(text)")
        }
    }

    // MARK: Order

    /// The whole point of the ladder. A held call outranks a question,
    /// which outranks a needs line, which outranks live work.
    func testAHeldCallOutranksEverythingElse() {
        var subject = session(activity: "Editing SessionStore.swift",
                              lastMessage: "Suite is green.")
        subject.plan = SessionStore.PlanProgress(step: "Running tests", done: 1, total: 3)
        subject.job = SessionStore.JobState(state: .blocked, needs: "say the word",
                                            detail: nil, result: nil, tokens: nil)
        subject.ask = SessionStore.Ask(
            id: "ask-1",
            questions: [.init(header: "H", question: "Ship it?", options: ["Yes", "No"],
                              multiSelect: false)],
            askedAt: Date()
        )
        subject.approval = SessionStore.Approval(
            id: "call-1", tool: "Bash", detail: "rm -rf build", askedAt: Date()
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text, "rm -rf build")
    }

    func testAQuestionOutranksANeedsLineAndLiveWork() {
        var subject = session(activity: "Editing SessionStore.swift")
        subject.job = SessionStore.JobState(state: .blocked, needs: "say the word",
                                            detail: nil, result: nil, tokens: nil)
        subject.ask = SessionStore.Ask(
            id: "ask-1",
            questions: [.init(header: "H", question: "Ship it?", options: ["Yes", "No"],
                              multiSelect: false)],
            askedAt: Date()
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text, "Ship it?")
    }

    // MARK: What a finished session leaves behind

    func testAFinishedBackgroundAgentShowsItsResult() {
        var subject = session(state: .done)
        subject.job = SessionStore.JobState(
            state: .done, needs: nil, detail: nil,
            result: "fixed: stuck states, wrong times, messages not landing", tokens: nil
        )

        let line = SessionActivity.line(for: subject)

        XCTAssertEqual(line.text, "fixed: stuck states, wrong times, messages not landing")
        XCTAssertEqual(line.source, .result)
    }

    // MARK: The rail's own line

    /// Claude Code names a session after its work, so two agents in one
    /// repo get one name. The old rail traded the branch for a start
    /// time to tell them apart; the line now carries what each is doing,
    /// which usually differs, and the start time is appended only when
    /// the titles actually collide.
    func testCollidingRowsKeepAStartTimeBesideTheirLine() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 6
        components.hour = 18; components.minute = 46
        let started = Calendar.current.date(from: components)!
        let subject = session(activity: "Editing SessionStore.swift", startedAt: started)

        XCTAssertEqual(SessionActivity.railLine(for: subject, disambiguating: true),
                       "Editing SessionStore.swift · from 18:46")
        XCTAssertEqual(SessionActivity.railLine(for: subject, disambiguating: false),
                       "Editing SessionStore.swift")
    }

    /// A row whose line is already its start time must not say it twice.
    func testARowWithNothingToSayIsNotDisambiguatedIntoNonsense() {
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 6
        components.hour = 18; components.minute = 46
        let started = Calendar.current.date(from: components)!

        XCTAssertEqual(
            SessionActivity.railLine(for: session(state: .idle, startedAt: started),
                                     disambiguating: true),
            "Started 18:46")
    }

    // MARK: What a finished row says

    func testAFinishedRowShowsWhatItCameBackWith() {
        let record = SessionStore.Finished(
            id: "s", title: "Push changes to PR", cwd: "/a/moai", branch: "main",
            agent: .claude, outcome: .done,
            lastMessage: "Merged and released 1.6.0.\nCI is green.",
            transcriptPath: nil, finishedAt: Date()
        )

        XCTAssertEqual(SessionActivity.line(for: record).text, "Merged and released 1.6.0.")
    }

    /// `lost` is the registry losing sight of a process, which
    /// `markGone` already refuses to call finishing. The row says the
    /// same honest thing.
    func testAFinishedRowWithNoLastWordsSaysWhatBecameOfIt() {
        let record = SessionStore.Finished(
            id: "s", title: "Push changes to PR", cwd: "/a/moai", branch: nil,
            agent: .claude, outcome: .lost, lastMessage: nil,
            transcriptPath: nil, finishedAt: Date()
        )

        XCTAssertEqual(SessionActivity.line(for: record).text, "Stopped without finishing")
    }

    // MARK: Whitespace

    func testAMultilineNeedsLineIsFlattenedRatherThanTruncated() {
        var subject = session(state: .idle)
        subject.job = SessionStore.JobState(
            state: .blocked,
            needs: "say the word\nand I'll do the release", detail: nil,
            result: nil, tokens: nil
        )

        XCTAssertEqual(SessionActivity.line(for: subject).text,
                       "say the word and I'll do the release")
    }
}
