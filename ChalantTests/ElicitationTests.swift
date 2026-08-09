import XCTest
@testable import Chalant

/// An MCP server's question, held inside its hook until somebody
/// answers it.
///
/// The payloads here are the ones the installed Claude Code (2.1.226)
/// actually posted to a throwaway HTTP hook, captured before any of this
/// was written. The spec guessed `requestedSchema`; the wire says
/// `requested_schema`, and there is no `tool_name` or `tool_use_id` on
/// this event at all.
final class ElicitationTests: XCTestCase {

    private var livePayload: [String: Any] {
        [
            "session_id": "2136e267-b817-4084-bf7d-f5428213ffef",
            "transcript_path": "/Users/x/.claude/projects/-Users-x/2136e267.jsonl",
            "cwd": "/Users/x/Downloads/chalant-phase5",
            "prompt_id": "30f67fac-6d63-402c-959c-d93d74efc51e",
            "hook_event_name": "Elicitation",
            "mcp_server_name": "chalant",
            "message": "Which colour do you prefer?",
            "mode": "form",
            "requested_schema": [
                "type": "object",
                "properties": [
                    "answer": [
                        "type": "string",
                        "title": "Colour preference",
                        "description": "Which colour do you prefer?",
                        "enum": ["red", "blue"],
                    ],
                ],
                "required": ["answer"],
            ],
        ]
    }

    func testALiveElicitationReadsCleanly() throws {
        let ask = try XCTUnwrap(HookPayload.elicitation(from: livePayload, id: "e1"))
        XCTAssertEqual(ask.sessionID, "2136e267-b817-4084-bf7d-f5428213ffef")
        XCTAssertEqual(ask.cwd, "/Users/x/Downloads/chalant-phase5")
        XCTAssertEqual(ask.message, "Which colour do you prefer?")
        XCTAssertEqual(ask.server, "chalant")
        XCTAssertEqual(ask.fields.count, 1)
        let field = try XCTUnwrap(ask.fields.first)
        XCTAssertEqual(field.name, "answer")
        XCTAssertEqual(field.title, "Colour preference")
        XCTAssertEqual(field.options, ["red", "blue"])
        XCTAssertEqual(field.kind, .string)
    }

    func testAQuestionWithNoChoicesIsAnsweredInYourOwnWords() throws {
        var freeText = livePayload
        freeText["message"] = "What should the release be called?"
        freeText["requested_schema"] = [
            "type": "object",
            "properties": ["name": ["type": "string", "title": "Release name"]],
            "required": ["name"],
        ]
        let ask = try XCTUnwrap(HookPayload.elicitation(from: freeText, id: "e1"))
        let field = try XCTUnwrap(ask.fields.first)
        XCTAssertTrue(field.options.isEmpty)
        // No description on the property, so the question falls back to
        // the message rather than rendering an empty row.
        XCTAssertEqual(field.prompt, "What should the release be called?")
    }

    func testABooleanIsOfferedAsTwoWordsRatherThanTypedOut() throws {
        var boolean = livePayload
        boolean["requested_schema"] = [
            "type": "object",
            "properties": ["confirm": ["type": "boolean", "title": "Ship it?"]],
            "required": ["confirm"],
        ]
        let ask = try XCTUnwrap(HookPayload.elicitation(from: boolean, id: "e1"))
        XCTAssertEqual(ask.fields.first?.options, ["Yes", "No"])
        XCTAssertEqual(ask.fields.first?.kind, .boolean)
    }

    func testRequiredFieldsComeFirstAndTheRestAreStable() throws {
        // Dictionaries have no order and a form does. `required` is the
        // only ordering the payload carries.
        var many = livePayload
        many["requested_schema"] = [
            "type": "object",
            "properties": [
                "zebra": ["type": "string", "title": "Z"],
                "alpha": ["type": "string", "title": "A"],
                "chosen": ["type": "string", "title": "C"],
            ],
            "required": ["chosen"],
        ]
        let ask = try XCTUnwrap(HookPayload.elicitation(from: many, id: "e1"))
        XCTAssertEqual(ask.fields.map(\.name), ["chosen", "alpha", "zebra"])
    }

