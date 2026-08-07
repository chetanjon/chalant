import Foundation
import os

/// What Claude Code publishes about an agent, beside the transcript.
///
/// Two directories nothing in this app had ever opened:
///
/// - `~/.claude/jobs/<short>/state.json`, written for every background
///   agent, carrying the agent's own `state`, the first-person `needs`
///   line it is blocked on, and the one-line `result` it came back with.
/// - `~/.claude/tasks/<sessionId>/*.json`, one file per step of whatever
///   the agent is working through, with the step in progress marked.
///
/// Both are pure functions of a directory URL. That is the seam that
/// keeps the real `~/.claude` out of every test, and it is the same
/// shape `SessionRegistry` already uses, so the tests that caught the
/// 1.6.0 bugs and these run the same way.
///
/// Neither is a contract Anthropic owes anybody. The standing law for
/// this overlay applies: a Claude Code release that moves these files
/// costs a badge, never the rail. Everything here fails to nil.
enum JobsReader {

    private static let log = Logger(subsystem: "com.cj.chalant", category: "jobs")

    /// Where Claude Code keeps background agents, unless told otherwise.
    static func defaultJobsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jobs")
    }

    /// Where Claude Code keeps live task lists.
    static func defaultTasksDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/tasks")
    }

    /// The daemon's roll of background workers, which is the only place
    /// a background agent's process id is written down.
    static func defaultRosterURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/daemon/roster.json")
    }

    /// The sessions with a background worker actually running behind
    /// them.
    ///
    /// This is the whole reason the roster is read at all. A
    /// `state.json` outlives its agent by days: the founder's own
    /// blocked job kept saying it needed a decision for three days after
    /// the daemon that ran it had gone. Showing that as a live question
    /// would be the same lie this release exists to end, so the rule the
    /// registry already holds is applied here too: a pid makes a session
    /// real, a warm file does not.
    static func liveSessionIDs(
        rosterAt url: URL, isAlive: (pid_t) -> Bool
    ) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workers = object["workers"] as? [String: Any]
        else { return [] }
        var live: Set<String> = []
        for (_, raw) in workers {
            guard let worker = raw as? [String: Any],
                  let sessionID = worker["sessionId"] as? String,
                  let pid = worker["pid"] as? Int,
                  isAlive(pid_t(pid))
            else { continue }
            live.insert(sessionID)
        }
        return live
    }

    /// Every background agent this directory knows about, keyed by the
    /// session id a row is keyed by.
    ///
    /// The directory is named with a short id and the rest of this app
    /// speaks full session ids, so an entry that cannot name its own
    /// session is dropped: attaching it to a row by guessing at a prefix
    /// is how a status ends up on the wrong agent.
    static func jobs(in directory: URL) -> [String: SessionStore.JobState] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var jobs: [String: SessionStore.JobState] = [:]
        for entry in entries {
            let file = entry.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                // One half-written file is not grounds to report every
                // other agent on the machine missing.
                log.debug("unreadable job state at \(file.path, privacy: .public)")
                continue
            }
            guard let sessionID = (object["sessionId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty
            else { continue }
            jobs[sessionID] = state(from: object)
        }
        return jobs
    }

    /// One agent's state, with every field allowed to be missing.
    ///
    /// `state` is deliberately optional. `SessionRegistry.parse` once
    /// treated an unrecognised enum value as grounds to discard the
    /// whole entry, and a single unexpected spelling (`"bg"`) disowned
    /// every background agent on the machine. An unknown value costs the
    /// field it is in and nothing else.
    private static func state(from object: [String: Any]) -> SessionStore.JobState {
        func text(_ key: String) -> String? {
            guard let raw = object[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let result = (object["output"] as? [String: Any])?["result"] as? String
        return SessionStore.JobState(
            state: text("state").flatMap(SessionStore.JobState.Phase.init(rawValue:)),
            needs: text("needs"),
            detail: text("detail"),
            result: result?.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestedReply: text("suggestedReply"),
            tokens: object["tokens"] as? Int,
            name: text("name"),
            cwd: text("cwd"),
            startedAt: text("createdAt").flatMap(Self.moment(from:))
        )
    }

    /// Claude Code writes these as ISO 8601 with fractional seconds,
    /// unlike the registry's epoch milliseconds. Both spellings are
    /// tried rather than assumed, because a start time that silently
    /// falls back to "now" is the bug that made two sessions in one repo
    /// indistinguishable in 1.6.0.
    private static func moment(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// What one session is working through, or nil if it never reached
    /// for the task tool.
    ///
    /// Measured on this machine on 2026-08-06: 4 of 22 task directories
    /// hold anything. Claude Code creates the folder either way, so an
    /// empty one has to read as "no plan" rather than "a plan of zero
    /// steps", which would put "0 of 0" on most rows in the rail.
    static func plan(forSession id: String, in directory: URL) -> SessionStore.PlanProgress? {
        let folder = directory.appendingPathComponent(id)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        guard !files.isEmpty else { return nil }

        var step: String?
        var done = 0
        var total = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let task = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            total += 1
            switch task["status"] as? String {
            case "completed":
                done += 1
            case "in_progress":
                // `activeForm` is the present-tense line written for
                // exactly this reading. It is optional in the format,
                // and a step nobody can read is worse than a subject.
                let active = (task["activeForm"] as? String) ?? (task["subject"] as? String)
                step = active?.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }
        guard total > 0 else { return nil }
        return SessionStore.PlanProgress(step: step, done: done, total: total)
    }
}
