import XCTest
@testable import Chalant

/// The gate's half of the contract: an agent suspended inside its own
/// hook, and an answer that reaches it exactly once.
final class HookGateTests: XCTestCase {

    private func call(
        id: String = "toolu_1", session: String = "s1", tool: String = "Bash",
        detail: String = "git push --force origin main"
    ) -> HeldCall {
        HeldCall(
            id: id, sessionID: session, tool: tool, detail: detail,
            cwd: "/tmp", permissionMode: "default", transcriptPath: "",
            event: "PermissionRequest", askedAt: Date()
        )
    }

    // MARK: Holding and answering

    func testAHeldCallSuspendsUntilSomebodyDecides() async {
        let store = PendingDecisionStore()
        let held = call()

        async let answer = store.hold(held)
        // The hold has to be registered before it can be answered, and
        // nothing about `async let` promises it has started yet.
        await waitUntilHeld(held.id, in: store)
        let resolved = await store.resolve(held.id, as: .allow)

        let decision = await answer
        XCTAssertTrue(resolved)
        XCTAssertEqual(decision, .allow)
        let outstanding = await store.count
        XCTAssertEqual(outstanding, 0)
    }

    func testDenyTravelsBackAsDeny() async {
        let store = PendingDecisionStore()
        let held = call()
        async let answer = store.hold(held)
        await waitUntilHeld(held.id, in: store)
        await store.resolve(held.id, as: .deny)
        let decision = await answer
        XCTAssertEqual(decision, .deny)
    }

    func testASecondAnswerFindsNothingAndDoesNothing() async {
        // Resuming a continuation twice is a trap, not a race you lose
        // quietly. A double tap, or a tap racing a hang-up, must be
        // survivable: the second one finds the id already gone.
        let store = PendingDecisionStore()
        let held = call()
        async let answer = store.hold(held)
        await waitUntilHeld(held.id, in: store)

        let first = await store.resolve(held.id, as: .allow)
        let second = await store.resolve(held.id, as: .deny)
        let third = await store.abandon(held.id)

        XCTAssertTrue(first)
        XCTAssertFalse(second, "a second answer must not resume anything")
        XCTAssertFalse(third, "a hang-up after an answer must not resume anything")
        let decision = await answer
        XCTAssertEqual(decision, .allow, "the first answer is the one that counts")
    }

    func testAnAgentThatWalksAwayStopsBeingHeld() async {
        let store = PendingDecisionStore()
        let held = call()
        async let answer = store.hold(held)
        await waitUntilHeld(held.id, in: store)

        let abandoned = await store.abandon(held.id)
        let decision = await answer

        XCTAssertTrue(abandoned)
        // Never allow, and never deny either: the agent's own permission
        // flow gets the call back untouched.
        XCTAssertEqual(decision, .abstain)
        let outstanding = await store.count
        XCTAssertEqual(outstanding, 0)
    }

    func testTheSameIdTwiceDoesNotStrandTheFirstWaiter() async {
        // Two hooks quoting one tool_use_id is the same question
        // arriving again, not a second one. Displacing the first waiter
        // would leave an agent suspended with nobody holding its
        // continuation, which is a hang with no timeout but its own.
        let store = PendingDecisionStore()
        let held = call()
        async let first = store.hold(held)
        await waitUntilHeld(held.id, in: store)

        let second = await store.hold(held)
        XCTAssertEqual(second, .abstain, "the duplicate falls through instead of taking over")

        await store.resolve(held.id, as: .allow)
        let answer = await first
        XCTAssertEqual(answer, .allow, "the original waiter is still the one answered")
    }

    func testTwoSessionsAreHeldAndAnsweredIndependently() async {
        // The queue case: two agents at the door at once, answered in
        // the opposite order to the one they arrived in.
        let store = PendingDecisionStore()
        let one = call(id: "toolu_one", session: "s1", tool: "Bash", detail: "rm -rf build")
        let two = call(id: "toolu_two", session: "s2", tool: "Write", detail: "/tmp/x.swift")

        async let firstAnswer = store.hold(one)
        async let secondAnswer = store.hold(two)
        await waitUntilHeld(one.id, in: store)
        await waitUntilHeld(two.id, in: store)

        let both = await store.count
        XCTAssertEqual(both, 2)

        await store.resolve(two.id, as: .allow)
        await store.resolve(one.id, as: .deny)

        let results = await (firstAnswer, secondAnswer)
        XCTAssertEqual(results.0, .deny)
        XCTAssertEqual(results.1, .allow)
    }

