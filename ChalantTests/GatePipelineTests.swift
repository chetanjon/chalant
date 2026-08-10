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

    private func makeGate() -> (server: ActivityServer, sessions: SessionStore) {
        let sessions = SessionStore()
        let server = ActivityServer()
        server.wire(sessions: sessions)
        return (server, sessions)
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
        async let body = server.settleGate(
            call: held, patience: 600, rules: ["Bash"], exceptions: [])
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
        async let body = server.settleGate(
            call: held, patience: 600, rules: ["Bash"], exceptions: [])
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
        let body = await server.settleGate(
            call: call(), patience: 600, rules: ["Write"], exceptions: [])
        XCTAssertNil(body)
        XCTAssertTrue(sessions.sessions.isEmpty, "an ungated call draws no card")
    }

    func testAnExceptionMakesTheGateStandAside() async {
        let (server, sessions) = makeGate()
        let body = await server.settleGate(
            call: call(detail: "git status"), patience: 600,
            rules: ["Bash"], exceptions: ["Bash(git *)"])
        XCTAssertNil(body)
        XCTAssertTrue(sessions.sessions.isEmpty)
    }

    func testAHangupWithdrawsTheCardAndAnswersNothing() async {
        let (server, sessions) = makeGate()
        let held = call(id: "toolu_gate_3")
        async let body = server.settleGate(
            call: held, patience: 600, rules: ["Bash"], exceptions: [])
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
        async let body = server.settleGate(
            call: held, patience: 600, rules: ["Bash"], exceptions: [])
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
        async let firstBody = server.settleGate(
            call: first, patience: 600, rules: ["Bash"], exceptions: [])
        await waitForCard(first.id, in: sessions)

        // Two cards racing for one row is worse than the second call
        // falling through to the terminal.
        let second = await server.settleGate(
            call: call(id: "toolu_gate_6"), patience: 600,
            rules: ["Bash"], exceptions: [])
        XCTAssertNil(second)

        sessions.decide(approvalID: first.id, as: .allow)
        let answer = await firstBody
        XCTAssertNotNil(answer, "the first hold is still the one answered")
    }
}