    func testNothingToAskIsNotSomethingToShow() {
        var empty = livePayload
        empty["requested_schema"] = ["type": "object", "properties": [:]]
        XCTAssertNil(HookPayload.elicitation(from: empty, id: "e1"))

        var sessionless = livePayload
        sessionless["session_id"] = ""
        XCTAssertNil(HookPayload.elicitation(from: sessionless, id: "e1"))

        XCTAssertNil(HookPayload.elicitation(from: [:], id: "e1"))
    }

    // MARK: What goes back

    private func output(_ json: String) throws -> [String: Any] {
        try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?[
            "hookSpecificOutput"] as? [String: Any])
    }

    func testAnAnswerGoesBackUnderTheNameTheServerAskedFor() throws {
        let fields = [Elicitation.Field(
            name: "answer", title: "Colour", prompt: "?", options: ["red", "blue"], kind: .string)]
        let body = try XCTUnwrap(
            HookPayload.response(for: .accept(["answer": "blue"]), fields: fields))
        let out = try output(body)
        XCTAssertEqual(out["hookEventName"] as? String, "Elicitation")
        XCTAssertEqual(out["action"] as? String, "accept")
        XCTAssertEqual((out["content"] as? [String: Any])?["answer"] as? String, "blue")
    }

    func testTypesSurviveTheRoundTripBecauseTheSchemaChecksThem() throws {
        // The content is validated against the schema at the far end, so
        // a boolean field answered with the string "Yes" is not an
        // answer. Carrying the field's type this far is what makes it
        // one.
        let fields = [
            Elicitation.Field(name: "confirm", title: "", prompt: "", options: ["Yes", "No"],
                              kind: .boolean),
            Elicitation.Field(name: "count", title: "", prompt: "", options: [], kind: .integer),
            Elicitation.Field(name: "ratio", title: "", prompt: "", options: [], kind: .number),
        ]
        let out = try output(try XCTUnwrap(HookPayload.response(
            for: .accept(["confirm": "Yes", "count": "3", "ratio": "1.5"]), fields: fields)))
        let content = try XCTUnwrap(out["content"] as? [String: Any])
        XCTAssertEqual(content["confirm"] as? Bool, true)
        XCTAssertEqual(content["count"] as? Int, 3)
        XCTAssertEqual(content["ratio"] as? Double, 1.5)

        let no = try output(try XCTUnwrap(HookPayload.response(
            for: .accept(["confirm": "No"]), fields: fields)))
        XCTAssertEqual((no["content"] as? [String: Any])?["confirm"] as? Bool, false)
    }

    func testTurningItDownIsARealAnswer() throws {
        let out = try output(try XCTUnwrap(HookPayload.response(for: .decline, fields: [])))
        XCTAssertEqual(out["action"] as? String, "decline")
        XCTAssertNil(out["content"])

        let cancelled = try output(try XCTUnwrap(HookPayload.response(for: .cancel, fields: [])))
        XCTAssertEqual(cancelled["action"] as? String, "cancel")
    }

    func testSayingNothingIsNotAnAnswerEither() {
        // Claude Code's own dialog handles it, exactly as it would if
        // this app were not here.
        XCTAssertNil(HookPayload.response(for: .abstain, fields: []))
    }

    // MARK: Holding one

    func testAQuestionSuspendsUntilItIsAnswered() async {
        let store = PendingAnswerStore()
        let ask = Elicitation(
            id: "e1", sessionID: "s1", cwd: "/tmp", message: "?", server: "chalant",
            fields: [])
        async let outcome = store.hold(ask)
        for _ in 0..<200 where await !store.isHeld("e1") {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await store.resolve("e1", as: .accept(["answer": "blue"]))
        let result = await outcome
        XCTAssertEqual(result, .accept(["answer": "blue"]))
        let left = await store.count
        XCTAssertEqual(left, 0)
    }

    func testASecondAnswerFindsNothing() async {
        let store = PendingAnswerStore()
        let ask = Elicitation(id: "e1", sessionID: "s1", cwd: "/tmp", message: "?",
                              server: "", fields: [])
        async let outcome = store.hold(ask)
        for _ in 0..<200 where await !store.isHeld("e1") {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let first = await store.resolve("e1", as: .decline)
        let second = await store.resolve("e1", as: .cancel)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let result = await outcome
        XCTAssertEqual(result, .decline)
    }

    // MARK: The row it lands on

    @MainActor
    func testAQuestionFromAnUnknownSessionStillGetsARow() {
        let store = SessionStore()
        let held = store.holdForElicitation(
            sessionID: "headless", askID: "e1",
            questions: [SessionStore.Ask.Question(
                header: "Colour", question: "Which?", options: ["red", "blue"],
                multiSelect: false, field: "answer")],
            cwd: "/Users/x/code/kizu", server: "chalant")
        XCTAssertTrue(held)
        let session = try? XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session?.title, "kizu")
        XCTAssertEqual(session?.ask?.elicitation, true)
        XCTAssertEqual(session?.ask?.server, "chalant")
        XCTAssertEqual(session?.ask?.questions.first?.field, "answer",
                       "the schema's own property name has to survive onto the card")
    }

    @MainActor
    func testAnsweringTellsWhoeverIsHoldingTheAgent() {
        let store = SessionStore()
        var answered: [String] = []
        store.onAnswered = { answered.append($0) }
        _ = store.holdForElicitation(
            sessionID: "s1", askID: "e1",
            questions: [SessionStore.Ask.Question(
                header: "", question: "Which?", options: ["red"], multiSelect: false,
                field: "answer")],
            cwd: "/tmp", server: "chalant")

        _ = store.answerQuestion(sessionID: "s1", questionIndex: 0, with: ["red"])

        XCTAssertEqual(answered, ["e1"])
        XCTAssertEqual(store.ask(withID: "e1")?.questions.first?.answer, ["red"])
    }

    @MainActor
    func testAHalfAnsweredBundleTellsNobodyYet() {
        let store = SessionStore()
        var answered: [String] = []
        store.onAnswered = { answered.append($0) }
        _ = store.holdForElicitation(
            sessionID: "s1", askID: "e1",
            questions: [
                SessionStore.Ask.Question(header: "", question: "One?", options: ["a"],
                                          multiSelect: false, field: "one"),
                SessionStore.Ask.Question(header: "", question: "Two?", options: ["b"],
                                          multiSelect: false, field: "two"),
            ],
            cwd: "/tmp", server: "chalant")

        _ = store.answerQuestion(sessionID: "s1", questionIndex: 0, with: ["a"])
        XCTAssertTrue(answered.isEmpty, "half a form is not an answer to send")
        _ = store.answerQuestion(sessionID: "s1", questionIndex: 1, with: ["b"])
        XCTAssertEqual(answered, ["e1"])
    }

    @MainActor
    func testAQuestionNeverLandsOnTopOfOneStillBeingAnswered() {
        let store = SessionStore()
        let question = SessionStore.Ask.Question(
            header: "", question: "Which?", options: ["a"], multiSelect: false, field: "f")
        XCTAssertTrue(store.holdForElicitation(
            sessionID: "s1", askID: "e1", questions: [question], cwd: "/tmp", server: "x"))
        XCTAssertFalse(store.holdForElicitation(
            sessionID: "s1", askID: "e2", questions: [question], cwd: "/tmp", server: "x"),
            "the second one falls through rather than replacing a question being answered")
        XCTAssertEqual(store.sessions.first?.ask?.id, "e1")
    }

    @MainActor
    func testClearingByAskIdFindsItWhateverRowItIsOn() {
        let store = SessionStore()
        _ = store.holdForElicitation(
            sessionID: "s1", askID: "e1",
            questions: [SessionStore.Ask.Question(
                header: "", question: "Which?", options: ["a"], multiSelect: false, field: "f")],
            cwd: "/tmp", server: "x")
        store.clearAsk(askID: "e1")
        XCTAssertNil(store.sessions.first?.ask)
        XCTAssertNil(store.ask(withID: "e1"))
    }
}
