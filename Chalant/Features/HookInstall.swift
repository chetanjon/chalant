import Foundation

/// Whether Claude Code, Cursor or Codex is set up to hand this app an
/// event. Each keeps its own live `hooks.json` (Cursor and Codex) or
/// `settings.json` (Claude Code), already pointed at another tool the
/// founder runs.
///
/// This file used to only ever read: never write, never merge, never
/// back up (founder decision, W-E; reaffirmed for the other two agents
/// in cursor-codex-hooks-evidence-2026-08-02.md). **That was reversed
/// for Claude Code on 2026-08-03**, and the reason is worth keeping: the
/// founder had approval rules configured for a day and not one of them
/// ever fired, because arming them meant hand-pasting JSON into
/// settings.json and nobody does that. A feature whose setup step no
/// user completes has not shipped.
///
/// So `arm()` and `disarm()` write, and they do the whole list the old
/// decision was avoiding rather than a convenient subset: refuse on
/// JSON this app cannot parse, merge into the hooks already configured
/// instead of replacing them, copy the old file aside first, write
/// atomically, and follow a symlink rather than replacing it. Cursor and
/// Codex are still read-only, because nobody has asked for those and the
/// reversal was specific.
enum HookInstall {
    /// The three tools this app knows how to be notified by. Kept here
    /// rather than reusing `SessionStore.Agent`: that enum names who a
    /// *session* belongs to (Claude Code or Cursor, the two agents this
    /// app can discover a running session for), while this one names
    /// who a *hook* can belong to. Codex has no session store at all,
    /// which is the evidence's whole finding: a notification needs
    /// only a hook, not a store.
    enum Agent: String, CaseIterable, Identifiable, Hashable {
        case claude
        case cursor
        case codex

        var id: String { rawValue }

