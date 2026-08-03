import XCTest
@testable import Chalant

/// The conversation reader.
///
/// Every record shape below was taken from a real Claude Code
/// transcript on 2026-08-03 rather than imagined, because the two
/// mistakes that are easy to make here both look reasonable on paper:
/// treating `promptSource == "typed"` as the test for a human turn (it
/// drops a message queued through this app's own outbox), and letting
/// `isSidechain` records through (it threads a subagent's whole
/// conversation into its parent's).
@MainActor
final class TranscriptTurnsTests: XCTestCase {
    private typealias Turn = SessionDiscovery.Turn

    // MARK: Fixtures, in the real file's shape

    private func human(_ text: String, uuid: String = "u1", at: String = "2026-08-03T16:06:30.174Z") -> String {
        """
        {"type":"user","uuid":"\(uuid)","timestamp":"\(at)","isSidechain":false,\
        "promptSource":"typed","userType":"external","message":{"role":"user","content":"\(text)"}}
        """
    }

    private func agentSaid(_ text: String, uuid: String = "a1", at: String = "2026-08-03T16:06:42.000Z") -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(at)","isSidechain":false,\
        "message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    private func agentThought(_ text: String, uuid: String = "t1") -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"2026-08-03T16:06:41.000Z",\
        "message":{"role":"assistant","content":[{"type":"thinking","thinking":"\(text)"}]}}
        """
    }

    private func toolCall(
        _ tool: String, id: String, input: String,
        uuid: String = "c1", at: String = "2026-08-03T16:06:44.000Z"
    ) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(at)","isSidechain":false,\
        "message":{"role":"assistant","content":[{"type":"tool_use","id":"\(id)",\
        "name":"\(tool)","input":\(input)}]}}
        """
    }

    private func toolResult(_ id: String, uuid: String = "r1", at: String = "2026-08-03T16:06:45.000Z") -> String {
        """
        {"type":"user","uuid":"\(uuid)","timestamp":"\(at)","isSidechain":false,\
        "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(id)",\
        "content":"ok"}]}}
        """
    }

    private func parse(_ lines: [String], skippingFirstLine: Bool = false) -> [Turn] {
        SessionDiscovery.parseTurns(lines.joined(separator: "\n"), skippingFirstLine: skippingFirstLine)
    }

    // MARK: Order and shape

    func testFileOrderIsTurnOrder() {
        let turns = parse([
            human("push the changes"),
            toolCall("Bash", id: "t1", input: #"{"command":"git push"}"#),
            toolResult("t1"),
            agentSaid("pushed"),
        ])
        XCTAssertEqual(turns.count, 3)
        guard case let .said(who, text) = turns[0].kind else { return XCTFail("first is a turn") }
        XCTAssertEqual(who, .you)
        XCTAssertEqual(text, "push the changes")
        guard case let .did(tool, detail, _, finishedAt) = turns[1].kind else { return XCTFail("second is a call") }
        XCTAssertEqual(tool, "Bash")
        XCTAssertEqual(detail, "git push")
        XCTAssertNotNil(finishedAt)
        guard case let .said(speaker, _) = turns[2].kind else { return XCTFail("third is a turn") }
        XCTAssertEqual(speaker, .agent)
    }

    /// A human turn arrives with `content` as a bare string, not blocks.
    func testAHumanTurnIsReadFromStringContent() {
        let turns = parse([human("yes, write the spec")])
        XCTAssertEqual(turns.count, 1)
        guard case let .said(who, text) = turns[0].kind else { return XCTFail("a turn") }
        XCTAssertEqual(who, .you)
        XCTAssertEqual(text, "yes, write the spec")
    }

    /// A `user` record carrying a tool_result is a tool returning, not
    /// somebody speaking.
    func testAToolResultIsNotMistakenForAHumanTurn() {
        let turns = parse([toolResult("t1")])
        XCTAssertTrue(turns.isEmpty)
    }

    func testThinkingIsNeverShown() {
        let turns = parse([agentThought("let me consider"), agentSaid("done")])
        XCTAssertEqual(turns.count, 1)
        guard case let .said(_, text) = turns[0].kind else { return XCTFail("a turn") }
        XCTAssertEqual(text, "done")
    }

    /// A `Task` call in the main thread already says a subagent was
    /// dispatched. Threading its own conversation in would make the pane
    /// unreadable in exactly the sessions where reading it matters most.
    func testSidechainRecordsAreDropped() {
        let sub = """
        {"type":"assistant","uuid":"s1","timestamp":"2026-08-03T16:06:50.000Z","isSidechain":true,\
        "message":{"role":"assistant","content":[{"type":"text","text":"subagent talking"}]}}
        """
        let turns = parse([agentSaid("parent talking"), sub])
        XCTAssertEqual(turns.count, 1)
        guard case let .said(_, text) = turns[0].kind else { return XCTFail("a turn") }
        XCTAssertEqual(text, "parent talking")
    }

    func testAnEmptyTextBlockIsNotATurn() {
        let turns = parse([agentSaid("   "), agentSaid("real", uuid: "a2")])
        XCTAssertEqual(turns.count, 1)
    }

    // MARK: Live calls

    /// No `tool_result` in the tail is how the in-flight call is known,
    /// and it is the whole reason a working session stops being an
    /// opaque spinner.
    func testACallWithNoResultIsTheLiveOne() {
        let turns = parse([
            toolCall("Bash", id: "t1", input: #"{"command":"echo one"}"#, uuid: "c1"),
            toolResult("t1"),
            toolCall("Bash", id: "t2", input: #"{"command":"xcodebuild test"}"#, uuid: "c2"),
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertFalse(turns[0].isLive)
        XCTAssertTrue(turns[1].isLive)
    }

    // MARK: Robustness, the laws parseMetadata already holds

    func testAMalformedLineIsSkippedWithoutTakingTheFileDown() {
        let turns = parse([
            human("first"),
            "{not json at all",
            "",
            agentSaid("second"),
        ])
        XCTAssertEqual(turns.count, 2)
    }

    func testATailBeginningMidLineDropsOnlyThatLine() {
        let turns = parse([
            #"pe":"user","message":{"content":"half a record"}}"#,
            human("whole record"),
        ], skippingFirstLine: true)
        XCTAssertEqual(turns.count, 1)
        guard case let .said(_, text) = turns[0].kind else { return XCTFail("a turn") }
        XCTAssertEqual(text, "whole record")
    }

    func testTheTurnListIsBounded() {
        let lines = (0..<(SessionDiscovery.maxTurns + 20)).map {
            agentSaid("line \($0)", uuid: "a\($0)")
        }
        let turns = parse(lines)
        XCTAssertEqual(turns.count, SessionDiscovery.maxTurns)
        // The tail of the conversation, not its head: the newest turns
        // are the ones worth keeping.
        guard case let .said(_, text) = turns.last?.kind else { return XCTFail("a turn") }
        XCTAssertEqual(text, "line \(SessionDiscovery.maxTurns + 19)")
    }

    /// A row keeps its identity across re-reads, so a growing transcript
    /// does not make every line look new to SwiftUI.
    func testIdentityComesFromTheRecordNotItsPosition() {
        let first = parse([human("a", uuid: "u1"), agentSaid("b", uuid: "a1")])
        let second = parse([agentSaid("b", uuid: "a1")])
        XCTAssertEqual(first.last?.id, second.last?.id)
    }

    // MARK: Tool detail

    func testEachRecognisedToolNamesTheRightField() {
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "Bash", input: ["command": "git rebase origin/main"]),
            "git rebase origin/main")
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "Read", input: ["file_path": "/a/b/Chalant/Views/Theme.swift"]),
            "Views/Theme.swift")
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "Edit", input: ["file_path": "/a/SessionStore.swift"]),
            "a/SessionStore.swift")
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "Grep", input: ["pattern": "stateSince"]), "stateSince")
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "Task", input: ["description": "Find flaky tests"]),
            "Find flaky tests")
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "WebSearch", input: ["query": "swift didSet"]),
            "swift didSet")
    }

    /// A line reading "Ran" is honest about knowing only the verb. A
    /// wrong guess about an unknown tool's shape reads as a fact.
    func testAnUnrecognisedToolGetsNoDetailRatherThanAGuess() {
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "SomeFutureTool", input: ["thing": "value"]), "")
    }

    /// A heredoc would otherwise turn one row of the conversation into a
    /// page of it.
    func testOnlyTheFirstLineOfACommandSurvives() {
        XCTAssertEqual(
            SessionDiscovery.toolDetail(tool: "Bash", input: ["command": "cat <<EOF\nlots\nmore\nEOF"]),
            "cat <<EOF")
    }

    func testDetailIsBounded() {
        let long = String(repeating: "x", count: 200)
        let detail = SessionDiscovery.toolDetail(tool: "Bash", input: ["command": long])
        XCTAssertEqual(detail.count, SessionDiscovery.detailLimit)
        XCTAssertTrue(detail.hasSuffix("\u{2026}"))
    }

    func testTheVerbIsInTheTenseTheCallIsIn() {
        XCTAssertEqual(SessionDiscovery.turnVerb(forTool: "Bash", live: true), "Running")
        XCTAssertEqual(SessionDiscovery.turnVerb(forTool: "Bash", live: false), "Ran")
        XCTAssertEqual(SessionDiscovery.turnVerb(forTool: "Read", live: false), "Read")
        XCTAssertEqual(SessionDiscovery.turnVerb(forTool: "SomeFutureTool", live: false), "SomeFutureTool")
    }

    // MARK: Reading a real file

    func testReadingATranscriptFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant-turns-\(UUID().uuidString).jsonl")
        let body = [human("hello"), agentSaid("hi")].joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let turns = try XCTUnwrap(SessionDiscovery.turns(atTranscript: url.path))
        XCTAssertEqual(turns.count, 2)
    }

    func testAMissingFileReadsAsNilRatherThanEmpty() {
        XCTAssertNil(SessionDiscovery.turns(atTranscript: "/nope/does/not/exist.jsonl"))
    }
}
