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

    func testSortIsAttentionFirstThenNewestWithinState() {
        let store = SessionStore()
        let now = Date()
        store.upsert(id: "done", title: "d", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .done, updatedAt: now.addingTimeInterval(-50))
        store.upsert(id: "failed", title: "f", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .failed, updatedAt: now.addingTimeInterval(-40))
        store.upsert(id: "stale", title: "s", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .stale, updatedAt: now.addingTimeInterval(-30))
        store.upsert(id: "working-old", title: "w1", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, updatedAt: now.addingTimeInterval(-20))
        store.upsert(id: "working-new", title: "w2", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .working, updatedAt: now.addingTimeInterval(-10))
        store.upsert(id: "needs-input", title: "n", cwd: "/a", branch: nil,
                     lastPrompt: nil, state: .needsInput, updatedAt: now)

        XCTAssertEqual(store.sessions.map(\.id), [
            "needs-input", "working-new", "working-old", "stale", "failed", "done",
        ])
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
            collapsed: [.media, .media]
        )
        let fixed = layout.repaired()
        XCTAssertEqual(fixed.placed.filter { $0 == .media }.count, 1)
        XCTAssertEqual(fixed.collapsed, [.media])
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
        // Saved before `sessions` existed: absent from the rows AND from
        // what that build knew, so it is new rather than unwanted.
        var layout = IslandLayout(
            rows: [IslandRow([.media]), IslandRow([.switcher]), IslandRow([.input])],
            collapsed: []
        )
        layout.knownElements = [.media, .switcher, .input, .ambience, .activities, .timers]
        XCTAssertTrue(layout.repaired().placed.contains(.sessions))
        // And the one that build did know about, and left out, stays out.
        XCTAssertFalse(layout.repaired().placed.contains(.ambience))
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

    func testConfigsRoundTripThroughJSON() throws {
        var config = DisplayConfigStore.Config()
        config.style = .pill
        config.width = 240
        config.cornerRadius = 22
        let data = try JSONEncoder().encode(["screen-uuid": config])
        let back = try JSONDecoder().decode([String: DisplayConfigStore.Config].self, from: data)
        XCTAssertEqual(back["screen-uuid"], config)
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

    func testEveryActionHasItsOwnDefaultsKey() {
        let keys = HotKeyCenter.Action.allCases.map(\.defaultsKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    // MARK: Tab persistence

    func testEveryTabRoundTripsThroughItsRawValue() {
        // The stored tab has to survive a relaunch, so a case added
        // later without a raw value would silently stop restoring.
        for tab in [NotchViewModel.Tab.today, .ask, .clipboard, .shelf,
                    .links, .notes, .focus, .chat] {
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
}
