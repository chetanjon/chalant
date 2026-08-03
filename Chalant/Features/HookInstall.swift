import Foundation

/// Whether Claude Code, Cursor or Codex is set up to hand this app an
/// event. Each keeps its own live `hooks.json` (Cursor and Codex) or
/// `settings.json` (Claude Code), already pointed at another tool the
/// founder runs, so this only ever reads, never writes, never merges,
/// never backs up (founder decision, W-E; reaffirmed for the other two
/// agents in cursor-codex-hooks-evidence-2026-08-02.md: both files are
/// "already in use," and Chalant "adds itself alongside" or does
/// nothing).
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

    /// Reads the real file fresh on every call — never cached, and
    /// never written by this app. A one-click install is a real feature
    /// with a real way to ruin somebody's config (a backup, an atomic
    /// write, a symlinked settings.json, merging with hooks already
    /// there); this round only ever reads (founder decision, W-E).
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
