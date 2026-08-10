import Foundation
import os

/// Watches `~/.claude/projects` and turns each session's metadata file
/// into a SessionStore row. This is the "always know it's there" half
/// of the two-signal design in architecture-session-bridge.md: zero
/// setup, no hook contract to get right, and it still shows sessions
/// that were already running before Chalant launched. Hooks (a later
/// phase) upgrade a row's liveness; this file only ever asserts
/// working-by-recency or stale, because a file being touched recently
/// is a proxy for "alive," not proof of it.
@MainActor
final class SessionDiscovery {
    nonisolated private static let log = Logger(subsystem: "com.cj.chalant", category: "sessions")

    /// One JSON object per line, `type` tagged, last write per field
    /// wins. Unknown fields and unknown types both stay nil / skipped:
    /// the file format is allowed to grow without this parser breaking
    /// on it. `mode`/`permissionMode` are parsed and carried even
    /// though Session doesn't expose them yet, so a later feature can
    /// read them without touching this parser again.
    struct ParsedMetadata: Equatable {
        var aiTitle: String?
        var lastPrompt: String?
        /// The last plain-text thing the assistant said, as opposed to
        /// the last tool it reached for. Both ride the same content
        /// blocks; this is the half a person would want to read.
        var lastMessage: String?
        var mode: String?
        var permissionMode: String?
        /// Recorded by Claude Code on every message record, so a live
        /// session's own working directory and branch come from the
        /// file itself rather than from decoding the directory name.
        var cwd: String?
        var gitBranch: String?
        /// The last tool the agent reached for, which is the closest
        /// thing the transcript has to "what it is doing right now".
        var lastTool: String?
        /// What that tool was pointed at: a file's name, a search
        /// pattern, the agent's own description of a command. Always
        /// rewritten together with `lastTool`, never carried over from
        /// an earlier call, or a row reads "Searching for
        /// SessionStore.swift".
        var lastToolDetail: String?
    }

    // `AskUserQuestion` is no longer read out of the transcript here.
    // It is intercepted whole at the `PreToolUse` door instead
    // (`/hook/ask-user`), where the card can actually answer it; a
    // scraped question could only ever queue a note for the next turn,
    // and the scrape was one transcript-format change away from
    // breaking silently.

    /// What a tool name means to someone glancing at a row.
    ///
    /// Tool names are the agent's vocabulary, not the user's: "Grep"
    /// and "NotebookEdit" say nothing to somebody watching a strip go
    /// by. Anything unrecognised falls through to the raw name rather
    /// than to a shrug — a name is still more use than "working".
    ///
    /// `detail` names what the tool is pointed at, and it is the half
    /// that makes the line worth reading: "Editing" answers a question
    /// nobody asked, "Editing SessionStore.swift" answers the one they
    /// did. Nil for a call whose input said nothing usable, which lands
    /// back on the plain phrase this has always returned.
    static func activityPhrase(forTool tool: String, detail: String? = nil) -> String {
        let named = detail.flatMap { $0.isEmpty ? nil : $0 }
        switch tool {
        case "Edit", "Write", "NotebookEdit":
            return named.map { "Editing \($0)" } ?? "Editing"
        case "Read":
            return named.map { "Reading \($0)" } ?? "Reading"
        // A described command is already a sentence the agent wrote
        // about itself. "Running a command: Run the test suite" spends
        // the row's width saying the same thing twice.
        case "Bash", "BashOutput":
            return named ?? "Running a command"
        case "Grep", "Glob":
            return named.map { "Searching for \($0)" } ?? "Searching"
        case "Task", "Agent":
            return named.map { "Running an agent: \($0)" } ?? "Running an agent"
        case "WebFetch", "WebSearch": return "Looking something up"
        case "TodoWrite": return "Planning"
        case "AskUserQuestion": return "Waiting on you"
        default: return tool
        }
    }

