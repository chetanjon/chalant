import Foundation

/// Whether Claude Code is set up to hand this app a Stop event.
///
/// Read from the user's own settings rather than assumed: the hook has
/// shipped and been documented since 2026-08-01 and was installed on no
/// machine, so every message queued would have sat there forever with
/// nothing saying why (notch-messaging-plan-2026-08-01.md, finding 1).
enum HookInstall {
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

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

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
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return status(settings: nil) }
        return status(settings: object)
    }

    /// Where the bundled hook actually lives on this machine, resolved
    /// rather than guessed — same lookup MediaRemoteBridge uses for its
    /// own bundled script (MediaRemoteBridge.swift:62).
    static var bundledScriptPath: String? {
        Bundle.main.url(forResource: "chalant-hook", withExtension: nil)?.path
    }
}
