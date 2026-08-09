import XCTest
@testable import Chalant

/// Writing somebody's Claude config.
///
/// This app refused to do this at all until 2026-08-03, and the list of
/// things a safe write has to get right was the reason for refusing.
/// Every item on that list is a test here, because the failure mode is
/// not a bad pixel, it is somebody's five configured hooks disappearing.
///
/// Nothing here touches `~/.claude/settings.json`: `arm(at:)` takes a
/// URL for exactly that reason.
@MainActor
final class ArmingTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chalant-arming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ json: String) throws {
        try json.write(to: settings, atomically: true, encoding: .utf8)
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hooks(_ object: [String: Any], _ event: String) -> [[String: Any]] {
        (object["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    // MARK: Merging, which is the whole point

    /// The machine this was written on runs another tool's hooks on five
    /// events. Losing them would be an outrage, and "replace the hooks
    /// object" is the obvious wrong implementation.
    func testArmingKeepsEveryHookAlreadyThere() throws {
        try write("""
        {"model":"opus","hooks":{
          "Stop":[{"hooks":[{"type":"command","command":"/other/tool.js"}]}],
          "SessionStart":[{"hooks":[{"type":"command","command":"/other/tool.js"}]}]
        }}
        """)
        guard case .armed = HookInstall.arm(at: settings) else { return XCTFail("should arm") }
        let after = try read()
        XCTAssertEqual(after["model"] as? String, "opus")
        XCTAssertEqual(hooks(after, "Stop").count, 1)
        XCTAssertEqual(hooks(after, "SessionStart").count, 1)
        XCTAssertTrue(HookInstall.holdsToolCalls(settings: after))
    }

    /// A PreToolUse hook belonging to somebody else stays put, beside
    /// ours rather than under it.
    func testArmingAppendsBesideAnExistingPreToolUseHook() throws {
        try write("""
        {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/other/guard.js"}]}]}}
        """)
        guard case .armed = HookInstall.arm(at: settings) else { return XCTFail("should arm") }
        let entries = hooks(try read(), "PreToolUse")
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(HookInstall.holdsToolCalls(settings: try read()))
    }

    func testArmingAnEmptyMachineCreatesTheFile() throws {
        guard case .armed(let backup) = HookInstall.arm(at: settings) else {
            return XCTFail("should arm")
        }
        // Nothing existed, so nothing was backed up, and the card says
        // so rather than naming a path that is not there.
        XCTAssertNil(backup)
        XCTAssertTrue(HookInstall.holdsToolCalls(settings: try read()))
    }

    func testArmingTwiceWritesNothingTheSecondTime() throws {
        _ = HookInstall.arm(at: settings)
        let first = try Data(contentsOf: settings)
        XCTAssertEqual(HookInstall.arm(at: settings), .alreadyArmed)
        XCTAssertEqual(try Data(contentsOf: settings), first)
    }

    // MARK: Refusing, which matters more

    /// A settings file this app cannot parse is a settings file it does
    /// not touch. Rewriting it would mean silently discarding whatever
    /// the person actually had in there.
    func testUnparseableSettingsAreRefusedAndLeftExactlyAsTheyWere() throws {
        let broken = "{\"hooks\": { oh dear ,,, }"
        try write(broken)
        guard case .refused = HookInstall.arm(at: settings) else {
            return XCTFail("should refuse to touch a file it cannot read")
        }
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), broken)
    }

    // MARK: The way back

    func testTheOldFileIsCopiedAsideBeforeItIsChanged() throws {
        try write(#"{"model":"opus","hooks":{}}"#)
        guard case .armed(let backup) = HookInstall.arm(at: settings),
              let backup
        else { return XCTFail("should back up an existing file") }
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: backup)))
                as? [String: Any])
        XCTAssertEqual(saved["model"] as? String, "opus")
        XCTAssertFalse(HookInstall.holdsToolCalls(settings: saved))
    }

    func testDisarmTakesOutOnlyOurOwnEntry() throws {
        try write("""
        {"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/other/guard.js"}]}]}}
        """)
        _ = HookInstall.arm(at: settings)
        XCTAssertEqual(hooks(try read(), "PreToolUse").count, 2)
        guard case .armed = HookInstall.disarm(at: settings) else { return XCTFail("should disarm") }
        let left = hooks(try read(), "PreToolUse")
        XCTAssertEqual(left.count, 1)
        XCTAssertFalse(HookInstall.holdsToolCalls(settings: try read()))
    }

    /// An entry somebody hand-built, mixing this app's hook with another
    /// tool's in one entry. Detection counts it as armed (any inner hook
    /// is ours), so disarm has to reach inside it the same way — the old
    /// all-or-nothing removal left it armed forever with no way out.
    func testDisarmReachesInsideAMixedEntryAndTakesOnlyOurHalf() throws {
        try write("""
        {"hooks":{"PreToolUse":[{"hooks":[
          {"type":"command","command":"/other/guard.js"},
          {"type":"command","command":"/somewhere/chalant-hook","timeout":40}]}]}}
        """)
        XCTAssertTrue(HookInstall.holdsToolCalls(settings: try read()))

        guard case .armed = HookInstall.disarm(at: settings) else { return XCTFail("should disarm") }

        let left = hooks(try read(), "PreToolUse")
        XCTAssertEqual(left.count, 1)
        let inner = try XCTUnwrap(left[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.map { $0["command"] as? String }, ["/other/guard.js"],
                       "the other tool's half of the entry is not ours to lose")
        XCTAssertFalse(HookInstall.holdsToolCalls(settings: try read()))
    }

    /// Arm, disarm, and the only difference to the file should be the
    /// hook itself.
    func testArmThenDisarmLeavesTheRestOfTheFileIntact() throws {
        try write("""
        {"model":"opus","permissions":{"allow":["Bash(ls:*)"]},
         "hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/tool.js"}]}]}}
        """)
        _ = HookInstall.arm(at: settings)
        _ = HookInstall.disarm(at: settings)
        let after = try read()
        XCTAssertEqual(after["model"] as? String, "opus")
        XCTAssertEqual(
            (after["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual(hooks(after, "Stop").count, 1)
        XCTAssertTrue(hooks(after, "PreToolUse").isEmpty)
    }

    /// Some people keep their Claude config in a dotfiles repo and point
    /// at it from ~/.claude. Replacing the link would quietly disconnect
    /// them from their own versioned file.
    func testWritingFollowsASymlinkInsteadOfReplacingIt() throws {
        let real = dir.appendingPathComponent("real-settings.json")
        try #"{"model":"opus","hooks":{}}"#.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)
        guard case .armed = HookInstall.arm(at: settings) else { return XCTFail("should arm") }
        let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        XCTAssertTrue(HookInstall.holdsToolCalls(settings: written))
    }

    // MARK: Reaching a session from your phone

    /// Claude Code 2.1.223 has this built in: with
    /// `remoteControlAtStartup` on at user scope, every session becomes
    /// viewable and drivable from the Claude app on a phone, permission
    /// prompts included. The founder already has `agentPushNotifEnabled`
    /// and `inputNeededNotifEnabled` on, so the push half was armed and
    /// had nothing to push. This is the missing setting, and one button
    /// is the whole feature: no phone app, no bridge, no relay.
    func testArmingThePhoneWritesTheSettingClaudeCodeReads() throws {
        try write("{}")

        // A file that existed is copied aside first, same as arming the
        // hook does. Nobody's settings change here without a way back.
        guard case .armed(let backup) = HookInstall.armRemoteControl(at: settings) else {
            return XCTFail("should arm")
        }
        XCTAssertNotNil(backup)
        XCTAssertEqual(try read()["remoteControlAtStartup"] as? Bool, true)
    }

    func testArmingThePhoneKeepsEveryOtherSettingAndHook() throws {
        try write("""
        {"permissions":{"allow":["Bash(ls:*)"]},
         "hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"node other.js"}]}]},
         "agentPushNotifEnabled":true}
        """)

        _ = HookInstall.armRemoteControl(at: settings)

        let after = try read()
        XCTAssertEqual(hooks(after, "Stop").count, 1, "somebody else's hooks are not ours to lose")
        XCTAssertNotNil(after["permissions"])
        XCTAssertEqual(after["agentPushNotifEnabled"] as? Bool, true)
    }

    func testArmingThePhoneTwiceWritesNothingTheSecondTime() throws {
        try write("{}")
        _ = HookInstall.armRemoteControl(at: settings)
        let first = try Data(contentsOf: settings)

        XCTAssertEqual(HookInstall.armRemoteControl(at: settings), .alreadyArmed)
        XCTAssertEqual(try Data(contentsOf: settings), first)
    }

    /// The same refusal the hook install makes, for the same reason: a
    /// settings file this app cannot read is a settings file it does not
    /// touch.
    func testUnparseableSettingsAreRefusedByThePhoneSwitchToo() throws {
        try write("{ not json")

        guard case .refused = HookInstall.armRemoteControl(at: settings) else {
            return XCTFail("a file it cannot read must not be rewritten")
        }
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ not json")
    }

    func testTurningThePhoneBackOffRemovesTheSettingRatherThanFalsifyingIt() throws {
        try write(#"{"remoteControlAtStartup":true,"agentPushNotifEnabled":true}"#)

        _ = HookInstall.disarmRemoteControl(at: settings)

        let after = try read()
        XCTAssertNil(after["remoteControlAtStartup"],
                     "absent is Claude Code's own default; false is a decision nobody made")
        XCTAssertEqual(after["agentPushNotifEnabled"] as? Bool, true)
    }

    func testWhetherThePhoneCanReachSessionsIsReadFromTheFile() throws {
        try write("{}")
        XCTAssertFalse(HookInstall.reachesYourPhone(at: settings))

        try write(#"{"remoteControlAtStartup":true}"#)
        XCTAssertTrue(HookInstall.reachesYourPhone(at: settings))

        // Explicitly off is off, and reads as off rather than as unset.
        try write(#"{"remoteControlAtStartup":false}"#)
        XCTAssertFalse(HookInstall.reachesYourPhone(at: settings))
    }

}

/// Typing into a running session.
@MainActor
final class SessionRemoteTests: XCTestCase {
    /// A newline in the composer would submit early and send the rest as
    /// a second message, which turns one instruction into two half ones.
    func testTextIsCollapsedToOneLine() {
        XCTAssertEqual(
            SessionRemote.oneLine("first line\nsecond line"), "first line second line")
        XCTAssertEqual(SessionRemote.oneLine("  spaced  \n\n  out  "), "spaced out")
        XCTAssertEqual(SessionRemote.oneLine("\n\n"), "")
    }

    func testOnlyRealTerminalsAreTypedInto() {
        let terminal = SessionRemote.Target(
            tty: "/dev/ttys004", bundleID: "com.apple.Terminal", appName: "Terminal")
        let iterm = SessionRemote.Target(
            tty: "/dev/ttys004", bundleID: "com.googlecode.iterm2", appName: "iTerm2")
        // An editor's built-in terminal cannot be named from outside, so
        // typing into it would mean typing blind into whatever buffer is
        // open. Those queue instead.
        let cursor = SessionRemote.Target(
            tty: "/dev/ttys004", bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        XCTAssertTrue(SessionRemote.canType(into: terminal))
        XCTAssertTrue(SessionRemote.canType(into: iterm))
        XCTAssertFalse(SessionRemote.canType(into: cursor))
    }

    func testTypingIsOffUntilItIsTurnedOn() {
        let suite = "chalant.tests.remote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SessionRemote.sendsStraightToTerminal(in: defaults))
        defaults.set(true, forKey: SessionRemote.straightToTerminalKey)
        XCTAssertTrue(SessionRemote.sendsStraightToTerminal(in: defaults))
    }

    /// An editor target refuses rather than typing, and says so in words
    /// meant for a person.
    func testAnEditorTargetRefusesInsteadOfTypingBlind() async {
        let cursor = SessionRemote.Target(
            tty: "/dev/ttys004", bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        guard case .cannot(let why) = await SessionRemote.type("hello", into: cursor) else {
            return XCTFail("must not type into an editor")
        }
        XCTAssertTrue(why.contains("Cursor"))
        XCTAssertTrue(why.lowercased().contains("queued"))
    }

    func testEmptyTextIsNeverSent() async {
        let terminal = SessionRemote.Target(
            tty: "/dev/ttys004", bundleID: "com.apple.Terminal", appName: "Terminal")
        guard case .cannot = await SessionRemote.type("   \n  ", into: terminal) else {
            return XCTFail("nothing to send")
        }
    }
}
