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

    // MARK: Doing it for real

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
