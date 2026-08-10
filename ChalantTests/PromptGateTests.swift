import XCTest
@testable import Chalant

/// Wiring the held call to the card: what the island shows, what a tap
/// reaches, and what the config file it writes actually says.
///
/// Nothing here touches `~/.claude/settings.json`. Every write goes
/// through the `at:` seam, for the reason `ArmingTests` gives.
@MainActor
final class PromptGateTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant-prompts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: settings)) as? [String: Any])
    }

    private func promptEntries(_ object: [String: Any]) -> [[String: Any]] {
        ((object["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? []
    }

    // MARK: A prompt reaching the row

    func testAPromptIsHeldWithNoRulesArmedAtAll() {
        // The arming rules decide which calls to INTERRUPT. This one was
        // already interrupted: Claude Code decided it needs a person.
        // Running it past the rules would leave the island silent about
        // the one question that is definitely being asked, which is how
        // 1.7.0 ended up reporting prompts it could not answer.
        let store = SessionStore()
        let surfaced = store.holdForPrompt(
            sessionID: "s1", id: "toolu_1", tool: "Bash",
            detail: "git push --force origin main", cwd: "/tmp/repo", patience: 600)

        XCTAssertTrue(surfaced)
        let approval = store.sessions.first { $0.id == "s1" }?.approval
        XCTAssertEqual(approval?.tool, "Bash")
        XCTAssertEqual(approval?.detail, "git push --force origin main")
        XCTAssertNil(approval?.decision)
    }

    func testAHeldPromptCarriesTheRealPatienceAndSaysItIsAlsoInTheTerminal() {
        let store = SessionStore()
        _ = store.holdForPrompt(
            sessionID: "s1", id: "toolu_1", tool: "Bash", detail: "ls",
            cwd: "/tmp", patience: 600)
        let approval = store.sessions.first { $0.id == "s1" }?.approval
        XCTAssertEqual(approval?.patience, 600)
        XCTAssertEqual(approval?.alsoInTerminal, true)
    }

    func testAGateHeldCallCarriesItsHooksRealPatienceAndOwnsTheScreen() {
        // The gate is an HTTP hook now: the agent waits out its own
        // configured timeout, suspended inside the request, and its
        // prompt is not on screen anywhere else.
        let store = SessionStore()
        _ = store.holdForApproval(
            sessionID: "s1", id: "toolu_1", tool: "Bash", detail: "ls", cwd: "/tmp",
            patience: 480, rules: ["Bash"])
        let approval = store.sessions.first { $0.id == "s1" }?.approval
        XCTAssertEqual(approval?.patience, 480)
        XCTAssertEqual(approval?.alsoInTerminal, false)
    }

    func testAnUnknownSessionStillGetsARowSoTheQuestionHasSomewhereToGo() {
        // Anything headless registers nowhere, and the folder is the only
        // name its row will ever have.
        let store = SessionStore()
        XCTAssertTrue(store.sessions.isEmpty)
        _ = store.holdForPrompt(
            sessionID: "headless", id: "t1", tool: "Bash", detail: "ls",
            cwd: "/Users/x/Downloads/kizu", patience: 600)
        XCTAssertEqual(store.sessions.first?.title, "kizu")
    }

    func testTwoSessionsAreHeldAtOnceAndRenderAsTheirOwnRows() {
        // The queue: the island draws one card per row, so two agents at
        // the door are two cards, each with its own answer.
        let store = SessionStore()
        _ = store.holdForPrompt(sessionID: "a", id: "t1", tool: "Bash",
                                detail: "rm -rf build", cwd: "/tmp/one", patience: 600)
        _ = store.holdForPrompt(sessionID: "b", id: "t2", tool: "Write",
                                detail: "/tmp/x.swift", cwd: "/tmp/two", patience: 600)

        let held = store.sessions.compactMap { $0.approval }
        XCTAssertEqual(held.count, 2)
        XCTAssertEqual(Set(held.map(\.id)), ["t1", "t2"])

        store.decide(approvalID: "t1", as: .allow)
        XCTAssertEqual(store.sessions.first { $0.id == "a" }?.approval?.decision, .allow)
        XCTAssertNil(store.sessions.first { $0.id == "b" }?.approval?.decision,
                     "answering one session must not answer the other")
    }

    func testASecondCallOnOneSessionFallsThroughRatherThanReplacingTheFirst() {
        let store = SessionStore()
        XCTAssertTrue(store.holdForPrompt(sessionID: "s1", id: "t1", tool: "Bash",
                                          detail: "one", cwd: "/tmp", patience: 600))
        XCTAssertFalse(store.holdForPrompt(sessionID: "s1", id: "t2", tool: "Bash",
                                           detail: "two", cwd: "/tmp", patience: 600))
        XCTAssertEqual(store.sessions.first?.approval?.id, "t1")
    }

    // MARK: The tap reaching a suspended agent

    func testDecidingTellsWhoeverIsHoldingTheAgent() {
        // The push that the polling shim never needed: an agent
        // suspended inside an HTTP request has to be told, not waited
        // for.
        let store = SessionStore()
        var told: [(String, SessionStore.Approval.Decision)] = []
        store.onDecided = { told.append(($0, $1)) }
        _ = store.holdForPrompt(sessionID: "s1", id: "t1", tool: "Bash",
                                detail: "ls", cwd: "/tmp", patience: 600)

        store.decide(approvalID: "t1", as: .deny)

        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?.0, "t1")
        XCTAssertEqual(told.first?.1, .deny)
    }

    func testDecidingSomethingNobodyIsHoldingTellsNobody() {
        let store = SessionStore()
        var told = 0
        store.onDecided = { _, _ in told += 1 }
        store.decide(approvalID: "never-existed", as: .allow)
        XCTAssertEqual(told, 0)
    }

    func testClearingTakesTheCardOffTheRow() {
        let store = SessionStore()
        _ = store.holdForPrompt(sessionID: "s1", id: "t1", tool: "Bash",
                                detail: "ls", cwd: "/tmp", patience: 600)
        store.clearApproval(id: "t1")
        XCTAssertNil(store.sessions.first?.approval)
    }

    func testTheTwoHooksAboutOnePromptDoNotBecomeTwoCards() {
        // `PermissionRequest` holds the prompt and `Notification` reports
        // it a moment later. Without the guard the row grows a second
        // card about the same question, one saying it cannot be answered
        // while the other is busy answering it.
        let store = SessionStore()
        _ = store.holdForPrompt(sessionID: "s1", id: "t1", tool: "Bash",
                                detail: "ls", cwd: "/tmp", patience: 600)
        store.notePendingPrompt(sessionID: "s1", tool: "Bash", detail: "ls")
        XCTAssertNil(store.sessions.first?.pendingPrompt)
        XCTAssertNotNil(store.sessions.first?.approval)
    }

    func testAPromptCardStillAppearsWhenNothingIsHoldingTheCall() {
        let store = SessionStore()
        _ = store.holdForPrompt(sessionID: "s1", id: "t1", tool: "Bash",
                                detail: "ls", cwd: "/tmp", patience: 600)
        store.clearApproval(id: "t1")
        store.notePendingPrompt(sessionID: "s1", tool: "Bash", detail: "ls")
        XCTAssertNotNil(store.sessions.first?.pendingPrompt)
    }

    // MARK: What the countdown says

    func testTheCountdownTellsTheTruthAboutBothKindsOfWait() {
        let asked = Date(timeIntervalSince1970: 1000)
        func text(_ patience: TimeInterval, _ elapsed: TimeInterval, terminal: Bool) -> String {
            ApprovalCard.remaining(
                patience: patience, askedAt: asked,
                now: asked.addingTimeInterval(elapsed), alsoInTerminal: terminal)
        }
        // The shim's 25 seconds, ticking.
        XCTAssertEqual(text(25, 5, terminal: false), "20s, then it asks the terminal")
        // Ten minutes is a fact about the wait, not a countdown to watch.
        XCTAssertEqual(text(600, 0, terminal: true), "10m, then only the terminal can answer")
        XCTAssertEqual(text(600, 330, terminal: true), "5m, then only the terminal can answer")
        // And it goes back to seconds when seconds start to matter.
        XCTAssertEqual(text(600, 570, terminal: true), "30s, then only the terminal can answer")
        // Run out. The prompt is still on screen in its terminal, so
        // this must not say the call went anywhere.
        XCTAssertEqual(text(600, 601, terminal: true), "only the terminal can answer now")
        XCTAssertEqual(text(25, 26, terminal: false), "back to the terminal")
    }

    // MARK: Writing the hook that makes any of it happen

    func testArmingWritesAnHttpHookWithALiteralToken() throws {
        let outcome = HookInstall.armPrompts(port: 4242, token: "sekrit", at: settings)
        guard case .armed = outcome else { return XCTFail("expected armed, got \(outcome)") }

        let entries = promptEntries(try read())
        XCTAssertEqual(entries.count, 1)
        let hook = try XCTUnwrap((entries[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["type"] as? String, "http")
        XCTAssertEqual(hook["url"] as? String, "http://127.0.0.1:4242/hook/permission-request")
        XCTAssertEqual(hook["timeout"] as? Int, 600)
        // Literal, never `$VAR`: interpolation reads the AGENT's
        // environment, and an unset variable there resolves to an empty
        // string, which is a 401 with nothing anywhere saying why.
        let headers = try XCTUnwrap(hook["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer sekrit")
        XCTAssertFalse(headers["Authorization"]?.contains("$") ?? true)
    }

    func testArmingKeepsEveryOtherHookIncludingAnotherPermissionRequestOne() throws {
        try #"""
        {"hooks": {
          "PermissionRequest": [{"matcher": "", "hooks": [
             {"type": "command", "command": "node /somebody/else/hook.js", "timeout": 5}]}],
          "Stop": [{"hooks": [{"type": "command", "command": "/theirs"}]}]
        }, "effortLevel": "high"}
        """#.write(to: settings, atomically: true, encoding: .utf8)

        HookInstall.armPrompts(port: 4242, token: "t", at: settings)

        let object = try read()
        XCTAssertEqual(object["effortLevel"] as? String, "high")
        XCTAssertNotNil((object["hooks"] as? [String: Any])?["Stop"])
        let entries = promptEntries(object)
        XCTAssertEqual(entries.count, 2, "somebody else's PermissionRequest hook must survive")
        XCTAssertTrue(entries.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("somebody/else") ?? false
            } ?? false
        })
    }

    func testArmingTwiceWritesNothingTheSecondTime() throws {
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        let stamp = try FileManager.default.attributesOfItem(
            atPath: settings.path)[.modificationDate] as? Date
        let again = HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        XCTAssertEqual(again, .alreadyArmed)
        let after = try FileManager.default.attributesOfItem(
            atPath: settings.path)[.modificationDate] as? Date
        XCTAssertEqual(stamp, after)
        XCTAssertEqual(promptEntries(try read()).count, 1)
    }

    func testAMovedPortRewritesTheEntryRatherThanAddingASecond() throws {
        // An installed hook carries this app's address inside somebody
        // else's file. If the port moved because something had 4242,
        // every prompt would post into a closed door.
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        let outcome = HookInstall.armPrompts(port: 4301, token: "t2", at: settings)
        guard case .armed = outcome else { return XCTFail("expected a rewrite") }

        let entries = promptEntries(try read())
        XCTAssertEqual(entries.count, 1, "a moved port must not leave the old entry behind")
        let hook = try XCTUnwrap((entries[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["url"] as? String, "http://127.0.0.1:4301/hook/permission-request")
        XCTAssertEqual((hook["headers"] as? [String: String])?["Authorization"], "Bearer t2")
    }

    func testWhetherPromptsAreAnsweredHereIsReadFromTheFile() throws {
        XCTAssertFalse(HookInstall.answersPrompts(at: settings))
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        XCTAssertTrue(HookInstall.answersPrompts(at: settings))
        HookInstall.disarmPrompts(at: settings)
        XCTAssertFalse(HookInstall.answersPrompts(at: settings))
    }

    func testDisarmTakesOutOnlyOurOwnEntry() throws {
        try #"""
        {"hooks": {"PermissionRequest": [{"matcher": "", "hooks": [
            {"type": "command", "command": "node /theirs.js"}]}]}}
        """#.write(to: settings, atomically: true, encoding: .utf8)
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        XCTAssertEqual(promptEntries(try read()).count, 2)

        HookInstall.disarmPrompts(at: settings)

        let entries = promptEntries(try read())
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue((entries[0]["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("theirs") ?? false
        } ?? false)
    }

    func testDisarmDropsTheEventEntirelyWhenOnlyOursWasThere() throws {
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        HookInstall.disarmPrompts(at: settings)
        let hooks = try XCTUnwrap(try read()["hooks"] as? [String: Any])
        XCTAssertNil(hooks["PermissionRequest"],
                     "an empty event list left behind is litter in somebody's config")
    }

    func testUnparseableSettingsAreRefusedAndLeftExactlyAsTheyWere() throws {
        let junk = "{ this is not json"
        try junk.write(to: settings, atomically: true, encoding: .utf8)
        let outcome = HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        guard case .refused = outcome else { return XCTFail("expected refused, got \(outcome)") }
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), junk)
    }

    func testArmingWithNoServerRunningRefusesRatherThanGuessingAPort() {
        // Without a resolved port there is no address to point Claude
        // Code at, and a guessed one is a hook that posts into nothing.
        let outcome = HookInstall.armPrompts(port: nil, token: nil, at: settings)
        if case .refused = outcome { return }
        // A real server.json on the machine running the tests is a fair
        // reason for this to succeed instead; what must never happen is
        // an entry with no port in it.
        let entries = (try? read()).map(promptEntries) ?? []
        for entry in entries {
            let url = ((entry["hooks"] as? [[String: Any]])?.first?["url"] as? String) ?? ""
            XCTAssertTrue(url.contains("127.0.0.1:"), "no port was resolved but one was written")
        }
    }

    func testTheSwitchAlsoInstallsTheTwoThatSayAQuestionIsOver() throws {
        // A prompt answered in its own terminal, or on a phone through
        // Remote Control, closes nothing this app can see. Stop is the
        // only proof it gets, because a turn cannot end while a prompt
        // is standing.
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        let hooks = try XCTUnwrap(try read()["hooks"] as? [String: Any])
        for event in ["PermissionRequest", "Elicitation", "Stop", "SessionEnd"] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "\(event) missing")
            let hook = try XCTUnwrap((entries.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(hook["type"] as? String, "http")
            XCTAssertTrue((hook["url"] as? String)?.hasPrefix("http://127.0.0.1:4242/hook/") ?? false)
        }
        // The two lifecycle ones never wait on a person, so they must
        // not carry a person's timeout.
        let stop = try XCTUnwrap(((hooks["Stop"] as? [[String: Any]])?.first?["hooks"]
            as? [[String: Any]])?.first)
        XCTAssertEqual(stop["timeout"] as? Int, HookInstall.lifecycleTimeout)
    }

    func testTurningItOffTakesAllFourBackOut() throws {
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        HookInstall.disarmPrompts(at: settings)
        let hooks = try XCTUnwrap(try read()["hooks"] as? [String: Any])
        for event in ["PermissionRequest", "Elicitation", "Stop", "SessionEnd"] {
            XCTAssertNil(hooks[event], "\(event) was left behind")
        }
    }

    func testDisarmLeavesSomebodyElsesStopHookAlone() throws {
        try #"""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/theirs"}]}]}}
        """#.write(to: settings, atomically: true, encoding: .utf8)
        HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        HookInstall.disarmPrompts(at: settings)
        let hooks = try XCTUnwrap(try read()["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertTrue((stop[0]["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String) == "/theirs"
        } ?? false)
    }

    func testTheOldFileIsCopiedAsideBeforeItIsChanged() throws {
        try #"{"hooks": {}, "mine": true}"#.write(to: settings, atomically: true, encoding: .utf8)
        let outcome = HookInstall.armPrompts(port: 4242, token: "t", at: settings)
        guard case .armed(let backup) = outcome, let backup else {
            return XCTFail("expected a backup path, got \(outcome)")
        }
        let copied = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: URL(fileURLWithPath: backup))) as? [String: Any])
        XCTAssertEqual(copied["mine"] as? Bool, true)
        XCTAssertTrue(promptEntries(copied).isEmpty, "the backup is the file from BEFORE")
    }
}