        var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .cursor: return "Cursor"
            case .codex: return "Codex"
            }
        }

        /// Shown in the dashboard so "merge this in" points at the
        /// right file: the three live in different places, in two
        /// different shapes (below).
        var configPath: String {
            switch self {
            case .claude: return "~/.claude/settings.json"
            case .cursor: return "~/.cursor/hooks.json"
            case .codex: return "~/.codex/hooks.json"
            }
        }

        fileprivate var fileURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(configPath.dropFirst(2)))
        }
    }

    enum Status: Equatable {
        case installed
        case missing
        case unreadable

        var symbol: String {
            switch self {
            case .installed: return "checkmark.circle.fill"
            case .missing: return "exclamationmark.circle"
            case .unreadable: return "exclamationmark.triangle"
            }
        }

        var label: String {
            switch self {
            case .installed: return "Installed"
            case .missing: return "Not set up"
            case .unreadable: return "Can't read your settings"
            }
        }
    }

    /// `installed` iff some entry under `hooks.Stop[].hooks[].command`
    /// contains "chalant-hook". A Notification-only install still reads
    /// as `missing`: Notification fires on a permission prompt, not a
    /// turn boundary, and cannot hand a message back into the model.
    ///
    /// A settings file that will not parse is `unreadable`, which must
    /// not render as `missing` — telling somebody to install what they
    /// already have, because their JSON has a stray comma, is worse
    /// than saying nothing. Pure over an already-decoded dictionary so
    /// it is testable without a real file.
    ///
    /// Also Codex's own detector: `~/.codex/hooks.json` is documented
    /// as Claude Code's exact shape (cursor-codex-hooks-evidence-
    /// 2026-08-02.md), so the whole file IS the `{"hooks": {...}}`
    /// object this already expects, and nothing here needed to change
    /// to read it, only where it comes from.
    static func status(settings: [String: Any]?) -> Status {
        guard let settings else { return .unreadable }
        guard let hooks = settings["hooks"] as? [String: Any],
              let stopEntries = hooks["Stop"] as? [[String: Any]]
        else { return .missing }
        let installed = stopEntries.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("chalant-hook") ?? false
            } ?? false
        }
        return installed ? .installed : .missing
    }

    /// Whether Claude Code is set up to let this app hold a tool call.
    ///
    /// A separate question from `status(settings:)`, and a separate
    /// hook. `Stop` carries a message back at a turn boundary;
    /// `PreToolUse` is the only event whose answer can stop a call from
    /// running at all. Somebody can perfectly well have one and not the
    /// other, and telling them the whole thing is installed when the
    /// deciding half is missing would be the worst kind of wrong: the
    /// rules would sit there looking armed.
    static func holdsToolCalls(settings: [String: Any]?) -> Bool {
        guard let settings,
              let hooks = settings["hooks"] as? [String: Any],
              let entries = hooks["PreToolUse"] as? [[String: Any]]
        else { return false }
        return entries.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("chalant-hook") ?? false
            } ?? false
        }
    }

    static func holdsToolCalls() -> Bool {
        guard case .parsed(let object) = fileState(at: settingsURL) else { return false }
        return holdsToolCalls(settings: object)
    }

    /// The line that arms the rules. Its own snippet rather than a
    /// bigger version of the main one: this hook can stop a command
    /// from running, so adding it is a decision of its own and should
    /// read like one.
    ///
    /// The generous timeout is the hook's patience plus room to answer.
    /// A shorter one than the hook waits would have Claude Code kill it
    /// mid-question and the card would outlive the agent asking.
    static var holdSnippet: String {
        let path = bundledScriptPath ?? "/path/to/scripts/chalant-hook"
        return """
        {
          "hooks": {
            "PreToolUse": [
              { "hooks": [ { "type": "command", "command": "\(path)", "timeout": 40 } ] }
            ]
          }
        }
        """
    }

    /// Cursor's own shape: `hooks.stop[]`, lower-case event name, each
    /// entry a bare `{"command": ...}` with no inner `hooks` key,
    /// flatter than Claude Code's, per the evidence. Pure for the same
    /// reason `status(settings:)` is: testable without a real file.
    static func cursorStatus(hooks: [String: Any]?) -> Status {
        guard let hooks else { return .unreadable }
        guard let hooksDict = hooks["hooks"] as? [String: Any],
              let stopEntries = hooksDict["stop"] as? [[String: Any]]
        else { return .missing }
        let installed = stopEntries.contains {
            ($0["command"] as? String)?.contains("chalant-hook") ?? false
        }
        return installed ? .installed : .missing
    }

    private static var settingsURL: URL { Agent.claude.fileURL }

    // MARK: Arming the door

    /// What happened when we tried to write somebody's settings file.
    enum ArmOutcome: Equatable {
        /// Written. The backup path is carried so the surface can say
        /// where the old file went rather than "trust me".
        case armed(backup: String?)
        case alreadyArmed
        /// Nothing was written, and this is why. Every failure here
        /// leaves the file exactly as it was.
        case refused(String)
    }

    /// The `PreToolUse` entry this app installs, and the only one it
    /// will ever remove.
    private static func holdEntry() -> [String: Any]? {
        guard let path = bundledScriptPath else { return nil }
        return ["hooks": [["type": "command", "command": path, "timeout": 40]]]
    }

    /// Add the hook that lets the island hold a tool call.
    ///
    /// Everything here is in service of one rule: a settings file this
    /// app does not fully understand is a settings file it does not
    /// touch. It refuses on unparseable JSON rather than "fixing" it,
    /// it merges into whatever hooks are already configured instead of
    /// replacing them (this machine runs pixel-agents hooks on five
    /// events, and losing those would be an outrage), it copies the old
    /// file aside first, and it writes through a symlink rather than
    /// replacing the link.
    ///
    /// `at:` is a testing seam and nothing else, the same shape
    /// `SessionStore`'s `outboxDirectory` is: a test must never be one
    /// typo away from rewriting the real install's Claude config.
    @discardableResult
    static func arm(at url: URL? = nil) -> ArmOutcome {
        let settingsURL = url ?? Self.settingsURL
        guard let entry = holdEntry() else {
            return .refused("Chalant can't find its own hook script inside the app bundle.")
        }
        var settings: [String: Any]
        switch fileState(at: settingsURL) {
        case .parsed(let object):
            settings = object
        case .missing:
            // No file is not a problem: Claude Code makes one when it
            // needs one, and so can this.
            settings = [:]
        case .unreadable:
            return .refused(
                "Your ~/.claude/settings.json has something in it that isn't valid JSON. "
                + "Chalant won't rewrite a file it can't read. Fix the file and try again.")
        }
        if holdsToolCalls(settings: settings) { return .alreadyArmed }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append(entry)
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        else { return .refused("Chalant could not build the new settings file.") }

        let backup = backUpSettings(settingsURL)
        // Through the symlink, not over it: some people keep their
        // Claude config in a dotfiles repo and point at it from here,
        // and replacing the link would quietly disconnect them from
        // their own versioned file.
        let destination = settingsURL.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            return .refused("Chalant could not write \(destination.path): \(error.localizedDescription)")
        }
        return .armed(backup: backup)
    }

    // MARK: Answering the prompt itself

    /// The path Claude Code posts a permission prompt to.
    ///
    /// It is also the tag. Nothing else on anybody's machine writes this
    /// URL, so finding our own entry again needs no marker key smuggled
    /// into a schema that belongs to Claude Code rather than to us.
    static let promptPath = "/hook/permission-request"

    /// How long the agent waits, and the number the card counts down.
    /// The same as Claude Code's own default, said out loud here because
    /// two places depend on it agreeing.
    static let promptTimeout = 600

    /// The `PermissionRequest` entry this app installs, and the only one
    /// it will ever remove.
    static func promptEntry(port: UInt16, token: String) -> [String: Any] {
        [
            "matcher": "*",
            "hooks": [[
                "type": "http",
                // Loopback by name. This is written into somebody's
                // config and outlives the process that wrote it.
                "url": "http://127.0.0.1:\(port)\(promptPath)",
                "timeout": promptTimeout,
                // The literal token, never `$VAR`. Header interpolation
                // reads the AGENT's environment, not this app's, and a
                // variable that is not set there resolves to an empty
                // string: a 401 with nothing anywhere saying why.
                "headers": ["Authorization": "Bearer \(token)"],
            ]],
        ]
    }

    private static func isOurPromptEntry(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            ($0["url"] as? String)?.contains(promptPath) ?? false
        } ?? false
    }

    /// Whether Claude Code will hand this app its permission prompts.
    static func answersPrompts(settings: [String: Any]?) -> Bool {
        guard let settings,
              let hooks = settings["hooks"] as? [String: Any],
              let entries = hooks["PermissionRequest"] as? [[String: Any]]
        else { return false }
        return entries.contains(where: isOurPromptEntry)
    }

    static func answersPrompts(at url: URL? = nil) -> Bool {
        guard case .parsed(let object) = fileState(at: url ?? Self.settingsURL) else {
            return false
        }
        return answersPrompts(settings: object)
    }

    /// Where the running server published its port and token.
    static func serverConfig() -> (port: UInt16, token: String)? {
        guard let data = try? Data(contentsOf: ActivityServer.configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let token = object["token"] as? String,
              port > 0, port <= Int(UInt16.max), !token.isEmpty
        else { return nil }
        return (UInt16(port), token)
    }

    /// Let Claude Code hand its permission prompts to the island.
    ///
    /// Adding and refreshing are one operation on purpose. The port is
    /// whichever one the server actually opened, and it can move if
    /// something else has 4242, so an entry written last week can be
    /// pointing at nothing. Re-running this fixes it, and re-running it
    /// when nothing has changed writes no file at all, which is what
    /// keeps it safe to call on every launch.
    ///
    /// Same safety as `arm`, through the same writer: refuses a file it
    /// cannot parse, keeps every other hook in it, copies the old file
    /// aside, writes atomically, and follows a symlink rather than
    /// replacing it.
    @discardableResult
    static func armPrompts(
        port: UInt16? = nil, token: String? = nil, at url: URL? = nil
    ) -> ArmOutcome {
        let resolved: (port: UInt16, token: String)
        if let port, let token {
            resolved = (port, token)
        } else if let found = serverConfig() {
            resolved = found
        } else {
            return .refused(
                "Chalant's own door isn't open yet, so there is no address to point Claude "
                + "Code at. Try again in a moment.")
        }
        let settingsURL = url ?? Self.settingsURL
        var settings: [String: Any]
        switch fileState(at: settingsURL) {
        case .parsed(let object): settings = object
        case .missing: settings = [:]
        case .unreadable:
            return .refused(
                "Your ~/.claude/settings.json has something in it that isn't valid JSON. "
                + "Chalant won't rewrite a file it can't read. Fix the file and try again.")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        let wanted = promptEntry(port: resolved.port, token: resolved.token)
        let ours = entries.filter(isOurPromptEntry)
        // Already exactly right, down to the port and the token. Writing
        // an identical file would still cost a backup and a timestamp,
        // and this runs on every launch.
        if ours.count == 1, NSDictionary(dictionary: ours[0]).isEqual(to: wanted) {
            return .alreadyArmed
        }
        entries.removeAll(where: isOurPromptEntry)
        entries.append(wanted)
        hooks["PermissionRequest"] = entries
        settings["hooks"] = hooks
        return commit(settings, to: settingsURL)
    }

    /// Take it back out, leaving every other `PermissionRequest` hook
    /// alone.
    @discardableResult
    static func disarmPrompts(at url: URL? = nil) -> ArmOutcome {
        let settingsURL = url ?? Self.settingsURL
        guard case .parsed(var settings) = fileState(at: settingsURL) else {
            return .refused("Chalant can't read your ~/.claude/settings.json.")
        }
        guard var hooks = settings["hooks"] as? [String: Any],
              var entries = hooks["PermissionRequest"] as? [[String: Any]]
        else { return .armed(backup: nil) }
        let before = entries.count
        entries.removeAll(where: isOurPromptEntry)
        guard entries.count != before else { return .armed(backup: nil) }
        if entries.isEmpty {
            hooks.removeValue(forKey: "PermissionRequest")
        } else {
            hooks["PermissionRequest"] = entries
        }
        settings["hooks"] = hooks
        return commit(settings, to: settingsURL)
    }

    // MARK: Reaching a session from your phone

    /// Claude Code's own setting for it. User scope only: repo-local
    /// settings may turn Remote Control off but never on.
    static let remoteControlKey = "remoteControlAtStartup"

    /// Whether sessions started on this machine can be reached from the
    /// Claude app on a phone.
    ///
    /// Absent means Claude Code's own default, which is off, and is kept
    /// distinct from an explicit `false` nowhere except here: both read
    /// as "no", and only `disarmRemoteControl` cares about the
    /// difference, because writing `false` over an unset key is a
    /// decision nobody made.
    static func reachesYourPhone(at url: URL? = nil) -> Bool {
        guard case .parsed(let settings) = fileState(at: url ?? Self.settingsURL)
        else { return false }
        return settings[remoteControlKey] as? Bool ?? false
    }

    /// Let the Claude app on your phone see and drive the sessions on
    /// this machine.
    ///
    /// The founder asked what the best way is to control agents from
    /// their phone. This is it, and it is not this app's invention:
    /// Claude Code 2.1.223 ships Remote Control, and with this one
    /// setting on, a local session becomes viewable and drivable from
    /// the Claude app, permission prompts included. Their machine
    /// already had `agentPushNotifEnabled` and `inputNeededNotifEnabled`
    /// set to true, so the phone half was armed the whole time and had
    /// nothing to reach.
    ///
    /// So Chalant ships a switch rather than a phone app, a push relay
    /// or a chat bridge. Every one of those would be this app rebuilding,
    /// worse, something already in the tool it watches.
    ///
    /// Same safety as `arm`, through the same writer: refuses a file it
    /// cannot parse, keeps everything else in it, backs up first, writes
    /// atomically, follows a symlink rather than replacing it.
    @discardableResult
    static func armRemoteControl(at url: URL? = nil) -> ArmOutcome {
        write(remoteControlKey, as: true, at: url)
    }

    /// Turn it back off by removing the key, not by writing `false`.
    ///
    /// The difference matters if Claude Code ever changes its own
    /// default: somebody who switched this off in Chalant asked for
    /// Chalant's opinion to go away, not to be pinned against a future
    /// version's.
    @discardableResult
    static func disarmRemoteControl(at url: URL? = nil) -> ArmOutcome {
        write(remoteControlKey, as: nil, at: url)
    }

    /// One top-level setting, changed in place. `nil` removes the key.
    private static func write(_ key: String, as value: Bool?, at url: URL?) -> ArmOutcome {
        let settingsURL = url ?? Self.settingsURL
        var settings: [String: Any]
        switch fileState(at: settingsURL) {
        case .parsed(let object): settings = object
        case .missing: settings = [:]
        case .unreadable:
            return .refused(
                "Your ~/.claude/settings.json has something in it that isn't valid JSON. "
                + "Chalant won't rewrite a file it can't read. Fix the file and try again.")
        }
        let current = settings[key] as? Bool
        guard current != value else { return .alreadyArmed }
        if let value { settings[key] = value } else { settings.removeValue(forKey: key) }
        return commit(settings, to: settingsURL)
    }

    /// The write half `arm`, `disarm` and the settings switches share:
    /// serialise, copy the old file aside, and write through any
    /// symlink rather than over it.
    private static func commit(_ settings: [String: Any], to settingsURL: URL) -> ArmOutcome {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        else { return .refused("Chalant could not build the new settings file.") }
        let backup = backUpSettings(settingsURL)
        let destination = settingsURL.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            return .refused(
                "Chalant could not write \(destination.path): \(error.localizedDescription)")
        }
        return .armed(backup: backup)
    }

    /// Take the hook back out, leaving every other hook alone.
    ///
    /// Matches on the command containing `chalant-hook`, the same test
    /// `holdsToolCalls` uses, so an entry somebody wrote themselves
    /// pointing at this app's script is removed too. That is the right
    /// answer: they asked for it gone.
    @discardableResult
    static func disarm(at url: URL? = nil) -> ArmOutcome {
        let settingsURL = url ?? Self.settingsURL
        guard case .parsed(var settings) = fileState(at: settingsURL) else {
            return .refused("Chalant can't read your ~/.claude/settings.json.")
        }
        guard var hooks = settings["hooks"] as? [String: Any],
              var preToolUse = hooks["PreToolUse"] as? [[String: Any]]
        else { return .armed(backup: nil) }
        preToolUse.removeAll { entry in
            (entry["hooks"] as? [[String: Any]])?.allSatisfy {
                ($0["command"] as? String)?.contains("chalant-hook") ?? false
            } ?? false
        }
        if preToolUse.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = preToolUse }
        settings["hooks"] = hooks
        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        else { return .refused("Chalant could not build the new settings file.") }
        let backup = backUpSettings(settingsURL)
        do {
            try data.write(to: settingsURL.resolvingSymlinksInPath(), options: .atomic)
        } catch {
            return .refused("Chalant could not write your settings: \(error.localizedDescription)")
        }
        return .armed(backup: backup)
    }

    /// A dated copy beside the original, so undo never depends on this
    /// app still running or on anybody trusting it.
    private static func backUpSettings(_ settingsURL: URL) -> String? {
        let source = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "settings.chalant-backup-"
            + stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")
            + ".json"
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.copyItem(at: source, to: destination)
        return FileManager.default.fileExists(atPath: destination.path) ? destination.path : nil
    }

    /// Reads the real file fresh on every call, never cached.
    ///
    /// This app used to refuse to write it at all, and the list of what
    /// a safe write would have to handle was the reason (a backup, an
    /// atomic write, a symlinked settings.json, merging with hooks
    /// already there). That refusal was reversed on 2026-08-03: the
    /// founder had approval rules configured for a day and not one of
    /// them ever fired, because arming them meant hand-pasting JSON and
    /// nobody does that. `arm()` below does the whole list rather than
    /// skipping it.
    ///
    /// A settings file that does not exist yet reads as `.missing`
    /// rather than `.unreadable`: there being no file is not a decoding
    /// failure, and it is in fact true that no hook is configured.
    static func status() -> Status {
        switch fileState(at: settingsURL) {
        case .missing: return .missing
        case .unreadable: return status(settings: nil)
        case .parsed(let object): return status(settings: object)
        }
    }

    /// Same missing/unreadable rules as Claude Code's `status()`, over
    /// Codex's `~/.codex/hooks.json`.
    static func status(agent: Agent) -> Status {
        switch agent {
        case .claude: return status()
        case .codex:
            switch fileState(at: agent.fileURL) {
            case .missing: return .missing
            case .unreadable: return .unreadable
            case .parsed(let object): return status(settings: object)
            }
        case .cursor:
            switch fileState(at: agent.fileURL) {
            case .missing: return .missing
            case .unreadable: return .unreadable
            case .parsed(let object): return cursorStatus(hooks: object)
            }
        }
    }

    private enum FileState {
        case missing
        case unreadable
        case parsed([String: Any])
    }

    private static func fileState(at url: URL) -> FileState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }
        return .parsed(object)
    }

    /// Where the bundled hook actually lives on this machine, resolved
    /// rather than guessed — same lookup MediaRemoteBridge uses for its
    /// own bundled script (MediaRemoteBridge.swift:62).
    static var bundledScriptPath: String? {
        Bundle.main.url(forResource: "chalant-hook", withExtension: nil)?.path
    }

    /// The snippet the dashboard offers for each agent, built around
    /// whichever path the running app resolves for its own bundled
    /// script: a placeholder when the app isn't bundled (a debug
    /// build run straight from Xcode), same fallback the Claude Code
    /// card already used.
    ///
    /// `CHALANT_AGENT` is how the hook script tells Cursor and Codex
    /// apart from Claude Code and from each other, set here in the
    /// snippet rather than guessed from the payload each sends
    /// (founder instruction: identified explicitly, the way the
    /// founder's own superset hooks set `SUPERSET_AGENT_ID`). Claude
    /// Code needs none: it is the default the script already assumes,
    /// and every install already out there predates this variable.
    static func snippet(for agent: Agent) -> String {
        let path = bundledScriptPath ?? "/path/to/scripts/chalant-hook"
        switch agent {
        case .claude:
            return """
            {
              "hooks": {
                "Notification": [
                  { "hooks": [ { "type": "command", "command": "\(path)" } ] }
                ],
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "\(path)" } ] }
                ]
              }
            }
            """
        case .codex:
            // Only Stop: it is the one event the evidence actually
            // found live in this founder's own ~/.codex/hooks.json.
            // Codex's file uses Claude Code's exact shape, but that is
            // a claim about the config schema, not proof Codex also
            // fires a Notification-equivalent event. Guessing that in
            // would be exactly the invented field name this feature
            // was told not to assume, one level up.
            return """
            {
              "hooks": {
                "Stop": [
                  { "hooks": [ { "type": "command", "command": "CHALANT_AGENT=codex \(path)" } ] }
                ]
              }
            }
            """
        case .cursor:
            // `stop` for "finished," and Cursor's two permission-request
            // events for the closest thing any of the three has to a
            // named "a question arrived": `beforeShellExecution` and
            // `beforeMCPExecution`. The hook script prints nothing on
            // those two: they may expect a structured reply, and
            // answering wrongly could block a command Cursor was about
            // to run.
            return """
            {
              "version": 1,
              "hooks": {
                "stop": [
                  { "command": "CHALANT_AGENT=cursor \(path) Stop" }
                ],
                "beforeShellExecution": [
                  { "command": "CHALANT_AGENT=cursor \(path) PermissionRequest" }
                ],
                "beforeMCPExecution": [
                  { "command": "CHALANT_AGENT=cursor \(path) PermissionRequest" }
                ]
              }
            }
            """
        }
    }
}
