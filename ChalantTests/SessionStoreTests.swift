import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Chalant

/// SessionStore mirrors ActivityStore's proven shape, and
/// SessionDiscovery earns its keep by never trusting a byte it reads
/// from `~/.claude/projects`. These lock both promises down: the sort
/// and TTL rules that were already paid for once, and the slug/JSON
/// parsing that has to survive a hostile or simply half-written file.
@MainActor
final class SessionStoreTests: XCTestCase {

    // MARK: Sort order (attention first, newest within a state)

    func testSortIsAttentionFirstThenNewestStartedWithinState() {
        let store = SessionStore()
        let now = Date()
        store.upsert(id: "done", title: "d", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .done, startedAt: now.addingTimeInterval(-50))
        store.upsert(id: "failed", title: "f", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .failed, startedAt: now.addingTimeInterval(-40))
        store.upsert(id: "stale", title: "s", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .stale, startedAt: now.addingTimeInterval(-30))
        store.upsert(id: "working-old", title: "w1", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, startedAt: now.addingTimeInterval(-20))
        store.upsert(id: "working-new", title: "w2", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, startedAt: now.addingTimeInterval(-10))
        store.upsert(id: "needs-input", title: "n", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .needsInput, startedAt: now)

        XCTAssertEqual(store.sessions.map(\.id), [
            "needs-input", "working-new", "working-old", "stale", "failed", "done",
        ])
    }

    func testRowsDoNotReshuffleWhenOnlyUpdatedAtChanges() {
        // The bug: a rescan rewrites updatedAt on every sweep, and
        // sorting by it traded two working rows' places on a five-second
        // clock for no reason a user could see (founder, 2026-08-02:
        // "just dont make them change places"). Only a rank change may
        // move a row now.
        let store = SessionStore()
        let now = Date()
        store.upsert(id: "older", title: "o", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, startedAt: now.addingTimeInterval(-20))
        store.upsert(id: "newer", title: "n", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, startedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(store.sessions.map(\.id), ["newer", "older"])

        // A rescan touches the older row with a fresh updatedAt, exactly
        // as SessionDiscovery does on every debounced sweep.
        store.upsert(id: "older", title: "o", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, updatedAt: now.addingTimeInterval(100))
        XCTAssertEqual(store.sessions.map(\.id), ["newer", "older"])
    }

    // MARK: TTL expiry (terminal states only)

    func testTerminalStatesExpireAfterTheirTTL() {
        let store = SessionStore(finishedTTL: 0.2)
        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .done)
        XCTAssertEqual(store.sessions.count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testNonTerminalStatesNeverExpireOnTheirOwn() {
        // A quiet, stale session is still a real row to glance at; only
        // done/failed are allowed to clear themselves on a clock.
        let store = SessionStore(finishedTTL: 0.1)
        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .stale)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(store.sessions.count, 1)
    }

    // MARK: Upsert by id

    func testUpsertByIdUpdatesInPlaceRatherThanDuplicating() {
        let store = SessionStore()
        store.upsert(id: "s1", title: "first", cwd: "/a", branch: nil,
                     lastPrompt: "p1", state: .working)
        store.upsert(id: "s1", title: "second", cwd: "/b", branch: "main",
                     lastPrompt: "p2", state: .needsInput)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.title, "second")
        XCTAssertEqual(store.sessions.first?.cwd, "/b")
        XCTAssertEqual(store.sessions.first?.branch, "main")
        XCTAssertEqual(store.sessions.first?.lastPrompt, "p2")
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
    }

    func testUpsertPreservesStartedAtAcrossUpdates() {
        let store = SessionStore()
        store.upsert(id: "s1", title: "first", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        let startedAt = store.sessions.first?.startedAt
        store.upsert(id: "s1", title: "second", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        XCTAssertEqual(store.sessions.first?.startedAt, startedAt)
    }

    // MARK: Slug -> cwd reconstruction

    private func makeScratchRoot() throws -> URL {
        // No hyphens of our own in the prefix, so the only ambiguity in
        // the resulting slug is the one each test deliberately builds.
        let name = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testResolveCwdHandlesTheOrdinaryUnambiguousPath() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("Users/testuser/github/chalant")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let slug = cwd.path.replacingOccurrences(of: "/", with: "-")
        XCTAssertEqual(SessionDiscovery.resolveCwd(fromSlug: slug), cwd.path)
    }

    func testResolveCwdBacktracksPastAHyphenatedDecoy() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("Users/testuser/github")
        // "to" is a real, existing directory that is also a dead end —
        // exactly the ambiguity the architecture doc warns about. The
        // real project lives at the three-token name next to it.
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("to"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("to-be-discussed"), withIntermediateDirectories: true)

        let realCwd = base.appendingPathComponent("to-be-discussed").path
        let slug = realCwd.replacingOccurrences(of: "/", with: "-")
        XCTAssertEqual(SessionDiscovery.resolveCwd(fromSlug: slug), realCwd)
    }

    func testResolveCwdDegradesToNilWhenNothingOnDiskMatches() {
        // Renamed or removed since the session ran: this must not guess.
        let slug = "-nonexistent-\(UUID().uuidString)-path"
        XCTAssertNil(SessionDiscovery.resolveCwd(fromSlug: slug))
    }

    func testResolveCwdRejectsASlugThatIsNotRooted() {
        XCTAssertNil(SessionDiscovery.resolveCwd(fromSlug: "Users-nohyphen-prefix"))
    }

    func testRecordedCwdWinsOverDecodingTheSlug() {
        // The slug here decodes to nothing on disk; the transcript said
        // outright where it was running. Guessing must never outrank
        // being told.
        let metadata = SessionDiscovery.ParsedMetadata(cwd: "/Users/x/github/chalant")
        XCTAssertEqual(
            SessionDiscovery.resolvedCwd(metadata: metadata, slug: "-gone-\(UUID().uuidString)"),
            "/Users/x/github/chalant"
        )
    }

    func testSlugDecodeStillCoversATranscriptThatRecordedNoCwd() throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("Users/testuser/github/chalant")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let slug = cwd.path.replacingOccurrences(of: "/", with: "-")
        XCTAssertEqual(
            SessionDiscovery.resolvedCwd(metadata: SessionDiscovery.ParsedMetadata(), slug: slug),
            cwd.path
        )
    }

    func testParseMetadataReadsCwdAndBranchOffAnyRecordThatCarriesThem() {
        // Neither is announced by a record type of its own — they ride
        // along on ordinary message records, and a relative path is not
        // a cwd no matter who wrote it.
        let text = """
        {"type":"user","cwd":"/Users/x/github/chalant","gitBranch":"main"}
        {"type":"ai-title","aiTitle":"Understanding Chalant concept"}
        {"type":"assistant","cwd":"relative/not/a/cwd","gitBranch":""}
        """
        let metadata = SessionDiscovery.parseMetadata(text, path: "test.jsonl")
        XCTAssertEqual(metadata.cwd, "/Users/x/github/chalant")
        XCTAssertEqual(metadata.gitBranch, "main")
    }

    // MARK: Title precedence

    func testTitlePrefersAiTitleOverEverythingElse() {
        let metadata = SessionDiscovery.ParsedMetadata(aiTitle: "Understanding Chalant concept")
        XCTAssertEqual(
            SessionDiscovery.title(metadata: metadata, resolvedCwd: "/Users/x/github/chalant", slug: "slug"),
            "Understanding Chalant concept"
        )
    }

    func testTitleFallsBackToTheResolvedCwdsLastComponent() {
        let metadata = SessionDiscovery.ParsedMetadata()
        XCTAssertEqual(
            SessionDiscovery.title(metadata: metadata, resolvedCwd: "/Users/x/github/chalant", slug: "slug"),
            "chalant"
        )
    }

    func testTitleFallsBackToTheRawSlugWhenNothingElseResolved() {
        let metadata = SessionDiscovery.ParsedMetadata()
        XCTAssertEqual(
            SessionDiscovery.title(metadata: metadata, resolvedCwd: nil, slug: "-nonexistent-path"),
            "-nonexistent-path"
        )
    }

    // MARK: Metadata parsing

    func testParseMetadataAppliesLastWriteWinsAndIgnoresUnknownTypes() {
        let text = """
        {"type":"ai-title","aiTitle":"first"}
        {"type":"last-prompt","lastPrompt":"do the thing"}
        {"type":"mode","mode":"normal"}
        {"type":"permission-mode","permissionMode":"auto"}
        {"type":"ai-title","aiTitle":"second"}
        {"type":"some-future-record","somethingUnrelated":true}
        """
        let metadata = SessionDiscovery.parseMetadata(text, path: "test.jsonl")
        XCTAssertEqual(metadata.aiTitle, "second")
        XCTAssertEqual(metadata.lastPrompt, "do the thing")
        XCTAssertEqual(metadata.mode, "normal")
        XCTAssertEqual(metadata.permissionMode, "auto")
    }

    func testParseMetadataNeverThrowsOnMalformedOrTruncatedLines() {
        let text = """
        not json at all
        {
        {"type":"ai-title"}
        {"type":123}
        {"aiTitle":"missing type"}
        {"type":"ai-title","aiTitle":42}

        {"type":"last-prompt","lastPrompt":"kept"}
        """
        let metadata = SessionDiscovery.parseMetadata(text, path: "test.jsonl")
        // None of the malformed lines produced a value; the one good
        // line after them still lands.
        XCTAssertNil(metadata.aiTitle)
        XCTAssertEqual(metadata.lastPrompt, "kept")
    }

    // MARK: Branch

    func testBranchDropsTheLiteralHeadThatNamesNoBranch() {
        // Worktrees and detached checkouts record "HEAD" as the branch.
        // It is not one, and it rendered as a column of "HEAD" down the
        // sessions list.
        let metadata = SessionDiscovery.ParsedMetadata(gitBranch: "HEAD")
        XCTAssertNil(SessionDiscovery.branch(metadata: metadata, resolvedCwd: nil))
    }

    func testBranchFallsBackToTheRecordedNameWhenTheCwdIsNotReadable() {
        let metadata = SessionDiscovery.ParsedMetadata(gitBranch: "feat/sessions")
        XCTAssertEqual(
            SessionDiscovery.branch(metadata: metadata, resolvedCwd: "/nonexistent/\(UUID().uuidString)"),
            "feat/sessions"
        )
    }

    func testBranchIsNilWhenNothingNamesOne() {
        XCTAssertNil(
            SessionDiscovery.branch(metadata: SessionDiscovery.ParsedMetadata(), resolvedCwd: nil)
        )
    }

    func testTheAgentBurstFillsItsFrameAndIsNotEmpty() {
        // Hand-built from trigonometry, so it is easy to produce
        // something empty or collapsed to a dot while still compiling.
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let path = ClaudeBurstShape().path(in: rect)
        XCTAssertFalse(path.isEmpty)
        let box = path.boundingRect
        // Rays reach the rim on both axes rather than hugging the hub.
        XCTAssertEqual(box.width, rect.width, accuracy: 1.5)
        XCTAssertEqual(box.height, rect.height, accuracy: 1.5)
        XCTAssertEqual(box.midX, rect.midX, accuracy: 0.5)
        XCTAssertEqual(box.midY, rect.midY, accuracy: 0.5)
    }

    // MARK: Questions from a session

