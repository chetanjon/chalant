import XCTest
@testable import Chalant

/// The gate as one pipeline: a `PreToolUse` suspended inside an HTTP
/// request, the card on the island, and the answer travelling back.
///
/// `settleGate` is the whole of the `/hook/pre-tool-use` route behind
/// the connection plumbing, which is why it exists as a method: these
/// prove the pipeline without a socket, a token file, or a listener.
@MainActor
final class GatePipelineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant-gatepipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func makeGate(
        policy: PolicyStore? = nil
    ) -> (server: ActivityServer, sessions: SessionStore) {
        let sessions = SessionStore()
        let server = ActivityServer()
        server.wire(sessions: sessions, policy: policy)
        return (server, sessions)
    }

    private func makePolicy() -> PolicyStore {
        PolicyStore(url: dir.appendingPathComponent("policy.json"))
    }

    private func call(
        id: String = "toolu_gate_1", session: String = "s1",
        tool: String = "Bash", detail: String = "git push origin main"
    ) -> HeldCall {
        HeldCall(
            id: id, sessionID: session, tool: tool, detail: detail,
            cwd: "/tmp/repo", permissionMode: "default", transcriptPath: "",
            event: "PreToolUse", askedAt: Date())
    }

    /// The card has to be on screen before anything can answer it; the
    /// hold registers on the main actor from a child task, so the test
    /// yields until it lands.
    private func waitForCard(
        _ id: String, in sessions: SessionStore, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if sessions.sessions.contains(where: { $0.approval?.id == id }) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("\(id) never made it onto a card", file: file, line: line)
    }

    private func decoded(_ body: String?) throws -> [String: Any] {
        let data = Data(try XCTUnwrap(body).utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap((object as? [String: Any])?["hookSpecificOutput"] as? [String: Any])
    }

    func testAllowTravelsBackInPreToolUseShape() async throws {
        let (server, sessions) = makeGate()
        let held = call()
        async let body = server.settleGate(call: held, patience: 600, rules: ["Bash"])
        await waitForCard(held.id, in: sessions)

        sessions.decide(approvalID: held.id, as: .allow)

        let output = try decoded(await body)
        XCTAssertEqual(output["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        XCTAssertNil(sessions.sessions.first?.approval, "an answered card must go")
    }

    func testDenyTravelsBackAsDeny() async throws {
        let (server, sessions) = makeGate()
        let held = call(id: "toolu_gate_2", detail: "rm -rf build")
        async let body = server.settleGate(call: held, patience: 600, rules: ["Bash"])
        await waitForCard(held.id, in: sessions)

        sessions.decide(approvalID: held.id, as: .deny)

        let output = try decoded(await body)
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        XCTAssertNil(sessions.sessions.first?.approval)
    }

    func testACallNoRuleWantsIsAnsweredWithSilence() async {
        // The common case, by a wide margin, and it must not wait on
        // anything: silence means the agent's own permission flow runs
        // exactly as it would if this app were not installed.
        let (server, sessions) = makeGate()
        let body = await server.settleGate(call: call(), patience: 600, rules: ["Write"])
        XCTAssertNil(body)
        XCTAssertTrue(sessions.sessions.isEmpty, "an ungated call draws no card")
    }

    func testAGrantAnswersAllowWithoutACard() async throws {
        // A grant is somebody who already answered this exact question,
        // so the gate answers allow outright rather than holding — and
        // writes it in the audit, because a gate that answers for you
        // silently is not supervision.
        let policy = makePolicy()
        let (server, sessions) = makeGate(policy: policy)
        policy.grant(pattern: "Bash(git *)", repo: "", for: nil)

        let body = await server.settleGate(
            call: call(detail: "git status"), patience: 600, rules: ["Bash"])

        let output = try decoded(body)
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        XCTAssertTrue(sessions.sessions.isEmpty, "no card for a question already answered")
        XCTAssertEqual(policy.audit.count, 1)
        XCTAssertEqual(policy.audit.first?.allowed, true)
    }

    func testAlwaysAllowIsHonoredOnTheVeryNextMatchingCall() async throws {
        // The whole point of folding the two stores together: the tap
        // that writes the grant and the gate that reads it are finally
        // the same pipeline.
        let policy = makePolicy()
        let (server, sessions) = makeGate(policy: policy)
        let first = call(id: "toolu_first", detail: "git status")
        async let firstBody = server.settleGate(call: first, patience: 600, rules: ["Bash"])
        await waitForCard(first.id, in: sessions)

        // What tapping "Always allow git *" on the card does.
        policy.grant(
            pattern: SessionStore.suggestedException(tool: first.tool, detail: first.detail),
            repo: "", for: nil)
        sessions.decide(approvalID: first.id, as: .allow)
        _ = await firstBody

        let second = await server.settleGate(
            call: call(id: "toolu_second", detail: "git log"), patience: 600, rules: ["Bash"])
        let output = try decoded(second)
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        XCTAssertNil(sessions.sessions.first?.approval, "no second card")
    }

    func testAGrantCannotWidenIntoTheAlwaysAskList() async {
        // Somebody who allowed "git *" did not agree to a force push:
        // the call falls through to the rules and is held like any
        // other.
        let policy = makePolicy()
        let (server, sessions) = makeGate(policy: policy)
        policy.grant(pattern: "Bash(git *)", repo: "", for: nil)
        let held = call(id: "toolu_force", detail: "git push --force origin main")

        async let body = server.settleGate(call: held, patience: 600, rules: ["Bash"])
        await waitForCard(held.id, in: sessions)

        sessions.decide(approvalID: held.id, as: .deny)
        let answer = await body
        XCTAssertNotNil(answer, "the force push was held, not granted through")
    }

    func testAHangupWithdrawsTheCardAndAnswersNothing() async {
        let (server, sessions) = makeGate()
        let held = call(id: "toolu_gate_3")
        async let body = server.settleGate(call: held, patience: 600, rules: ["Bash"])
        await waitForCard(held.id, in: sessions)

        // What `watchForHangup` does when the agent's side of the wire
        // goes quiet: the hook timed out, or its terminal closed.
        let found = await server.gate.abandon(held.id)
        XCTAssertTrue(found)

        let answer = await body
        XCTAssertNil(answer, "an abandoned hold must not become an allow or a deny")
        XCTAssertNil(sessions.sessions.first?.approval, "the card goes with the asker")
    }

    func testSessionEndReleasesTheHold() async {
        // The only signal that arrives when a prompt is settled
        // somewhere else — the terminal, or a phone through Remote
        // Control. Without it the card outlived its question.
        let (server, sessions) = makeGate()
        let held = call(id: "toolu_gate_4")
        async let body = server.settleGate(call: held, patience: 600, rules: ["Bash"])
        await waitForCard(held.id, in: sessions)

        await server.releaseHolds(inSession: held.sessionID)

        let answer = await body
        XCTAssertNil(answer)
        XCTAssertNil(
            sessions.sessions.first(where: { $0.id == held.sessionID })?.approval)
    }

    func testASecondCallInOneSessionFallsThroughWhileTheFirstIsHeld() async {
        let (server, sessions) = makeGate()
        let first = call(id: "toolu_gate_5")
        async let firstBody = server.settleGate(call: first, patience: 600, rules: ["Bash"])
        await waitForCard(first.id, in: sessions)

        // Two cards racing for one row is worse than the second call
        // falling through to the terminal.
        let second = await server.settleGate(
            call: call(id: "toolu_gate_6"), patience: 600, rules: ["Bash"])
        XCTAssertNil(second)

        sessions.decide(approvalID: first.id, as: .allow)
        let answer = await firstBody
        XCTAssertNotNil(answer, "the first hold is still the one answered")
    }
}
