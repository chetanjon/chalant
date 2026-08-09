import XCTest
@testable import Chalant

/// Writing Cursor's and Codex's own hooks files.
///
/// The first time this app has written either. The standing rule was
/// that it never would, and the rule was written when there was nothing
/// to write; the reversal is deliberate and behind a button, and it
/// inherits every safety the Claude Code writer has, because it is the
/// same hazard: somebody else's configured hooks disappearing.
@MainActor
final class OtherAgentsTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("hooks.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: file)) as? [String: Any])
    }

    private func events(_ object: [String: Any]) -> [String: Any] {
        (object["hooks"] as? [String: Any]) ?? [:]
    }

    // MARK: Cursor

    func testCursorGetsItsOwnFlatShapeNotClaudeCodes() {
        // Cursor's entry is flat: the command sits on the entry itself,
        // with no inner `hooks` array. Writing Claude Code's nesting
        // here would produce a file Cursor reads as having no hooks at
        // all, and nothing anywhere would say so.
        let entry = HookInstall.cursorGateEntry(path: "/x/chalant-gate", endpoint: "gate")
        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertEqual(entry["command"] as? String, "/x/chalant-gate cursor gate")
        XCTAssertNil(entry["hooks"], "Cursor's shape has no inner hooks array")
    }

    func testArmingCursorWritesBothDecisionPointsAndAVersion() throws {
        guard case .armed = HookInstall.armCursor(at: file) else {
            throw XCTSkip("no bundled gate script in this test host")
        }
        let object = try read()
        // A hooks file without a version may not be read at all.
        XCTAssertEqual(object["version"] as? Int, 1)
        for event in HookInstall.cursorGateEvents {
            let entries = try XCTUnwrap(events(object)[event] as? [[String: Any]], event)
            XCTAssertTrue(entries.contains {
                (($0["command"] as? String) ?? "").contains("chalant-gate")
            }, "\(event) is missing the gate")
        }
        XCTAssertTrue(HookInstall.cursorAnswers(at: file))
    }

    func testArmingCursorKeepsEveryHookAlreadyThere() throws {
        try #"""
        {"version": 1, "hooks": {
           "beforeShellExecution": [{"command": "/theirs/check.sh", "type": "command"}],
           "afterFileEdit": [{"command": "/theirs/format.sh", "type": "command"}]
        }}
        """#.write(to: file, atomically: true, encoding: .utf8)
        guard case .armed = HookInstall.armCursor(at: file) else {
            throw XCTSkip("no bundled gate script in this test host")
        }
        let object = try read()
        XCTAssertNotNil(events(object)["afterFileEdit"])
        let shell = try XCTUnwrap(events(object)["beforeShellExecution"] as? [[String: Any]])
        XCTAssertEqual(shell.count, 2, "somebody else's shell hook must survive")
        XCTAssertTrue(shell.contains { ($0["command"] as? String) == "/theirs/check.sh" })
    }

    func testDisarmingCursorTakesOutOnlyOurs() throws {
        try #"""
        {"version": 1, "hooks": {"beforeShellExecution": [
            {"command": "/theirs/check.sh", "type": "command"}]}}
        """#.write(to: file, atomically: true, encoding: .utf8)
        guard case .armed = HookInstall.armCursor(at: file) else {
            throw XCTSkip("no bundled gate script in this test host")
        }
        HookInstall.disarmCursor(at: file)
        let object = try read()
        let shell = try XCTUnwrap(events(object)["beforeShellExecution"] as? [[String: Any]])
        XCTAssertEqual(shell.count, 1)
        XCTAssertEqual(shell[0]["command"] as? String, "/theirs/check.sh")
        XCTAssertFalse(HookInstall.cursorAnswers(at: file))
    }

    func testArmingCursorTwiceWritesNothingTheSecondTime() throws {
        guard case .armed = HookInstall.armCursor(at: file) else {
            throw XCTSkip("no bundled gate script in this test host")
        }
        XCTAssertEqual(HookInstall.armCursor(at: file), .alreadyArmed)
    }

    func testUnparseableCursorSettingsAreRefusedAndLeftAlone() throws {
        let junk = "{ not json at all"
        try junk.write(to: file, atomically: true, encoding: .utf8)
        guard case .refused = HookInstall.armCursor(at: file) else {
            return XCTFail("a file this app cannot read must never be rewritten")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), junk)
    }

    // MARK: Codex

    func testCodexGetsClaudeCodesNestedShape() {
        let entry = HookInstall.codexGateEntry(path: "/x/chalant-gate")
        let inner = (entry["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(inner?["command"] as? String, "/x/chalant-gate codex gate")
        XCTAssertEqual(inner?["type"] as? String, "command")
        XCTAssertNil(entry["command"], "Codex's shape nests, unlike Cursor's")
    }

    func testArmingCodexMergesAndDisarmingUnmerges() throws {
        try #"""
        {"hooks": {"PreToolUse": [{"hooks": [
            {"type": "command", "command": "/theirs/audit"}]}]}}
        """#.write(to: file, atomically: true, encoding: .utf8)
        guard case .armed = HookInstall.armCodex(at: file) else {
            throw XCTSkip("no bundled gate script in this test host")
        }
        var entries = try XCTUnwrap(events(try read())["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(HookInstall.codexAnswers(at: file))

        HookInstall.disarmCodex(at: file)
        entries = try XCTUnwrap(events(try read())["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue((entries[0]["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String) == "/theirs/audit"
        } ?? false)
        XCTAssertFalse(HookInstall.codexAnswers(at: file))
    }

    func testDisarmingCodexDropsTheEventWhenOnlyOursWasThere() throws {
        guard case .armed = HookInstall.armCodex(at: file) else {
            throw XCTSkip("no bundled gate script in this test host")
        }
        HookInstall.disarmCodex(at: file)
        XCTAssertNil(events(try read())["PreToolUse"],
                     "an empty event list left behind is litter in somebody's config")
    }

    // MARK: The queue they share

    func testACallCarriesWhichAgentItCameFromOntoItsRow() throws {
        // Claude Code never sends this and never needs to. The shim adds
        // it, because a row with the wrong mark on it is a row about
        // somebody else's agent.
        let payload: [String: Any] = [
            "session_id": "cursor-9", "cwd": "/tmp/kizu", "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build"], "tool_use_id": "t1",
            "agent": "cursor",
        ]
        let call = try XCTUnwrap(HookPayload.call(from: payload, fallbackID: "f"))
        XCTAssertEqual(call.agent, .cursor)

        var codex = payload
        codex["agent"] = "codex"
        XCTAssertEqual(HookPayload.call(from: codex, fallbackID: "f")?.agent, .codex)

        // Absent, or a word this app does not know, reads as Claude Code:
        // that is who has always been on the other end of this endpoint.
        var unknown = payload
        unknown["agent"] = "borg"
        XCTAssertEqual(HookPayload.call(from: unknown, fallbackID: "f")?.agent, .claude)
        var absent = payload
        absent.removeValue(forKey: "agent")
        XCTAssertEqual(HookPayload.call(from: absent, fallbackID: "f")?.agent, .claude)
    }

    func testThreeAgentsShareOneQueueAndKeepTheirOwnMarks() {
        let store = SessionStore()
        _ = store.holdForPrompt(sessionID: "a", id: "t1", tool: "Bash", detail: "sudo reboot",
                                cwd: "/tmp/one", patience: 600, agent: .cursor)
        _ = store.holdForPrompt(sessionID: "b", id: "t2", tool: "Bash", detail: "git push --force",
                                cwd: "/tmp/two", patience: 600, agent: .codex)
        _ = store.holdForPrompt(sessionID: "c", id: "t3", tool: "Write", detail: "/etc/hosts",
                                cwd: "/tmp/three", patience: 600, agent: .claude)

        let held = store.sessions.filter { $0.approval != nil }
        XCTAssertEqual(held.count, 3)
        XCTAssertEqual(Set(held.map(\.agent)), [.cursor, .codex, .claude])
    }
}
