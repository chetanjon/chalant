import Darwin
import Foundation
import os

/// Watches `~/.claude/sessions`, one JSON file per live Claude Code
/// process — the same directory `claude agents --json` reads
/// (notch-messaging-evidence-2026-08-01.md). This is the liveness half
/// of the two-signal design: `SessionDiscovery` infers "still going"
/// from a transcript's mtime, which cannot tell a session sitting at
/// its prompt from one that quit five minutes ago. This directory
/// carries a pid, so aliveness is checked rather than guessed.
///
/// Deliberately an overlay, never the sole source: the directory is
/// undocumented, and a Claude Code release that moves it should cost a
/// busy/idle badge, nothing more. `SessionStore.markLive` never writes
/// `title`, `cwd`, `activity`, `lastPrompt` or `branch` — those stay
/// the scraper's, so the strip is exactly as good as it was before this
/// file existed the moment this directory goes missing.
@MainActor
final class SessionRegistry {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "sessions")

    /// One registry file, reduced to what a row needs.
    struct Entry: Equatable {
        var sessionId: String
        var pid: pid_t
        var cwd: String
        var name: String
        var kind: SessionStore.Kind
        /// Raw as Claude Code writes it ("busy", "idle", "blocked", …).
        /// `state(for:alive:)` is the one place this becomes a
        /// `SessionStore.State`.
        var status: String
    }

    /// Same burst-collapsing window `SessionDiscovery` uses for the
    /// same reason: a status flip rewrites the file, and the handful of
    /// files this directory ever holds do not need each write handled
    /// separately.
    private static let debounceInterval: TimeInterval = 0.5
    /// Slow enough to be free, fast enough that a status is never
    /// visibly wrong for long. See `startSweep`.
    private static let sweepInterval: TimeInterval = 5

    // A directory-level watch, plus a slow sweep beside it. The watch
    // alone would be correct only if Claude Code replaces each
    // pid.json wholesale on a status flip, since a rename-over shows
    // up as a directory event and an in-place rewrite does not. That
    // is an undocumented detail of another program, and betting the
    // busy/idle badge on it means betting silently: a wrong status
    // never announces itself, it just sits there. See `startSweep`.

    private let store: SessionStore
    private let fileManager: FileManager
    private let root: URL
    private let watchQueue = DispatchQueue(label: "chalant.sessions.registry.watch")
    private let isAlive: (pid_t) -> Bool

    private var dirWatch: DispatchSourceFileSystemObject?
    private var sweep: DispatchSourceTimer?
    private var pendingRescan: DispatchWorkItem?
    /// Ids this directory reported alive last time it was read
    /// successfully, so a failed read is never mistaken for "everyone
    /// left" (EC-4).
    private var lastAliveIds: Set<String> = []

    init(
        store: SessionStore, root: URL? = nil, fileManager: FileManager = .default,
        isAlive: @escaping (pid_t) -> Bool = SessionRegistry.processIsAlive
    ) {
        self.store = store
        self.fileManager = fileManager
        self.root = root ?? Self.defaultRoot
        self.isAlive = isAlive
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    func start() {
        guard fileManager.fileExists(atPath: root.path) else {
            // An older Claude Code, or a fresh Mac: the strip is
            // exactly as good as it was before this file ever ran.
            Self.log.debug("no ~/.claude/sessions yet, no liveness overlay")
            return
        }
        watchDirectory()
        startSweep()
        rescan()
    }

    func stop() {
        dirWatch?.cancel()
        dirWatch = nil
        sweep?.cancel()
        sweep = nil
        pendingRescan?.cancel()
        pendingRescan = nil
    }

    // MARK: Scanning

    /// Re-lists the directory and re-derives every entry's liveness.
    /// A failed listing changes nothing — it is not the directory
    /// saying "empty", and reconciliation only ever runs on a read that
    /// actually succeeded (EC-4).
    private func rescan() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        var aliveIds: Set<String> = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = Self.parse(data, filename: file.lastPathComponent)
            else { continue }
            guard isAlive(entry.pid) else { continue } // a crash left the file behind (EC-5)
            aliveIds.insert(entry.sessionId)
            if let state = Self.state(for: entry, alive: isAlive) {
                store.markLive(
                    id: entry.sessionId, name: entry.name, cwd: entry.cwd,
                    pid: entry.pid, kind: entry.kind, status: state
                )
            }
            // Else: alive, but a status this milestone has no opinion
            // on (background's "blocked", or anything unrecognized).
            // Liveness is still recorded above so the id is never
            // wrongly reported gone; the row simply gets no state
            // opinion from the registry this round.
        }
        let gone = lastAliveIds.subtracting(aliveIds)
        if !gone.isEmpty { store.markGone(gone) }
        lastAliveIds = aliveIds
    }

    // MARK: Parsing

    /// Refuses an entry whose filename pid and body pid disagree
    /// (EC-5) and a `cwd` that is not absolute, exactly as
    /// `SessionDiscovery.parseMetadata` does for its own cwd field.
    nonisolated static func parse(_ data: Data, filename: String) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let sessionId = object["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        guard let bodyPid = object["pid"] as? Int, bodyPid > 0 else { return nil }
        let base = filename.hasSuffix(".json") ? String(filename.dropLast(5)) : filename
        // The body is the one to trust, and both are checked so a
        // renamed file cannot lie about which process it speaks for.
        guard let filenamePid = Int(base), filenamePid == bodyPid else { return nil }
        guard let cwd = object["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
        guard let kindRaw = object["kind"] as? String, let kind = SessionStore.Kind(rawValue: kindRaw)
        else { return nil }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? cwd.split(separator: "/").last.map(String.init) ?? cwd
        let status = object["status"] as? String ?? ""
        return Entry(
            sessionId: sessionId, pid: pid_t(bodyPid), cwd: cwd, name: name, kind: kind, status: status
        )
    }

    /// `.working` for busy, `.idle` for idle, `nil` when the pid is
    /// dead — or when the status is one this milestone does not
    /// classify (background's "blocked" is real but out of scope here;
    /// see `rescan`'s comment).
    nonisolated static func state(for entry: Entry, alive: (pid_t) -> Bool) -> SessionStore.State? {
        guard alive(entry.pid) else { return nil }
        switch entry.status {
        case "busy": return .working
        case "idle": return .idle
        default: return nil
        }
    }

    /// `kill(pid, 0)` sends no signal, only asks whether delivery would
    /// be possible: 0 means the process exists and is ours; `EPERM`
    /// means it exists but belongs to someone else, which still counts
    /// as alive; anything else (`ESRCH`, chiefly) means it is gone.
    nonisolated static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: Filesystem watching

    private func watchDirectory() {
        let descriptor = open(root.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.error("registry watch failed to open \(self.root.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename], queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleDebouncedRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        dirWatch = source
    }

    /// A directory watch fires when entries are added, removed or
    /// renamed. It does NOT fire when a program rewrites an existing
    /// file's bytes in place, and whether Claude Code rewrites
    /// `<pid>.json` in place or writes-and-renames is undocumented.
    /// Measured here rather than assumed: four session files went 90
    /// seconds without a single write while a session was working
    /// throughout, so the file is touched only when the status
    /// actually changes - which is exactly the event that must not be
    /// missed. Getting this wrong is silent and permanent: a session
    /// would sit on the island wearing a status it left minutes ago,
    /// and the whole point of the status is telling someone whether
    /// their message lands in seconds or never.
    ///
    /// So the watch is not trusted alone. A slow sweep re-reads the
    /// directory regardless, which costs a listing of four small files
    /// and removes the dependency on an implementation detail of
    /// another program entirely.
    ///
    /// ponytail: 5s poll beside the watch. If the registry is ever
    /// documented as writing atomically, delete this and keep the
    /// watch.
    private func startSweep() {
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
        timer.resume()
        sweep = timer
    }

    private func scheduleDebouncedRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}
