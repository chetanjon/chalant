import AppKit
import Darwin
import os

/// Finds the app a session is running inside, so a row can take you
/// there.
///
/// An agent process is not itself an application — it is a command in
/// somebody's shell. What the user wants focused is whatever window
/// that shell lives in, which is found by walking up the parent chain
/// until a process turns out to be a running application:
///
///     claude → zsh → Cursor Helper: terminal pty-host → Cursor.app
///
/// That is why this works for a terminal inside VS Code or Cursor and
/// not only for Terminal.app: the chain ends at whichever app owns the
/// shell, whatever it happens to be.
@MainActor
enum SessionLocator {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "sessions")

    /// One process, reduced to what the search needs.
    struct Snapshot: Equatable {
        var pid: pid_t
        var parent: pid_t
        var name: String
        var cwd: String?
    }

    /// The application that ultimately owns `pid`.
    ///
    /// Pure so it can be tested: the awkward part is the walk, not the
    /// reading. A chain can be broken, circular (pid tables are read
    /// without a lock, so a parent can appear to be its own descendant)
    /// or simply reach launchd, and none of those may hang.
    static func owningApplication(
        of pid: pid_t, in table: [pid_t: Snapshot], applications: Set<pid_t>
    ) -> pid_t? {
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, seen.insert(current).inserted {
            if applications.contains(current) { return current }
            guard let entry = table[current] else { return nil }
            current = entry.parent
        }
        return nil
    }

    /// The agent process working in `cwd`, preferring the most recently
    /// started when several match — nested checkouts and repeated
    /// sessions in one folder both happen.
    static func agentProcess(
        forCwd cwd: String, in table: [pid_t: Snapshot], agentNames: Set<String>
    ) -> pid_t? {
        table.values
            .filter { agentNames.contains($0.name) && $0.cwd == cwd }
            .map(\.pid)
            .max()
    }

    /// Names that mean "an agent is running here". Matched on the
    /// executable's own name, so a shell that merely mentions one in
    /// its arguments is not mistaken for the thing itself.
    static let agentNames: Set<String> = ["claude", "codex", "cursor-agent"]

    /// The app each of these processes lives inside, named, in one walk
    /// of the process table.
    ///
    /// A pid is simply absent from the result when its parent chain
    /// reaches launchd without passing through a running application,
    /// which is the ordinary shape of a session started detached. That
    /// absence means "nobody could tell", never "nothing owns it":
    /// Terminal can perfectly well own the tty of a process it is not an
    /// ancestor of, which is why callers may only read a *present* answer
    /// here as evidence.
    ///
    /// Batched because the walk is the expensive half and the lookups are
    /// free, and the caller asks about everything that arrived in one
    /// sweep.
    static func owningApps(of pids: [pid_t]) -> [pid_t: (bundleID: String, name: String)] {
        guard !pids.isEmpty else { return [:] }
        var byPid: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            byPid[app.processIdentifier] = app
        }
        let table = processTable()
        let applications = Set(byPid.keys)
        var found: [pid_t: (bundleID: String, name: String)] = [:]
        for pid in pids {
            guard let owner = owningApplication(of: pid, in: table, applications: applications),
                  let app = byPid[owner], let bundleID = app.bundleIdentifier
            else { continue }
            found[pid] = (bundleID, app.localizedName ?? bundleID)
        }
        return found
    }

    // MARK: Doing it for real

    /// Brings the application running this exact process to the front.
    ///
    /// By pid, because a working directory is not an identity: three
    /// sessions in one repo share a cwd, and `reveal(cwd:)` below picks
    /// whichever of them started last. That was already known to be wrong
    /// for deciding where a message goes (SessionRemote.swift:86) and it
    /// is the same wrong for deciding which window to raise.
    @discardableResult
    static func reveal(pid: pid_t) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        guard let owner = owningApplication(
            of: pid, in: processTable(), applications: Set(apps.map(\.processIdentifier))
        ), let app = NSRunningApplication(processIdentifier: owner) else { return false }
        app.activate(options: [.activateAllWindows])
        return true
    }

    /// Brings whatever is running the session in `cwd` to the front.
    ///
    /// Returns false when nothing could be found, so the caller can do
    /// something else rather than leave a click looking ignored.
    @discardableResult
    static func reveal(cwd: String) -> Bool {
        let table = processTable()
        let apps = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        guard let agent = agentProcess(forCwd: cwd, in: table, agentNames: agentNames),
              let owner = owningApplication(of: agent, in: table, applications: apps),
              let app = NSRunningApplication(processIdentifier: owner)
        else {
            log.debug("no running agent found for \(cwd, privacy: .public)")
            return false
        }
        app.activate(options: [.activateAllWindows])
        return true
    }

    // MARK: Reading the system

    /// Every process this user can see, as snapshots.
    ///
    /// `proc_pidinfo` rather than shelling out to ps or lsof: this runs
    /// on a click, and spawning two processes to answer a question the
    /// kernel will answer directly is a poor trade.
    static func processTable() -> [pid_t: Snapshot] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        // Room to spare: processes can appear between sizing and reading.
        count += 64
        var pids = [pid_t](repeating: 0, count: Int(count))
        let bytes = proc_listallpids(&pids, count * Int32(MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [:] }
        let found = Int(bytes) / MemoryLayout<pid_t>.size

        var table: [pid_t: Snapshot] = [:]
        for pid in pids.prefix(found) where pid > 0 {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            let name = withUnsafePointer(to: info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            table[pid] = Snapshot(
                pid: pid, parent: pid_t(info.pbi_ppid), name: name,
                // Only looked up for processes that might be an agent:
                // asking for every process's working directory is a
                // syscall each, on a click, for answers nobody reads.
                cwd: agentNames.contains(name) ? workingDirectory(of: pid) : nil
            )
        }
        return table
    }

    /// The controlling terminal a process is attached to, as a device
    /// path (`/dev/ttys004`), or nil for a process with no terminal.
    ///
    /// This is the one identifier that ties a session to a *window*
    /// rather than to an application. Terminal.app and iTerm both
    /// publish it on their own tabs, so a message can be put into
    /// exactly the session it was written for instead of into whatever
    /// happened to be frontmost. Without it, "type this into my agent"
    /// would be a guess, and a wrong guess types somebody's message into
    /// somebody else's shell.
    static func tty(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        // NODEV, the kernel's "this process has no controlling
        // terminal". Background agents land here, which is the same
        // answer `hasTerminal` already gives the composer.
        guard info.e_tdev != UInt32.max, info.e_tdev != 0 else { return nil }
        guard let name = devname(dev_t(info.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = proc_pidinfo(
            pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }
}
