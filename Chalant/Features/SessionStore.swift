import Foundation
import os

/// Discovered Claude Code sessions, one row per session_id. Mirrors
/// ActivityStore's shape on purpose (architecture-session-bridge.md):
/// attention first, bounded count, terminal states expire themselves.
/// A live agent asking a question and a live deploy failing are the
/// same kind of "look here now," so the sort and eviction rules that
/// were already proven for pills are reused rather than reinvented.
/// Sessions get their own store instead of overloading Activity because
/// they carry structured questions, options, a cwd and a branch —
/// forcing one shape into the other would bend both.
@MainActor
final class SessionStore: ObservableObject {
    /// Which tool the session belongs to. Rows from different agents
    /// sit in one list, so each has to say whose it is.
    enum Agent: String, Codable {
        case claude
        case cursor

        var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .cursor: return "Cursor"
            }
        }
    }

    enum State: String, Codable {
        case working
        case needsInput = "needs-input"
        case done
        case failed
        // File presence is not liveness. A session whose metadata file
        // has gone quiet past the stale window, with no hook event to
        // say otherwise, renders as "last seen" — never as running.
        case stale
    }

    struct Session: Identifiable, Equatable {
        let id: String            // Claude Code session_id
        var title: String         // aiTitle, else the cwd's last component
        var cwd: String
        var branch: String?
        var lastPrompt: String?
        /// What the agent is doing right now, in the user's words.
        /// Nil while nothing has been reached for yet.
        var activity: String?
        var agent: Agent = .claude
        var state: State          // working | needsInput | done | failed | stale
        var ask: Ask?             // present iff a question is outstanding
        var startedAt: Date
        var updatedAt: Date
    }

    struct Ask: Identifiable, Equatable {
        let id: String
        var header: String
        var question: String
        var options: [String]
        var multiSelect: Bool
        var answer: [String]?     // set when the user taps; hook polls for this
        var askedAt: Date
    }

    private static let log = Logger(subsystem: "com.cj.chalant", category: "sessions")

    /// Attention first: needs-input, then working, then last-seen, then
    /// the terminal states, each newest first. Views render straight
    /// through, same contract as ActivityStore.activities.
    @Published private(set) var sessions: [Session] = []

    private let maxSessions: Int
    /// Terminal rows linger just long enough to be seen before they
    /// clear themselves — same idea, same window ActivityStore uses
    /// for a finished pill.
    private let finishedTTL: TimeInterval
    private var expiryWork: [String: DispatchWorkItem] = [:]

    /// TTL and cap are constructor args rather than baked-in constants
    /// so a test can shrink the TTL to something it can actually wait
    /// out, instead of proving a 60-second timer fires 60 seconds at a
    /// time.
    init(maxSessions: Int = 20, finishedTTL: TimeInterval = 60) {
        self.maxSessions = maxSessions
        self.finishedTTL = finishedTTL
    }

    /// Upsert keyed by Claude Code's own session id. `startedAt` is
    /// preserved from the first time this store saw the id: the
    /// metadata file carries no session-start timestamp of its own, so
    /// "first seen here" is the honest substitute. `ask` is left alone
    /// on purpose — discovery has no opinion on it, and clobbering it
    /// on every metadata-file rescan would drop a question a hook (a
    /// later phase) pushed moments before.
    func upsert(
        id: String, title: String, cwd: String, branch: String?,
        lastPrompt: String?, state: State, activity: String? = nil,
        agent: Agent = .claude, updatedAt: Date = Date()
    ) {
        var session = sessions.first { $0.id == id }
            ?? Session(
                id: id, title: title, cwd: cwd, branch: branch,
                lastPrompt: lastPrompt, activity: activity, agent: agent,
                state: state, ask: nil, startedAt: Date(), updatedAt: updatedAt
            )
        let previousState = session.state
        session.title = title
        session.cwd = cwd
        session.branch = branch
        session.lastPrompt = lastPrompt
        session.activity = activity
        session.agent = agent
        session.state = state
        session.updatedAt = updatedAt
        sessions.removeAll { $0.id == id }
        sessions.append(session)
        sort()
        if previousState != state {
            Self.log.debug(
                "\(id, privacy: .public): \(previousState.rawValue, privacy: .public) -> \(state.rawValue, privacy: .public)"
            )
        }
        if sessions.count > maxSessions {
            // The oldest terminal row goes first; a session still being
            // watched, needing input, or merely gone quiet never gets
            // dropped to make room.
            if let victim = sessions.last(where: { $0.state == .done || $0.state == .failed })
                ?? sessions.last {
                clear(id: victim.id)
            }
        }
        expiryWork[id]?.cancel()
        if state == .done || state == .failed {
            let work = DispatchWorkItem { [weak self] in self?.clear(id: id) }
            expiryWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + finishedTTL, execute: work)
        }
    }

    func clear(id: String) {
        expiryWork[id]?.cancel()
        expiryWork[id] = nil
        sessions.removeAll { $0.id == id }
    }

    func clearAll() {
        sessions.map(\.id).forEach { clear(id: $0) }
    }

    private func sort() {
        func rank(_ state: State) -> Int {
            switch state {
            case .needsInput: return 0
            case .working: return 1
            case .stale: return 2
            case .failed: return 3
            case .done: return 4
            }
        }
        sessions.sort {
            rank($0.state) != rank($1.state)
                ? rank($0.state) < rank($1.state)
                : $0.updatedAt > $1.updatedAt
        }
    }
}
