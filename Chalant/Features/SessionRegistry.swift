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
        /// Nil for a word this app has never seen, which is a shrug
        /// rather than a failure: see `parse`.
        var kind: SessionStore.Kind?
        /// How this session was started ("cli", "sdk-cli", …). The one
        /// field that separates a person's agent from another tool's
        /// worker; `isHeadlessBot` is the only place it is judged.
        var entrypoint: String?
        /// When the session itself began, as the registry records it.
        ///
        /// Nil for a file that does not carry one, in which case the store
        /// keeps its own "first seen here" stand-in. That stand-in is what
        /// the rail was using to tell two identically-named sessions
        /// apart, and at launch it is the same instant for all of them.
        var startedAt: Date?
        /// Raw as Claude Code writes it ("busy", "idle", "blocked", …).
        /// `state(for:alive:)` is the one place this becomes a
        /// `SessionStore.State`.
        var status: String
        /// What claude.ai/code knows this session by, when it is bridged.
        ///
        /// The whole "pick it up on your phone" story in one field: a
        /// bridged session is drivable from the Claude app, and this app
        /// only has to hand over the door. Nil means this session is not
        /// bridged, which is a fact about that session rather than about
        /// the machine, so the offer appears exactly where it is true.
        var bridgeID: String?
    }

    /// Sessions that belong to another program rather than to a person.
    ///
    /// claude-mem's observer registers itself in this directory exactly
    /// the way a person's shell does, and the two fields that look like
    /// they should tell them apart cannot. `kind` says `interactive` for
    /// both (verified 2026-08-02). A missing controlling terminal does
    /// not separate them either, because the founder's own `claude bg`
    /// jobs have no terminal and are very much theirs.
    ///
    /// `entrypoint` does separate them: Claude Code writes `sdk-cli` for
    /// a session the SDK launched, and `cli` for one somebody started
    /// (~/.claude/sessions/27558.json, the claude-mem observer, sitting
    /// beside two `cli` sessions of the founder's own, 2026-08-03).
    ///
    /// A deny-list of the known-headless on purpose, never an allow-list
    /// of the known-human: an entrypoint this app has not heard of is far
    /// more likely to be a new way for people to start Claude Code than a
    /// new robot, and the cost of guessing wrong is a session that
    /// silently never appears.
    nonisolated static func isHeadlessBot(entrypoint: String?) -> Bool {
        entrypoint == "sdk-cli"
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
    /// Injected beside `isAlive` and for the same reason: both ask the
    /// kernel about a real process, and neither should need one to be
    /// tested.
    private let hasTerminal: (pid_t) -> Bool

    private var dirWatch: DispatchSourceFileSystemObject?
    private var sweep: DispatchSourceTimer?
    private var pendingRescan: DispatchWorkItem?
    /// Ids this directory reported alive last time it was read
    /// successfully, so a failed read is never mistaken for "everyone
    /// left" (EC-4).
    private var lastAliveIds: Set<String> = []
    /// Ids whose owning application has already been looked up. Answering
    /// that means walking the whole process table, and a session does not
    /// move between windows, so it is asked once and never again.
    private var ownerResolved: Set<String> = []

    /// Where background agents live. They register no file under
    /// `root` at all, so without this half the whole class is invisible.
    private let jobsRoot: URL
    /// The daemon's roll, which is where a background agent's pid is.
    private let rosterURL: URL
    /// Where live task lists are, so a row can say which step it is on.
    private let tasksRoot: URL

    init(
        store: SessionStore, root: URL? = nil, fileManager: FileManager = .default,
        jobsRoot: URL? = nil, rosterURL: URL? = nil, tasksRoot: URL? = nil,
        isAlive: @escaping (pid_t) -> Bool = SessionRegistry.processIsAlive,
        hasTerminal: @escaping (pid_t) -> Bool = SessionRegistry.processHasTerminal
    ) {
        self.store = store
        self.fileManager = fileManager
        self.root = root ?? Self.defaultRoot
        // A registry pointed at a directory of its own does not go and
        // read the real machine's background agents. Caught the moment
        // this half was written: every existing registry test passes a
        // scratch `root`, and without this they all started picking up
        // the founder's own three-day-old blocked job from
        // `~/.claude/jobs` and failing on a row they never wrote.
        //
        // The nil defaults are for the app, which passes no roots at
        // all. Anything that names one is either a test or a second
        // machine's worth of files, and in both cases reaching into
        // `~/.claude` behind its back is wrong.
        let elsewhere = root?.appendingPathComponent("no-such-directory")
        self.jobsRoot = jobsRoot ?? elsewhere ?? JobsReader.defaultJobsDirectory()
        self.rosterURL = rosterURL ?? elsewhere ?? JobsReader.defaultRosterURL()
        self.tasksRoot = tasksRoot ?? elsewhere ?? JobsReader.defaultTasksDirectory()
        self.isAlive = isAlive
        self.hasTerminal = hasTerminal
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Fired when the set of live sessions actually changes, so the
    /// transcript scraper can go and describe whoever just arrived
    /// instead of waiting out its own twenty-second clock.
    ///
    /// Needed because the two halves now depend on each other: discovery
    /// only reads the transcripts of sessions this directory vouches for,
    /// so it has to be told when that list grows. Its own directory watch
    /// catches a brand new session (a new transcript file appears), but
    /// not a resumed one, whose file was already there.
    var onLiveSetChanged: (() -> Void)?

    func start() {
        guard fileManager.fileExists(atPath: root.path) else {
            // An older Claude Code, or a fresh Mac: the strip is
            // exactly as good as it was before this file ever ran.
            Self.log.debug("no ~/.claude/sessions yet, no liveness overlay")
            return
        }
        // The directory is there, so it gets to hold the list: a session
        // is a process this can see, not a file somebody left behind. Set
        // before the first `rescan` so nothing is ever written into the
        // store under the older rule.
        store.noteRegistryIsAuthoritative()
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
        // Background agents first, and outside the guard below: they
        // keep no file under `root`, so a machine with no
        // `~/.claude/sessions` at all still has agents to show.
        let backgroundIds = scanBackgroundAgents()
        guard let files = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        var aliveIds: Set<String> = backgroundIds
        var entries: [Entry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = Self.parse(data, filename: file.lastPathComponent)
            else { continue }
            guard isAlive(entry.pid) else { continue } // a crash left the file behind (EC-5)
            // Another program's worker, not a person's agent. Skipped
            // before it can be counted alive, so nothing downstream ever
            // learns it existed: it earns no row, no place in the record,
            // and no say in `reconcileLive`. See `isHeadlessBot`.
            guard !Self.isHeadlessBot(entrypoint: entry.entrypoint) else { continue }
            aliveIds.insert(entry.sessionId)
            entries.append(entry)
            // Always, even for a status this app has no opinion on
            // (background's "blocked", or anything from a later Claude
            // Code). `markLive` is now the only thing that can put a
            // session on the list at all, so skipping it here would not
            // cost a badge, it would lose the session: the row would
            // simply never exist. A nil status means "here, alive, no
            // opinion on what it is doing", which `markLive` reads as
            // leaving whatever the transcript already said alone.
            store.markLive(
                id: entry.sessionId, name: entry.name, cwd: entry.cwd,
                pid: entry.pid, kind: entry.kind,
                hasTerminal: hasTerminal(entry.pid),
                status: Self.state(for: entry, alive: isAlive),
                startedAt: entry.startedAt,
                bridgeID: entry.bridgeID
            )
        }
        let gone = lastAliveIds.subtracting(aliveIds)
        if !gone.isEmpty { store.markGone(gone) }
        // And the ones it never reported at all. `lastAliveIds` can only
        // catch a session this directory once knew about; discovery can
        // invent one out of a transcript that was never here.
        store.reconcileLive(against: aliveIds)
        // What each live session is working through, if it has reached
        // for the task tool. Live ones only: the folder outlives the
        // session by months, and a finished row's old to-do list is not
        // news.
        for id in aliveIds {
            store.attach(plan: JobsReader.plan(forSession: id, in: tasksRoot), to: id)
        }
        // After the store has its rows, because `noteOwningApp` decorates
        // a row rather than making one, and once per session rather than
        // once per sweep: see `ownerResolved`.
        resolveOwners(of: entries)
        ownerResolved.formIntersection(aliveIds)
        let changed = aliveIds != lastAliveIds
        lastAliveIds = aliveIds
        if changed { onLiveSetChanged?() }
    }

    /// Puts every background agent with a running worker on the list,
    /// and hands its published state to the row.
    ///
    /// A background agent is a session by every measure this app uses
    /// (a process, a folder, a transcript, a person waiting on it) and
    /// it was invisible here for one accidental reason: it writes its
    /// file somewhere else. The founder ran one that sat blocked for
    /// three days behind a sentence the island could not show.
    ///
    /// The roster decides liveness, never the state file. `state.json`
    /// is still readable long after the daemon that wrote it has gone,
    /// and a stale `blocked` rendered as a live question is exactly the
    /// pretending this release is removing.
    private func scanBackgroundAgents() -> Set<String> {
        let live = JobsReader.liveSessionIDs(rosterAt: rosterURL, isAlive: isAlive)
        guard !live.isEmpty else { return [] }
        var marked: Set<String> = []
        for (sessionID, job) in JobsReader.jobs(in: jobsRoot) where live.contains(sessionID) {
            store.markLive(
                id: sessionID,
                name: job.name ?? "Background agent",
                cwd: job.cwd ?? "",
                pid: 0,
                kind: .background,
                // Never. A background agent holds no controlling
                // terminal by definition, which is what closes the
                // composer on a row nothing typed could reach.
                hasTerminal: false,
                // Its own vocabulary, translated once, here. `blocked`
                // is a question waiting on a person, which is the one
                // state this app has to get right.
                status: job.state.map(Self.state(forJobPhase:)) ?? .idle,
                startedAt: job.startedAt
            )
            store.attach(job: job, to: sessionID)
            marked.insert(sessionID)
        }
        return marked
    }

    /// A background agent's own word for what it is doing, in this
    /// app's vocabulary. Kept as a translation rather than a shared
    /// enum: the two answer different questions, and collapsing them is
    /// how this app talked itself into guessing before.
    static func state(forJobPhase phase: SessionStore.JobState.Phase) -> SessionStore.State {
        switch phase {
        case .working: return .working
        case .blocked: return .needsInput
        case .done: return .done
        case .failed: return .failed
        }
    }

    /// Names the app each newly-seen session is running inside.
    ///
    /// One process-table walk for however many arrived together, and none
    /// at all on the ordinary sweep where nothing changed.
    private func resolveOwners(of entries: [Entry]) {
        let fresh = entries.filter { !ownerResolved.contains($0.sessionId) }
        guard !fresh.isEmpty else { return }
        let owners = SessionLocator.owningApps(of: fresh.map(\.pid))
        for entry in fresh {
            ownerResolved.insert(entry.sessionId)
            guard let owner = owners[entry.pid] else { continue }
            store.noteOwningApp(id: entry.sessionId, bundleID: owner.bundleID, name: owner.name)
        }
    }

    // MARK: Parsing

    /// Refuses an entry whose filename pid and body pid disagree
    /// (EC-5) and a `cwd` that is not absolute, exactly as
    /// `SessionDiscovery.parseMetadata` does for its own cwd field.
    ///
    /// Refuses nothing else. The three guards below are the fields that
    /// actually identify a live session: which session, which process,
    /// and where. Everything after them is description, and description
    /// this app cannot read is a thing to shrug at, never a reason to
    /// throw away a pid.
    ///
    /// That distinction is not academic. `kind` used to be a guard, on
    /// the strength of the two words `claude agents --json` prints, and
    /// the file itself says a third: `"bg"`. Every background session on
    /// the machine was therefore parsed as nil, never entered
    /// `aliveIds`, was disowned by `reconcileLive` as a session the
    /// registry had never heard of, and was filed in the record as
    /// having gone away — while running. One unrecognised word cost the
    /// whole session, which is the exact failure this file's own opening
    /// doc promises cannot happen here.
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
        let kind = (object["kind"] as? String).flatMap(SessionStore.Kind.init(registryValue:))
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? cwd.split(separator: "/").last.map(String.init) ?? cwd
        let status = object["status"] as? String ?? ""
        // Epoch milliseconds. Anything at or below zero is not a moment,
        // it is a field that failed to be written.
        let startedAt = (object["startedAt"] as? Double)
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return Entry(
            sessionId: sessionId, pid: pid_t(bodyPid), cwd: cwd, name: name, kind: kind,
            entrypoint: object["entrypoint"] as? String, startedAt: startedAt, status: status,
            bridgeID: (object["bridgeSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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

    /// Whether this process holds a controlling terminal, which is the
    /// honest form of "is there a window somewhere that could show you
    /// a reply". `claude agents --json` cannot answer it: it reports
    /// its own headless worker as `interactive` alongside a real shell
    /// (2026-08-02, a running claude-mem indexer beside this session).
    /// The kernel can, and does, in one `sysctl` with no subprocess.
    ///
    /// Every failure answers `true`. A pid that has already gone, a pid
    /// that never was, a `sysctl` that refused: none of those are
    /// evidence of a missing terminal, and only evidence is allowed to
    /// take a composer away.
    nonisolated static func processHasTerminal(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0
        else { return true }
        // NODEV, spelled out: the macro does not survive the import,
        // and `e_tdev` is a dev_t, which is a signed 32-bit value here.
        return info.kp_eproc.e_tdev != -1
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
