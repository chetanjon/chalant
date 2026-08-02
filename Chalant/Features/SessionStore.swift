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
        /// The registry says the session is alive and sitting at its
        /// prompt. Only the registry can say this — a quiet transcript
        /// file alone is `.stale`, never this — because a file that
        /// stopped changing is not proof the process it belongs to did
        /// (notch-messaging-plan-2026-08-01, EC-3).
        case idle
        case done
        case failed
        // File presence is not liveness. A session whose metadata file
        // has gone quiet past the stale window, with no hook event to
        // say otherwise, renders as "last seen" — never as running.
        case stale
    }

    /// Interactive (a terminal) or background (no terminal at all): the
    /// two kinds `claude agents --json` reports
    /// (notch-messaging-evidence-2026-08-01.md).
    enum Kind: String, Codable, Equatable {
        case interactive
        case background
    }

    /// A message the user left for a session, waiting for that session
    /// to come and collect it.
    ///
    /// The mirror image of `Ask`, and deliberately the same shape: the
    /// island cannot reach into a running agent, so the agent comes and
    /// collects, exactly as it already does for an answer.
    /// One message waiting for a session, kept whole.
    ///
    /// Separate items rather than one joined string, because that is
    /// how Claude Code's own terminal queue behaves: type twice while
    /// it is busy and you get two queued messages, each editable and
    /// cancellable on its own, each arriving as its own turn. Joining
    /// them lost the boundary and delivered a wall (founder,
    /// 2026-08-02, "same as sending it in the terminal").
    struct QueuedMessage: Identifiable, Equatable {
        let id: String
        var text: String
        var queuedAt: Date
    }

    struct Outbox: Equatable {
        /// In order. The head is what the next turn boundary collects;
        /// the rest wait their turn, exactly as a terminal queue does.
        var pending: [QueuedMessage] = []
        var deliveredAt: Date?
        /// The session went away before it read these.
        var undelivered: Bool = false

        var isEmpty: Bool { pending.isEmpty }
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
        var state: State          // working | needsInput | idle | done | failed | stale
        var ask: Ask?             // present iff a question is outstanding
        /// The live process, when the registry knows of one. Nil means
        /// "discovered from a transcript only", which is not proof of
        /// life.
        var pid: pid_t?
        /// A background agent has no terminal to go to, unlike an
        /// interactive one; nil means the registry has never reported
        /// this id.
        var kind: Kind?
        /// A message queued here, waiting to be collected. Nil means
        /// nothing is waiting.
        var outbox: Outbox?
        var startedAt: Date
        var updatedAt: Date

        /// Whether a message left here has somewhere to land. Cursor
        /// keeps no hook contract with this app, and a session the
        /// registry has stopped reporting has no process left to
        /// collect anything.
        var canReceiveMessages: Bool { agent == .claude && state != .stale }
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
        // An outstanding question outranks whatever discovery inferred.
        //
        // Discovery reads working-or-stale off a file's mtime every
        // twenty seconds and has no way to know a question is waiting,
        // so it must not be able to overwrite one. Without this the row
        // lost its glyph, its tint, its place at the top of the list
        // and the island's waiting mark one rescan after the question
        // arrived — while the question itself stayed answerable, so
        // nothing looked broken.
        let questionOutstanding = session.ask.map { $0.answer == nil } ?? false
        session.state = questionOutstanding ? .needsInput : state
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

    // MARK: Questions

    /// Longest a question, header or option may be. These arrive over
    /// the local API from another process, so they are bounded here
    /// rather than trusted to be sensible — an unbounded string would
    /// push the island off the screen.
    static let askFieldLimit = 200
    static let maxOptions = 6

    /// Attaches a question to a session and lifts it to needs-input.
    ///
    /// Trimmed and bounded on the way in: everything here came off a
    /// socket. An empty question is refused outright, since a row that
    /// says a session wants something without saying what is worse than
    /// no row at all.
    @discardableResult
    func attach(
        askID: String, to sessionID: String, header: String, question: String,
        options: [String], multiSelect: Bool
    ) -> Bool {
        let question = String(question.prefix(Self.askFieldLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let index = sessions.firstIndex(where: { $0.id == sessionID })
        else { return false }
        sessions[index].ask = Ask(
            id: askID,
            header: String(header.prefix(Self.askFieldLimit)),
            question: question,
            options: options.prefix(Self.maxOptions)
                .map { String($0.prefix(Self.askFieldLimit)) }
                .filter { !$0.isEmpty },
            multiSelect: multiSelect,
            answer: nil,
            askedAt: Date()
        )
        let wasAlreadyAsking = sessions[index].state == .needsInput
        sessions[index].state = .needsInput
        sessions[index].updatedAt = Date()
        sort()
        // Only on the way in. A re-attached question on a row already
        // asking is the same question, and announcing it twice trains
        // people to ignore the announcement.
        if !wasAlreadyAsking { onSessionWantsYou?(sessions[index].title) }
        // A question outlives the discovery rescan that would otherwise
        // put the row back to `working`, so the expiry timer is dropped.
        expiryWork[sessionID]?.cancel()
        expiryWork[sessionID] = nil
        return true
    }

    /// Records what the user chose. The agent polls for this.
    @discardableResult
    func answer(sessionID: String, with choices: [String]) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].ask != nil
        else { return false }
        sessions[index].ask?.answer = choices
        // Back to working: the question is answered, and leaving the row
        // at needs-input would keep claiming the top of the list.
        sessions[index].state = .working
        sessions[index].updatedAt = Date()
        sort()
        return true
    }

    func pendingAsk(sessionID: String) -> Ask? {
        sessions.first { $0.id == sessionID }?.ask
    }

    /// Drops the question once the agent has collected its answer, so
    /// the island stops offering a choice that has already been made.
    func clearAsk(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].ask = nil
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
            case .idle: return 2
            case .stale: return 3
            case .failed: return 4
            case .done: return 5
            }
        }
        sessions.sort {
            rank($0.state) != rank($1.state)
                ? rank($0.state) < rank($1.state)
                : $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: Liveness (the registry)

    /// The registry's one entry point. Unlike `upsert`, this never
    /// touches `title`, `cwd`, `activity`, `lastPrompt` or `branch` —
    /// those belong to the transcript scraper, and a second writer
    /// touching them would blank them on every registry tick. The one
    /// exception is a session id the scraper has never found (EC-3,
    /// commonly a session that fell out of `SessionDiscovery`'s
    /// freshest-12 window): there is no scraper row to protect, so this
    /// makes a minimal one from what the registry itself knows.
    ///
    /// An outstanding ask outranks the registry exactly as it outranks
    /// the scraper at `upsert`'s `questionOutstanding` check above —
    /// the same rule, written once more because a second writer now
    /// reaches `state` (4d6ccff fixed this once already, for the
    /// scraper; this is the same bug wearing the registry's clothes).
    func markLive(id: String, name: String, cwd: String, pid: pid_t, kind: Kind, status: State) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].pid = pid
            sessions[index].kind = kind
            let questionOutstanding = sessions[index].ask.map { $0.answer == nil } ?? false
            if !questionOutstanding {
                sessions[index].state = status
            }
            sessions[index].updatedAt = Date()
        } else {
            sessions.append(Session(
                id: id, title: name, cwd: cwd, branch: nil, lastPrompt: nil,
                activity: nil, agent: .claude, state: status, ask: nil,
                pid: pid, kind: kind, startedAt: Date(), updatedAt: Date()
            ))
        }
        sort()
    }

    /// Ids the registry reported alive last time and does not report
    /// now: the process is gone. `.stale`, never `.done` — a killed
    /// session did not finish, and claiming an outcome this store
    /// cannot know is the kind of lie it does not tell anywhere else.
    /// A message still waiting in the outbox flips to undelivered
    /// rather than vanishing (EC-11).
    func markGone(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { continue }
            sessions[index].pid = nil
            sessions[index].state = .stale
            sessions[index].updatedAt = Date()
            failMessage(sessionID: id)
            expiryWork[id]?.cancel()
            expiryWork[id] = nil
        }
        sort()
    }

    // MARK: Outbox — the mirror image of Ask

    /// Longest message that may be queued. This becomes model context
    /// in another process, so it is bounded here rather than trusted.
    /// Fired when a session goes away with messages still queued, so
    /// the island can say so rather than letting them vanish quietly.
    var onMessageUndelivered: ((String) -> Void)?

    /// Fired when a session stops and wants an answer.
    ///
    /// A row quietly changing shape is not a notification. The whole
    /// promise of this app is that you find out an agent is waiting
    /// without watching for it, and until this existed the arrival was
    /// silent: the mark changed colour and nothing else happened
    /// (founder, 2026-08-02, "I didn't get a notification that it
    /// stopped working").
    var onSessionWantsYou: ((String) -> Void)?

    static let maxMessage = 2000
    /// A queue this deep is somebody holding the key down, not somebody
    /// with eight things to say.
    static let maxQueued = 8

    /// Queues a message for a session to collect at its next turn
    /// boundary. Validation mirrors `attach()`'s above: trimmed,
    /// refused empty, refused for a session this store cannot reach,
    /// control characters other than newline and tab stripped. A
    /// second queue before the first is collected appends rather than
    /// replacing it, joined by a blank line — the composer shows the
    /// whole pending text, so nothing is hidden (EC-10). Overflow past
    /// `maxMessage` is refused outright rather than truncated: handing
    /// a model half an instruction is worse than handing it none
    /// (EC-16).
    @discardableResult
    func queue(message: String, for sessionID: String) -> Bool {
        let cleaned = Self.sanitizeMessage(message)
        guard !cleaned.isEmpty, cleaned.count <= Self.maxMessage,
              let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].canReceiveMessages
        else { return false }
        var outbox = sessions[index].outbox ?? Outbox()
        // A queue that had already been emptied by a collection is a
        // fresh queue, not a delivered one: clearing these is what
        // stops the next message inheriting the last one's verdict.
        if outbox.pending.isEmpty {
            outbox.deliveredAt = nil
            outbox.undelivered = false
        }
        guard outbox.pending.count < Self.maxQueued else { return false }
        outbox.pending.append(
            QueuedMessage(id: UUID().uuidString, text: cleaned, queuedAt: Date())
        )
        sessions[index].outbox = outbox
        return true
    }

    /// Drop one queued message without sending it.
    func cancelMessage(id: String, for sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].outbox?.pending.removeAll { $0.id == id }
        if sessions[index].outbox?.pending.isEmpty == true {
            sessions[index].outbox = nil
        }
    }

    private static func sanitizeMessage(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
        }
        return String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hands the pending message to whoever came to collect it, once.
    /// The text is cleared before the caller can write a response — the
    /// same ordering `ActivityServer` gives `clearAsk` — so a Stop hook
    /// that fires twice, or a retried curl, cannot deliver the same
    /// instruction twice (EC-7).
    /// Hand over the next message, and only that one.
    ///
    /// One per turn boundary rather than the whole queue at once: each
    /// queued message is its own instruction, and three of them glued
    /// together is one confusing instruction. The rest stay queued and
    /// arrive at the turns after this, which is what a terminal queue
    /// does.
    func collectMessage(sessionID: String) -> String? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              var outbox = sessions[index].outbox,
              !outbox.undelivered,
              !outbox.pending.isEmpty
        else { return nil }
        let next = outbox.pending.removeFirst()
        outbox.deliveredAt = Date()
        sessions[index].outbox = outbox
        return next.text
    }

    func failMessage(sessionID: String) {
        // Anything still queued is undelivered, whatever came before
        // it: with a queue rather than one message, a session can have
        // collected two and died holding the third, and that third is
        // exactly as lost as a message that never went at all.
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let outbox = sessions[index].outbox, !outbox.pending.isEmpty
        else { return }
        sessions[index].outbox?.undelivered = true
        onMessageUndelivered?(sessions[index].title)
    }

    /// Drops whatever is in a session's outbox — queued, delivered or
    /// undelivered — so a composer can dismiss a card once its message
    /// has been seen.
    func clearMessage(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].outbox = nil
    }
}