    func testHeldCallsAreListedOldestFirst() async {
        let store = PendingDecisionStore()
        let older = HeldCall(
            id: "a", sessionID: "s1", tool: "Bash", detail: "ls", cwd: "/tmp",
            permissionMode: "default", transcriptPath: "", event: "PermissionRequest",
            askedAt: Date(timeIntervalSince1970: 100))
        let newer = HeldCall(
            id: "b", sessionID: "s2", tool: "Bash", detail: "ls", cwd: "/tmp",
            permissionMode: "default", transcriptPath: "", event: "PermissionRequest",
            askedAt: Date(timeIntervalSince1970: 200))
        async let first = store.hold(newer)
        await waitUntilHeld(newer.id, in: store)
        async let second = store.hold(older)
        await waitUntilHeld(older.id, in: store)

        let held = await store.held
        XCTAssertEqual(held.map(\.id), ["a", "b"])

        await store.abandon("a")
        await store.abandon("b")
        _ = await (first, second)
    }

    private func waitUntilHeld(
        _ id: String, in store: PendingDecisionStore, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await store.isHeld(id) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("\(id) was never held", file: file, line: line)
    }

    // MARK: The two schemas that are not the same schema

    func testPermissionRequestAndPreToolUseAnswerInDifferentShapes() throws {
        // This is the whole reason the shipped card says Chalant cannot
        // answer a permission prompt. The note behind that claim says a
        // `permissionDecision` was returned on `PermissionRequest` and
        // ignored, and it would be: that is the PreToolUse field.
        // PermissionRequest wants a `decision` object with a `behavior`
        // in it. Same event family, different shape, and the wrong one
        // is accepted in silence and simply does nothing.
        let permission = try output(of: XCTUnwrap(
            HookPayload.response(for: .allow, event: "PermissionRequest")))
        XCTAssertEqual(permission["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((permission["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        XCTAssertNil(permission["permissionDecision"],
                     "the PreToolUse field must never appear on a PermissionRequest answer")

        let pre = try output(of: XCTUnwrap(
            HookPayload.response(for: .allow, event: "PreToolUse")))
        XCTAssertEqual(pre["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(pre["permissionDecision"] as? String, "allow")
        XCTAssertNil(pre["decision"],
                     "the PermissionRequest field must never appear on a PreToolUse answer")
    }

    func testDenyKeepsItsShapeToo() throws {
        let permission = try output(of: XCTUnwrap(
            HookPayload.response(for: .deny, event: "PermissionRequest")))
        XCTAssertEqual((permission["decision"] as? [String: Any])?["behavior"] as? String, "deny")

        let pre = try output(of: XCTUnwrap(
            HookPayload.response(for: .deny, event: "PreToolUse")))
        XCTAssertEqual(pre["permissionDecision"] as? String, "deny")
        XCTAssertFalse((pre["permissionDecisionReason"] as? String ?? "").isEmpty)
    }

    func testSilenceIsNotApproval() {
        // An empty body is "no opinion". Writing it as an allow would
        // turn every payload this app fails to read into a yes.
        XCTAssertNil(HookPayload.response(for: .abstain, event: "PermissionRequest"))
        XCTAssertNil(HookPayload.response(for: .abstain, event: "PreToolUse"))
    }

    private func output(of json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap((object as? [String: Any])?["hookSpecificOutput"] as? [String: Any])
    }

    // MARK: Reading what an agent actually sends

    /// The exact payload the installed Claude Code (2.1.226) posted to a
    /// throwaway HTTP hook, field for field.
    private var livePayload: [String: Any] {
        [
            "session_id": "d55e87a2-973d-42ad-b5f0-1d1641dd98ed",
            "prompt_id": "01fb1f47-bcf1-42df-a624-ed6702f86df2",
            "transcript_path": "/Users/x/.claude/projects/-Users-x/d55e87a2.jsonl",
            "cwd": "/Users/x/Downloads/chalant-phase0",
            "permission_mode": "default",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_use_id": "toolu_01HLicUdKzQVArCXd2nSKBCq",
            "tool_input": ["command": "touch hello.txt", "description": "Create empty file"],
            "effort": "high",
        ]
    }

    func testALivePayloadReadsCleanly() throws {
        let call = try XCTUnwrap(HookPayload.call(from: livePayload, fallbackID: "fallback"))
        XCTAssertEqual(call.id, "toolu_01HLicUdKzQVArCXd2nSKBCq")
        XCTAssertEqual(call.sessionID, "d55e87a2-973d-42ad-b5f0-1d1641dd98ed")
        XCTAssertEqual(call.tool, "Bash")
        XCTAssertEqual(call.detail, "touch hello.txt", "the command itself, never a paraphrase")
        XCTAssertEqual(call.cwd, "/Users/x/Downloads/chalant-phase0")
        XCTAssertEqual(call.permissionMode, "default")
    }

    func testAPayloadWithNothingToActOnIsRefused() {
        // Refused means the agent carries on through its own permission
        // flow, which is the right outcome and never an error worth
        // interrupting anybody over.
        var noSession = livePayload
        noSession["session_id"] = ""
        XCTAssertNil(HookPayload.call(from: noSession, fallbackID: "f"))

        var noTool = livePayload
        noTool.removeValue(forKey: "tool_name")
        XCTAssertNil(HookPayload.call(from: noTool, fallbackID: "f"))

        XCTAssertNil(HookPayload.call(from: [:], fallbackID: "f"))
    }

    func testACallWithNoToolUseIdStillGetsOne() throws {
        var anonymous = livePayload
        anonymous.removeValue(forKey: "tool_use_id")
        let call = try XCTUnwrap(HookPayload.call(from: anonymous, fallbackID: "generated-1"))
        XCTAssertEqual(call.id, "generated-1")
    }

    func testIdsAreSanitisedBecauseTheyBecomePartOfAPath() {
        // An id is stored under one spelling and asked after under
        // another only once before you stop trusting either. Sanitising
        // in one place is what keeps them the same string.
        XCTAssertEqual(HookPayload.sanitised("toolu_01Ab-cd"), "toolu_01Ab-cd")
        XCTAssertEqual(HookPayload.sanitised("../../etc/passwd"), "------etc-passwd")
        XCTAssertEqual(HookPayload.sanitised("a b/c?d"), "a-b-c-d")
    }

    func testARelativeCwdIsNotBelieved() throws {
        var relative = livePayload
        relative["cwd"] = "Downloads/somewhere"
        let call = try XCTUnwrap(HookPayload.call(from: relative, fallbackID: "f"))
        XCTAssertEqual(call.cwd, "", "a relative cwd reads fine and names the wrong repo")
    }

    func testTheDetailIsWhicheverFieldTheToolActuallyUses() {
        XCTAssertEqual(HookPayload.detail(from: ["command": "ls -la"]), "ls -la")
        XCTAssertEqual(HookPayload.detail(from: ["file_path": "/tmp/a.swift"]), "/tmp/a.swift")
        XCTAssertEqual(HookPayload.detail(from: ["url": "https://example.com"]),
                       "https://example.com")
        XCTAssertEqual(HookPayload.detail(from: ["something_else": "x"]), "")
        XCTAssertEqual(HookPayload.detail(from: nil), "")
        XCTAssertEqual(HookPayload.detail(from: "not an object"), "")
        // Half a megabyte of one unbroken line is a legal body.
        let huge = String(repeating: "a", count: 100_000)
        XCTAssertEqual(HookPayload.detail(from: ["command": huge]).count,
                       ActivityServer.maxDetail)
    }

    func testOnlyTheThreeDecisionWordsAreAccepted() {
        XCTAssertEqual(ActivityServer.decision(named: "allow"), .allow)
        XCTAssertEqual(ActivityServer.decision(named: "deny"), .deny)
        XCTAssertEqual(ActivityServer.decision(named: "abstain"), .abstain)
        XCTAssertNil(ActivityServer.decision(named: "Allow"))
        XCTAssertNil(ActivityServer.decision(named: "yes"))
        XCTAssertNil(ActivityServer.decision(named: ""))
    }
}