    /// What a tool call is pointed at, read from the tool_use block's
    /// own input.
    ///
    /// Every key here is one Claude Code actually writes. A path is cut
    /// to its last component: the row has one line, and the directory is
    /// almost always the session's own folder, which the row already
    /// names elsewhere.
    ///
    /// Bash prefers the agent's `description` over the raw `command`.
    /// That is the opposite of the approval card's verbatim rule, and
    /// deliberately: the card is asking somebody to authorise a command,
    /// where a summary would be a summary of the wrong thing, while this
    /// is a glance at work already permitted.
    static func toolDetail(fromInput input: [String: Any], tool: String) -> String? {
        func text(_ key: String) -> String? {
            guard let raw = input[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch tool {
        case "Bash", "BashOutput":
            return text("description") ?? text("command")?
                .split(whereSeparator: \.isNewline).first.map(String.init)
        case "Task", "Agent":
            return text("description")
        case "Grep", "Glob":
            return text("pattern")
        case "WebFetch", "WebSearch":
            return nil
        default:
            guard let path = text("file_path") ?? text("path") ?? text("notebook_path")
            else { return nil }
            return path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    private struct TrackedFile {
        var mtime: Date
        var title: String
        var cwd: String
        var branch: String?
        var lastPrompt: String?
        var activity: String?
        var lastMessage: String?
    }

    /// A burst of fs events for one file (title, then prompt, then mode
    /// all rewritten together) collapses into a single rescan instead
    /// of thrashing the store once per event.
    private static let debounceInterval: TimeInterval = 0.5
    /// A single agent turn commonly runs several minutes without the
    /// metadata file being touched at all — title, prompt, and mode
    /// only get rewritten on specific events, not on a heartbeat. A
    /// window shorter than this would flicker a session that is still
    /// very much going; longer would keep calling a closed terminal
    /// "working" long after it quit. Chosen, not measured; the honest
    /// fallback either way is "last seen," never a wrong "running."
    private static let staleWindow: TimeInterval = 5 * 60
    /// Nothing else touches these files to raise a filesystem event
    /// once a session goes quiet, so staleness has to be re-checked on
    /// a clock as well as on write.
    private static let staleRecheckInterval: TimeInterval = 20
    /// Only the freshest files are worth reading at all; a machine with
    /// months of history should not pay to open all of it on every
    /// launch, and the store's own cap keeps far fewer than this
    /// visible regardless.
    private static let maxFilesToTrack = 12
    /// These files are the session's whole transcript, not a metadata
    /// sidecar — 119 MB on the machine this was first run against — and
    /// the records worth reading (title, prompt, mode, cwd, branch) are
    /// appended on every turn. So only the tail is ever read. Measured
    /// against this machine's sessions, 256 KB carries all of them with
    /// room to spare; a session whose last turn was larger than that
    /// simply falls back to naming itself after its folder.
    nonisolated private static let tailBytes = 256 * 1024

    private let store: SessionStore
    private let fileManager: FileManager
    private let root: URL
    private let watchQueue = DispatchQueue(label: "chalant.sessions.watch")

    private var dirWatches: [String: DispatchSourceFileSystemObject] = [:]
    private var fileWatches: [String: DispatchSourceFileSystemObject] = [:]
    private var tracked: [String: TrackedFile] = [:]
    private var pendingRescan: DispatchWorkItem?
    private var staleTimer: Timer?

    init(store: SessionStore, root: URL? = nil, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
        self.root = root ?? Self.defaultRoot
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func start() {
        Self.log.debug("discovery start at \(self.root.path, privacy: .public)")
        guard fileManager.fileExists(atPath: root.path) else {
            // Nobody has run Claude Code from this Mac yet. Nothing to
            // watch; a relaunch after the directory exists picks it up.
            Self.log.debug("no ~/.claude/projects yet, nothing to discover")
            return
        }
        watchDirectory(root.path)
        // Deferred rather than called straight through: this scrape
        // reads transcript tails and can walk the filesystem to resolve
        // a cwd, which is the slow half of session loading (B3). Firing
        // it a turn later lets whatever the cheap registry sweep already
        // painted reach the screen first, instead of both finishing
        // before the notch gets its first frame.
        Task { @MainActor in
            self.rescanAll()
            Self.log.debug("sessions found on launch: \(self.tracked.count, privacy: .public)")
        }
        staleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.staleRecheckInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.rescanAll() }
        }
    }

    /// Go and look now, because the registry just found somebody.
    ///
    /// Debounced rather than immediate: a sweep that vouches for three
    /// sessions at once should cost one scan, not three.
    func refresh() {
        scheduleDebouncedRescan()
    }

    func stop() {
        staleTimer?.invalidate()
        staleTimer = nil
        pendingRescan?.cancel()
        pendingRescan = nil
        dirWatches.values.forEach { $0.cancel() }
        dirWatches.removeAll()
        fileWatches.values.forEach { $0.cancel() }
        fileWatches.removeAll()
        tracked.removeAll()
    }

    // MARK: Scanning

    /// Re-lists the whole tree and re-derives every tracked session's
    /// state. Called from a debounced fs event and from the stale
    /// clock alike, so there is exactly one code path that can be
    /// wrong instead of two drifting apart.
    private func rescanAll() {
        let projectDirs = subdirectories(of: root)
        for dir in projectDirs where dirWatches[dir.path] == nil {
            watchDirectory(dir.path)
        }
        let files = projectDirs.flatMap { jsonlFiles(in: $0) }
        // Freshness alone is the wrong test for which transcripts are
        // worth reading. The registry knows exactly which sessions are
        // running, and a running session that fell outside the freshest
        // dozen kept the placeholder name the registry gave it forever:
        // it showed as "offseason-workspace-47" beside a sibling
        // wearing its real title, because nothing was reading the file
        // that holds the title (founder, 2026-08-02).
        //
        // A pid is the registry's mark: `markLive` is the only writer,
        // and it only sets one for a process it confirmed alive. Those
        // come first, then the freshest fill whatever room is left, so
        // a machine with months of history still never opens all of it.
        let live = Set(store.sessions.filter { $0.pid != nil }.map(\.id))
        let byFreshness = files.sorted { $0.mtime > $1.mtime }
        let liveFiles = byFreshness.filter { live.contains($0.id) }
        let rest = byFreshness.filter { !live.contains($0.id) }
        // While the registry holds the list, the running sessions are the
        // whole of it, and reading anything else is work nobody asked for.
        //
        // The freshest-dozen fill was how a session got found at all
        // before there was a registry, and it is what filled the rail with
        // other people's robots: eight of the twelve freshest transcripts
        // on the founder's Mac belonged to claude-mem's observer
        // (2026-08-03). The store now refuses to make rows out of them, so
        // reading them buys nothing and costs a quarter of a megabyte a
        // time, on a file that a busy bot rewrites every few seconds.
        //
        // The fill stays for the case it was written for: no registry
        // directory, so no list, so transcripts are the list again.
        let freshest = store.registryIsAuthoritative
            ? liveFiles
            : liveFiles + rest.prefix(max(0, Self.maxFilesToTrack - liveFiles.count))
        var seenIds = Set<String>()
        for file in freshest {
            seenIds.insert(file.id)
            if fileWatches[file.id] == nil {
                watchFile(file.path, id: file.id)
            }
            refreshTrackedFile(id: file.id, path: file.path, mtime: file.mtime)
        }
        // Anything that fell out of the freshest set, or vanished
        // outright, stops being watched. The store entry is left to
        // age out on its own terms rather than yanked mid-glance.
        for danglingId in tracked.keys where !seenIds.contains(danglingId) {
            fileWatches[danglingId]?.cancel()
            fileWatches[danglingId] = nil
            tracked[danglingId] = nil
        }
    }

    private func refreshTrackedFile(id: String, path: String, mtime: Date) {
        if tracked[id]?.mtime != mtime {
            guard let metadata = loadMetadata(at: path) else { return }
            let slug = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            let resolvedCwd = Self.resolvedCwd(metadata: metadata, slug: slug, fileManager: fileManager)
            let cwd = resolvedCwd ?? slug
            let branch = Self.branch(metadata: metadata, resolvedCwd: resolvedCwd)
            let title = Self.title(metadata: metadata, resolvedCwd: resolvedCwd, slug: slug)
            tracked[id] = TrackedFile(
                mtime: mtime, title: title, cwd: cwd, branch: branch,
                lastPrompt: metadata.lastPrompt,
                activity: metadata.lastTool.map {
                    Self.activityPhrase(forTool: $0, detail: metadata.lastToolDetail)
                },
                lastMessage: metadata.lastMessage
            )
        }
        guard let entry = tracked[id] else { return }
        let state: SessionStore.State =
            Date().timeIntervalSince(mtime) <= Self.staleWindow ? .working : .stale
        store.upsert(
            id: id, title: entry.title, cwd: entry.cwd, branch: entry.branch,
            lastPrompt: entry.lastPrompt, state: state,
            activity: entry.activity, updatedAt: mtime,
            lastMessage: entry.lastMessage, transcriptPath: path
        )
    }

    // MARK: Directory listing

    private func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// The sibling `<session-id>/` directory (subagents/, tool-results/)
    /// sits next to these same files but carries no `.jsonl` extension,
    /// so it is skipped here without needing to know it exists.
    private func jsonlFiles(in directory: URL) -> [(path: String, id: String, mtime: Date)] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.compactMap { url -> (String, String, Date)? in
            guard url.pathExtension == "jsonl" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard !id.isEmpty else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url.path, id, mtime)
        }
    }

    // MARK: Filesystem watching

    private func watchDirectory(_ path: String) {
        dirWatches[path] = makeWatch(path: path)
    }

    private func watchFile(_ path: String, id: String) {
        fileWatches[id] = makeWatch(path: path)
    }

    private func makeWatch(path: String) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.error("watch failed to open \(path, privacy: .public)")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleDebouncedRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleDebouncedRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescanAll() }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    // MARK: Metadata parsing

