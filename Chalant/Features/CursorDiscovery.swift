import Foundation
import os

/// Finds Cursor's agent chats the same way Chalant finds Claude Code's:
/// by reading what the tool already writes, with nothing to install.
///
/// Cursor keeps one directory per chat under
/// `~/.cursor/chats/<workspace>/<chat>/`, holding a `meta.json` beside a
/// SQLite `store.db`. Only the JSON is read — the conversation lives in
/// the database, and opening someone's chat contents to put a folder
/// name in a strip would be a wildly disproportionate thing to do.
@MainActor
final class CursorDiscovery {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "sessions")

    /// The fields Chalant needs out of a chat's `meta.json`.
    struct Meta: Equatable {
        var cwd: String
        var updatedAt: Date

        /// Times arrive as milliseconds since the epoch. Anything that
        /// is not a positive number is not a time, and a chat without a
        /// working directory has nothing a row could point at.
        init?(json: [String: Any]) {
            guard let cwd = json["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
            let millis = (json["updatedAtMs"] as? Double)
                ?? (json["createdAtMs"] as? Double)
            guard let millis, millis > 0 else { return nil }
            self.cwd = cwd
            self.updatedAt = Date(timeIntervalSince1970: millis / 1000)
        }
    }

    static func parseMeta(_ data: Data) -> Meta? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Meta(json: object)
    }

    /// Cursor rewrites `meta.json` as a chat moves, but nothing here
    /// watches for it: a poll on the same clock the stale check already
    /// runs on is enough for a surface measured in minutes, and it
    /// avoids holding a file descriptor per chat on a machine that
    /// accumulates hundreds of them.
    private static let pollInterval: TimeInterval = 20
    private static let staleWindow: TimeInterval = 5 * 60
    /// Same reasoning as the Claude scanner: only the freshest are worth
    /// reading, and the store's own cap shows fewer than this anyway.
    private static let maxChatsToTrack = 12

    private let store: SessionStore
    private let fileManager: FileManager
    private let root: URL
    private var timer: Timer?

    init(store: SessionStore, root: URL? = nil, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
        self.root = root ?? Self.defaultRoot
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/chats", isDirectory: true)
    }

    func start() {
        guard fileManager.fileExists(atPath: root.path) else {
            Self.log.debug("no ~/.cursor/chats, nothing to discover")
            return
        }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        let workspaces = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var found: [(id: String, meta: Meta)] = []
        for workspace in workspaces {
            let chats = (try? fileManager.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for chat in chats {
                let metaURL = chat.appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = Self.parseMeta(data)
                else { continue }
                found.append((id: "cursor:" + chat.lastPathComponent, meta: meta))
            }
        }
        for entry in found.sorted(by: { $0.meta.updatedAt > $1.meta.updatedAt })
            .prefix(Self.maxChatsToTrack) {
            let fresh = Date().timeIntervalSince(entry.meta.updatedAt) <= Self.staleWindow
            store.upsert(
                id: entry.id,
                title: entry.meta.cwd.split(separator: "/").last.map(String.init)
                    ?? entry.meta.cwd,
                cwd: entry.meta.cwd,
                branch: nil,
                lastPrompt: nil,
                state: fresh ? .working : .stale,
                agent: .cursor,
                updatedAt: entry.meta.updatedAt
            )
        }
    }
}