    private func storeWithSession(_ id: String = "s1") -> SessionStore {
        let store = SessionStore()
        store.upsert(id: id, title: "t", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        return store
    }

    func testAQuestionLiftsItsSessionToNeedsInput() {
        let store = storeWithSession()
        XCTAssertTrue(store.attach(
            askID: "q1", to: "s1", header: "Pick", question: "Which one?",
            options: ["A", "B"], multiSelect: false))
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
        XCTAssertEqual(store.pendingAsk(sessionID: "s1")?.options, ["A", "B"])
    }

    func testAQuestionForAnUnknownSessionIsRefused() {
        // Accepting it would leave the agent polling for an answer that
        // can never arrive, since the row it would appear on does not
        // exist.
        let store = SessionStore()
        XCTAssertFalse(store.attach(
            askID: "q", to: "ghost", header: "h", question: "q?",
            options: [], multiSelect: false))
    }

    func testAnEmptyQuestionIsRefused() {
        // A row saying a session wants something without saying what is
        // worse than no row at all.
        let store = storeWithSession()
        XCTAssertFalse(store.attach(
            askID: "q", to: "s1", header: "h", question: "   ",
            options: ["A"], multiSelect: false))
        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    func testQuestionFieldsArriveOffASocketAndAreBounded() {
        let store = storeWithSession()
        let long = String(repeating: "x", count: 5000)
        store.attach(askID: "q", to: "s1", header: long, question: long,
                     options: Array(repeating: "opt", count: 40), multiSelect: false)
        let ask = store.pendingAsk(sessionID: "s1")
        XCTAssertEqual(ask?.question.count, SessionStore.askFieldLimit)
        XCTAssertEqual(ask?.header.count, SessionStore.askFieldLimit)
        XCTAssertEqual(ask?.options.count, SessionStore.maxOptions)
    }

    func testAnsweringReturnsTheSessionToWorking() {
        let store = storeWithSession()
        store.attach(askID: "q", to: "s1", header: "h", question: "q?",
                     options: ["A", "B"], multiSelect: false)
        XCTAssertTrue(store.answer(sessionID: "s1", with: ["A"]))
        XCTAssertEqual(store.pendingAsk(sessionID: "s1")?.answer, ["A"])
        // Still needs-input would keep claiming the top of the list.
        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    func testDiscoveryCannotOverwriteAnOutstandingQuestion() {
        // Discovery rescans every twenty seconds and pushes
        // working-or-stale from the file's mtime. It has no way to know
        // a question is waiting, so it must not be able to clear one:
        // the row would lose its glyph, its tint, its place at the top
        // and the island's waiting mark, while the question stayed
        // answerable — nothing would look broken.
        let store = storeWithSession()
        store.attach(askID: "q", to: "s1", header: "h", question: "q?",
                     options: ["A"], multiSelect: false)
        XCTAssertEqual(store.sessions.first?.state, .needsInput)

        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
        // Even a session gone quiet is still waiting on an answer.
        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .stale)
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
    }

    func testOnceAnsweredDiscoveryTakesTheStateBack() {
        // The override lasts exactly as long as the question does, or a
        // finished session would sit at needs-input forever.
        let store = storeWithSession()
        store.attach(askID: "q", to: "s1", header: "h", question: "q?",
                     options: ["A"], multiSelect: false)
        store.answer(sessionID: "s1", with: ["A"])
        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .stale)
        XCTAssertEqual(store.sessions.first?.state, .stale)
    }

    func testAnsweringSomethingThatWasNeverAskedIsRefused() {
        let store = storeWithSession()
        XCTAssertFalse(store.answer(sessionID: "s1", with: ["A"]))
        XCTAssertFalse(store.answer(sessionID: "ghost", with: ["A"]))
    }

    func testClearingTheAskStopsTheIslandOfferingAnAnsweredChoice() {
        let store = storeWithSession()
        store.attach(askID: "q", to: "s1", header: "h", question: "q?",
                     options: ["A"], multiSelect: false)
        store.answer(sessionID: "s1", with: ["A"])
        store.clearAsk(sessionID: "s1")
        XCTAssertNil(store.pendingAsk(sessionID: "s1"))
    }

    // MARK: Bundled asks — several questions, answered one at a time

    private func bundledQuestions() -> [SessionStore.Ask.Question] {
        [
            SessionStore.Ask.Question(header: "Logo", question: "Which one?", options: ["A", "B"], multiSelect: false),
            SessionStore.Ask.Question(header: "Mic", question: "Move it?", options: ["Yes", "No"], multiSelect: false),
            SessionStore.Ask.Question(header: "Drag", question: "Scope?", options: ["One", "Per display"], multiSelect: false),
        ]
    }

    /// The core the two `attach` overloads share: a bundle attaches as
    /// one ask carrying every question, in order, none dropped — the gap
    /// this whole feature exists to close (`parseNativeAsk` used to keep
    /// only `questions.first`).
    func testABundleAttachesAsOneAskCarryingEveryQuestion() {
        let store = storeWithSession()
        XCTAssertTrue(store.attach(askID: "bundle", to: "s1", questions: bundledQuestions(), native: true))
        let ask = store.pendingAsk(sessionID: "s1")
        XCTAssertEqual(ask?.questions.count, 3)
        XCTAssertEqual(ask?.questions.map(\.header), ["Logo", "Mic", "Drag"])
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
    }

    /// The partly-answered rule: two of three questions answered is
    /// neither answered nor unanswered, and must read as outstanding —
    /// `isFullyAnswered` false, state still needs-input — exactly as
    /// zero of three does. Only the last answer changes that.
    func testABundleTwoOfThreeAnsweredIsStillOutstanding() {
        let store = storeWithSession()
        store.attach(askID: "bundle", to: "s1", questions: bundledQuestions(), native: false)

        XCTAssertTrue(store.answerQuestion(sessionID: "s1", questionIndex: 0, with: ["A"]))
        XCTAssertFalse(store.pendingAsk(sessionID: "s1")?.isFullyAnswered ?? true)
        XCTAssertEqual(store.sessions.first?.state, .needsInput, "one of three answered is still outstanding")

        XCTAssertTrue(store.answerQuestion(sessionID: "s1", questionIndex: 1, with: ["Yes"]))
        XCTAssertFalse(store.pendingAsk(sessionID: "s1")?.isFullyAnswered ?? true)
        XCTAssertEqual(store.sessions.first?.state, .needsInput, "two of three answered is still outstanding")

        XCTAssertTrue(store.answerQuestion(sessionID: "s1", questionIndex: 2, with: ["One"]))
        let ask = store.pendingAsk(sessionID: "s1")
        XCTAssertEqual(ask?.questions.map(\.answer), [["A"], ["Yes"], ["One"]])
        XCTAssertTrue(ask?.isFullyAnswered ?? false)
        // Non-native: a fully-answered bundle goes back to working, the
        // same rule a single-question answer always followed.
        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    /// A native bundle's own row never flips back to working just
    /// because every question got tapped in the card: there is no
    /// supported way to resolve the real `AskUserQuestion` prompt from
    /// here, so the row stays needs-input until the transcript itself
    /// says the question was resolved — same rule a single native
    /// question always followed.
    func testANativeBundleFullyAnsweredLeavesTheRowNeedingInput() {
        let store = storeWithSession()
        store.attach(askID: "bundle", to: "s1", questions: bundledQuestions(), native: true)
        for index in 0..<3 {
            store.answerQuestion(sessionID: "s1", questionIndex: index, with: ["pick"])
        }
        XCTAssertTrue(store.pendingAsk(sessionID: "s1")?.isFullyAnswered ?? false)
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
    }

    /// Answering an index outside the bundle, or a session with no ask
    /// at all, is refused rather than silently accepted.
    func testAnsweringAQuestionIndexOutOfRangeIsRefused() {
        let store = storeWithSession()
        store.attach(askID: "bundle", to: "s1", questions: bundledQuestions(), native: false)
        XCTAssertFalse(store.answerQuestion(sessionID: "s1", questionIndex: 3, with: ["x"]))
        XCTAssertFalse(store.answerQuestion(sessionID: "ghost", questionIndex: 0, with: ["x"]))
    }

    /// `answer()`, the scripted `chalant ask` shape, is exactly
    /// `answerQuestion` at index 0 — unchanged behaviour, expressed
    /// through the one function that now does all of this.
    func testLegacyAnswerIsQuestionZeroOfASingleQuestionBundle() {
        let store = storeWithSession()
        store.attach(askID: "q", to: "s1", header: "h", question: "q?", options: ["A"], multiSelect: false)
        XCTAssertTrue(store.answer(sessionID: "s1", with: ["A"]))
        XCTAssertEqual(store.pendingAsk(sessionID: "s1")?.answer, ["A"])
        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    // MARK: Registry liveness (T1-T3, T8)

    /// `kind` and `entrypoint` are both optional here, and both for the
    /// same reason: they are fields of another program's undocumented
    /// file, and a test that can only build the shape this app happens to
    /// expect today cannot catch the day that shape changes. Which is
    /// exactly what happened: every fixture in this file said
    /// `kind: "interactive"`, so nothing noticed that a real background
    /// session says `"bg"` and was being thrown away whole.
    private func registryEntryJSON(
        sessionId: String = "s1", pid: Int = 4242, status: String = "idle",
        kind: String? = "interactive", cwd: String = "/a", name: String = "chalant-f1",
        entrypoint: String? = "cli"
    ) -> Data {
        let optional = [kind.map { "\"kind\":\"\($0)\"" }, entrypoint.map { "\"entrypoint\":\"\($0)\"" }]
            .compactMap { $0 }
            .map { "," + $0 }
            .joined()
        return Data("""
        {"sessionId":"\(sessionId)","pid":\(pid),"cwd":"\(cwd)","name":"\(name)",
         "status":"\(status)"\(optional)}
        """.utf8)
    }

    func testALiveSessionSittingAtItsPromptReadsAsIdleNotStale() {
        // The bug this whole feature is built on top of: a session
        // waiting at its prompt is not proof it ended, and only the
        // registry — never a quiet transcript file — can tell the two
        // apart.
        let entry = SessionRegistry.parse(registryEntryJSON(status: "idle"), filename: "4242.json")
        XCTAssertNotNil(entry)
        XCTAssertEqual(SessionRegistry.state(for: entry!, alive: { _ in true }), .idle)
        XCTAssertNil(SessionRegistry.state(for: entry!, alive: { _ in false }))

        // markLive must never blank what the scraper already knows —
        // the two-writers bug this store already fixed once for the
        // scraper itself (4d6ccff).
        let store = storeWithSession()
        store.upsert(id: "s1", title: "chalant", cwd: "/somewhere", branch: "main",
                     lastPrompt: "do the thing", state: .working, activity: "Editing")
        store.markLive(id: "s1", name: entry!.name, cwd: entry!.cwd, pid: entry!.pid,
                        kind: entry!.kind, status: .idle)
        XCTAssertEqual(store.sessions.first?.state, .idle)
        XCTAssertEqual(store.sessions.first?.title, "chalant")
        XCTAssertEqual(store.sessions.first?.activity, "Editing")
        XCTAssertEqual(store.sessions.first?.pid, 4242)
        XCTAssertEqual(store.sessions.first?.kind, .interactive)
    }

    func testARegistryEntryWhoseProcessIsGoneIsNotALiveSession() {
        let entry = SessionRegistry.parse(registryEntryJSON(status: "busy"), filename: "4242.json")
        XCTAssertNotNil(entry)
        XCTAssertNil(SessionRegistry.state(for: entry!, alive: { _ in false }))

        // A renamed file cannot lie about which process it speaks for:
        // the filename pid and the body pid are both checked.
        XCTAssertNil(SessionRegistry.parse(registryEntryJSON(), filename: "9999.json"))
    }

    func testTheRegistryGoingSilentNeverBlanksTheStrip() {
        let store = storeWithSession()
        // A failed read is not the directory saying "empty".
        store.markGone([])
        XCTAssertEqual(store.sessions.first?.state, .working)

        // A real id the registry no longer reports: last seen, not
        // dropped, and never claimed as `.done` — this store cannot
        // know a killed session finished.
        store.markGone(["s1"])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.state, .stale)
        XCTAssertNil(store.sessions.first?.pid)
    }

    func testMarkGoneFiresOnSessionGoneOncePerId() {
        // H5: whatever else is keyed off this session's id (the
        // ActivityStore pill the Claude Code hook posted) needs to hear
        // that it ended, so it can resolve instead of outliving it.
        let store = storeWithSession()
        var gone: [String] = []
        store.onSessionGone = { gone.append($0) }
        store.markGone([])
        XCTAssertEqual(gone, [], "an empty set is not the registry saying something ended")
        store.markGone(["s1"])
        XCTAssertEqual(gone, ["s1"])
        // An id the store never held is not a session that ended.
        store.markGone(["never-seen"])
        XCTAssertEqual(gone, ["s1"])
    }

    // MARK: What the registry actually writes

    /// The bug that made this app report a running agent as dead.
    ///
    /// `SessionStore.Kind` was written with the two words
    /// `claude agents --json` reports, and the file on disk uses neither
    /// for a background job: it says `"kind":"bg"`
    /// (~/.claude/sessions/65463.json, observed 2026-08-03, for a session
    /// that was running at the time). The old parser answered nil to the
    /// whole entry, so the pid went with it, `reconcileLive` concluded
    /// the registry had never heard of the session, and it was filed in
    /// the record as "this session's process went away" — permanently,
    /// because `disownedByRegistry` is sticky.
    func testABackgroundSessionIsReadRatherThanThrownAway() {
        let entry = SessionRegistry.parse(registryEntryJSON(kind: "bg"), filename: "4242.json")
        XCTAssertNotNil(entry, "a background session is still a session")
        XCTAssertEqual(entry?.kind, .background)
        XCTAssertEqual(entry?.pid, 4242)
    }

    /// Both spellings, so this cannot break again in either direction.
    func testTheOlderSpellingOfBackgroundIsStillRead() {
        let entry = SessionRegistry.parse(registryEntryJSON(kind: "background"), filename: "4242.json")
        XCTAssertEqual(entry?.kind, .background)
    }

    /// The rule that generalises the fix: **kind is decoration, the pid
    /// is the payload.** This file's own doc promises that a change on
    /// Claude Code's side costs a badge and nothing more; discarding the
    /// entry cost the whole session. A word this app has never seen now
    /// costs exactly that word.
    func testAKindThisAppHasNeverSeenCostsTheKindAndNothingElse() {
        let entry = SessionRegistry.parse(
            registryEntryJSON(kind: "some-kind-from-2027"), filename: "4242.json")
        XCTAssertNotNil(entry, "an unknown kind is not a reason to lose a live pid")
        XCTAssertNil(entry?.kind)
        XCTAssertEqual(entry?.pid, 4242)
        XCTAssertEqual(entry?.sessionId, "s1")
    }

    func testAnEntryWithNoKindAtAllIsStillAnEntry() {
        let entry = SessionRegistry.parse(registryEntryJSON(kind: nil), filename: "4242.json")
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.kind)
    }

    /// Everything the parser genuinely cannot do without is still fatal.
    /// Loosening `kind` must not loosen these.
    func testTheFieldsThatActuallyIdentifyASessionAreStillRequired() {
        XCTAssertNil(
            SessionRegistry.parse(Data(#"{"pid":4242,"cwd":"/a"}"#.utf8), filename: "4242.json"),
            "no sessionId, no session")
        XCTAssertNil(
            SessionRegistry.parse(Data(#"{"sessionId":"s1","cwd":"/a"}"#.utf8), filename: "4242.json"),
            "no pid, nothing to check for life")
        XCTAssertNil(
            SessionRegistry.parse(registryEntryJSON(cwd: "not/absolute"), filename: "4242.json"),
            "a cwd that is not a path is not a cwd")
    }

    // MARK: Whose session is it

    /// claude-mem's observer registers itself exactly like a person's
    /// shell does, and it is not a person's shell. `kind` cannot tell
    /// them apart (both say `interactive`) and neither can the absence of
    /// a terminal, because the founder's own background jobs have no
    /// terminal either. `entrypoint` can: Claude Code writes `sdk-cli`
    /// for a session the SDK launched
    /// (~/.claude/sessions/27558.json, the claude-mem observer, observed
    /// 2026-08-03 beside two `cli` sessions of the founder's own).
    func testAnSDKLaunchedSessionIsNobodysAgent() {
        XCTAssertTrue(SessionRegistry.isHeadlessBot(entrypoint: "sdk-cli"))
    }

    /// A deny-list of the known-headless, never an allow-list of the
    /// known-human: a new entrypoint that real people use must not
    /// silently vanish from the rail.
    func testEverythingElseIsSomebodysAgentUntilProvenOtherwise() {
        XCTAssertFalse(SessionRegistry.isHeadlessBot(entrypoint: "cli"))
        XCTAssertFalse(SessionRegistry.isHeadlessBot(entrypoint: nil))
        XCTAssertFalse(SessionRegistry.isHeadlessBot(entrypoint: "some-entrypoint-from-2027"))
    }

    /// The founder's own background jobs are `cli` with `kind: "bg"`, and
    /// hiding bots must never hide those. They belong on the list; they
    /// simply have no terminal to be typed into.
    func testABackgroundJobIsTheFoundersEvenThoughItHasNoTerminal() {
        let entry = SessionRegistry.parse(
            registryEntryJSON(kind: "bg", entrypoint: "cli"), filename: "4242.json")
        XCTAssertEqual(entry?.kind, .background)
        XCTAssertFalse(SessionRegistry.isHeadlessBot(entrypoint: entry?.entrypoint))
    }

    // MARK: When a session actually started

    /// Two agents in one repo, and nothing on either row to tell them
    /// apart.
    ///
    /// Claude Code names a session after its work, so two sessions doing
    /// the same job in the same folder get the same name: the founder's
    /// own machine had two live rows both reading "Push changes to PR and
    /// pull", in the same repo, on the same branch (2026-08-03). The rail
    /// already knows to fall back to the start time when titles collide,
    /// and the start time it had was the moment *this app* first noticed
    /// the session, which at launch is the same instant for every row on
    /// screen. So the tiebreaker read "from 18:13" on both.
    ///
    /// The registry has the real answer and always did: `startedAt`, in
    /// epoch milliseconds, per session.
    func testTheRegistryKnowsWhenASessionActuallyStarted() {
        let json = #"""
        {"sessionId":"s1","pid":4242,"cwd":"/a","name":"n","kind":"interactive",
         "entrypoint":"cli","status":"idle","startedAt":1785666427179}
        """#
        let entry = SessionRegistry.parse(Data(json.utf8), filename: "4242.json")
        XCTAssertEqual(entry?.startedAt, Date(timeIntervalSince1970: 1_785_666_427.179))
    }

    func testAnAbsentOrNonsenseStartTimeIsSimplyNotOne() {
        XCTAssertNil(SessionRegistry.parse(registryEntryJSON(), filename: "4242.json")?.startedAt)
        let zero = #"{"sessionId":"s","pid":1,"cwd":"/a","kind":"interactive","startedAt":0}"#
        XCTAssertNil(SessionRegistry.parse(Data(zero.utf8), filename: "1.json")?.startedAt)
    }

    /// And the row takes it, over the "first seen here" stand-in, because
    /// one of the two is a fact about the session and the other is a fact
    /// about when the app happened to open.
    func testTwoSessionsInOneRepoAreToldApartByWhenTheyReallyStarted() {
        let store = SessionStore()
        let morning = Date(timeIntervalSince1970: 1_785_666_427)
        let evening = Date(timeIntervalSince1970: 1_785_727_118)
        store.markLive(id: "older", name: "Push changes to PR and pull", cwd: "/moai", pid: 1,
                       kind: .interactive, status: .idle, startedAt: morning)
        store.markLive(id: "newer", name: "Push changes to PR and pull", cwd: "/moai", pid: 2,
                       kind: .interactive, status: .idle, startedAt: evening)

        XCTAssertEqual(store.sessions.first { $0.id == "older" }?.startedAt, morning)
        XCTAssertEqual(store.sessions.first { $0.id == "newer" }?.startedAt, evening)
        XCTAssertEqual(store.sessions.map(\.id), ["newer", "older"],
                       "and the sort finally means something: newest first")
    }

    /// A session the registry has no start time for keeps the stand-in
    /// rather than losing the one it had.
    func testASessionWithNoRealStartTimeKeepsTheStandIn() {
        let store = SessionStore()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .idle)
        let standIn = try? XCTUnwrap(store.sessions.first?.startedAt)
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        XCTAssertEqual(store.sessions.first?.startedAt, standIn)
    }

    // MARK: The whole directory, end to end

    /// The test that would have caught all of this.
    ///
    /// Every registry test above this one checks `parse` in isolation and
    /// every store test drives the store by hand, so both halves were
    /// green while the thing they add up to was broken on the founder's
    /// own machine. This drives the real `SessionRegistry` over a real
    /// directory holding the exact three files that were on that machine
    /// (2026-08-03) and asks what a person would actually see.
    ///
    /// The three: their own session in a VS Code terminal wearing a
    /// twenty-one hour old `busy`; claude-mem's observer, registered as
    /// `sdk-cli`; and a `claude bg` job whose kind is spelled `bg`.
    private func writeRegistry(_ files: [(pid: Int, json: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant.tests.registry.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            try Data(file.json.utf8).write(to: root.appendingPathComponent("\(file.pid).json"))
        }
        return root
    }

    func testTheFoundersOwnMachineReadCorrectly() throws {
        let root = try writeRegistry([
            (14727, #"{"sessionId":"mine","pid":14727,"cwd":"/Users/x/moai","name":"roll-out-echo-mark","kind":"interactive","entrypoint":"cli","status":"busy"}"#),
            (33079, #"{"sessionId":"observer","pid":33079,"cwd":"/Users/x/.claude-mem/observer-sessions","name":"observer-sessions-ad","kind":"interactive","entrypoint":"sdk-cli"}"#),
            (65463, #"{"sessionId":"bgjob","pid":65463,"cwd":"/Users/x/moai","name":"Push changes to PR and pull","kind":"bg","entrypoint":"cli","status":"busy"}"#),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore()
        let registry = SessionRegistry(
            store: store, root: root,
            isAlive: { _ in true },
            // Only the VS Code session holds one. A background job does
            // not, and neither does the observer.
            hasTerminal: { $0 == 14727 }
        )
        registry.start()
        defer { registry.stop() }

        XCTAssertEqual(Set(store.sessions.map(\.id)), ["mine", "bgjob"],
                       "the observer is another program's worker and does not belong on the list")
        XCTAssertEqual(store.sessions.first { $0.id == "bgjob" }?.kind, .background,
                       "\"bg\" is a kind, not a parse failure")
        XCTAssertEqual(store.sessions.first { $0.id == "bgjob" }?.pid, 65463)
        XCTAssertTrue(store.finished.isEmpty, "nothing here ended, so the record is empty")
    }

    // MARK: A call at the door from a session nobody has heard of

    /// The hole the founder's own live test found (2026-08-08). A
    /// `claude -p` run leaves a transcript but never registers in
    /// `~/.claude/sessions`, so the store had no row for it and threw
    /// its held call away. Anything headless walked straight past the
    /// gate, which for a supervision feature is the whole feature
    /// missing.
    ///
    /// It also contradicted this file's own doctrine: a held call is the
    /// strongest proof of life there is, because a process is standing
    /// in that hook right now waiting on an answer. That outranks a
    /// registry file, so it is allowed to make its own row.
    func testACallFromAnUnknownSessionMakesItsOwnRow() {
        let store = SessionStore()

        let held = store.holdForApproval(
            sessionID: "headless", id: "call-1", tool: "Bash", detail: "rm -rf build",
            cwd: "/Users/x/moai", rules: ["Bash"])

        XCTAssertTrue(held)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.approval?.detail, "rm -rf build")
        XCTAssertEqual(store.sessions.first?.cwd, "/Users/x/moai")
        XCTAssertEqual(store.sessions.first?.title, "moai", "the folder is the only name it has")
        XCTAssertEqual(store.groups().first?.group, .needsYou)
    }

    /// Only when the call is actually held. Every tool call in every
    /// session reaches this route, gated or not, and inventing a row for
    /// each one would put every headless worker on the machine on the
    /// rail, which is exactly what `isHeadlessBot` exists to prevent.
    func testAnUngatedCallFromAnUnknownSessionInventsNothing() {
        let store = SessionStore()

        let held = store.holdForApproval(
            sessionID: "headless", id: "call-1", tool: "Read", detail: "/a/b.txt",
            cwd: "/Users/x/moai", rules: ["Bash"])

        XCTAssertFalse(held)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// And the row has to survive the sweep that lands five seconds
    /// later. The registry never reported this session and never will,
    /// so `reconcileLive` would file it as lost while its agent is still
    /// standing at the door.
    func testTheRegistryDoesNotDisownARowAHookIsStandingIn() {
        let store = SessionStore()
        _ = store.holdForApproval(
            sessionID: "headless", id: "call-1", tool: "Bash", detail: "rm -rf build",
            cwd: "/Users/x/moai", rules: ["Bash"])

        // A sweep that saw somebody else entirely.
        store.markLive(id: "other", name: "n", cwd: "/a", pid: 1,
                       kind: .interactive, status: .working)
        store.reconcileLive(against: ["other"])

        XCTAssertEqual(store.sessions.first(where: { $0.id == "headless" })?.state, .needsInput)
        XCTAssertTrue(store.finished.isEmpty, "nothing here ended")
    }

    /// The exemption is a vouch, not a permanent pass. Once the hook has
    /// been gone longer than the window, the registry's word stands
    /// again and the row leaves like any other.
    func testAnOldVouchStopsProtectingTheRow() {
        let store = SessionStore()
        _ = store.holdForApproval(
            sessionID: "headless", id: "call-1", tool: "Bash", detail: "rm -rf build",
            cwd: "/Users/x/moai", rules: ["Bash"])
        store.expireVouch(sessionID: "headless")

        store.markLive(id: "other", name: "n", cwd: "/a", pid: 1,
                       kind: .interactive, status: .working)
        store.reconcileLive(against: ["other"])

        XCTAssertEqual(store.sessions.first(where: { $0.id == "headless" })?.state, .stale)
    }

    /// A call with no folder still gets a row: something is waiting on
    /// an answer, and having nothing to call it is not a reason to drop
    /// the question.
    func testACallWithNoFolderStillGetsARow() {
        let store = SessionStore()

        XCTAssertTrue(store.holdForApproval(
            sessionID: "headless", id: "call-1", tool: "Bash", detail: "curl example.com",
            cwd: nil, rules: ["Bash"]))
        XCTAssertEqual(store.sessions.first?.title, "An agent")
    }

    // MARK: A prompt Claude Code is showing in its own terminal

    /// The band exists so nothing waiting on a person is ever quiet. A
    /// terminal prompt is exactly that, even though the island cannot
    /// answer it.
    func testASessionStuckAtATerminalPromptLandsInAnswerThis() {
        let store = SessionStore()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)

        store.notePendingPrompt(sessionID: "s", tool: "Bash", detail: "git push --force")

        XCTAssertEqual(store.groups().first?.group, .needsYou)
        XCTAssertEqual(store.sessions.first?.pendingPrompt?.detail, "git push --force")
    }

    /// Decoration, not creation, the same law `attach` follows: a
    /// notification for a session nobody vouches for cannot invent a row.
    func testAPromptForAnUnknownSessionIsDropped() {
        let store = SessionStore()

        store.notePendingPrompt(sessionID: "ghost", tool: "Bash", detail: "rm -rf /")

        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// The turn ending is proof the prompt was answered: Claude Code
    /// cannot finish a turn while it is still standing at one.
    func testTheTurnEndingClearsTheTerminalPrompt() {
        let store = SessionStore()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        store.notePendingPrompt(sessionID: "s", tool: "Bash", detail: "git push")

        store.clearPendingPrompt(sessionID: "s")

        XCTAssertNil(store.sessions.first?.pendingPrompt)
    }

    /// And so is the next tool call: Claude Code does not reach for one
    /// while a prompt about the last one is unanswered.
    func testTheNextHeldCallClearsTheTerminalPrompt() {
        let store = SessionStore()
        store.markLive(id: "s", name: "n", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        store.notePendingPrompt(sessionID: "s", tool: "Bash", detail: "git push")

        _ = store.holdForApproval(
            sessionID: "s", id: "call-1", tool: "Bash", detail: "ls", rules: ["Bash"])

        XCTAssertNil(store.sessions.first?.pendingPrompt)
        XCTAssertEqual(store.sessions.first?.approval?.detail, "ls")
    }

    // MARK: Not asking twice about the same thing
    //
    // "Yes, and don't ask again for git *" is a Grant now, checked by
    // `settleGate` where the policy store lives — GatePipelineTests
    // proves a grant makes the gate stand aside, and PolicyTests proves
    // the grant itself. This store only answers to the hold rules.

    /// The button's text has to be the rule it will write, or somebody
    /// taps "always allow" and gets a different promise than they read.
    func testTheSuggestedExceptionIsTheCommandsOwnName() {
        XCTAssertEqual(
            SessionStore.suggestedException(tool: "Bash", detail: "git --version"),
            "Bash(git *)")
        XCTAssertEqual(
            SessionStore.suggestedException(tool: "Bash", detail: "npm run build -- --watch"),
            "Bash(npm *)")
    }

    /// A command with a path or a pipe in it must not become a rule
    /// covering half the machine. When the first word is not a plain
    /// command name, the offer is the exact command and nothing wider.
    func testAnUnusualCommandOffersOnlyItself() {
        XCTAssertEqual(
            SessionStore.suggestedException(tool: "Bash", detail: "./scripts/deploy.sh prod"),
            "Bash(./scripts/deploy.sh prod)")
        XCTAssertEqual(
            SessionStore.suggestedException(tool: "Bash", detail: "rm -rf / && echo done"),
            "Bash(rm -rf / && echo done)")
    }

    /// For everything that is not a shell command there is no first
    /// word to generalise from, so the offer is the whole tool.
    func testANonShellToolOffersTheToolItself() {
        XCTAssertEqual(
            SessionStore.suggestedException(tool: "Write", detail: "/a/b/notes.md"), "Write")
        XCTAssertEqual(SessionStore.suggestedException(tool: "Edit", detail: ""), "Edit")
    }

    // MARK: The session that can be picked up on a phone

    /// A bridged session carries the id claude.ai/code knows it by, and
    /// that is the whole "control it from your phone" story: the Claude
    /// app drives the session, this app hands you the door. Read off the
    /// registry file rather than inferred from a setting, so a row only
    /// offers it when it is actually true of that session.
    func testABridgedSessionKnowsWhereItCanBePickedUp() throws {
        let entry = try XCTUnwrap(SessionRegistry.parse(Data(#"""
        {"sessionId":"mine","pid":16155,"cwd":"/Users/x/moai","kind":"interactive",
         "bridgeSessionId":"session_01Vmte6hoS5L6Lww4F4a3Mh4"}
        """#.utf8), filename: "16155.json"))

        XCTAssertEqual(entry.bridgeID, "session_01Vmte6hoS5L6Lww4F4a3Mh4")
        XCTAssertEqual(SessionStore.Session.phoneURL(bridgeID: entry.bridgeID)?.absoluteString,
                       "https://claude.ai/code/session_01Vmte6hoS5L6Lww4F4a3Mh4")
    }

    func testASessionWithNoBridgeOffersNoLink() throws {
        let entry = try XCTUnwrap(SessionRegistry.parse(Data(#"""
        {"sessionId":"mine","pid":16155,"cwd":"/Users/x/moai","kind":"interactive"}
        """#.utf8), filename: "16155.json"))

        XCTAssertNil(entry.bridgeID)
        XCTAssertNil(SessionStore.Session.phoneURL(bridgeID: nil))
    }

    /// An id with a slash in it would build a URL pointing somewhere
    /// else entirely, and this link is offered as "your session".
    func testAnIDThatIsNotAnIDBuildsNoLink() {
        XCTAssertNil(SessionStore.Session.phoneURL(bridgeID: "../../somewhere/else"))
        XCTAssertNil(SessionStore.Session.phoneURL(bridgeID: ""))
    }

    // MARK: Background agents, which have no registry file at all

    /// A `claude bg` job run through the daemon registers no
    /// `~/.claude/sessions/<pid>.json` at all: it lives in
    /// `~/.claude/jobs/<short>/state.json`, with its process listed in
    /// the daemon's roster. So the whole class was invisible here, and
    /// the founder's own agent sat blocked for three days behind a line
    /// this app could have shown on day one.
    private func writeJobs(
        _ jobs: [(short: String, json: String)], roster: String
    ) throws -> (jobs: URL, roster: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant.tests.jobs.\(UUID().uuidString)")
        for job in jobs {
            let dir = root.appendingPathComponent(job.short)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(job.json.utf8).write(to: dir.appendingPathComponent("state.json"))
        }
        let rosterURL = root.appendingPathComponent("roster.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(roster.utf8).write(to: rosterURL)
        return (root, rosterURL)
    }

    func testALiveBackgroundAgentIsOnTheRailWithWhatItNeeds() throws {
        let registryRoot = try writeRegistry([])
        let written = try writeJobs([
            (short: "b8827367", json: #"""
            {"state":"blocked","sessionId":"bgjob","name":"Push changes to PR and pull",
             "cwd":"/Users/x/moai","tokens":384376,
             "needs":"say the word and I'll bump to 1.6.1 and do the proper release",
             "suggestedReply":"bump to 1.6.1 and do the proper release"}
            """#),
        ], roster: #"{"proto":1,"supervisorPid":27476,"workers":{"b8827367":{"pid":65450,"sessionId":"bgjob"}}}"#)
        defer {
            try? FileManager.default.removeItem(at: registryRoot)
            try? FileManager.default.removeItem(at: written.jobs)
        }

        let store = SessionStore()
        let registry = SessionRegistry(
            store: store, root: registryRoot,
            jobsRoot: written.jobs, rosterURL: written.roster,
            isAlive: { $0 == 65450 }, hasTerminal: { _ in false })
        registry.start()
        defer { registry.stop() }

        let session = store.sessions.first { $0.id == "bgjob" }
        XCTAssertNotNil(session, "a background agent with a live worker is a session")
        XCTAssertEqual(session?.kind, .background)
        XCTAssertEqual(session?.job?.state, .blocked)
        XCTAssertEqual(SessionActivity.line(for: session!).text,
                       "say the word and I'll bump to 1.6.1 and do the proper release")
    }

    /// The same file, three days later, with the daemon long gone. This
    /// is the branch's own law applied to a second directory: a pid
    /// makes a session real, a warm file does not.
    func testABackgroundAgentWhoseWorkerIsGoneIsNotOnTheRail() throws {
        let registryRoot = try writeRegistry([])
        let written = try writeJobs([
            (short: "b8827367", json: #"{"state":"blocked","sessionId":"bgjob","needs":"say the word"}"#),
        ], roster: #"{"proto":1,"supervisorPid":27476,"workers":{"b8827367":{"pid":65450,"sessionId":"bgjob"}}}"#)
        defer {
            try? FileManager.default.removeItem(at: registryRoot)
            try? FileManager.default.removeItem(at: written.jobs)
        }

        let store = SessionStore()
        let registry = SessionRegistry(
            store: store, root: registryRoot,
            jobsRoot: written.jobs, rosterURL: written.roster,
            isAlive: { _ in false }, hasTerminal: { _ in false })
        registry.start()
        defer { registry.stop() }

        XCTAssertTrue(store.sessions.isEmpty,
                      "a three day old question from a dead process is not something to ask about")
    }

    /// A job the roster has never heard of has no process behind it
    /// either, whatever its file says.
    func testAJobMissingFromTheRosterIsNotOnTheRail() throws {
        let registryRoot = try writeRegistry([])
        let written = try writeJobs([
            (short: "orphan", json: #"{"state":"working","sessionId":"ghost"}"#),
        ], roster: #"{"proto":1,"supervisorPid":1,"workers":{}}"#)
        defer {
            try? FileManager.default.removeItem(at: registryRoot)
            try? FileManager.default.removeItem(at: written.jobs)
        }

        let store = SessionStore()
        let registry = SessionRegistry(
            store: store, root: registryRoot,
            jobsRoot: written.jobs, rosterURL: written.roster,
            isAlive: { _ in true }, hasTerminal: { _ in false })
        registry.start()
        defer { registry.stop() }

        XCTAssertTrue(store.sessions.isEmpty)
    }

    /// And then the transcripts arrive, which is the moment the rail used
    /// to start blinking: the registry says busy every five seconds, the
    /// scraper says the file went cold every twenty, and a cold row is
    /// filtered out of the rail entirely.
    func testASweepAfterAColdTranscriptLeavesTheRailStandingStill() throws {
        let root = try writeRegistry([
            (14727, #"{"sessionId":"mine","pid":14727,"cwd":"/Users/x/moai","name":"roll-out-echo-mark","kind":"interactive","entrypoint":"cli","status":"busy"}"#),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore()
        let registry = SessionRegistry(
            store: store, root: root, isAlive: { _ in true }, hasTerminal: { _ in true })
        registry.start()
        defer { registry.stop() }

        // The scraper reads a transcript last written an hour ago, over
        // and over, exactly as it does every twenty seconds forever.
        for _ in 0..<5 {
            store.upsert(id: "mine", title: "Chalant 1.6.0", cwd: "/Users/x/moai", branch: "main",
                         lastPrompt: nil, state: .stale,
                         updatedAt: Date().addingTimeInterval(-3600))
        }

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.state, .idle,
                       "alive, and a day-old \"busy\" is not evidence it is working")
        XCTAssertEqual(store.groups().first?.group, .atPrompt)
        XCTAssertEqual(store.groups().first?.live.map(\.id), ["mine"],
                       "and it is on the rail, every single time somebody looks")
        XCTAssertTrue(store.finished.isEmpty)
        XCTAssertEqual(store.sessions.first?.title, "Chalant 1.6.0",
                       "the registry says who exists; the transcript still says who they are")
    }

    func testAnOutstandingQuestionStillOutranksTheRegistry() {
        let store = storeWithSession()
        store.attach(askID: "q", to: "s1", header: "h", question: "q?",
                     options: ["A"], multiSelect: false)
        XCTAssertEqual(store.sessions.first?.state, .needsInput)

        store.markLive(id: "s1", name: "t", cwd: "/a", pid: 1, kind: .interactive, status: .working)
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
    }

    // MARK: A session with nowhere to show you a reply

    /// `kind` cannot answer this. Claude Code reports its own headless
    /// worker as `interactive` alongside a real terminal session
    /// (verified 2026-08-02 against `claude agents --json`: the
    /// claude-mem indexer at ~/.claude-mem/observer-sessions and a
    /// person's own shell come back wearing the same word). The honest
    /// question is not what the session is called but whether there is
    /// a window anywhere that a reply could appear in, which is exactly
    /// what a controlling terminal is.
    func testASessionWithNoTerminalIsNotOfferedAComposer() {
        let store = SessionStore()
        store.markLive(id: "headless", name: "observer-sessions", cwd: "/a/observer-sessions",
                       pid: 1, kind: .interactive, hasTerminal: false, status: .working)

        XCTAssertFalse(store.sessions.first?.canReceiveMessages ?? true,
                       "a session with no terminal has nowhere to put an answer")
    }

    func testASessionWithATerminalIsStillOfferedAComposer() {
        let store = SessionStore()
        store.markLive(id: "real", name: "t", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: true, status: .working)

        XCTAssertTrue(store.sessions.first?.canReceiveMessages ?? false)
    }

    /// Only ever demoted on positive knowledge. A scraper row has no
    /// pid, so nobody has looked, and a row found from a transcript
    /// alone must keep behaving exactly as it did before this signal
    /// existed — the same rule `markLive` follows for every other field
    /// the registry does not own.
    func testASessionNobodyHasCheckedKeepsItsComposer() {
        let store = storeWithSession()
        XCTAssertNil(store.sessions.first?.hasTerminal)
        XCTAssertTrue(store.sessions.first?.canReceiveMessages ?? false)
    }

    /// The registry owns this field and a sweep must not un-learn it:
    /// `markLive` runs every five seconds, and an overwrite with a
    /// stale default is how a row would silently get its composer back.
    func testASweepDoesNotForgetThatThereIsNoTerminal() {
        let store = SessionStore()
        store.markLive(id: "headless", name: "n", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: false, status: .working)
        store.markLive(id: "headless", name: "n", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: false, status: .idle)

        XCTAssertEqual(store.sessions.first?.hasTerminal, false)
        XCTAssertFalse(store.sessions.first?.canReceiveMessages ?? true)
    }

    // MARK: A terminal nobody can address

    /// Having a terminal and being reachable are two different questions,
    /// and this app was only asking the first one.
    ///
    /// The founder's own session runs in VS Code's integrated terminal.
    /// The kernel says it holds ttys002, so `hasTerminal` is true and the
    /// composer opened. But typing is done by asking Terminal or iTerm
    /// which of their tabs owns that tty, and VS Code answers no such
    /// question, so every message silently became a note for later.
    func testASessionInsideAnEditorSaysSoInsteadOfTakingAMessage() {
        let store = SessionStore()
        store.markLive(id: "s", name: "moai", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: true, status: .working)
        store.noteOwningApp(id: "s", bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")

        XCTAssertFalse(store.sessions.first?.canReceiveMessages ?? true)
        XCTAssertEqual(AgentSessionsStrip.unreachableReason(store.sessions[0]),
                       "runs in Visual Studio Code, which Chalant can't type into")
    }

    func testASessionInARealTerminalKeepsItsComposer() {
        let store = SessionStore()
        store.markLive(id: "s", name: "moai", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: true, status: .working)
        store.noteOwningApp(id: "s", bundleID: "com.apple.Terminal", name: "Terminal")

        XCTAssertTrue(store.sessions.first?.canReceiveMessages ?? false)
        XCTAssertNil(AgentSessionsStrip.unreachableReason(store.sessions[0]))
    }

    /// The rule is one-sided on purpose, and this is the case that makes
    /// it so. A session started detached has no application ancestor at
    /// all, and Terminal may still own its tty
    /// (`SessionRemote.target(for:)`, which is what actually decides).
    /// Nobody being able to name an owning app is not evidence of
    /// anything, so nothing is taken away.
    func testASessionWithNoOwningAppAtAllIsLeftAlone() {
        let store = SessionStore()
        store.markLive(id: "s", name: "moai", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: true, status: .working)

        XCTAssertNil(store.sessions.first?.terminalApp)
        XCTAssertTrue(store.sessions.first?.canReceiveMessages ?? false)
        XCTAssertNil(AgentSessionsStrip.unreachableReason(store.sessions[0]))
    }

    /// A background job has no terminal at all, and that is the more
    /// fundamental thing to say about it. It is also the case most likely
    /// to be mislabelled: a `claude bg` job started from a VS Code
    /// terminal still has VS Code somewhere up its parent chain.
    func testNoTerminalOutranksWhicheverAppHappensToBeUpTheChain() {
        let store = SessionStore()
        store.markLive(id: "bg", name: "a background job", cwd: "/a", pid: 1,
                       kind: .background, hasTerminal: false, status: .working)
        store.noteOwningApp(id: "bg", bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")

        XCTAssertEqual(AgentSessionsStrip.unreachableReason(store.sessions[0]), "no terminal")
    }

    /// Terminal and iTerm, and the same set `SessionRemote` types into:
    /// two copies of this list is exactly how a row would promise
    /// something the sender cannot deliver.
    func testTheAddressableTerminalsAreTheOnesThatCanActuallyBeTypedInto() {
        XCTAssertTrue(SessionRemote.canAddress(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(SessionRemote.canAddress(bundleID: "com.googlecode.iterm2"))
        XCTAssertFalse(SessionRemote.canAddress(bundleID: "com.microsoft.VSCode"))
        XCTAssertTrue(
            SessionRemote.canType(
                into: SessionRemote.Target(
                    tty: "/dev/ttys002", bundleID: "com.apple.Terminal", appName: "Terminal")),
            "the sender and the row read the same list")
    }

    /// launchd is pid 1 on every Mac and has never had a controlling
    /// terminal, which makes it the one process this can assert against
    /// without spawning anything.
    func testTheKernelIsAskedWhetherAProcessHasATerminal() {
        XCTAssertFalse(SessionRegistry.processHasTerminal(1))
    }

    /// Every unknown answers "yes". A pid that has gone, a pid that
    /// never was, a sysctl that failed: none of those are evidence of a
    /// missing terminal, and guessing "no" would quietly take the
    /// composer off a session that has one.
    func testAProcessTheKernelCannotFindIsNeverDemoted() {
        XCTAssertTrue(SessionRegistry.processHasTerminal(0))
        XCTAssertTrue(SessionRegistry.processHasTerminal(-1))
        XCTAssertTrue(SessionRegistry.processHasTerminal(999_999))
    }

    // MARK: Holding a tool call at the door

    /// A hook asks before every single tool call, so the answer for
    /// anything ungated has to be an instant no. Anything else puts a
    /// pause on work nobody asked to supervise.
    func testAnUngatedToolIsNeverHeld() {
        let store = storeWithSession()
        XCTAssertFalse(store.holdForApproval(
            sessionID: "s1", id: "call-1", tool: "Read", detail: "/etc/hosts", rules: ["Bash"]))
        XCTAssertNil(store.sessions.first?.approval)
    }

    func testAGatedToolIsHeldAndShownVerbatim() {
        let store = storeWithSession()
        XCTAssertTrue(store.holdForApproval(
            sessionID: "s1", id: "call-1", tool: "Bash",
            detail: "rm -rf build && xcodebuild test", rules: ["Bash"]))

        let approval = store.sessions.first?.approval
        XCTAssertEqual(approval?.tool, "Bash")
        XCTAssertEqual(approval?.detail, "rm -rf build && xcodebuild test",
                       "the command is shown as written, never summarised")
        XCTAssertNil(approval?.decision)
    }

    /// This rule was the other way round until 2026-08-08, and the doc
    /// here said "nowhere to draw a card is a reason to decline, not to
    /// invent a row". It sounded careful and it was a hole: a `claude
    /// -p` run registers nowhere, so its held calls were dropped and
    /// every headless agent on the machine walked past a gate the user
    /// believed was holding everything. The founder's own live test
    /// found it within a minute of arming.
    ///
    /// A hook mid-call is a process talking to this app right now about
    /// something it is doing this second. Declining to draw that is not
    /// caution, it is losing the one event the whole feature exists for.
    /// See `testACallFromAnUnknownSessionMakesItsOwnRow` for the shape
    /// of the row it makes.
    func testAToolCallForAnUnknownSessionIsHeldOnItsOwnNewRow() {
        let store = SessionStore()
        XCTAssertTrue(store.holdForApproval(
            sessionID: "ghost", id: "c", tool: "Bash", detail: "ls", rules: ["Bash"]))
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.approval?.detail, "ls")
    }

    /// Two cards racing for one row is worse than the second call going
    /// to the terminal.
    func testOnlyOneCallIsHeldPerSessionAtATime() {
        let store = storeWithSession()
        XCTAssertTrue(store.holdForApproval(
            sessionID: "s1", id: "first", tool: "Bash", detail: "one", rules: ["Bash"]))
        XCTAssertFalse(store.holdForApproval(
            sessionID: "s1", id: "second", tool: "Bash", detail: "two", rules: ["Bash"]))
        XCTAssertEqual(store.sessions.first?.approval?.id, "first")
    }

    /// The hook gave up and the question went back to the terminal, so
    /// the card has to go with it.
    func testAnAbandonedCallLeavesNoCardBehind() {
        let store = storeWithSession()
        _ = store.holdForApproval(
            sessionID: "s1", id: "c", tool: "Bash", detail: "ls", rules: ["Bash"])
        store.abandonApproval(id: "c")
        XCTAssertNil(store.sessions.first?.approval)
    }

    /// Off until asked for. An install that never opts in behaves
    /// exactly as it did, and a hook talking to an older Chalant is told
    /// no and gets out of the way.
    func testNothingIsHeldByDefault() {
        let empty = UserDefaults(suiteName: "chalant.tests.gates")!
        empty.removePersistentDomain(forName: "chalant.tests.gates")
        XCTAssertTrue(SessionStore.approvalRules(in: empty).isEmpty)

        empty.set("Bash(rm *)\n\n  Write  \n", forKey: SessionStore.approvalRulesKey)
        XCTAssertEqual(SessionStore.approvalRules(in: empty), ["Bash(rm *)", "Write"],
                       "blank lines and stray spacing are typing, not rules")
    }

    // MARK: Which calls a rule actually wants

    /// A bare tool name holds everything it names, which is the blunt
    /// instrument the pattern form exists to replace.
    func testABareToolNameHoldsEveryCallToIt() {
        XCTAssertTrue(SessionStore.rule("Bash", holds: "Bash", "ls"))
        XCTAssertTrue(SessionStore.rule("Bash", holds: "Bash", "rm -rf /"))
        XCTAssertFalse(SessionStore.rule("Bash", holds: "Write", "anything"))
    }

    /// The whole point: an agent runs dozens of reads for every delete,
    /// and holding all of them to catch one means approving so much that
    /// you stop reading.
    func testAPatternHoldsOnlyWhatItNames() {
        let rule = "Bash(rm *)"
        XCTAssertTrue(SessionStore.rule(rule, holds: "Bash", "rm -rf build"))
        XCTAssertFalse(SessionStore.rule(rule, holds: "Bash", "ls -la"))
        XCTAssertFalse(SessionStore.rule(rule, holds: "Bash", "echo rm"),
                       "the pattern anchors at the start, so a mention is not a use")
        XCTAssertFalse(SessionStore.rule(rule, holds: "Write", "rm -rf build"),
                       "the tool has to match too")
    }

    /// Claude Code's own rules treat "git *" as matching a bare "git",
    /// and a syntax borrowed for familiarity has to behave the same or
    /// it is worse than a new one.
    func testTrailingStarAlsoHoldsTheBareCommand() {
        XCTAssertTrue(SessionStore.rule("Bash(git push *)", holds: "Bash", "git push"))
        XCTAssertTrue(SessionStore.rule("Bash(git push *)", holds: "Bash", "git push --force"))
        XCTAssertFalse(SessionStore.rule("Bash(git push *)", holds: "Bash", "git pushover"),
                       "the space is part of the pattern")
    }

    func testAStarMatchesAnywhereItIsWritten() {
        XCTAssertTrue(SessionStore.glob("*prod*", matches: "deploy to prod now"))
        XCTAssertTrue(SessionStore.glob("*", matches: ""))
        XCTAssertTrue(SessionStore.glob("a*b*c", matches: "axxbyyc"))
        XCTAssertFalse(SessionStore.glob("a*b*c", matches: "axxbyy"))
        XCTAssertFalse(SessionStore.glob("", matches: "x"))
    }

    /// No regex, on purpose. A field where a stray dot silently widens
    /// what gets held is the wrong field for deciding whether a command
    /// runs.
    func testRegexCharactersAreJustCharacters() {
        XCTAssertFalse(SessionStore.rule("Bash(.*)", holds: "Bash", "rm -rf /"))
        XCTAssertTrue(SessionStore.rule("Bash(.*)", holds: "Bash", ".anything"))
    }

    /// Malformed rules hold nothing rather than everything. Getting this
    /// backwards would turn a typo into a stalled agent.
    func testAMalformedRuleHoldsNothing() {
        for bad in ["", "   ", "Bash(", "(rm *)", "Bash)rm *("] {
            XCTAssertFalse(SessionStore.rule(bad, holds: "Bash", "rm -rf /"), bad)
        }
    }

    /// Every suggestion the UI offers has to be a rule the matcher
    /// actually understands, or the button ships a dud.
    func testEverySuggestedRuleParses() {
        for rule in SessionStore.suggestedApprovalRules {
            XCTAssertTrue(rule.hasPrefix("Bash("), rule)
            let sample = String(rule.dropFirst("Bash(".count).dropLast())
                .replacingOccurrences(of: "*", with: "something")
            XCTAssertTrue(SessionStore.rule(rule, holds: "Bash", sample),
                          "\(rule) does not match its own shape")
        }
    }

    // MARK: A warm file is not a running process

    /// `SessionDiscovery` infers "still going" from a transcript's
    /// mtime. `SessionRegistry` reads a directory Claude Code writes one
    /// file per live process into. When they disagree, the one holding a
    /// pid is right, and until now it had no way to say so: the overlay
    /// could only ever add liveness, never withdraw it.
    ///
    /// Seen on the shipped 1.4.0: claude-mem's indexer kept a row in the
    /// strip, and a place in the island's count, while `claude agents`
    /// listed one session and `~/.claude/sessions` held one file.
    func testDiscoveryCannotClaimASessionTheRegistryDoesNotKnow() {
        let store = SessionStore()
        store.upsert(id: "real", title: "mine", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        store.upsert(id: "ghost", title: "warm file", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working)

        store.reconcileLive(against: ["real"])

        XCTAssertEqual(store.sessions.first { $0.id == "real" }?.state, .working)
        XCTAssertEqual(store.sessions.first { $0.id == "ghost" }?.state, .stale,
                       "no process, so no claim of running")
    }

    /// The demotion has to stick. Discovery rescans on its own clock and
    /// would re-assert the same warm file seconds later, and a row that
    /// flips between running and last-seen every few seconds is worse
    /// than either answer.
    func testDiscoveryCannotUndoTheRegistrysVerdict() {
        let store = SessionStore()
        store.upsert(id: "ghost", title: "warm file", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working)
        store.reconcileLive(against: ["real"])

        store.upsert(id: "ghost", title: "warm file", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working)

        XCTAssertEqual(store.sessions.first { $0.id == "ghost" }?.state, .stale,
                       "the same warm file, read again, is still not a process")
    }

    /// The registry is undocumented and may move. A read that found
    /// nothing is not the registry saying "nobody is running", it is the
    /// registry saying nothing at all, and it must cost a badge rather
    /// than empty the strip.
    func testARegistryThatFoundNothingDisownsNobody() {
        let store = SessionStore()
        store.upsert(id: "a", title: "t", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)

        store.reconcileLive(against: [])

        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    /// And it has to be reversible: claude-mem's indexer comes back
    /// under a new pid every few minutes, and a session the registry
    /// starts reporting again is running again.
    func testASessionTheRegistryReportsAgainIsLiveAgain() {
        let store = SessionStore()
        store.upsert(id: "b", title: "t", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working)
        store.reconcileLive(against: ["a"])
        XCTAssertEqual(store.sessions.first { $0.id == "b" }?.state, .stale)

        store.markLive(id: "b", name: "t", cwd: "/b", pid: 2, kind: .interactive, status: .working)
        XCTAssertEqual(store.sessions.first { $0.id == "b" }?.state, .working)

        store.upsert(id: "b", title: "t", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working)
        XCTAssertEqual(store.sessions.first { $0.id == "b" }?.state, .working,
                       "vouched for again, so discovery is trusted again")
    }

    /// The exact order a real sweep runs in: every live entry is marked,
    /// then the whole list is held against that same set. A session the
    /// registry just vouched for must survive the reconciliation that
    /// follows it in the same pass, or the strip empties itself once a
    /// second and the feature is worse than not having it.
    func testASweepDoesNotDisownTheSessionsItJustMarked() {
        let store = SessionStore()
        store.markLive(id: "mine", name: "moai", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: true, status: .working)
        store.markLive(id: "other", name: "moai", cwd: "/b", pid: 2, kind: .interactive,
                       hasTerminal: true, status: .idle)

        store.reconcileLive(against: ["mine", "other"])

        XCTAssertEqual(store.sessions.first { $0.id == "mine" }?.state, .working)
        XCTAssertEqual(store.sessions.first { $0.id == "other" }?.state, .idle)
        XCTAssertEqual(store.glanceable.map(\.id), ["mine"])
    }

    /// And it has to keep surviving. `reconcileLive` runs on every sweep,
    /// five seconds apart, forever.
    func testRepeatedSweepsLeaveALiveSessionAlone() {
        let store = SessionStore()
        store.markLive(id: "mine", name: "moai", cwd: "/a", pid: 1, kind: .interactive,
                       hasTerminal: true, status: .working)
        for _ in 0..<10 {
            store.reconcileLive(against: ["mine"])
            store.upsert(id: "mine", title: "moai", cwd: "/a", branch: nil,
                         lastPrompt: nil, state: .working)
        }
        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    /// Cursor keeps no such directory, so Claude Code's registry has no
    /// standing to call a Cursor chat dead.
    func testTheRegistryHasNoOpinionAboutCursor() {
        let store = SessionStore()
        store.upsert(id: "cursor-1", title: "t", cwd: "/c", branch: nil,
                     lastPrompt: nil, state: .working, agent: .cursor)

        store.reconcileLive(against: ["some-claude-session"])

        XCTAssertEqual(store.sessions.first?.state, .working)
    }

    /// Whether a process has a terminal is a fact about the process, not
    /// a fact about its status, and it used to be written only on the
    /// path that also decided what the process was *doing*. A registry
    /// file with no `status` key took the other branch every sweep and
    /// the row kept a composer it could never answer.
    ///
    /// The gap is closed at the source now: the registry calls `markLive`
    /// for everything it can see, and passes nil for a status this app
    /// has no opinion on. Nil is an opinion about the work, never about
    /// the process.
    func testAProcessIsMeasuredEvenWhenItsStatusMeansNothingToUs() {
        let store = SessionStore()
        store.upsert(id: "indexer", title: "observer", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working)
        XCTAssertTrue(store.sessions.first?.canReceiveMessages ?? false)

        store.markLive(id: "indexer", name: "observer", cwd: "/b", pid: 2,
                       kind: .interactive, hasTerminal: false, status: nil)

        XCTAssertEqual(store.sessions.first?.hasTerminal, false)
        XCTAssertFalse(store.sessions.first?.canReceiveMessages ?? true,
                       "registered, running, and still nowhere to put a reply")
        XCTAssertTrue(store.glanceable.isEmpty)
        XCTAssertEqual(store.sessions.first?.state, .working,
                       "no opinion is not an opinion that it stopped")
    }

    /// And it must put the session on the list, which is the half that
    /// changed. `markLive` is the only thing that can create a row now, so
    /// declining to call it for an unfamiliar status would not cost a
    /// badge, it would lose the session outright: a `claude bg` job
    /// reporting "blocked" would simply never appear.
    func testAProcessWithAnUnfamiliarStatusIsStillASession() {
        let store = SessionStore()
        store.markLive(id: "blocked-bg", name: "a background job", cwd: "/b", pid: 3,
                       kind: .background, hasTerminal: false, status: nil)

        XCTAssertEqual(store.sessions.map(\.id), ["blocked-bg"])
        XCTAssertEqual(store.sessions.first?.state, .idle,
                       "alive, with nothing known to be happening in it")
        XCTAssertEqual(store.sessions.first?.pid, 3)
    }

    // MARK: What earns a mark on the resting island

    /// The count on the closed pill is the app's smallest claim and its
    /// most-read one. It said 2 while one of the two was a memory
    /// indexer with no terminal, and claude-mem runs nearly always, so
    /// the badge was on its way to being permanently lit. A glance that
    /// never changes carries nothing.
    func testTheGlanceCountLeavesOutASessionWithNoTerminal() {
        let store = SessionStore()
        store.markLive(id: "mine", name: "moai", cwd: "/a", pid: 1,
                       kind: .interactive, hasTerminal: true, status: .working)
        store.markLive(id: "indexer", name: "observer", cwd: "/b", pid: 2,
                       kind: .interactive, hasTerminal: false, status: .working)

        XCTAssertEqual(store.glanceable.map(\.id), ["mine"])
    }

    /// Same rule the strip uses, so the number and the list can never
    /// disagree about what is running.
    func testTheGlanceCountIsThingsHappeningNotThingsExisting() {
        let store = SessionStore()
        store.upsert(id: "working", title: "w", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        store.upsert(id: "asking", title: "n", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .needsInput)
        store.upsert(id: "resting", title: "i", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .idle)
        store.upsert(id: "gone", title: "s", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .stale)

        XCTAssertEqual(Set(store.glanceable.map(\.id)), ["working", "asking"],
                       "idle and last-seen are listed, never counted")
    }

    // MARK: A row that says the same thing twice says nothing

    /// A session whose transcript never yielded a title falls back to
    /// its folder name, and the subtitle is the folder name too, so the
    /// row read "observer-sessions" over "observer-sessions" (founder,
    /// 2026-08-02, looking at the real strip).
    func testASubtitleThatOnlyEchoesTheTitleIsDropped() {
        let session = SessionStore.Session(
            id: "s", title: "moai", cwd: "/a/moai", branch: nil, lastPrompt: nil,
            activity: nil, agent: .claude, state: .working, ask: nil, pid: nil,
            kind: nil, startedAt: Date(), updatedAt: Date()
        )
        XCTAssertNil(AgentSessionsStrip.subtitle(session))
    }

    func testASubtitleThatAddsSomethingSurvives() {
        let session = SessionStore.Session(
            id: "s", title: "Push changes to PR", cwd: "/a/moai", branch: "main",
            lastPrompt: nil, activity: "Running a command", agent: .claude,
            state: .working, ask: nil, pid: nil, kind: nil,
            startedAt: Date(), updatedAt: Date()
        )
        XCTAssertEqual(AgentSessionsStrip.subtitle(session), "Running a command · moai · main")
    }

    /// The reason lived in a tooltip, which is a place nobody looks
    /// before deciding a feature is broken. Both kinds of "you cannot
    /// message this" now say so in the row itself.
    func testARowThatCannotBeMessagedSaysWhyInTheSubtitle() {
        let headless = SessionStore.Session(
            id: "h", title: "observer-sessions", cwd: "/a/observer-sessions", branch: nil,
            lastPrompt: nil, activity: nil, agent: .claude, state: .working, ask: nil,
            pid: 1, kind: .interactive, hasTerminal: false, startedAt: Date(), updatedAt: Date()
        )
        XCTAssertEqual(AgentSessionsStrip.title(headless), "Background task")
        XCTAssertEqual(AgentSessionsStrip.subtitle(headless), "observer-sessions · no terminal")

        let cursor = SessionStore.Session(
            id: "c", title: "Fix the header", cwd: "/a/site", branch: nil,
            lastPrompt: nil, activity: nil, agent: .cursor, state: .working, ask: nil,
            pid: nil, kind: nil, startedAt: Date(), updatedAt: Date()
        )
        XCTAssertEqual(AgentSessionsStrip.subtitle(cursor), "site · no hook yet")
    }

    /// A headless session that did earn a real title keeps it. Only the
    /// folder-name fallback is replaced, because only that one tells
    /// you nothing.
    func testAHeadlessSessionWithARealTitleKeepsIt() {
        let session = SessionStore.Session(
            id: "h", title: "Indexing your history", cwd: "/a/observer-sessions", branch: nil,
            lastPrompt: nil, activity: nil, agent: .claude, state: .working, ask: nil,
            pid: 1, kind: .interactive, hasTerminal: false, startedAt: Date(), updatedAt: Date()
        )
        XCTAssertEqual(AgentSessionsStrip.title(session), "Indexing your history")
    }

    // MARK: The outbox (T4, T7)

    func testAQueuedMessageIsHandedOverExactlyOnce() {
        let store = storeWithSession()
        XCTAssertTrue(store.queue(message: "do the thing", for: "s1"))
        XCTAssertEqual(store.collectMessage(sessionID: "s1"), "do the thing")
        // Collected once: a second collect is nil.
        XCTAssertNil(store.collectMessage(sessionID: "s1"))

        // A second queue before the first is collected appends rather
        // than replacing it.
        XCTAssertTrue(store.queue(message: "first", for: "s1"))
        XCTAssertTrue(store.queue(message: "second", for: "s1"))
        // Two queued messages stay two, and leave one turn at a time,
        // the way a terminal queue does. Glued together they would
        // arrive as one confusing instruction (2026-08-02).
        XCTAssertEqual(store.sessions.first?.outbox?.pending.count, 2)
        XCTAssertEqual(store.collectMessage(sessionID: "s1"), "first")
        XCTAssertEqual(store.collectMessage(sessionID: "s1"), "second")
        XCTAssertNil(store.collectMessage(sessionID: "s1"))

        // A Cursor session keeps no hook contract with this app.
        store.upsert(id: "cur", title: "c", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working, agent: .cursor)
        XCTAssertFalse(store.queue(message: "hi", for: "cur"))

        // A session the registry has stopped listing has no process
        // left to collect anything.
        store.upsert(id: "gone", title: "g", cwd: "/c", branch: nil,
                     lastPrompt: nil, state: .stale)
        XCTAssertFalse(store.queue(message: "hi", for: "gone"))
    }

    func testAMessageTooLongIsRefusedRatherThanTruncated() {
        // A silent truncation would hand a model half an instruction,
        // which is worse than none.
        let store = storeWithSession()
        let tooLong = String(repeating: "x", count: SessionStore.maxMessage + 1)
        XCTAssertFalse(store.queue(message: tooLong, for: "s1"))
        XCTAssertNil(store.collectMessage(sessionID: "s1"))

        let atLimit = String(repeating: "x", count: SessionStore.maxMessage)
        XCTAssertTrue(store.queue(message: atLimit, for: "s1"))
    }

    func testASessionThatExitsWithAMessageQueuedFlipsToUndelivered() {
        let store = storeWithSession()
        XCTAssertTrue(store.queue(message: "still waiting", for: "s1"))
        var flashed: String?
        store.onMessageUndelivered = { flashed = $0 }
        store.markGone(["s1"])
        XCTAssertEqual(store.sessions.first?.state, .stale)
        // The text stays, for Copy and Dismiss — it does not vanish.
        XCTAssertEqual(store.sessions.first?.outbox?.pending.map(\.text), ["still waiting"])
        XCTAssertTrue(store.sessions.first?.outbox?.undelivered ?? false)
        // The store has no glance to flash; it hands the title back and
        // the view model does the flashing (EC-11, left for W-C).
        XCTAssertEqual(flashed, "t")
    }

    // MARK: The outbox survives a relaunch (persist, but refuse a stale one)

    /// A scratch directory per test, never the real Application Support
    /// folder: a persistence test must not be able to touch an actual
    /// install's queued messages.
    private func outboxScratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant-outbox-test-\(UUID().uuidString)", isDirectory: true)
    }

    func testAQueuedMessageSurvivesARelaunchAndReattachesOnlyOnceTheSessionIsRediscovered() {
        let dir = outboxScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SessionStore(outboxDirectory: dir)
        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .working)
        XCTAssertTrue(store.queue(message: "still here after a restart", for: "s1"))

        // A fresh instance stands in for a relaunch: nothing here can
        // come from the in-memory copy above.
        let reloaded = SessionStore(outboxDirectory: dir)
        XCTAssertNil(reloaded.sessions.first?.outbox,
                     "a bare id on disk is not proof the session is still running")
        reloaded.upsert(id: "s1", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .working)
        XCTAssertEqual(reloaded.sessions.first?.outbox?.pending.map(\.text),
                       ["still here after a restart"],
                       "rediscovering the same session id reattaches what survived")
    }

    /// The other half of persisting at all: a message old enough to be
    /// stale must never reach an agent, restored or not. `collectMessage`
    /// is the one path text turns into model context, so this is where
    /// the refusal has to hold.
    func testAMessageThatAgedOutIsRefusedNotDeliveredEvenAfterRediscovery() throws {
        let dir = outboxScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let staleQueuedAt = Date().addingTimeInterval(-SessionStore.outboxExpiry - 60)
        let onDisk: [String: SessionStore.Outbox] = [
            "s1": SessionStore.Outbox(pending: [
                SessionStore.QueuedMessage(id: "m1", text: "do the thing", queuedAt: staleQueuedAt),
            ]),
        ]
        try JSONEncoder().encode(onDisk).write(to: dir.appendingPathComponent("outbox.json"))

        let store = SessionStore(outboxDirectory: dir)
        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .working)

        XCTAssertEqual(store.sessions.first?.outbox?.pending.first?.text, "do the thing",
                       "kept, with the text still there, not dropped silently")
        XCTAssertTrue(store.sessions.first?.outbox?.pending.first?.isExpired ?? false)
        XCTAssertNil(store.collectMessage(sessionID: "s1"),
                     "a stale instruction must never reach the agent silently")

        // Resend restarts the clock, the same as if just typed, and it
        // becomes deliverable again at the next turn boundary.
        store.resendMessage(id: "m1", for: "s1")
        XCTAssertFalse(store.sessions.first?.outbox?.pending.first?.isExpired ?? true)
        XCTAssertEqual(store.collectMessage(sessionID: "s1"), "do the thing")
    }

    /// A hand-edited or corrupted file gets exactly the bounding a live
    /// `queue(message:for:)` call already enforces: oversized text
    /// refused outright, control characters stripped, depth capped at
    /// `maxQueued`, never trusted just because it came from disk.
    func testACorruptedOutboxFileCannotInjectUnboundedOrUncleanTextIntoASession() throws {
        let dir = outboxScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tooLong = String(repeating: "x", count: SessionStore.maxMessage + 500)
        var messages: [SessionStore.QueuedMessage] = [
            SessionStore.QueuedMessage(id: "too-long", text: tooLong, queuedAt: Date()),
            SessionStore.QueuedMessage(id: "control", text: "hi\u{0007}there", queuedAt: Date()),
        ]
        for i in 0..<(SessionStore.maxQueued + 5) {
            messages.append(SessionStore.QueuedMessage(id: "m\(i)", text: "msg \(i)", queuedAt: Date()))
        }
        let onDisk: [String: SessionStore.Outbox] = ["s1": SessionStore.Outbox(pending: messages)]
        try JSONEncoder().encode(onDisk).write(to: dir.appendingPathComponent("outbox.json"))

        let store = SessionStore(outboxDirectory: dir)
        store.upsert(id: "s1", title: "t", cwd: "/a", branch: nil, lastPrompt: nil, state: .working)
        let pending = store.sessions.first?.outbox?.pending ?? []

        XCTAssertEqual(pending.count, SessionStore.maxQueued,
                       "a hand-edited file cannot claim a deeper queue than a live one could")
        XCTAssertFalse(pending.contains { $0.id == "too-long" },
                       "oversized text is refused, never truncated, same as a live queue")
        XCTAssertEqual(pending.first { $0.id == "control" }?.text, "hithere",
                       "control characters are stripped exactly as a live message's are")
    }

    // MARK: The Stop hook's install state (T6)

    func testTheHookReadsAsInstalledOnlyWhenAStopHookPointsAtIt() {
        let installed: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/x/scripts/chalant-hook"]]]]],
        ]
        XCTAssertEqual(HookInstall.status(settings: installed), .installed)

        let somethingElse: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/usr/bin/true"]]]]],
        ]
        XCTAssertEqual(HookInstall.status(settings: somethingElse), .missing)

        // Notification is a different hook event and cannot hand a
        // message back into the model — it is not the injection path.
        let notificationOnly: [String: Any] = [
            "hooks": ["Notification": [["hooks": [["type": "command", "command": "/x/scripts/chalant-hook"]]]]],
        ]
        XCTAssertEqual(HookInstall.status(settings: notificationOnly), .missing)

        // A settings file that would not parse must never render as
        // "missing" — that would tell someone to install what they
        // already have.
        XCTAssertEqual(HookInstall.status(settings: nil), .unreadable)
    }

    // MARK: Codex and Cursor's own install state (B8)

    /// Codex's ~/.codex/hooks.json is documented as Claude Code's exact
    /// shape (cursor-codex-hooks-evidence-2026-08-02.md): the whole
    /// file IS the `{"hooks": {...}}` object `status(settings:)`
    /// already parses, so this locks that reuse rather than a second
    /// parser.
    func testCodexReusesClaudeCodesOwnParserBecauseTheShapeIsIdentical() {
        let installed: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/x/scripts/chalant-hook"]]]]],
        ]
        XCTAssertEqual(HookInstall.status(settings: installed), .installed)
        XCTAssertEqual(HookInstall.status(settings: [:]), .missing)
    }

    /// Cursor's hooks.json is flatter: `hooks.stop[]`, lower-case event
    /// name, no inner `hooks` key on each entry.
    func testCursorsFlatterShapeIsReadOnItsOwnTerms() {
        let installed: [String: Any] = [
            "hooks": ["stop": [["command": "/x/scripts/chalant-hook"]]],
        ]
        XCTAssertEqual(HookInstall.cursorStatus(hooks: installed), .installed)

        let somethingElse: [String: Any] = [
            "hooks": ["stop": [["command": "/x/.superset/hooks/cursor-hook.sh"]]],
        ]
        XCTAssertEqual(HookInstall.cursorStatus(hooks: somethingElse), .missing)

        // Claude Code's own nested shape must not read as installed
        // here: the two files are different schemas, not a shared one.
        let claudeShapedEntry: [String: Any] = [
            "hooks": ["stop": [["hooks": [["type": "command", "command": "/x/scripts/chalant-hook"]]]]],
        ]
        XCTAssertEqual(HookInstall.cursorStatus(hooks: claudeShapedEntry), .missing)

        XCTAssertEqual(HookInstall.cursorStatus(hooks: nil), .unreadable)
    }

    // MARK: Finding the app a session runs in

    private func snap(_ pid: pid_t, _ parent: pid_t, _ name: String, _ cwd: String? = nil)
        -> SessionLocator.Snapshot {
        SessionLocator.Snapshot(pid: pid, parent: parent, name: name, cwd: cwd)
    }

    func testTheOwningAppIsFoundThroughTheShellChain() {
        // claude -> zsh -> pty-host -> Cursor. The point of the walk:
        // an agent inside an IDE's terminal belongs to the IDE, not to
        // Terminal.app, and nothing in the chain says so directly.
        let table: [pid_t: SessionLocator.Snapshot] = [
            100: snap(100, 90, "claude", "/w"),
            90: snap(90, 80, "zsh"),
            80: snap(80, 70, "Cursor Helper"),
            70: snap(70, 1, "Cursor"),
        ]
        XCTAssertEqual(
            SessionLocator.owningApplication(of: 100, in: table, applications: [70]), 70)
    }

    func testACircularParentChainDoesNotHang() {
        // Process tables are read without a lock, so a parent can appear
        // to be its own descendant. Left unguarded this spins forever
        // on the main thread, on a click.
        let table: [pid_t: SessionLocator.Snapshot] = [
            10: snap(10, 20, "claude", "/w"),
            20: snap(20, 10, "zsh"),
        ]
        XCTAssertNil(SessionLocator.owningApplication(of: 10, in: table, applications: [999]))
    }

    func testAChainThatReachesNoApplicationFindsNothing() {
        let table: [pid_t: SessionLocator.Snapshot] = [
            10: snap(10, 5, "claude", "/w"),
            5: snap(5, 1, "zsh"),
        ]
        XCTAssertNil(SessionLocator.owningApplication(of: 10, in: table, applications: []))
        // A broken chain — the parent already exited — is not a hang.
        XCTAssertNil(
            SessionLocator.owningApplication(of: 10, in: [10: snap(10, 77, "claude")],
                                             applications: [70]))
    }

    func testTheAgentIsMatchedByNameAndWorkingDirectory() {
        let table: [pid_t: SessionLocator.Snapshot] = [
            1: snap(1, 0, "claude", "/other"),
            2: snap(2, 0, "zsh", "/w"),
            3: snap(3, 0, "claude", "/w"),
            4: snap(4, 0, "claude", "/w"),
        ]
        // Newest wins: the same folder gets used again and again.
        XCTAssertEqual(
            SessionLocator.agentProcess(forCwd: "/w", in: table, agentNames: ["claude"]), 4)
        // A shell sitting in that folder is not an agent.
        XCTAssertNil(
            SessionLocator.agentProcess(forCwd: "/nope", in: table, agentNames: ["claude"]))
    }

    // MARK: Cursor chats

    func testCursorMetaYieldsAWorkingDirectoryAndATime() throws {
        let json = """
        {"schemaVersion":1,"createdAtMs":1785438868562,"hasConversation":true,
         "updatedAtMs":1785438994844,"cwd":"/Users/x/github/thing"}
        """
        let meta = try XCTUnwrap(CursorDiscovery.parseMeta(Data(json.utf8)))
        XCTAssertEqual(meta.cwd, "/Users/x/github/thing")
        XCTAssertEqual(meta.updatedAt.timeIntervalSince1970, 1785438994.844, accuracy: 0.01)
    }

    func testCursorMetaFallsBackToCreatedWhenNeverUpdated() throws {
        let json = #"{"createdAtMs":1785438868562,"cwd":"/Users/x/a"}"#
        let meta = try XCTUnwrap(CursorDiscovery.parseMeta(Data(json.utf8)))
        XCTAssertEqual(meta.updatedAt.timeIntervalSince1970, 1785438868.562, accuracy: 0.01)
    }

    func testCursorMetaWithoutSomewhereToPointIsNoSession() {
        // A row has to name a place and a time. Anything else is a
        // chat Chalant has nothing true to say about.
        XCTAssertNil(CursorDiscovery.parseMeta(Data("not json".utf8)))
        XCTAssertNil(CursorDiscovery.parseMeta(Data(#"{"updatedAtMs":1}"#.utf8)))
        XCTAssertNil(CursorDiscovery.parseMeta(Data(#"{"cwd":"/a"}"#.utf8)))
        // A relative path is not a working directory.
        XCTAssertNil(CursorDiscovery.parseMeta(Data(#"{"cwd":"rel","updatedAtMs":1}"#.utf8)))
        XCTAssertNil(CursorDiscovery.parseMeta(Data(#"{"cwd":"/a","updatedAtMs":0}"#.utf8)))
    }

    func testSessionsFromDifferentAgentsCoexist() {
        // Ids are namespaced by agent, so a Cursor chat and a Claude
        // session that happen to share a UUID stay two rows.
        let store = SessionStore()
        store.upsert(id: "abc", title: "claude one", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        store.upsert(id: "cursor:abc", title: "cursor one", cwd: "/b", branch: nil,
                     lastPrompt: nil, state: .working, agent: .cursor)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions.filter { $0.agent == .cursor }.count, 1)
    }

    // MARK: What a session is doing

    func testTheLastToolCallIsWhatTheSessionIsDoing() {
        // Tool calls ride inside an assistant message's content blocks
        // rather than arriving as their own record type, and the last
        // one in file order is the current activity.
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"thinking"},{"type":"tool_use","name":"Bash"}]}}
        """
        XCTAssertEqual(SessionDiscovery.parseMetadata(text, path: "t.jsonl").lastTool, "Bash")
    }

    func testAssistantRecordsWithoutToolCallsLeaveTheActivityAlone() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}
        {"type":"assistant"}
        {"type":"assistant","message":{"content":"not an array"}}
        """
        XCTAssertEqual(SessionDiscovery.parseMetadata(text, path: "t.jsonl").lastTool, "Edit")
    }

    func testToolNamesBecomeSomethingAReaderUnderstands() {
        XCTAssertEqual(SessionDiscovery.activityPhrase(forTool: "Bash"), "Running a command")
        XCTAssertEqual(SessionDiscovery.activityPhrase(forTool: "Edit"), "Editing")
        XCTAssertEqual(SessionDiscovery.activityPhrase(forTool: "AskUserQuestion"), "Waiting on you")
        // An unmapped tool keeps its name: still more use than a shrug,
        // and new tools appear faster than this table is updated.
        XCTAssertEqual(SessionDiscovery.activityPhrase(forTool: "SomeNewTool"), "SomeNewTool")
    }

    // MARK: Naming what it is doing it to

    /// "Editing" answers half a question. The half a person actually
    /// wants is which file, and the transcript has it: the tool_use
    /// block carries its own input beside its name.
    func testTheThingATooIsPointedAtIsReadAlongsideTheToolName() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b/SessionStore.swift"}}]}}
        """
        let parsed = SessionDiscovery.parseMetadata(text, path: "t.jsonl")
        XCTAssertEqual(parsed.lastTool, "Edit")
        XCTAssertEqual(parsed.lastToolDetail, "SessionStore.swift")
    }

    /// A Bash call carries both a command and the agent's own one-line
    /// description of it. The description is what a glance wants; the
    /// verbatim command belongs to the approval card, where somebody is
    /// being asked to authorise it.
    func testABashCallIsNamedByItsDescriptionRatherThanItsCommand() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"xcodebuild test -scheme Chalant | tail -5","description":"Run the test suite"}}]}}
        """
        XCTAssertEqual(SessionDiscovery.parseMetadata(text, path: "t.jsonl").lastToolDetail,
                       "Run the test suite")
    }

    func testABashCallWithNoDescriptionFallsBackToTheCommand() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}
        """
        XCTAssertEqual(SessionDiscovery.parseMetadata(text, path: "t.jsonl").lastToolDetail,
                       "git status")
    }

    /// The detail belongs to the tool it arrived with. A later call
    /// without one must not leave the previous call's file behind, or a
    /// row reads "Searching for SessionStore.swift".
    func testANewToolCallClearsThePreviousOnesDetail() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b/SessionStore.swift"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Glob"}]}}
        """
        let parsed = SessionDiscovery.parseMetadata(text, path: "t.jsonl")
        XCTAssertEqual(parsed.lastTool, "Glob")
        XCTAssertNil(parsed.lastToolDetail)
    }

    func testAPhraseNamesWhatTheToolIsPointedAt() {
        XCTAssertEqual(
            SessionDiscovery.activityPhrase(forTool: "Edit", detail: "SessionStore.swift"),
            "Editing SessionStore.swift")
        XCTAssertEqual(
            SessionDiscovery.activityPhrase(forTool: "Read", detail: "RELEASING.md"),
            "Reading RELEASING.md")
        XCTAssertEqual(
            SessionDiscovery.activityPhrase(forTool: "Grep", detail: "remoteControl"),
            "Searching for remoteControl")
        // A described command is already a sentence. Wrapping it in
        // "Running a command:" spends the row's width on nothing.
        XCTAssertEqual(
            SessionDiscovery.activityPhrase(forTool: "Bash", detail: "Run the test suite"),
            "Run the test suite")
    }

    /// The old behaviour is the floor, not a regression: a tool call
    /// whose input said nothing usable still reads as the plain phrase.
    func testAPhraseWithNothingToNameIsTheOldOne() {
        XCTAssertEqual(SessionDiscovery.activityPhrase(forTool: "Edit", detail: nil), "Editing")
        XCTAssertEqual(SessionDiscovery.activityPhrase(forTool: "Bash", detail: nil),
                       "Running a command")
    }

    // MARK: Claude Code's own AskUserQuestion, read from the transcript

    func testAnAskUserQuestionToolCallIsReadAsAPendingNativeAsk() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"header":"Pick","question":"Which one?","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}}]}}
        """
        let ask = SessionDiscovery.parseMetadata(text, path: "t.jsonl").pendingNativeAsk
        XCTAssertEqual(ask?.id, "toolu_1")
        XCTAssertEqual(ask?.questions.first?.header, "Pick")
        XCTAssertEqual(ask?.questions.first?.question, "Which one?")
        // Only the label travels; description and preview are dropped,
        // the same options shape the scripted `chalant ask` already sends.
        XCTAssertEqual(ask?.questions.first?.options, ["A", "B"])
        XCTAssertEqual(ask?.questions.first?.multiSelect, false)
    }

    /// `AskUserQuestion` routinely bundles several questions into one
    /// call (a real one, in this app's own transcript, asked about the
    /// logo, the microphone and drag scope together) — every one of
    /// them is kept now, in order, none dropped.
    func testABundledAskKeepsEveryQuestionInOrder() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"header":"First","question":"q1?","options":[{"label":"A"}],"multiSelect":false},{"header":"Second","question":"q2?","options":[{"label":"B"},{"label":"C"}],"multiSelect":true},{"header":"Third","question":"q3?","options":[{"label":"D"}]}]}}]}}
        """
        let ask = SessionDiscovery.parseMetadata(text, path: "t.jsonl").pendingNativeAsk
        XCTAssertEqual(ask?.questions.map(\.header), ["First", "Second", "Third"])
        XCTAssertEqual(ask?.questions.map(\.question), ["q1?", "q2?", "q3?"])
        XCTAssertEqual(ask?.questions[1].options, ["B", "C"])
        XCTAssertEqual(ask?.questions[1].multiSelect, true)
    }

    /// A question with blank text is not worth showing and is dropped
    /// from the bundle rather than shown blank; the rest of a real
    /// bundle survives one malformed entry.
    func testABundledAskDropsAQuestionWithNoText() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"header":"First","question":"q1?","options":[{"label":"A"}]},{"header":"Blank","question":"   ","options":[{"label":"B"}]}]}}]}}
        """
        let ask = SessionDiscovery.parseMetadata(text, path: "t.jsonl").pendingNativeAsk
        XCTAssertEqual(ask?.questions.map(\.header), ["First"])
    }

    /// The one thing this whole feature turned on: whether a live
    /// question can be told apart from an already-answered one. Verified
    /// against a real transcript (native-questions-evidence-2026-08-03.md):
    /// the answer lands as a `tool_result` wearing the tool_use's own
    /// id, as the very next record.
    func testAToolResultAnsweringTheSameIdClearsThePendingAsk() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"header":"Pick","question":"Which one?","options":[{"label":"A"}]}]}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"answered"}]}}
        """
        XCTAssertNil(SessionDiscovery.parseMetadata(text, path: "t.jsonl").pendingNativeAsk,
                     "a matching tool_result means this question stopped being live")
    }

    func testAToolResultForADifferentIdLeavesThePendingAskAlone() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"header":"Pick","question":"Which one?","options":[{"label":"A"}]}]}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_something_else","content":"unrelated"}]}}
        """
        XCTAssertEqual(SessionDiscovery.parseMetadata(text, path: "t.jsonl").pendingNativeAsk?.id, "toolu_1")
    }

    /// A newer AskUserQuestion replaces an older pending one, same
    /// last-write-wins rule the rest of this fold already follows.
    func testANewerAskUserQuestionReplacesAnOlderPendingOne() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"header":"First","question":"q1?","options":[{"label":"A"}]}]}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"AskUserQuestion","input":{"questions":[{"header":"Second","question":"q2?","options":[{"label":"B"}]}]}}]}}
        """
        XCTAssertEqual(SessionDiscovery.parseMetadata(text, path: "t.jsonl").pendingNativeAsk?.id, "toolu_2")
    }

    /// A `SessionStore.attach` carrying `native: true` is what
    /// `SessionDiscovery` calls for one of these; `AskCard` reads the
    /// flag to know it can only queue a pick, never answer.
    func testANativeAskIsMarkedAsSuchOnTheStore() {
        let store = storeWithSession()
        store.attach(askID: "toolu_1", to: "s1", header: "Pick", question: "Which one?",
                     options: ["A"], multiSelect: false, native: true)
        XCTAssertEqual(store.pendingAsk(sessionID: "s1")?.native, true)
    }

    /// The scripted `chalant ask` path is unaffected: it never passes
    /// `native`, and must keep defaulting to false.
    func testAnUnmarkedAttachIsNotNative() {
        let store = storeWithSession()
        store.attach(askID: "q", to: "s1", header: "h", question: "q?",
                     options: ["A"], multiSelect: false)
        XCTAssertEqual(store.pendingAsk(sessionID: "s1")?.native, false)
    }

    // MARK: A window that comes back to a changed desk

    func testARememberedFrameOnAVanishedScreenIsNotOnScreen() {
        // The real case: saved at x=3390 on a display spanning
        // 2560–5120, reopened after that display went away. The window
        // opens, takes focus, and is nowhere.
        let saved = NSRect(x: 3390, y: 568, width: 900, height: 652)
        let screensNow = [NSRect(x: 0, y: 0, width: 2560, height: 1440)]
        XCTAssertFalse(DashboardWindowController.isOnScreen(saved, screens: screensNow))
    }

    func testAFrameOnAScreenThatStillExistsIsLeftAlone() {
        let frame = NSRect(x: 300, y: 200, width: 900, height: 620)
        let screens = [NSRect(x: 0, y: 0, width: 2560, height: 1440)]
        XCTAssertTrue(DashboardWindowController.isOnScreen(frame, screens: screens))
    }

    func testAWindowPeekingOntoAScreenCountsAsLost() {
        // A sliver on screen puts the title bar off it, so the window
        // cannot be dragged back. Being technically visible is not the
        // same as being reachable.
        let barelyThere = NSRect(x: 2520, y: 700, width: 900, height: 620)
        let screens = [NSRect(x: 0, y: 0, width: 2560, height: 1440)]
        XCTAssertFalse(DashboardWindowController.isOnScreen(barelyThere, screens: screens))
    }

    func testASecondScreenStillCounts() {
        // Restoring onto a display that is still attached is correct
        // and must not be dragged back to the main one.
        let frame = NSRect(x: 3000, y: 300, width: 900, height: 620)
        let screens = [
            NSRect(x: 0, y: 0, width: 2560, height: 1440),
            NSRect(x: 2560, y: 0, width: 2560, height: 1440),
        ]
        XCTAssertTrue(DashboardWindowController.isOnScreen(frame, screens: screens))
    }

    // MARK: Icons

    /// An SF Symbol name that does not exist renders as nothing at all.
    /// There is no crash, no warning and no gap in the build log — the
    /// icon is simply absent, which is why a typo in one can ship and
    /// sit there. Everything the app asks for by name is checked here.
    private func assertSymbolExists(_ name: String, _ where: String) {
        XCTAssertNotNil(
            NSImage(systemSymbolName: name, accessibilityDescription: nil),
            "\(`where`) asks for SF Symbol \"\(name)\", which does not resolve"
        )
    }

    func testEveryDashboardSectionIconResolves() {
        for section in DashboardSection.allCases {
            assertSymbolExists(section.symbol, "Dashboard section \(section.title)")
        }
    }

    func testEveryPlaceableElementIconResolves() {
        for element in IslandElement.allCases {
            assertSymbolExists(element.symbol, "Island element \(element.title)")
        }
    }

    func testEveryIconTheIslandAndDashboardDrawResolves() {
        // Written out rather than grepped: these live inside switches
        // and view bodies where no build step can find them, which is
        // exactly why they need pinning.
        let symbols = [
            // Session rows and their states. Filled, matching
            // ActivityStore.State.symbol: the same idea, done or
            // failed, wears the same weight in both lists.
            "exclamationmark.circle.fill", "circle.dashed", "clock",
            "checkmark.circle.fill", "xmark.circle.fill", "cursorarrow",
            // Displays pane
            "laptopcomputer", "display", "checkmark",
            // Glances
            "bolt.fill", "battery.25", "battery.100",
            // Media row
            "backward.fill", "forward.fill", "shuffle", "speaker.wave.2.fill",
            "pause.fill", "play.fill", "mic.fill",
            // Chrome and actions
            "gearshape", "magnifyingglass", "xmark", "minus.circle",
            "line.3.horizontal", "doc.on.doc", "square.and.arrow.up",
            "dot.radiowaves.left.and.right", "arrow.up.circle.fill",
            "chevron.left", "plus", "paperclip",
            // Shortcuts chip's hover-remove badge: not the xmark that
            // means failed, the same remove idea as minus.circle above.
            "minus.circle.fill",
            // Ambience scenes (fire and cafe), not the flame/cup glyphs
            // the focus streak and Keep Awake already own.
            "fireplace.fill", "takeoutbag.and.cup.and.straw.fill",
        ]
        for symbol in symbols {
            assertSymbolExists(symbol, "A view")
        }
    }

    // MARK: Searching what you copied

    private func textClip(_ text: String) -> ClipboardStore.Clip {
        var clip = ClipboardStore.Clip()
        clip.text = text
        return clip
    }

    func testSearchMatchesAnywhereNotJustTheStart() {
        // People search for the fragment they remember, not a prefix.
        let clip = textClip("the deployment key is in 1Password")
        XCTAssertTrue(ClipboardStore.matches(clip, query: "1Password"))
        XCTAssertTrue(ClipboardStore.matches(clip, query: "deploy"))
        XCTAssertFalse(ClipboardStore.matches(clip, query: "kubernetes"))
    }

    func testSearchIgnoresCaseAndAccents() {
        let clip = textClip("Café Münster")
        XCTAssertTrue(ClipboardStore.matches(clip, query: "cafe"))
        XCTAssertTrue(ClipboardStore.matches(clip, query: "MUNSTER"))
    }

    func testAnEmptySearchKeepsEverything() {
        // The field starts empty and must not hide the history behind
        // a query nobody typed.
        let clips = [textClip("a"), textClip("b")]
        XCTAssertEqual(ClipboardStore.filtered(clips, query: "").count, 2)
        XCTAssertEqual(ClipboardStore.filtered(clips, query: "   ").count, 2)
    }

    func testFilesMatchOnTheirNameNotTheirWholePath() {
        // The name is what a person remembers copying; matching the
        // path would make every clip answer to "Users".
        var clip = ClipboardStore.Clip()
        clip.filePaths = ["/Users/someone/Documents/invoice-april.pdf"]
        XCTAssertTrue(ClipboardStore.matches(clip, query: "invoice"))
        XCTAssertFalse(ClipboardStore.matches(clip, query: "Documents"))
    }

    func testAnImageCannotMatchASearch() {
        // It carries no text, so it can only fail — quietly ranking it
        // as a match for everything would be worse.
        var clip = ClipboardStore.Clip()
        clip.imageURL = URL(fileURLWithPath: "/tmp/shot.png")
        XCTAssertFalse(ClipboardStore.matches(clip, query: "shot"))
        // But an empty search still leaves it in the list.
        XCTAssertTrue(ClipboardStore.matches(clip, query: ""))
    }

    // MARK: Island layout

    func testTheStandardLayoutIsAlreadyValid() {
        XCTAssertEqual(IslandLayout.standard.repaired(), IslandLayout.standard)
    }

    func testADuplicatedElementIsRenderedOnlyOnce() {
        // A bad drag can drop an element into two rows; rendering it
        // twice would double its state and its side effects.
        let layout = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.media, .ambience]), IslandRow([.switcher]),
                   IslandRow([.input])],
            collapsed: [.agents, .agents]
        )
        let fixed = layout.repaired()
        XCTAssertEqual(fixed.placed.filter { $0 == .media }.count, 1)
        XCTAssertEqual(fixed.collapsed.filter { $0 == .agents }.count, 1)
    }

    func testARowCannotHoldMoreThanTheColumnLimit() {
        let layout = IslandLayout(
            rows: [IslandRow([.media, .ambience, .sessions, .activities])],
            collapsed: []
        )
        XCTAssertTrue(layout.repaired().rows.allSatisfy { $0.elements.count <= IslandRow.maxColumns })
    }

    func testARequiredElementComesBackIfItGoesMissing() {
        // Without the switcher and the input there is no way to use the
        // island at all, so neither can be dragged out of existence.
        let layout = IslandLayout(rows: [IslandRow([.media])], collapsed: [])
        let placed = layout.repaired().placed
        XCTAssertTrue(placed.contains(.switcher))
        XCTAssertTrue(placed.contains(.input))
    }

    func testAnElementTheUserRemovedStaysRemoved() {
        // Known to the build that saved it and absent: a deliberate
        // choice, not a gap to be filled.
        var layout = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.switcher]), IslandRow([.input])],
            collapsed: []
        )
        layout.knownElements = IslandElement.allCases
        XCTAssertFalse(layout.repaired().placed.contains(.ambience))
    }

    func testAnElementAddedInALaterBuildAppearsRatherThanStayingInvisible() {
        // Saved before `activities` existed: absent from the rows AND
        // from what that build knew, so it is new rather than unwanted.
        var layout = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.switcher]), IslandRow([.input])],
            collapsed: []
        )
        layout.knownElements = [.media, .switcher, .input, .ambience, .sessions, .timers]
        XCTAssertTrue(layout.repaired().placed.contains(.activities))
        // And the one that build did know about, and left out, stays out.
        XCTAssertFalse(layout.repaired().placed.contains(.ambience))
    }

    func testSessionsNeverComesBackAsARowEvenForALayoutThatNeverKnewIt() {
        // B1: sessions moved into its own tab. A layout saved before that
        // still decodes, but the body must never place it as a row
        // again, whether or not the build that saved it had ever heard
        // of it.
        var neverKnew = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.switcher]), IslandRow([.input])],
            collapsed: []
        )
        neverKnew.knownElements = [.media, .switcher, .input]
        XCTAssertFalse(neverKnew.repaired().placed.contains(.sessions))

        // Nor does a layout that had it placed keep it.
        let hadIt = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.sessions]), IslandRow([.switcher]), IslandRow([.input])],
            collapsed: []
        )
        XCTAssertFalse(hadIt.repaired().placed.contains(.sessions))
    }

    func testEmptyRowsAreDropped() {
        let layout = IslandLayout(
            rows: [IslandRow([]), IslandRow([.media]), IslandRow([])],
            collapsed: []
        )
        XCTAssertTrue(layout.repaired().rows.allSatisfy { !$0.elements.isEmpty })
    }

    func testDraggingARowUpwardLandsWhereItWasDropped() {
        let layout = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.sessions]), IslandRow([.ambience])],
            collapsed: []
        )
        XCTAssertEqual(
            layout.moving(.ambience, to: 0).rows.map(\.elements),
            [[.ambience], [.media], [.sessions]]
        )
    }

    func testDraggingARowDownwardAccountsForItsOwnRemoval() {
        // The off-by-one: pulling the row out first shifts everything
        // below it up, so without the correction a downward drag
        // overshoots by exactly one row.
        let layout = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.sessions]), IslandRow([.ambience])],
            collapsed: []
        )
        XCTAssertEqual(
            layout.moving(.media, to: 2).rows.map(\.elements),
            [[.sessions], [.media], [.ambience]]
        )
    }

    func testDroppingARowOnItselfChangesNothing() {
        let layout = IslandLayout.standard
        XCTAssertEqual(layout.moving(.media, to: 1), layout)
    }

    func testMovingSomethingNotPlacedChangesNothing() {
        let layout = IslandLayout(rows: [IslandRow([.media])], collapsed: [])
        XCTAssertEqual(layout.moving(.ambience, to: 0), layout)
    }

    func testTheCollapsedOrderKeepsEveryGlanceReachable() {
        // Only one glance fits beside the notch, so this list is a
        // precedence order. A glance missing from it can never win,
        // which is indistinguishable from it not existing.
        let repaired = IslandLayout.standard.repaired()
        XCTAssertEqual(Set(repaired.collapsed), Set(CollapsedItem.allCases))
    }

    func testAStoredOrderGainsGlancesAddedSince() {
        // Saved before `battery` existed. Left out it would sit
        // permanently last and invisible, with no way to promote it.
        var layout = IslandLayout.standard
        layout.collapsed = [.timers, .event]
        let repaired = layout.repaired()
        XCTAssertEqual(Array(repaired.collapsed.prefix(2)), [.timers, .event])
        XCTAssertTrue(repaired.collapsed.contains(.battery))
        XCTAssertTrue(repaired.collapsed.contains(.agents))
    }

    func testTheCollapsedOrderNeverRepeatsAGlance() {
        var layout = IslandLayout.standard
        layout.collapsed = [.battery, .battery, .agents]
        let repaired = layout.repaired()
        XCTAssertEqual(repaired.collapsed.filter { $0 == .battery }.count, 1)
        // And the user's own precedence survives the repair.
        XCTAssertEqual(repaired.collapsed.first, .battery)
    }

    func testGlancePrecedenceReordersLikeTheRowsDo() {
        var layout = IslandLayout.standard
        layout.collapsed = [.agents, .timers, .event, .battery]
        // Downward: the same off-by-one both lists now share.
        XCTAssertEqual(
            layout.movingCollapsed(.agents, to: 3).collapsed,
            [.timers, .event, .agents, .battery]
        )
        // Upward.
        XCTAssertEqual(
            layout.movingCollapsed(.battery, to: 0).collapsed,
            [.battery, .agents, .timers, .event]
        )
    }

    func testTheSharedReorderHandlesItsEdges() {
        let items = ["a", "b", "c"]
        XCTAssertEqual(items.movingItem(at: 0, to: 0), items)
        // Out of range is a no-op rather than a crash: indices come
        // from a drop, and a list can change under one.
        XCTAssertEqual(items.movingItem(at: 9, to: 0), items)
        XCTAssertEqual(items.movingItem(at: 2, to: 99), ["a", "b", "c"])
    }

    func testLayoutsAndPresetsRoundTripThroughJSON() throws {
        let presets = LayoutPreset.defaults()
        XCTAssertEqual(presets.count, LayoutPreset.count)
        let data = try JSONEncoder().encode(presets)
        XCTAssertEqual(try JSONDecoder().decode([LayoutPreset].self, from: data), presets)
    }

    // MARK: Island silhouette

    func testIslandPathCoversItsFrameItsEavesAndItsOverscan() {
        // The path is hand-built from curves and is easy to break into
        // something empty or inside out while it still compiles; on a
        // notchless display the island is often invisible anyway, so a
        // screenshot cannot be trusted to catch it.
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let shape = IslandShape(eave: 12, bottomRadius: 16, belly: 3)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty)

        let box = path.boundingRect
        // Flares `eave` past each side.
        XCTAssertEqual(box.minX, rect.minX - 12, accuracy: 0.5)
        XCTAssertEqual(box.maxX, rect.maxX + 12, accuracy: 0.5)
        // Closes above the frame so the join never lands on screen.
        XCTAssertEqual(box.minY, rect.minY - shape.topOverscan, accuracy: 0.5)
        // And hangs below it, by the belly.
        XCTAssertGreaterThan(box.maxY, rect.maxY)
    }

    func testAnEaveSmallerThanTheTipRadiusDoesNotInvertTheShape() {
        // The resting sliver runs a tiny eave; an unclamped tip radius
        // would round straight past the tip and fold the outline.
        let rect = CGRect(x: 0, y: 0, width: 120, height: 12)
        var shape = IslandShape(eave: 2, bottomRadius: 4, belly: 0.5)
        shape.tipRadius = 40
        let box = shape.path(in: rect).boundingRect
        XCTAssertEqual(box.minX, rect.minX - 2, accuracy: 0.5)
        XCTAssertEqual(box.maxX, rect.maxX + 2, accuracy: 0.5)
        XCTAssertFalse(shape.path(in: rect).isEmpty)
    }

    func testThePillIsAFloatingBarNotANotchWithItsEavesRemoved() {
        // A notch flares past its frame to cling to the screen edge and
        // closes above it. A pill does neither: it sits inside its own
        // bounds with a real top edge, which is the difference between
        // reading as an island and reading as a notch on a monitor.
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        var pill = IslandShape(eave: 0, bottomRadius: 14, belly: 3)
        pill.topRadius = 14
        let box = pill.path(in: rect).boundingRect

        XCTAssertEqual(box.minX, rect.minX, accuracy: 0.5)
        XCTAssertEqual(box.maxX, rect.maxX, accuracy: 0.5)
        XCTAssertEqual(box.minY, rect.minY, accuracy: 0.5)
        XCTAssertGreaterThan(box.maxY, rect.maxY)
    }

    func testAPillRadiusCannotExceedHalfTheShape() {
        // A radius larger than the bar is half its height would fold the
        // corners through each other.
        let rect = CGRect(x: 0, y: 0, width: 120, height: 20)
        var pill = IslandShape(eave: 0, bottomRadius: 400, belly: 0)
        pill.topRadius = 400
        let box = pill.path(in: rect).boundingRect
        XCTAssertFalse(pill.path(in: rect).isEmpty)
        XCTAssertEqual(box.width, rect.width, accuracy: 0.5)
        XCTAssertEqual(box.height, rect.height, accuracy: 0.5)
    }

    // MARK: The cutout measurement (notch-geometry-plan, W-A)

    func testACutoutHeightIsTakenEvenWhenTheWidthIsNot() {
        // EC-3: a notched screen under mirroring, or a chassis that
        // reports one aux area and not the other, still has a real
        // cutout with a real height. Losing the whole measurement
        // because only the width is unmeasurable would make A2 fail
        // with no symptom anyone could name.
        let bothMissing = NSScreen.cutout(
            safeAreaTop: 32, left: nil, right: nil, frameWidth: 1470)
        XCTAssertEqual(bothMissing?.height, 32)
        XCTAssertEqual(bothMissing?.width, 1470)

        let oneMissing = NSScreen.cutout(
            safeAreaTop: 32, left: CGRect(x: 0, y: 0, width: 620, height: 32), right: nil,
            frameWidth: 1470)
        XCTAssertEqual(oneMissing?.height, 32)

        // No safe area at all is no cutout, aux areas or not.
        XCTAssertNil(
            NSScreen.cutout(
                safeAreaTop: 0,
                left: CGRect(x: 0, y: 0, width: 620, height: 32),
                right: CGRect(x: 850, y: 0, width: 620, height: 32),
                frameWidth: 1470))
    }

    func testACutoutWidthIsTheGapBetweenTheAuxiliaryAreasNotTheFrameMinusThem() {
        // EC-7: `frame.width - left.width - right.width` silently
        // assumes both aux areas start and end at the screen edges;
        // `right.minX - left.maxX` measures the gap directly and
        // assumes nothing.
        let cutout = NSScreen.cutout(
            safeAreaTop: 32,
            left: CGRect(x: 0, y: 0, width: 619, height: 32),
            right: CGRect(x: 851, y: 0, width: 619, height: 32),
            frameWidth: 1470)
        XCTAssertEqual(cutout, CGSize(width: 232, height: 32))
    }

    // MARK: Collapsed geometry, flush at rest (notch-geometry-plan, W-C)

    func testAQuietIslandOnRealHardwareIsExactlyTheCutout() {
        // A2: at rest, nothing to say, nobody reaching, the painted
        // frame must be exactly the cutout -- not the cutout minus the
        // old 8pt tuck -- because only exactly-the-cutout is eaten by
        // the hardware and invisible by construction.
        let cutout = CGSize(width: 200, height: 32)
        XCTAssertEqual(
            NotchViewModel.collapsedFrame(
                cutout: cutout, base: cutout, wings: 0, hovering: false),
            cutout)
        // The moment there is something to say, it is no longer flush.
        XCTAssertNotEqual(
            NotchViewModel.collapsedFrame(
                cutout: cutout, base: cutout, wings: 88, hovering: false),
            cutout)
    }

    func testAnEmulatedNotchKeepsItsApronBecauseItHasNothingToHideIn() {
        // EC-5: no cutout means no hardware to disappear into, so the
        // 8pt tuck and 3pt apron apply unconditionally, keyed on
        // `cutout == nil`, never on the style.
        let frame = NotchViewModel.collapsedFrame(
            cutout: nil, base: CGSize(width: 196, height: 38), wings: 0, hovering: false)
        XCTAssertEqual(frame, CGSize(width: 188, height: 41))
    }

    func testAFlushIslandHasNoArcAndNothingOutsideItsFrame() {
        // A3: zero overhang means zero eave and zero belly, and an
        // `IslandShape` built from them draws no arc across the bottom
        // and nothing beyond its own rect.
        let (eave, belly) = NotchViewModel.eaveAndBelly(overhang: 0)
        XCTAssertEqual(eave, 0)
        XCTAssertEqual(belly, 0)

        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let box = IslandShape(eave: eave, bottomRadius: 16, belly: belly).path(in: rect).boundingRect
        XCTAssertEqual(box.maxY, rect.maxY, accuracy: 0.5)
        XCTAssertEqual(box.width, rect.width, accuracy: 0.5)
    }

    func testTheEaveGrowsWithTheOverhangUpToItsCeiling() {
        // Something to say grows the frame, and the eave and belly
        // come back in step with that growth rather than snapping to a
        // fixed constant regardless of how much actually overhangs.
        XCTAssertEqual(NotchViewModel.eaveAndBelly(overhang: -4).eave, 0)
        XCTAssertEqual(NotchViewModel.eaveAndBelly(overhang: 3).eave, 3)
        XCTAssertEqual(NotchViewModel.eaveAndBelly(overhang: 3).belly, Theme.Island.bellyCollapsed)
        // Clamped at the ceiling rather than growing without bound.
        XCTAssertEqual(NotchViewModel.eaveAndBelly(overhang: 40).eave, Theme.Island.eaveCollapsed)
    }

    // MARK: Per-display config

    func testAutomaticResolvesFromTheHardwareAndNothingElseIsTouched() {
        // This is the whole of "detect the display and pick the notch".
        XCTAssertEqual(
            DisplayConfigStore.resolve(.auto, hasHardwareNotch: true), .notch)
        XCTAssertEqual(
            DisplayConfigStore.resolve(.auto, hasHardwareNotch: false), .pill)
        // An explicit choice outranks the hardware in both directions:
        // a matching external panel may want the notch cutout, and a
        // MacBook may want the pill.
        XCTAssertEqual(
            DisplayConfigStore.resolve(.notch, hasHardwareNotch: false), .notch)
        XCTAssertEqual(
            DisplayConfigStore.resolve(.pill, hasHardwareNotch: true), .pill)
        XCTAssertEqual(
            DisplayConfigStore.resolve(.off, hasHardwareNotch: true), .off)
    }

    func testAConfigFromDiskIsClampedIntoRange() {
        // Values arriving from JSON have not been through a slider, so
        // a hand-edited or corrupted blob must not produce an island
        // that cannot be seen or dismissed.
        var wild = DisplayConfigStore.Config()
        wild.width = 9000
        wild.height = -40
        wild.cornerRadius = 999
        wild.contentPadding = 0
        let safe = wild.clamped
        XCTAssertEqual(safe.width, DisplayConfigStore.Config.widthRange.upperBound)
        XCTAssertEqual(safe.height, DisplayConfigStore.Config.heightRange.lowerBound)
        XCTAssertEqual(safe.cornerRadius, DisplayConfigStore.Config.cornerRange.upperBound)
        XCTAssertEqual(safe.contentPadding, DisplayConfigStore.Config.paddingRange.lowerBound)
    }

    func testAnUntouchedConfigSurvivesClamping() {
        // The defaults reproduce what the island did before any of this
        // existed; clamping must not quietly move them.
        let plain = DisplayConfigStore.Config()
        XCTAssertEqual(plain.clamped, plain)
    }

    func testTheExpandedSizeDialsAreClampedLikeTheOldOnes() {
        // W-F adds two new sliders; a hand-edited or corrupted blob
        // must not be able to produce an expanded island that cannot
        // be seen either.
        var wild = DisplayConfigStore.Config()
        wild.expandedWidth = 5
        wild.expandedMinHeight = -40
        let safe = wild.clamped
        XCTAssertEqual(safe.expandedWidth, DisplayConfigStore.Config.expandedWidthRange.lowerBound)
        XCTAssertEqual(
            safe.expandedMinHeight, DisplayConfigStore.Config.expandedMinHeightRange.lowerBound)
    }

    func testConfigsRoundTripThroughJSON() throws {
        var config = DisplayConfigStore.Config()
        config.style = .pill
        config.width = 240
        config.cornerRadius = 22
        let data = try JSONEncoder().encode(["screen-uuid": config])
        let back = try JSONDecoder().decode([String: DisplayConfigStore.Config].self, from: data)
        XCTAssertEqual(back["screen-uuid"], config)
    }

    func testAStoredBlobFromAnOlderBuildKeepsItsValues() throws {
        // Exactly today's key set: `expandedWidth` and
        // `expandedMinHeight` both absent, the way every already
        // installed user's stored blob reads the moment this build
        // lands. Verified by throwing this exact decode at the
        // synthesized `Codable` first: it threw `keyNotFound`, and
        // `load()` answers any decode failure by deleting the whole
        // stored map, so a field this struct gains would otherwise
        // wipe every existing display's settings on the first launch
        // after the upgrade (EC-1).
        let json = """
            {"style":"pill","width":210,"height":40,"cornerRadius":10,"contentPadding":18}
            """
        let config = try JSONDecoder().decode(
            DisplayConfigStore.Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.style, .pill)
        XCTAssertEqual(config.width, 210)
        XCTAssertEqual(config.height, 40)
        XCTAssertEqual(config.cornerRadius, 10)
        XCTAssertEqual(config.contentPadding, 18)
        // Keys this build adds were never written; the property's own
        // default stands in rather than the whole decode failing.
        XCTAssertEqual(config.expandedWidth, 520)
        XCTAssertEqual(config.expandedMinHeight, 0)
        // `sizeFollowsHardware` is newer still and absent from this
        // exact blob too; its default of `true` must reproduce what
        // this same blob already did before the field existed (EC-6).
        XCTAssertTrue(config.sizeFollowsHardware)
    }

    func testFollowingTheHardwareIsTheDefaultAndAStoredSizeStillWins() {
        // W-D, EC-6: a blob with no `sizeFollowsHardware` key -- every
        // blob written before this round -- reads `true`.
        XCTAssertTrue(DisplayConfigStore.Config().sizeFollowsHardware)

        // Following the hardware, the cutout wins over a stored size.
        XCTAssertEqual(
            NotchViewModel.notchSize(
                cutout: CGSize(width: 200, height: 32), sizeFollowsHardware: true,
                configWidth: 300, configHeight: 40),
            CGSize(width: 200, height: 32))
        // Turned off, the stored size wins even with real hardware
        // right there to measure.
        XCTAssertEqual(
            NotchViewModel.notchSize(
                cutout: CGSize(width: 200, height: 32), sizeFollowsHardware: false,
                configWidth: 300, configHeight: 40),
            CGSize(width: 300, height: 40))
        // No hardware at all: nothing to follow, the stored size wins
        // regardless of the setting, exactly as it always has.
        XCTAssertEqual(
            NotchViewModel.notchSize(
                cutout: nil, sizeFollowsHardware: true, configWidth: 196, configHeight: 38),
            CGSize(width: 196, height: 38))
    }

    func testUnreadableStoredSettingsAreDroppedRatherThanFailingEveryLaunch() throws {
        let suite = "chalant.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "displayConfigs")

        let store = DisplayConfigStore(defaults: defaults)
        XCTAssertTrue(store.configs.isEmpty)
        XCTAssertNil(defaults.data(forKey: "displayConfigs"))
    }

    func testAnEmptyStoredMapIsReadAsDefaultsNotAFailure() throws {
        // `{}` decodes cleanly to an empty map - this is not the
        // unreadable-blob path above, and must not be treated like it.
        // It is also the exact state `displayConfigs` was found in on
        // 2026-08-01 (the Reset button's own footprint), and it is not
        // itself a bug.
        let suite = "chalant.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{}".utf8), forKey: "displayConfigs")

        let store = DisplayConfigStore(defaults: defaults)
        XCTAssertTrue(store.configs.isEmpty)
        // Unlike the unreadable path, which scrubs the key, a valid
        // empty map is left exactly where it was.
        XCTAssertNotNil(defaults.data(forKey: "displayConfigs"))
    }

    func testAStoredConfigSurvivesAResetOfADifferentDisplay() throws {
        // Locks the write/reset semantics that produced the `{}` this
        // investigation started from: a Reset on one display's row
        // must not be able to erase another's settings too.
        let suite = "chalant.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisplayConfigStore(defaults: defaults)

        var configA = DisplayConfigStore.Config()
        configA.style = .pill
        store.set(configA, forKey: "display-a")
        var configB = DisplayConfigStore.Config()
        configB.style = .notch
        store.set(configB, forKey: "display-b")

        store.reset(forKey: "display-a")

        XCTAssertEqual(store.config(forKey: "display-a").style, .auto)
        XCTAssertEqual(store.config(forKey: "display-b").style, .notch)
    }

    func testWritingOneDisplayNeverTouchesAnother() throws {
        // The H2 invariant in code: the pane presents every attached
        // display as an equal, and editing one must never silently
        // move a value stored under another's key.
        let suite = "chalant.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisplayConfigStore(defaults: defaults)

        var configB = DisplayConfigStore.Config()
        configB.width = 300
        store.set(configB, forKey: "display-b")
        var configA = DisplayConfigStore.Config()
        configA.cornerRadius = 4
        store.set(configA, forKey: "display-a")

        // Through a fresh instance, not just the in-memory copy: this
        // is the write path the Displays pane actually exercises.
        let reloaded = DisplayConfigStore(defaults: defaults)
        XCTAssertEqual(reloaded.config(forKey: "display-b").width, 300)
        XCTAssertEqual(reloaded.config(forKey: "display-a").cornerRadius, 4)
    }

    // MARK: A panel per display (island-per-display-plan, W-C: the bead
    // and the collapsed island used to answer two different questions
    // about the same display; there is no bead any more, every display
    // that is not Off wears a real island instead)

    func testEveryDisplayButAnOffOneWearsAnIsland() {
        let panelSize = CGSize(width: 1000, height: 720)
        let screens: [(id: CGDirectDisplayID, frame: CGRect, style: DisplayConfigStore.Style)] = [
            (1, CGRect(x: 0, y: 0, width: 1512, height: 982), .notch),
            (2, CGRect(x: 1512, y: 0, width: 1920, height: 1080), .pill),
            (3, CGRect(x: -1920, y: 0, width: 1920, height: 1080), .off),
            (4, CGRect(x: 0, y: 1080, width: 2560, height: 1440), .pill),
        ]
        let frames = NotchWindowController.islandFrames(for: screens, panelSize: panelSize)
        // Three of four: the Off display gets no panel at all, not an
        // invisible one (EC-10) — a long press on it must have nothing
        // to open.
        XCTAssertEqual(frames.count, 3)
        XCTAssertNil(frames[3])
        for screen in screens where screen.style != .off {
            guard let frame = frames[screen.id] else {
                XCTFail("missing a frame for display \(screen.id)")
                continue
            }
            XCTAssertEqual(frame.width, panelSize.width)
            XCTAssertEqual(frame.height, panelSize.height)
            XCTAssertEqual(frame.midX, screen.frame.midX)
            XCTAssertEqual(frame.maxY, screen.frame.maxY)
        }
        // A momentarily empty screen list (mid-wake) is a no-op, not an
        // instruction to remove every panel (EC-19).
        XCTAssertTrue(NotchWindowController.islandFrames(for: [], panelSize: panelSize).isEmpty)
    }

    func testThePanelSetIsADiffAndNotARebuild() {
        // A screen present in both maps at the same frame: kept, and it
        // must never be torn down to be re-placed (EC-7) — this is what
        // stops an open island's WKWebView reloading, or a voice
        // session dying, on every unrelated screen event.
        let steady = CGRect(x: 0, y: 0, width: 1000, height: 720)
        let before = CGRect(x: 1512, y: 0, width: 1000, height: 720)
        let after = CGRect(x: 1512, y: 200, width: 1000, height: 720)
        let current: [CGDirectDisplayID: CGRect] = [
            1: steady, 2: before, 3: CGRect(x: 0, y: 0, width: 1, height: 1),
        ]
        let wanted: [CGDirectDisplayID: CGRect] = [
            1: steady, 2: after, 4: CGRect(x: 0, y: 0, width: 1, height: 1),
        ]
        let diff = NotchWindowController.diffPanels(current: current, wanted: wanted)
        XCTAssertEqual(diff.added, [4])
        XCTAssertEqual(diff.removed, [3])
        XCTAssertEqual(diff.moved, [2])
        // Present in both, unchanged: in none of the three.
        XCTAssertFalse(diff.added.contains(1))
        XCTAssertFalse(diff.removed.contains(1))
        XCTAssertFalse(diff.moved.contains(1))
    }

    // MARK: Hover and expansion ownership (island-per-display-plan, W-D)

    func testAnOpenIslandNeverOpensASecondOne() {
        let a: CGDirectDisplayID = 1, b: CGDirectDisplayID = 2, c: CGDirectDisplayID = 3

        // Ownership: every face but the owner reads collapsed, however
        // loud the shared state is (EC-4, the crux).
        XCTAssertEqual(NotchViewModel.state(.expanded, expandedOn: a, face: a), .expanded)
        XCTAssertEqual(NotchViewModel.state(.expanded, expandedOn: a, face: b), .collapsed)
        XCTAssertEqual(NotchViewModel.state(.expanded, expandedOn: a, face: c), .collapsed)

        // defaultOwner: the pointer's own display first, then the last
        // hovered, then main, then whatever is attached (EC-12).
        XCTAssertEqual(NotchViewModel.defaultOwner(pointerOn: a, lastHovered: b, main: c, any: c), a)
        XCTAssertEqual(NotchViewModel.defaultOwner(pointerOn: nil, lastHovered: b, main: c, any: c), b)
        XCTAssertEqual(NotchViewModel.defaultOwner(pointerOn: nil, lastHovered: nil, main: c, any: a), c)
        XCTAssertEqual(NotchViewModel.defaultOwner(pointerOn: nil, lastHovered: nil, main: nil, any: a), a)
        // Nowhere to go means expand() does nothing rather than crash.
        XCTAssertNil(NotchViewModel.defaultOwner(pointerOn: nil, lastHovered: nil, main: nil, any: nil))
    }

    // MARK: Collapsed content, per display (island-per-display-plan
    // 2026-08-02, W-A/W-B: the pill used to render from a shorter,
    // separate list than the one deciding whether to show anything at
    // all, which is how an agent session with nothing else running
    // grew a pill to a 40x18 lozenge with nothing drawn in it)

    func testAPillIsOnlyAsWideAsItActuallyDraws() {
        XCTAssertNil(NotchViewModel.collapsedSpan(left: 0, right: 0, style: .pill))
        XCTAssertNil(NotchViewModel.collapsedSpan(left: 0, right: 0, style: .notch))
        // The case that shipped wrong: a glance with real width must
        // make the span non-nil, on both styles, or the renderer draws
        // something the show/hide rule never agreed to.
        XCTAssertEqual(NotchViewModel.collapsedSpan(left: 0, right: 44, style: .pill), 44)
        XCTAssertEqual(NotchViewModel.collapsedSpan(left: 0, right: 44, style: .notch), 88)
        // A pill's two wings sit adjacent; a notch's widen symmetrically
        // around the camera.
        XCTAssertEqual(NotchViewModel.collapsedSpan(left: 30, right: 44, style: .pill), 74)
        XCTAssertEqual(NotchViewModel.collapsedSpan(left: 30, right: 44, style: .notch), 88)
    }

    func testACountdownKeepsItsDigitsOnAPillAndLosesThemInANotch() {
        // A notch's narrow wing has room for the ring or the stopwatch
        // glyph, never digits; a pill has room for both.
        XCTAssertEqual(NotchViewModel.timersWidth(sessionOnRight: true, style: .pill), 90)
        XCTAssertEqual(NotchViewModel.timersWidth(sessionOnRight: true, style: .notch), 30)
        // Nothing to cross to the right wing for without music also
        // holding the left one, on either style.
        XCTAssertEqual(NotchViewModel.timersWidth(sessionOnRight: false, style: .pill), 0)
        XCTAssertEqual(NotchViewModel.timersWidth(sessionOnRight: false, style: .notch), 0)
    }

    // MARK: One number for a reservation and what fills it (W-E, EC-13)

    func testTheSongGlanceReservesExactlyWhatItDraws() {
        // `leftWingNeed`'s song branch and `songBeside`'s frame both
        // read this one constant now, rather than 156 and 140 written
        // separately in two files; pinning the number is what stops
        // them drifting apart again the way they already had once.
        XCTAssertEqual(Theme.Island.songGlanceWidth, 140)
    }

    // MARK: Expanded size, a dial and a floor that is never a ceiling
    // (W-F)

    func testChatFullKeepsItsBreakpointAboveAUserWidth() {
        // The chat site's desktop breakpoint at 0.8 zoom needs 680; a
        // user who dialed the island down must not undercut it while
        // full-mode chat is open.
        XCTAssertEqual(
            NotchViewModel.expandedWidth(
                configWidth: 600, tab: .chat, pane: .none, chatFull: true), 680)
        // A dial already past the breakpoint wins on its own merits.
        XCTAssertEqual(
            NotchViewModel.expandedWidth(
                configWidth: 720, tab: .chat, pane: .none, chatFull: true), 720)
        // Anywhere else, or with full mode off, the dial is just the width.
        XCTAssertEqual(
            NotchViewModel.expandedWidth(
                configWidth: 600, tab: .today, pane: .none, chatFull: true), 600)
        XCTAssertEqual(
            NotchViewModel.expandedWidth(
                configWidth: 600, tab: .chat, pane: .none, chatFull: false), 600)
    }

    func testTheExpandedHeightIsAFloorAndContentStillWins() {
        XCTAssertEqual(NotchViewModel.expandedHeight(measured: 170, floor: 300), 300)
        XCTAssertEqual(NotchViewModel.expandedHeight(measured: 400, floor: 300), 400)
        // No floor set at all is today's behaviour: purely content-measured.
        XCTAssertEqual(NotchViewModel.expandedHeight(measured: 170, floor: 0), 170)
    }

    func testOnlyTheDisplayThatWasOpenedReadsAsOpen() {
        let a: CGDirectDisplayID = 1, b: CGDirectDisplayID = 2
        XCTAssertEqual(NotchViewModel.state(.expanded, expandedOn: a, face: a), .expanded)
        XCTAssertEqual(NotchViewModel.state(.expanded, expandedOn: a, face: b), .collapsed)
        XCTAssertEqual(NotchViewModel.state(.listening, expandedOn: a, face: b), .collapsed)
        // No owner means nobody is open, however loud the shared state is.
        XCTAssertEqual(NotchViewModel.state(.expanded, expandedOn: nil, face: a), .collapsed)
        // A face with no id never inherits an expansion.
        XCTAssertEqual(NotchViewModel.state(.expanded, expandedOn: a, face: nil), .collapsed)
    }

    func testAnOffDisplayNeverShowsAndANotchAlwaysDoes() {
        for expandedHere in [true, false] {
            for hasSomethingToSay in [true, false] {
                XCTAssertFalse(NotchViewModel.islandIsShowing(
                    style: .off, expandedHere: expandedHere, hasSomethingToSay: hasSomethingToSay))
                XCTAssertTrue(NotchViewModel.islandIsShowing(
                    style: .notch, expandedHere: expandedHere, hasSomethingToSay: hasSomethingToSay))
                XCTAssertTrue(NotchViewModel.islandIsShowing(
                    style: .auto, expandedHere: expandedHere, hasSomethingToSay: hasSomethingToSay))
            }
        }
        // A pill shows when it is the open one, or when it has
        // something to say collapsed, and stays a sliver only when
        // neither is true.
        XCTAssertFalse(NotchViewModel.islandIsShowing(
            style: .pill, expandedHere: false, hasSomethingToSay: false))
        XCTAssertTrue(NotchViewModel.islandIsShowing(
            style: .pill, expandedHere: true, hasSomethingToSay: false))
        XCTAssertTrue(NotchViewModel.islandIsShowing(
            style: .pill, expandedHere: false, hasSomethingToSay: true))
        XCTAssertTrue(NotchViewModel.islandIsShowing(
            style: .pill, expandedHere: true, hasSomethingToSay: true))
    }

    // MARK: Activity eviction

    func testAFullListNeverDropsAQuestionWaitingOnTheUser() {
        // needs-input sorts first, so the old `?? activities.last`
        // fallback picked exactly this row once every slot held a
        // question. Nothing re-pushes one, so it was gone for good.
        let store = ActivityStore()
        for index in 0..<12 {
            store.push(id: "q\(index)", title: "question \(index)", detail: nil, state: .needsInput)
        }
        XCTAssertEqual(store.activities.count, 12)
        XCTAssertTrue(store.activities.allSatisfy { $0.state == .needsInput })
    }

    func testAFullListDropsFinishedWorkBeforeAnythingLive() {
        let store = ActivityStore()
        store.push(id: "done", title: "finished", detail: nil, state: .done)
        for index in 0..<8 {
            store.push(id: "w\(index)", title: "working \(index)", detail: nil, state: .working)
        }
        XCTAssertFalse(store.activities.contains { $0.id == "done" })
        XCTAssertEqual(store.activities.filter { $0.state == .working }.count, 8)
    }

    func testAFullListOfWorkingRowsDropsTheStalestOne() {
        // Working rows are still capped: the bound exists to keep the
        // island from outgrowing its panel, and the oldest one is the
        // least likely to still be watched.
        let store = ActivityStore()
        for index in 0..<10 {
            store.push(id: "w\(index)", title: "working \(index)", detail: nil, state: .working)
        }
        XCTAssertEqual(store.activities.count, 8)
        XCTAssertFalse(store.activities.contains { $0.id == "w0" })
        XCTAssertTrue(store.activities.contains { $0.id == "w9" })
    }

    // MARK: A session ending resolves its pill (H5)

    func testResolveIfPendingRetiresAStaleNeedsInputPill() {
        let store = ActivityStore()
        store.push(id: "claude-s1", title: "wants you", detail: nil, state: .needsInput)
        store.resolveIfPending(id: "claude-s1")
        // Demoted off the top and carrying a detail that says why,
        // rather than still claiming to be waiting on someone who is
        // no longer there to answer.
        XCTAssertEqual(store.activities.first?.state, .failed)
        XCTAssertNotNil(store.activities.first?.detail)
    }

    func testResolveIfPendingLeavesAnAnsweredOrAbsentPillAlone() {
        let store = ActivityStore()
        // Nothing posted under this id: a no-op, not a crash.
        store.resolveIfPending(id: "claude-nobody")
        XCTAssertTrue(store.activities.isEmpty)

        // Already resolved (or never needs-input to begin with): a
        // second call changes nothing further.
        store.push(id: "claude-s2", title: "building", detail: nil, state: .working)
        store.resolveIfPending(id: "claude-s2")
        XCTAssertEqual(store.activities.first?.state, .working)
    }

    // MARK: Global shortcuts

    func testComboRoundTripsThroughItsStoredForm() {
        let combo = HotKeyCenter.Combo(keyCode: 49, modifiers: UInt32(cmdKey | optionKey))
        XCTAssertEqual(HotKeyCenter.Combo(storage: combo.storage), combo)
    }

    func testComboRejectsHalfWrittenOrJunkStorage() {
        // A binding read back wrong must be no binding, never a
        // shortcut on some other key.
        XCTAssertNil(HotKeyCenter.Combo(storage: ""))
        XCTAssertNil(HotKeyCenter.Combo(storage: "49"))
        XCTAssertNil(HotKeyCenter.Combo(storage: "49:"))
        XCTAssertNil(HotKeyCenter.Combo(storage: "49:256:1"))
        XCTAssertNil(HotKeyCenter.Combo(storage: "space:cmd"))
    }

    func testABareOrShiftOnlyKeyIsNeverAcceptedAsAShortcut() {
        // These register system-wide: without a real modifier, typing
        // the letter anywhere would open the island.
        XCTAssertFalse(HotKeyCenter.Combo(keyCode: 17, modifiers: 0).isSafe)
        XCTAssertFalse(HotKeyCenter.Combo(keyCode: 17, modifiers: UInt32(shiftKey)).isSafe)
        XCTAssertTrue(HotKeyCenter.Combo(keyCode: 17, modifiers: UInt32(cmdKey)).isSafe)
        XCTAssertTrue(HotKeyCenter.Combo(keyCode: 17, modifiers: UInt32(controlKey)).isSafe)
        XCTAssertTrue(
            HotKeyCenter.Combo(keyCode: 17, modifiers: UInt32(optionKey | shiftKey)).isSafe
        )
    }

    func testShortcutDisplayWritesModifiersInTheOrderMacOSDoes() {
        let combo = HotKeyCenter.Combo(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
        XCTAssertEqual(combo.display, "⌃⌥⇧⌘Space")
    }

    func testShortcutsThatOpenAPanelNameOneThatExists() {
        // A shortcut pointing at a tab the switcher cannot show would
        // open a panel with no way back but Today.
        for action in HotKeyCenter.Action.allCases {
            guard let tab = action.tab else { continue }
            XCTAssertTrue(
                NotchViewModel.Tab.allCases.contains(tab),
                "\(action.title) opens a tab that does not exist")
        }
    }

    func testNoTwoShortcutsOpenTheSamePanel() {
        // Two bindings for one destination is a setting nobody can
        // reason about, and one of them would look broken.
        let tabs = HotKeyCenter.Action.allCases.compactMap(\.tab)
        XCTAssertEqual(Set(tabs).count, tabs.count)
    }

    func testTheIslandsOwnActionsOpenNoPanel() {
        // Talking, toggling and settings are not destinations; giving
        // them a tab would send the island somewhere on a keypress
        // meant to do something else entirely.
        XCTAssertNil(HotKeyCenter.Action.toggleIsland.tab)
        XCTAssertNil(HotKeyCenter.Action.talk.tab)
        XCTAssertNil(HotKeyCenter.Action.openSettings.tab)
    }

    func testEveryActionHasItsOwnDefaultsKey() {
        let keys = HotKeyCenter.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    // MARK: The front door

    /// Every open of the island landed on Today, and Today with no
    /// calendar access is a sentence telling you to go somewhere else.
    /// The most-seen screen in the app was an error state.
    func testTheIslandDoesNotOpenOntoATodayThatCanShowNothing() {
        let defaults = Self.emptyDefaults()
        XCTAssertEqual(NotchViewModel.landingTab(todayCanSee: false, in: defaults), .clipboard)
    }

    /// One working source is enough. A denial line beside real content
    /// is information, not a dead end, and moving the front door on
    /// anything less would be diverting people away from a tab that
    /// works.
    func testTodayStaysTheFrontDoorWheneverItHasAnythingToShow() {
        let defaults = Self.emptyDefaults()
        XCTAssertEqual(NotchViewModel.landingTab(todayCanSee: true, in: defaults), .today)
    }

    /// "Nothing due" is only sayable about a list this app can read.
    /// The line used to vanish entirely whenever anything was denied, so
    /// a granted reminders list with nothing in it said nothing at all
    /// and the panel was one denial and a date.
    func testTheEmptyDayClaimsOnlyWhatItActuallyLookedAt() {
        XCTAssertEqual(
            TodayView.clearDayDetail(seesCalendar: true, seesReminders: true),
            "Nothing scheduled, nothing due. The day is yours.")
        XCTAssertEqual(
            TodayView.clearDayDetail(seesCalendar: false, seesReminders: true), "Nothing due.")
        XCTAssertEqual(
            TodayView.clearDayDetail(seesCalendar: true, seesReminders: false), "Nothing scheduled.")
        XCTAssertTrue(
            TodayView.clearDayDetail(seesCalendar: false, seesReminders: false).isEmpty,
            "with nothing visible there is nothing to report")
    }

    /// Not simply the next tab along. `ask` sits second in the switcher
    /// and is empty until something asks, so falling through to it would
    /// trade one blank screen for another.
    func testTheFallbackSkipsTabsThatAreAlsoEmptyByNature() {
        let defaults = Self.emptyDefaults()
        let landing = NotchViewModel.landingTab(todayCanSee: false, in: defaults)
        XCTAssertNotEqual(landing, .ask)
        XCTAssertNotEqual(landing, .today)
    }

    /// A tool switched off is not somewhere to open onto, exactly as
    /// `restoreLastTabIfWanted` already refuses to reopen into one.
    func testTheFallbackSkipsToolsTheUserSwitchedOff() {
        let defaults = Self.emptyDefaults()
        defaults.set(false, forKey: NotchViewModel.Tab.clipboard.toolKey!)
        XCTAssertEqual(NotchViewModel.landingTab(todayCanSee: false, in: defaults), .sessions)
    }

    /// And if every tool is off, Today is still the only place left. A
    /// blank Today beats no tab at all.
    func testWithEveryToolOffTodayIsStillTheAnswer() {
        let defaults = Self.emptyDefaults()
        for tab in NotchViewModel.Tab.allCases {
            if let key = tab.toolKey { defaults.set(false, forKey: key) }
        }
        XCTAssertEqual(NotchViewModel.landingTab(todayCanSee: false, in: defaults), .today)
    }

    private static func emptyDefaults() -> UserDefaults {
        let suite = "chalant.tests.landing"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: Tab persistence

    func testEveryTabRoundTripsThroughItsRawValue() {
        // The stored tab has to survive a relaunch, so a case added
        // later without a raw value would silently stop restoring.
        for tab in [NotchViewModel.Tab.today, .ask, .clipboard, .shelf,
                    .links, .notes, .focus, .chat, .sessions, .battery] {
            XCTAssertEqual(NotchViewModel.Tab(rawValue: tab.rawValue), tab)
        }
    }

    func testATabIsUnavailableOnlyWhenItsToolIsExplicitlyOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "chalant.tests.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        // Unset means the tool ships on, matching the @AppStorage
        // defaults the settings window declares.
        XCTAssertTrue(NotchViewModel.isAvailable(.notes, in: defaults))
        defaults.set(true, forKey: "toolNotes")
        XCTAssertTrue(NotchViewModel.isAvailable(.notes, in: defaults))
        defaults.set(false, forKey: "toolNotes")
        XCTAssertFalse(NotchViewModel.isAvailable(.notes, in: defaults))

        // The island's own surfaces answer to no switch.
        defaults.set(false, forKey: "toolClips")
        XCTAssertTrue(NotchViewModel.isAvailable(.today, in: defaults))
        XCTAssertTrue(NotchViewModel.isAvailable(.ask, in: defaults))
        XCTAssertFalse(NotchViewModel.isAvailable(.clipboard, in: defaults))
    }

    func testOnlyHideableToolsCarryASettingsKey() {
        // today and ask are the island itself; the rest each answer to
        // the switch that hides them, and restoring onto a hidden tool
        // would open a panel whose switcher icon is gone.
        XCTAssertNil(NotchViewModel.Tab.today.toolKey)
        XCTAssertNil(NotchViewModel.Tab.ask.toolKey)
        XCTAssertEqual(NotchViewModel.Tab.clipboard.toolKey, "toolClips")
        XCTAssertEqual(NotchViewModel.Tab.shelf.toolKey, "toolShelf")
        XCTAssertEqual(NotchViewModel.Tab.links.toolKey, "toolGo")
        XCTAssertEqual(NotchViewModel.Tab.notes.toolKey, "toolNotes")
        XCTAssertEqual(NotchViewModel.Tab.focus.toolKey, "toolFocus")
        XCTAssertEqual(NotchViewModel.Tab.chat.toolKey, "toolChat")
        XCTAssertEqual(NotchViewModel.Tab.sessions.toolKey, "toolSessions")
        XCTAssertEqual(NotchViewModel.Tab.battery.toolKey, "toolBattery")
    }

    func testABatteryTabIsUnavailableWithoutTheHardwareRegardlessOfTheSetting() throws {
        // The one tab gated on more than a settings flag: no battery
        // means no panel to open, whatever `toolBattery` says.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "chalant.tests.\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        XCTAssertTrue(
            NotchViewModel.isAvailable(.battery, in: defaults, batteryPresent: true))
        XCTAssertFalse(
            NotchViewModel.isAvailable(.battery, in: defaults, batteryPresent: false))
        defaults.set(false, forKey: "toolBattery")
        XCTAssertFalse(
            NotchViewModel.isAvailable(.battery, in: defaults, batteryPresent: true))
    }

    // MARK: Dashboard section lookup

    func testDashboardSectionNamedMatchesTheDebugHarnessSpellings() {
        // "debug settings island" used to scroll the in-island pane to a
        // section header; it now picks a window section, and both the
        // one-word key and the displayed title have to land.
        XCTAssertEqual(DashboardSection.named("island"), .island)
        XCTAssertEqual(DashboardSection.named("Island"), .island)
        XCTAssertEqual(DashboardSection.named("what shows"), .whatShows)
        XCTAssertEqual(DashboardSection.named("sessions"), .sessions)
        XCTAssertNil(DashboardSection.named("nonexistent"))
    }

    func testParseMetadataToleratesRecordsMissingSessionAndLeafFields() {
        // mode/permission-mode records on this machine carry no
        // leafUuid at all; the parser must not require one.
        let text = #"{"type":"mode","mode":"normal"}"#
        let metadata = SessionDiscovery.parseMetadata(text, path: "test.jsonl")
        XCTAssertEqual(metadata.mode, "normal")
    }
    // MARK: An agent finishing reaches the island (2026-08-03)

    func testComingToRestFiresOnceForTheTransitionNotForTheState() {
        let store = SessionStore()
        var announced: [String] = []
        store.onSessionCameToRest = { _, title in announced.append(title) }

        store.upsert(id: "s1", title: "a turn", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        // The registry confirming it alive and working is not an ending.
        store.markLive(id: "s1", name: "a turn", cwd: "/a", pid: 1,
                       kind: .interactive, hasTerminal: true, status: .working)
        XCTAssertTrue(announced.isEmpty)

        // Working to idle is the turn ending, and is worth saying once.
        store.markLive(id: "s1", name: "a turn", cwd: "/a", pid: 1,
                       kind: .interactive, hasTerminal: true, status: .idle)
        XCTAssertEqual(announced, ["a turn"])

        // Idle is idle on every rescan and every five second sweep. A
        // rule written against the state rather than the change would
        // announce this same finished turn for as long as it sat there.
        store.markLive(id: "s1", name: "a turn", cwd: "/a", pid: 1,
                       kind: .interactive, hasTerminal: true, status: .idle)
        store.markLive(id: "s1", name: "a turn", cwd: "/a", pid: 1,
                       kind: .interactive, hasTerminal: true, status: .idle)
        XCTAssertEqual(announced, ["a turn"], "a resting session must not re-announce")
    }

    func testTwoWritersFlappingOverOneFinishedTurnAnnounceItOnce() {
        let store = SessionStore()
        var announced: [String] = []
        store.onSessionCameToRest = { _, title in announced.append(title) }

        // The scraper sees a transcript written to a moment ago and says
        // working; the registry sees the process sitting at its prompt
        // and says idle. They disagree for a while after a turn ends, so
        // the edge happens several times for one finished turn. This
        // opened the island, collapsed it and opened it again while the
        // founder was typing (2026-08-03).
        store.upsert(id: "s1", title: "one turn", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, lastMessage: "here is what I did")
        for _ in 0..<4 {
            store.markLive(id: "s1", name: "one turn", cwd: "/a", pid: 1,
                           kind: .interactive, hasTerminal: true, status: .idle)
            store.upsert(id: "s1", title: "one turn", cwd: "/a", branch: nil,
                         lastPrompt: nil, state: .working, lastMessage: "here is what I did")
        }
        XCTAssertEqual(announced, ["one turn"], "one finished turn is one announcement")

        // A genuinely new turn produces new words, and is announced.
        store.upsert(id: "s1", title: "one turn", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, lastMessage: "and then this")
        store.markLive(id: "s1", name: "one turn", cwd: "/a", pid: 1,
                       kind: .interactive, hasTerminal: true, status: .idle)
        XCTAssertEqual(announced.count, 2, "new words are a new turn")
    }

    func testAQuestionOutstandingHoldsBackTheFinishedAnnouncement() {
        let store = SessionStore()
        var announced: [String] = []
        store.onSessionCameToRest = { _, title in announced.append(title) }
        store.upsert(id: "s1", title: "asking", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working)
        XCTAssertTrue(store.attach(askID: "q", to: "s1", header: "H",
                                   question: "Which?", options: ["a", "b"], multiSelect: false))
        // An unanswered question already owns the row's state, so the
        // registry never writes over it and there is no transition to
        // report: the question is the louder event and says its own
        // piece.
        store.markLive(id: "s1", name: "asking", cwd: "/a", pid: 1,
                       kind: .interactive, hasTerminal: true, status: .idle)
        XCTAssertTrue(announced.isEmpty)
    }

}