    /// Reads the last `tailBytes` of the transcript and nothing else.
    /// The seek costs the same on a 100 MB session as on a 10 KB one,
    /// which is the only reason watching a live agent's transcript is
    /// affordable at all.
    private func loadMetadata(at path: String) -> ParsedMetadata? {
        guard let tail = Self.tail(at: path) else { return nil }
        return Self.parseMetadata(
            tail.text, path: path, skippingFirstLine: tail.beganMidLine
        )
    }

    /// The last `tailBytes` of a file, and whether the cut landed inside
    /// a line.
    ///
    /// Pulled out of `loadMetadata` so the conversation reader
    /// (`turns(atTranscript:)`) reads a transcript exactly the way the
    /// metadata fold does rather than growing a second, subtly different
    /// way of doing the same thing. `beganMidLine` is the caller's cue
    /// to drop the first line: a tail almost always starts partway
    /// through one, and cutting inside a multi-byte character would
    /// otherwise throw the whole decode away.
    nonisolated static func tail(at path: String) -> (text: String, beganMidLine: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            log.error("transcript could not be opened: \(path, privacy: .public)")
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else {
            log.error("transcript tail could not be read: \(path, privacy: .public)")
            return nil
        }
        return (String(decoding: data, as: UTF8.self), offset > 0)
    }

