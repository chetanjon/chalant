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

    // MARK: The question pipeline

    private func questionCall(id: String = "toolu_ask_1") -> HeldCall {
        HeldCall(
            id: id, sessionID: "s1", tool: "AskUserQuestion", detail: "",
            cwd: "/tmp/repo", permissionMode: "default", transcriptPath: "",
            event: "PreToolUse", askedAt: Date())
    }

    private func oneQuestion() -> [SessionStore.Ask.Question] {
        [SessionStore.Ask.Question(
            header: "Pick", question: "Which one?", options: ["A", "B"],
            multiSelect: false, field: "q0", optionDescriptions: ["first", "second"])]
    }

    private func waitForAsk(
        _ id: String, in sessions: SessionStore, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if sessions.sessions.contains(where: { $0.ask?.id == id }) { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("\(id) never made it onto a card", file: file, line: line)
    }

    func testAnAnsweredQuestionTravelsBackAsADenyCarryingTheAnswer() async throws {
        let (server, sessions) = makeGate()
        let held = questionCall()
        async let body = server.settleQuestion(
            call: held, questions: oneQuestion(), patience: 600)
        await waitForAsk(held.id, in: sessions)

        // What tapping option B on the card does.
        let session = sessions.sessions.first { $0.ask?.id == held.id }
        XCTAssertEqual(session?.ask?.intercepted, true)
        sessions.answerQuestion(sessionID: "s1", questionIndex: 0, with: ["B"])

        let output = try decoded(await body)
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        XCTAssertTrue((output["permissionDecisionReason"] as? String ?? "")
            .contains("User answered via Chalant: B."))
        XCTAssertNil(sessions.sessions.first?.ask, "an answered card must go")
    }

    func testAnUnansweredQuestionFallsThroughAtItsDeadline() async {
        // The 20-second promise, at test speed: nobody answers, the
        // response is an empty 200, and the picker runs in the terminal
        // exactly as it always did.
        let (server, sessions) = makeGate()
        let held = questionCall(id: "toolu_ask_2")
        let body = await server.settleQuestion(
            call: held, questions: oneQuestion(), patience: 0.1)
        XCTAssertNil(body)
        XCTAssertNil(sessions.sessions.first?.ask, "the card goes when the question does")
    }

    func testDecliningAQuestionHandsItBackToTheTerminal() async {
        let (server, sessions) = makeGate()
        let held = questionCall(id: "toolu_ask_3")
        async let body = server.settleQuestion(
            call: held, questions: oneQuestion(), patience: 600)
        await waitForAsk(held.id, in: sessions)

        // What "Answer in terminal" does.
        server.decline(askID: held.id)

        let answer = await body
        XCTAssertNil(answer, "declining must fall through, never deny the question itself")
    }

    func testSessionEndReleasesAHeldQuestion() async {
        // The same release the gate's holds get: a turn cannot end while
        // a question is standing, so session-end is proof it was settled
        // somewhere else, and the card must not outlive it.
        let (server, sessions) = makeGate()
        let held = questionCall(id: "toolu_ask_5")
        async let body = server.settleQuestion(
            call: held, questions: oneQuestion(), patience: 600)
        await waitForAsk(held.id, in: sessions)

        await server.releaseHolds(inSession: held.sessionID)

        let answer = await body
        XCTAssertNil(answer)
        XCTAssertNil(sessions.sessions.first(where: { $0.id == held.sessionID })?.ask)
    }

    func testAQuestionHangupWithdrawsTheCardAndAnswersNothing() async {
        // What `watchForHangup(answers: true)` does when the asking
        // side of the wire goes quiet.
        let (server, sessions) = makeGate()
        let held = questionCall(id: "toolu_ask_6")
        async let body = server.settleQuestion(
            call: held, questions: oneQuestion(), patience: 600)
        await waitForAsk(held.id, in: sessions)

        let found = await server.answers.abandon(held.id)
        XCTAssertTrue(found)

        let answer = await body
        XCTAssertNil(answer, "an abandoned question must not become an answer")
        XCTAssertNil(sessions.sessions.first?.ask, "the card goes with the asker")
    }

    // MARK: Who owns the preferred port

    func testOnlyAChalantShapedAnswerReadsAsAnotherChalant() {
        // The guard that keeps a fallback-port instance from rewriting
        // the owner's config: /health answers with the app's name, and
        // even its 401 names the app. Anything else on the port is not
        // one of us, and the hooks must follow this instance instead.
        XCTAssertTrue(ActivityServer.portOwnerIsChalant(
            Data(#"{"ok":true,"app":"Chalant","version":"1.8.2"}"#.utf8)))
        XCTAssertTrue(ActivityServer.portOwnerIsChalant(
            Data(#"{"ok":false,"error":"send X-Chalant-Token or Authorization: Bearer, see ~/Library/Application Support/Chalant/server.json"}"#.utf8)))
        XCTAssertFalse(ActivityServer.portOwnerIsChalant(
            Data(#"{"ok":true,"app":"SomethingElse"}"#.utf8)))
        XCTAssertFalse(ActivityServer.portOwnerIsChalant(Data()))
        XCTAssertFalse(ActivityServer.portOwnerIsChalant(nil))
    }

    func testTheGateStandsAsideForAQuestionEvenWhenARuleMatchesIt() async {
        // A rule broad enough to name AskUserQuestion must not draw an
        // approval card with no options on it: the ask pipeline owns
        // the tool.
        let (server, sessions) = makeGate()
        let body = await server.settleGate(
            call: questionCall(id: "toolu_ask_4"), patience: 600,
            rules: ["AskUserQuestion"])
        XCTAssertNil(body)
        XCTAssertTrue(sessions.sessions.isEmpty)
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