    /// Folds every line into one value. Lines can repeat and arrive in
    /// any order — Claude Code simply appends the latest snapshot of
    /// whichever field changed — so later lines for the same field
    /// always win by virtue of running the fold in file order. Every
    /// line is independent: one truncated or malformed line never
    /// takes the rest of the file down with it.
    static func parseMetadata(
        _ text: String, path: String, skippingFirstLine skipFirst: Bool = false
    ) -> ParsedMetadata {
        var metadata = ParsedMetadata()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        if skipFirst { lines = lines.dropFirst() }
        for (index, line) in lines.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String
            else {
                log.debug("unparseable metadata line \(index, privacy: .public) in \(path, privacy: .public)")
                continue
            }
            // Carried on message records rather than announced by a
            // record type of its own, so it is read off whatever line
            // happens to have it. Anything that is not an absolute path
            // is not a cwd, whoever wrote it.
            if let cwd = object["cwd"] as? String, cwd.hasPrefix("/") {
                metadata.cwd = cwd
            }
            if let branch = object["gitBranch"] as? String, !branch.isEmpty {
                metadata.gitBranch = branch
            }
            // Tool calls ride inside an assistant message's content
            // blocks rather than arriving as a record type of their own,
            // so the last one in file order is the current activity.
            if type == "assistant",
               let message = object["message"] as? [String: Any],
               let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "tool_use":
                        if let name = block["name"] as? String, !name.isEmpty {
                            metadata.lastTool = name
                            // Written together, always. A detail left
                            // behind by the previous call would be
                            // attached to this one, which is worse than
                            // having none.
                            metadata.lastToolDetail = (block["input"] as? [String: Any])
                                .flatMap { Self.toolDetail(fromInput: $0, tool: name) }
                        }
                    case "text":
                        // File order is turn order, so the last one
                        // standing is what it said most recently.
                        if let text = (block["text"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !text.isEmpty {
                            metadata.lastMessage = text
                        }
                    default:
                        break
                    }
                }
            }
            switch type {
            case "ai-title":
                if let value = object["aiTitle"] as? String { metadata.aiTitle = value }
            case "last-prompt":
                if let value = object["lastPrompt"] as? String { metadata.lastPrompt = value }
            case "mode":
                if let value = object["mode"] as? String { metadata.mode = value }
            case "permission-mode":
                if let value = object["permissionMode"] as? String { metadata.permissionMode = value }
            default:
                break // forward-compatible: an unrecognized type is skipped, not an error
            }
        }
        return metadata
    }

    static func title(metadata: ParsedMetadata, resolvedCwd: String?, slug: String) -> String {
        if let aiTitle = metadata.aiTitle, !aiTitle.isEmpty { return aiTitle }
        if let resolvedCwd, let last = resolvedCwd.split(separator: "/").last {
            return String(last)
        }
        return slug
    }

    // MARK: cwd reconstruction

    /// The transcript states its own absolute `cwd` on every message
    /// record, so decoding the directory name is only ever the fallback
    /// for a file that never wrote one. This ordering matters: the slug
    /// decode is lossy by construction, and a session whose folder has
    /// since been renamed resolves to nil there while the recorded path
    /// still names it exactly.
    static func resolvedCwd(
        metadata: ParsedMetadata, slug: String, fileManager: FileManager = .default
    ) -> String? {
        metadata.cwd ?? resolveCwd(fromSlug: slug, fileManager: fileManager)
    }

    /// Reconstructs a session's working directory from Claude Code's
    /// slug naming (`cwd` with every "/" replaced by "-"). The
    /// replacement is lossy: a real directory name that itself
    /// contains a hyphen is indistinguishable from a path separator by
    /// looking at the slug alone. This walks the slug shortest-segment
    /// first — a hyphen usually was a separator — and only reaches for
    /// a longer, hyphenated segment when the short reading dead-ends
    /// against the real filesystem. If nothing on disk matches at all
    /// (the directory was renamed or removed since the session ran),
    /// this returns nil rather than guess, and the caller falls back to
    /// showing the raw slug.
    static func resolveCwd(fromSlug slug: String, fileManager: FileManager = .default) -> String? {
        guard slug.hasPrefix("-") else { return nil }
        let tokens = Array(slug.dropFirst().components(separatedBy: "-"))
        guard !tokens.isEmpty else { return nil }
        // A budget, not a real limit: it exists so a pathological slug
        // (hyphen soup with many false-positive footholds on disk)
        // degrades to nil instead of backtracking exponentially.
        var attemptsRemaining = 5000
        return resolve(
            tokens: tokens[...], accumulated: "", fileManager: fileManager,
            attempts: &attemptsRemaining
        )
    }

    private static func resolve(
        tokens: ArraySlice<String>, accumulated: String,
        fileManager: FileManager, attempts: inout Int
    ) -> String? {
        guard !tokens.isEmpty else { return accumulated }
        guard tokens.count <= 64 else { return nil } // no real cwd is this deep
        for count in 1...tokens.count {
            guard attempts > 0 else { return nil }
            attempts -= 1
            let component = tokens.prefix(count).joined(separator: "-")
            let candidate = accumulated + "/" + component
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            if let resolved = resolve(
                tokens: tokens.dropFirst(count), accumulated: candidate,
                fileManager: fileManager, attempts: &attempts
            ) {
                return resolved
            }
        }
        return nil
    }

    /// The branch to show for a session, or nil for "do not show one".
    ///
    /// HEAD on disk is the live answer; the transcript's record is the
    /// fallback for a checkout this cannot read — notably a worktree,
    /// whose `.git` is a file rather than the directory the read below
    /// expects. In exactly those cases Claude Code writes the literal
    /// string "HEAD", which names no branch and rendered as a column of
    /// meaningless "HEAD" labels down the sessions list. It is dropped
    /// here, at the one place a branch is decided, rather than filtered
    /// by each surface that displays one.
    static func branch(metadata: ParsedMetadata, resolvedCwd: String?) -> String? {
        let candidate = resolvedCwd.flatMap { gitBranch(atCwd: $0) } ?? metadata.gitBranch
        guard let candidate, !candidate.isEmpty, candidate != "HEAD" else { return nil }
        return candidate
    }

    /// Best-effort only: a direct read of `.git/HEAD`, never a spawned
    /// `git` process. A session's cwd is not guaranteed to be a repo at
    /// all, and a missing file or a detached HEAD both simply read as
    /// nil rather than something worth logging.
    private static func gitBranch(atCwd cwd: String) -> String? {
        guard let contents = try? String(contentsOfFile: cwd + "/.git/HEAD", encoding: .utf8)
        else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count))
    }
}
