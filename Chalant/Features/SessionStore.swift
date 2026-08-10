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
        /// Only ever reaches a row through the gate shim. Codex publishes
        /// no session state this app can discover, so a Codex row exists
        /// exactly as long as it is standing at a question and no longer.
        case codex

        var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .cursor: return "Cursor"
            case .codex: return "Codex"
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

        /// States that assert a process exists right now, as opposed to
        /// describing one that did.
        var isLive: Bool {
            switch self {
            case .working, .needsInput, .idle: return true
            case .done, .failed, .stale: return false
            }
        }
    }

    /// Interactive (a terminal) or background (no terminal at all): the
    /// two kinds `claude agents --json` reports
    /// (notch-messaging-evidence-2026-08-01.md).
    enum Kind: String, Codable, Equatable {
        case interactive
        case background

        /// What the registry file on disk actually says, which is not
        /// what `claude agents --json` prints.
        ///
        /// A background session's file says `"kind":"bg"`
        /// (~/.claude/sessions/65463.json, 2026-08-03, for a session that
        /// was running while this app reported it dead). The raw
        /// initialiser matched neither, `SessionRegistry.parse` treated
        /// that as grounds to discard the entire entry, and the pid went
        /// with it — so every background agent on the machine was
        /// disowned and filed in the record as gone.
        ///
        /// Both spellings are taken so this cannot break again from
        /// either side, and an unrecognised one answers nil for the
        /// caller to shrug at rather than for the parser to die on.
        init?(registryValue raw: String) {
            switch raw {
            case "interactive": self = .interactive
            case "bg", "background": self = .background
            default: return nil
            }
        }
    }

    /// An application a session is running inside, and what to call it on
    /// screen. The bundle id decides; the name is only ever shown.
    struct TerminalApp: Equatable {
        var bundleID: String
        var name: String
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
    /// `Codable` so the outbox can survive a relaunch (`saveOutbox`/
    /// `loadOutbox` below); nothing about the shape changes for that.
    struct QueuedMessage: Identifiable, Equatable, Codable {
        let id: String
        var text: String
        var queuedAt: Date

        /// Past the point `collectMessage` will still hand this over.
        ///
        /// Computed, not a flag set once at load: "now" has to mean now,
        /// whether this message rode out a relaunch or simply sat in a
        /// live outbox while a turn ran long. `>=` at the boundary: a
        /// message exactly `outboxExpiry` old reads as stale rather than
        /// as one more tick of trust, because handing over a borderline
        /// instruction is the wrong side to guess wrong on.
        var isExpired: Bool {
            -queuedAt.timeIntervalSinceNow >= SessionStore.outboxExpiry
        }
    }

    struct Outbox: Equatable, Codable {
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
        // working | needsInput | idle | done | failed | stale
        //
        // `didSet` rather than a timestamp maintained at the call
        // sites: six different places in this file write state
        // (`upsert`, `attach`, `clearAsk`, `markLive`, `markGone`, and
        // the ask path), and a clock kept in step by convention across
        // six sites is a clock that drifts. This way the two cannot
        // disagree, and a seventh writer added later gets it for free.
        var state: State {
            didSet {
                guard state != oldValue else { return }
                stateSince = Date()
            }
        }
        /// When this session entered the state it is in now.
        ///
        /// The row's trailing number used to be
        /// `RelativeAge.short(updatedAt)`, which discovery rewrites on
        /// every sweep, so every live row read "now" forever: it was
        /// reporting how recently this app looked rather than anything
        /// about the session. This is the timestamp that moves when
        /// something actually happens, so "running 4m" means the turn
        /// has run four minutes.
        ///
        /// Deliberately real-clock rather than carrying `upsert`'s
        /// `updatedAt` seam. What it measures is elapsed wall time in
        /// front of a person, and a test faking discovery's clock an
        /// hour into the past must not be able to make a session claim
        /// it has been working for an hour.
        private(set) var stateSince = Date()
        var ask: Ask?             // present iff a question is outstanding
        /// A tool call held at the door, waiting on you.
        var approval: Approval?
        /// The last thing the agent actually said, so a row can show
        /// what it wants rather than only that it wants something. Read
        /// from the transcript, which means it works whether or not the
        /// Stop hook is installed (founder, 2026-08-02: "is there a way
        /// to see the message that the AI sent").
        var lastMessage: String?
        /// A permission prompt Claude Code is showing in its own
        /// terminal. See `PendingPrompt`.
        var pendingPrompt: PendingPrompt?
        /// When a hook last stood in this session waiting on an answer.
        ///
        /// The one thing allowed to outvote the registry, and only
        /// briefly. A hook mid-call is a process talking to this app in
        /// real time; a registry that has never heard of that session is
        /// silence. Silence does not get to end a conversation somebody
        /// is having. See `hookVouchWindow`.
        var vouchedByHookAt: Date?
        /// What a background agent published about itself, when it is one
        /// and Claude Code wrote the file. See `JobState`.
        var job: JobState?
        /// The agent's own to-do list, when it has reached for one. See
        /// `PlanProgress`.
        var plan: PlanProgress?
        /// The live process, when the registry knows of one. Nil means
        /// "discovered from a transcript only", which is not proof of
        /// life.
        var pid: pid_t?
        /// What `claude agents --json` calls this session. Kept for the
        /// record, and deliberately not used to decide anything: it was
        /// once believed to separate a session you can reach from one
        /// you cannot, and it does not. Claude Code's own headless
        /// worker reports `interactive` exactly as a person's shell
        /// does (verified 2026-08-02 against a running claude-mem
        /// indexer). `hasTerminal` is the field that answers that.
        var kind: Kind?
        /// Whether the process holds a controlling terminal: whether
        /// there is a window, anywhere, that a reply could appear in.
        /// Nil means nobody has looked, which is the ordinary state of
        /// a row the scraper found and the registry has never seen.
        var hasTerminal: Bool?
        /// The application this session's process lives inside, when one
        /// could be named.
        ///
        /// A second question from `hasTerminal`, and the founder's own
        /// session is why both are needed. It runs in VS Code's built-in
        /// terminal: the kernel says it holds a tty, so `hasTerminal` is
        /// true and the composer opened, but typing works by asking
        /// Terminal or iTerm which of their tabs owns that tty and VS Code
        /// answers no such question. Every message became a silent note
        /// for later.
        ///
        /// Read in one direction only. A named owner that cannot be
        /// addressed is knowledge: nothing typed here would arrive. Nil is
        /// not: a session started detached has no application ancestor and
        /// Terminal may still own its tty, so nothing is taken away.
        var terminalApp: TerminalApp?
        /// A message queued here, waiting to be collected. Nil means
        /// nothing is waiting.
        var outbox: Outbox?
        /// When this session's transcript was last written, as the
        /// filesystem reports it. Written only by `upsert`, which is the
        /// only writer that has read a file.
        ///
        /// It exists so a claim can be corroborated. The registry's
        /// `status` is another program's word for what a process is
        /// doing, and that word can go stale without any sign: the
        /// founder's own session said `busy` for twenty-one hours because
        /// Claude Code stops rewriting the file once a session parks a
        /// background job. A transcript that has not moved in a quarter of
        /// an hour is the evidence that says otherwise.
        var transcriptTouchedAt: Date?
        /// Where this session's transcript lives on disk.
        ///
        /// Discovery has always known it (`jsonlFiles(in:)` returns one
        /// per session) and has always thrown it away after reading the
        /// tail. It is kept now so a session can still be read after it
        /// has left `sessions` for the finished record, which is what
        /// makes a finished row worth selecting rather than only worth
        /// counting. Nil for a row the registry made without discovery
        /// ever finding a file.
        var transcriptPath: String?
        var startedAt: Date
        var updatedAt: Date

        /// Whether a message left here has somewhere to land. Cursor
        /// keeps no hook contract with this app, and a session the
        /// registry has stopped reporting has no process left to
        /// collect anything.
        ///
        /// `hasTerminal != false`, never `== true`: a session nobody
        /// has checked keeps the composer it has always had. The only
        /// thing that takes it away is the kernel saying, positively,
        /// that this process has no terminal — because a message to
        /// such a session would be collected and answered into a void.
        ///
        /// `isAddressable` is the same shape of rule about the same kind
        /// of evidence: only a *named* owner that cannot be typed into
        /// closes the composer.
        var canReceiveMessages: Bool {
            agent == .claude && state != .stale && hasTerminal != false && isAddressable
        }

        /// What claude.ai/code knows this session by, when it is bridged.
        /// See `SessionRegistry.Entry.bridgeID`.
        var bridgeID: String?

        /// Where this session can be picked up from another device.
        ///
        /// The answer to "how do I control my agents from my phone":
        /// Claude Code bridges a session, the Claude app drives it, and
        /// this app hands over the door rather than building a second
        /// one. Turned on for every future session by
        /// `HookInstall.armRemoteControl`.
        ///
        /// Refuses anything that is not a plain identifier. This link is
        /// offered as "your session", and an id carrying a slash would
        /// build a URL pointing somewhere else entirely.
        static func phoneURL(bridgeID: String?) -> URL? {
            guard let bridgeID, !bridgeID.isEmpty,
                  bridgeID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { return nil }
            return URL(string: "https://claude.ai/code/\(bridgeID)")
        }

        /// Whether anything is positively known to stand between a typed
        /// message and this session. Nil `terminalApp` is not, see there.
        var isAddressable: Bool {
            guard let terminalApp else { return true }
            return SessionRemote.canAddress(bundleID: terminalApp.bundleID)
        }
    }

    /// A session this app watched end.
    ///
    /// The strip's own doc carries a law against exactly this: "a
    /// developer's machine carries months of history, and listing all of
    /// it would push a wall of finished work into a surface whose whole
    /// premise is calm." The law is kept. What changes is that a bounded
    /// record is not a wall, and the bound that does the work is the
    /// first one: a row only ever lands here on an observed transition
    /// out of a live state. A session discovered from a cold transcript
    /// was never live in this store's eyes, never transitions, and so
    /// can never enter the record however many of them are on the disk.
    ///
    /// The other two bounds (`historyCap`, and the window the user
    /// chooses) are ordinary and enforced in `remember`.
    ///
    /// Its own array rather than letting `sessions` hold the dead:
    /// `sessions` goes on meaning "what I am tracking now", which every
    /// other reader already relies on, and the record has to survive
    /// `clear(id:)`, which is the very call that would delete it.
    struct Finished: Identifiable, Equatable {
        /// What became of it, as far as this store can honestly say.
        enum Outcome: String, Equatable {
            case done
            case failed
            /// The registry stopped seeing the process. Deliberately not
            /// `done`: `markGone` already refuses to claim an outcome it
            /// cannot know ("a killed session did not finish"), and the
            /// record is not where that starts being a lie.
            case lost
        }

        let id: String
        var title: String
        var cwd: String
        var branch: String?
        var agent: Agent
        var outcome: Outcome
        /// Its final words, so the rail has something to say about a row
        /// whose transcript has since been rotated away.
        var lastMessage: String?
        var transcriptPath: String?
        var finishedAt: Date
    }

    /// A tool call an agent is holding at the door, waiting to be told
    /// yes or no.
    ///
    /// The one thing in this app that reaches into a running agent and
    /// changes what it does. Everything else here watches, or leaves a
    /// note for the agent to collect; this decides. It works because a
    /// `PreToolUse` hook may return a `permissionDecision` and Claude
    /// Code obeys it (verified 2026-08-02 against a throwaway session:
    /// the deny landed and the command never ran).
    struct Approval: Identifiable, Equatable {
        enum Decision: String, Equatable { case allow, deny }

        /// Claude Code's own `tool_use_id`: unique per call, so a hook
        /// polling for its answer cannot be handed somebody else's.
        let id: String
        var tool: String
        /// The command, path, or whatever else names what is about to
        /// happen. Shown verbatim: a summary of a command you are being
        /// asked to authorise is a summary of the wrong thing.
        var detail: String
        var askedAt: Date
        var decision: Decision?
        /// How long the agent will actually wait: its hook's own
        /// `timeout`, carried in the payload, 600 seconds unless
        /// somebody configured otherwise. The card counts this down out
        /// loud, so it has to be the real one.
        var patience: TimeInterval = 600
        /// Whether the same question is also on screen in the session's
        /// own terminal.
        ///
        /// True for a `PermissionRequest`, and this is measured rather
        /// than assumed: Claude Code paints its own prompt whatever a
        /// hook is doing, and it still painted it when the answer came
        /// back four milliseconds later. So that card is a second place
        /// to answer from, never the only one, and it must not claim
        /// otherwise.
        var alsoInTerminal: Bool = false
    }

    /// One or several questions asked together and answered one at a
    /// time. `AskUserQuestion` routinely bundles two to four questions
    /// into a single call; the scripted `chalant ask` only ever sends
    /// one. Both are this same array — the single-question shape is it
    /// holding one element, not a second type running alongside this
    /// one that everything would have to be kept in step with.
    struct Ask: Identifiable, Equatable {
        let id: String
        var questions: [Question]
        var askedAt: Date

        /// A question held inside a hook, answerable in place: an MCP
        /// server's `elicitation/create`, or an intercepted
        /// `AskUserQuestion`. The agent is suspended waiting on the
        /// hook's reply, so the card's buttons resolve it rather than
        /// queueing a message for later. It can also be turned down,
        /// which is a real answer of its own.
        var elicitation: Bool = false
        /// True for an `AskUserQuestion` held at the `PreToolUse` door
        /// (its answer travels back as a deny whose reason is the
        /// answer), false for an MCP elicitation. Only the card reads
        /// it, to say which kind of wait this is and what not answering
        /// does. The transcript-scraped, queue-only "native" ask this
        /// flag replaced is gone: interception answers the prompt
        /// itself instead of leaving a note for the next turn.
        var intercepted: Bool = false
        /// Which MCP server asked, so the card can say whose question
        /// this is.
        var server: String = ""

        /// One question inside an ask: what it asks, what it offers,
        /// and what got picked, once it has been. `answer` lives here
        /// rather than once on the whole `Ask` so a bundle can be
        /// answered one question at a time — two of three answered is a
        /// real, intermediate state, not a rounding error toward zero
        /// or all.
        struct Question: Equatable {
            var header: String
            var question: String
            var options: [String]
            var multiSelect: Bool
            var answer: [String]? = nil     // set when the user taps; hook polls for this
            /// The schema property this question came from, for an
            /// elicitation. The answer has to go back under the name the
            /// MCP server asked for, and nothing else in the card knows
            /// that name.
            var field: String = ""
            /// One description per option, aligned by index with
            /// `options`, empty where an option has none. Carried for an
            /// intercepted `AskUserQuestion`, whose options arrive as
            /// label-and-description pairs; everything else leaves it
            /// empty.
            var optionDescriptions: [String] = []
        }

        /// True once every question in the bundle has an answer. For a
        /// single-question ask this is exactly what `answer != nil`
        /// always meant before bundles existed.
        var isFullyAnswered: Bool { questions.allSatisfy { $0.answer != nil } }

        // MARK: Single-question compatibility
        //
        // `ActivityServer`'s `/ask` routes and `scripts/chalant ask` both
        // predate bundled asks and both only ever carry one question.
        // These proxy the first (and, for them, only) question so
        // neither had to change to learn about the rest.
        var header: String { questions.first?.header ?? "" }
        var question: String { questions.first?.question ?? "" }
        var options: [String] { questions.first?.options ?? [] }
        var multiSelect: Bool { questions.first?.multiSelect ?? false }
        var answer: [String]? { questions.first?.answer }
    }

    private static let log = Logger(subsystem: "com.cj.chalant", category: "sessions")

    /// Attention first: needs-input, then working, then last-seen, then
    /// the terminal states, each newest first. Views render straight
    /// through, same contract as ActivityStore.activities.
    @Published private(set) var sessions: [Session] = []

    /// What ended while this app was watching, newest first.
    ///
    /// Never rendered in the glance: `AgentSessionsStrip` filters to
    /// live and goes on doing so, so the calm surface is exactly as calm
    /// as it was. This is for the room somebody deliberately opened.
    @Published private(set) var finished: [Finished] = []

    /// Most rows the record ever holds. Small on purpose: the point is
    /// "what happened while I was away", and the eleventh most recent
    /// thing to finish is not that.
    static let historyCap = 8

    /// How far back the record goes, in seconds. Nil means the user
    /// turned it off, which stops rows being kept at all rather than
    /// merely hiding them: a record nobody can see is not a record, it
    /// is a leak.
    static let historyWindowKey = "sessionHistoryWindow"

    nonisolated static func historyWindow(in defaults: UserDefaults = .standard) -> TimeInterval? {
        // Absent means never set, which is the default rather than off.
        guard let raw = defaults.string(forKey: historyWindowKey) else { return 2 * 3600 }
        switch raw {
        case "off": return nil
        case "hour": return 3600
        case "today": return 24 * 3600
        default: return 2 * 3600
        }
    }

    /// Whether `~/.claude/sessions` is there to be read, latched by
    /// `SessionRegistry.start()`.
    ///
    /// The one switch between "a pid makes a session real" and the older
    /// "a warm file makes a session real". While this is true the registry
    /// is the list and discovery only describes what is on it; while it is
    /// false nothing has changed since before the registry existed.
    ///
    /// That fallback is the standing law for this overlay, not politeness:
    /// the directory is undocumented, and a Claude Code release that moves
    /// it has to cost a busy/idle badge rather than empty the rail.
    private(set) var registryIsAuthoritative = false

    func noteRegistryIsAuthoritative() { registryIsAuthoritative = true }

    /// How long a transcript may sit still before the registry's "busy"
    /// stops being taken at face value.
    ///
    /// Generous on purpose. A single agent turn commonly runs several
    /// minutes without the transcript being touched at all
    /// (`SessionDiscovery.staleWindow` is five, for the same reason), and
    /// demoting somebody mid-thought would be a worse bug than the one
    /// this fixes. Twenty-one hours is what this was actually built
    /// against; fifteen minutes is comfortably past any real turn and
    /// nowhere near that.
    static let workCorroborationWindow: TimeInterval = 15 * 60

    private let maxSessions: Int
    /// Terminal rows linger just long enough to be seen before they
    /// clear themselves — same idea, same window ActivityStore uses
    /// for a finished pill.
    private let finishedTTL: TimeInterval
    private var expiryWork: [String: DispatchWorkItem] = [:]

    /// Claude Code sessions the registry went looking for and did not
    /// find, while it was demonstrably working. Held so discovery cannot
    /// put them back: see `upsert`. Emptied of anything the registry
    /// vouches for again, and of anything no longer in the list at all,
    /// so it stays the size of the store rather than the size of the day.
    private var disownedByRegistry: Set<String> = []

    /// Sessions that earn a mark on the resting island: something is
    /// happening, and you could go and see it.
    ///
    /// `idle` and `stale` are listed in the strip and never counted here
    /// (you cannot pick what is not listed, but a number that grows every
    /// time a terminal sits at its prompt says less, not more). A session
    /// with no controlling terminal is left out for a sharper reason:
    /// there is nowhere to go and see it, and the one that prompted this
    /// runs nearly always, so counting it lit the badge permanently.
    ///
    /// Lives here rather than in the view so the number on the closed
    /// pill and the rows in the open strip can never disagree about what
    /// is running.
    var glanceable: [Session] {
        sessions.filter {
            ($0.state == .working || $0.state == .needsInput) && $0.hasTerminal != false
        }
    }

    /// Outbox entries read off disk at launch, keyed by session id, not
    /// yet attached to a row. A bare id on disk is not proof the session
    /// is still running, so these wait here until `upsert` or `markLive`
    /// rediscovers that exact session, or forever if it never comes back.
    private var restoredOutbox: [String: Outbox] = [:]
    /// Nil disables persistence outright: no read at `init`, no write on
    /// any mutation. That is the default on purpose. Unlike
    /// `ClipboardStore`, this type already had ~170 tests in
    /// `SessionStoreTests` written against a bare `SessionStore()` that
    /// never touched disk; defaulting this to the real Application
    /// Support path the moment persistence shipped would have made every
    /// one of them read and write a real install's file through nothing
    /// but a plain, no-argument `SessionStore()`. Production opts in
    /// explicitly, passing `SessionStore.defaultOutboxDirectory()`
    /// (`NotchViewModel`); a persistence test opts in with its own
    /// scratch directory, the seam `ClipboardStore`'s `clipsDirectory`
    /// already uses. Neither path can reach a real install by accident.
    private let outboxDir: URL?

    /// TTL and cap are constructor args rather than baked-in constants
    /// so a test can shrink the TTL to something it can actually wait
    /// out, instead of proving a 60-second timer fires 60 seconds at a
    /// time. See `outboxDir` above for why `outboxDirectory` defaults to
    /// nil rather than a real path.
    /// Where the user's own choices are read from. Injectable for the
    /// same reason `finishedTTL` is: a test needs to say "history is off"
    /// or "history is one hour" without writing to the real install's
    /// defaults, and the window is read on every append rather than
    /// cached so flipping the setting takes effect at once.
    private let defaults: UserDefaults

    init(
        maxSessions: Int = 20, finishedTTL: TimeInterval = 60,
        outboxDirectory: URL? = nil, defaults: UserDefaults = .standard
    ) {
        self.maxSessions = maxSessions
        self.finishedTTL = finishedTTL
        self.outboxDir = outboxDirectory
        self.defaults = defaults
        loadOutbox()
    }

    /// Upsert keyed by Claude Code's own session id. `startedAt` is
    /// preserved from the first time this store saw the id: the
    /// metadata file carries no session-start timestamp of its own, so
    /// "first seen here" is the honest substitute. `ask` is left alone
    /// on purpose — discovery has no opinion on it, and clobbering it
    /// on every metadata-file rescan would drop a question a hook (a
    /// later phase) pushed moments before.
    /// `startedAt` is a testing seam only, exactly like `updatedAt`
    /// below: real callers never pass it, and it is only read the
    /// first time this id is seen.
    func upsert(
        id: String, title: String, cwd: String, branch: String?,
        lastPrompt: String?, state: State, activity: String? = nil,
        agent: Agent = .claude, updatedAt: Date = Date(), startedAt: Date = Date(),
        transcriptPath: String? = nil
    ) {
        let alreadyKnown = sessions.first { $0.id == id }
        // A warm file is not a session.
        //
        // While the registry is answering, it holds the list and this
        // only ever describes what is already on it. Discovery reads the
        // freshest transcripts on the machine and has no idea whose they
        // are: on the founder's Mac, eight of the twelve freshest belonged
        // to claude-mem's observer bot (2026-08-03), and each one became a
        // row, then a "lost" entry in the record seconds later when no
        // process turned up to claim it. Both problems are the same
        // problem, and this line is where it stops.
        //
        // Claude Code only, the same carve-out `reconcileLive` makes and
        // for the same reason: Cursor keeps no registry, so this registry
        // has no standing to say a Cursor chat does not exist.
        guard alreadyKnown != nil || agent != .claude || !registryIsAuthoritative else { return }
        var session = alreadyKnown
            ?? Session(
                id: id, title: title, cwd: cwd, branch: branch,
                lastPrompt: lastPrompt, activity: activity, agent: agent,
                state: state, ask: nil,
                startedAt: startedAt, updatedAt: updatedAt
            )
        // A row appearing for the first time this launch is exactly the
        // "session rediscovered" moment a restored outbox is waiting
        // for. Discovery found a real transcript at this id, which is
        // more than the persisted file alone could ever say.
        if alreadyKnown == nil, let restored = restoredOutbox.removeValue(forKey: id) {
            session.outbox = restored
        }
        let previousState = session.state
        session.title = title
        session.cwd = cwd
        session.branch = branch
        session.lastPrompt = lastPrompt
        session.activity = activity
        session.agent = agent
        // `lastMessage` is deliberately not written here any more: what
        // the assistant last said arrives on the Stop hook's own
        // payload (`noteLastWords`), not from a transcript rescan.
        // The registry can upsert a row it made itself, and it has no
        // path to offer. Never blank a real one.
        if let transcriptPath { session.transcriptPath = transcriptPath }
        // An outstanding question outranks whatever discovery inferred.
        //
        // Discovery reads working-or-stale off a file's mtime every
        // twenty seconds and has no way to know a question is waiting,
        // so it must not be able to overwrite one. Without this the row
        // lost its glyph, its tint, its place at the top of the list
        // and the island's waiting mark one rescan after the question
        // arrived — while the question itself stayed answerable, so
        // nothing looked broken.
        let questionOutstanding = session.ask.map { !$0.isFullyAnswered } ?? false
        var resolved = questionOutstanding ? .needsInput : state
        // A pid outranks an mtime, which is the half of that rule this
        // file was missing.
        //
        // Discovery infers "gone" from a transcript that stopped moving,
        // and a session sitting at its prompt stops moving all the time.
        // The registry holds the process itself. Without this the two
        // writers simply took turns: the sweep said working every five
        // seconds, the rescan said stale every twenty, and a stale row is
        // filtered out of `groups()` — so the founder's own session
        // vanished from the rail and came back, over and over, and
        // `stateSince` reset on each flip so its age read as nonsense.
        //
        // Only while the registry still vouches for it. Once `reconcile`
        // has disowned the id its pid is cleared and discovery is trusted
        // again, which is the rule immediately below.
        //
        // What it keeps is the state the registry gave it, held against
        // this very read: a transcript that has gone quiet for a quarter
        // of an hour is exactly the evidence that a "busy" is out of date,
        // and this is the moment that evidence arrives.
        if !questionOutstanding, state == .stale, session.pid != nil,
           !disownedByRegistry.contains(id) {
            resolved = Self.corroborated(session.state, transcriptTouchedAt: updatedAt)
        }
        // And a registry that went looking and did not find this
        // session outranks both. Discovery reads an mtime; the registry
        // holds a pid. A warm transcript is not a running process, and
        // this is the only place in the app that difference is known.
        //
        // Sticky on purpose. Discovery rescans on its own clock and
        // would re-assert the same warm file twenty seconds later, and a
        // row flipping between running and last-seen is worse than
        // either answer on its own.
        if disownedByRegistry.contains(id), resolved.isLive {
            resolved = .stale
        }
        session.state = resolved
        session.updatedAt = updatedAt
        // The one writer that has actually looked at a file, so the one
        // that may say when it last moved. `markLive` reads this to decide
        // whether a "busy" is still worth believing.
        session.transcriptTouchedAt = updatedAt
        // The record's second entrance. `remember` decides whether this
        // qualifies; all this has to do is be honest about what state
        // was being left. A session that arrives already `.done` because
        // discovery found a cold file has a non-live `previousState` and
        // is refused there.
        if resolved == .done || resolved == .failed {
            remember(session, leaving: previousState, as: resolved == .done ? .done : .failed)
        } else if resolved.isLive {
            revive(id)
        }
        sessions.removeAll { $0.id == id }
        sessions.append(session)
        sort()
        // What the row actually became, not what the caller proposed.
        // Those are two different things now that a vouched-for session
        // can refuse a transcript's "gone", and a log that reports the
        // proposal would show a flip on every single rescan of a quiet
        // file while the row sat perfectly still.
        if previousState != resolved {
            Self.log.debug(
                "\(id, privacy: .public): \(previousState.rawValue, privacy: .public) -> \(resolved.rawValue, privacy: .public)"
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
    /// A bundle this deep is already more questions than the island can
    /// show without becoming the whole point of looking at it. Real
    /// `AskUserQuestion` calls run to three or four
    /// (native-questions-evidence-2026-08-03.md); this is a ceiling
    /// against a runaway payload, not a limit anyone should reach.
    static let maxQuestions = 6

    /// Attaches one or several questions to a session as a single ask,
    /// and lifts it to needs-input. Every other `attach` is sugar over
    /// this one — the single-question shape is this array holding one
    /// element, so there is exactly one place that trims, bounds and
    /// stores a question, whether there is one of them or several.
    ///
    /// Each question is trimmed and bounded on the way in: everything
    /// here came off a socket or a transcript this app does not control.
    /// A question whose text is blank after trimming is dropped from the
    /// bundle rather than shown blank; if that empties the bundle
    /// entirely, the whole attach is refused — a row that says a session
    /// wants something without saying what is worse than no row at all.
    @discardableResult
    func attach(
        askID: String, to sessionID: String, questions rawQuestions: [Ask.Question],
        elicitation: Bool = false, intercepted: Bool = false, server: String = ""
    ) -> Bool {
        let questions: [Ask.Question] = rawQuestions.prefix(Self.maxQuestions).compactMap { raw in
            let question = String(raw.question.prefix(Self.askFieldLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            // Options and their descriptions stay aligned by walking
            // them together: dropping a blank label drops its
            // description with it, never sliding one under a
            // neighbour.
            let kept: [(label: String, described: String)] = raw.options
                .prefix(Self.maxOptions).enumerated().compactMap { offset, label in
                    let trimmedLabel = String(label.prefix(Self.askFieldLimit))
                    guard !trimmedLabel.isEmpty else { return nil }
                    let described = offset < raw.optionDescriptions.count
                        ? String(raw.optionDescriptions[offset].prefix(Self.askFieldLimit))
                        : ""
                    return (trimmedLabel, described)
                }
            return Ask.Question(
                header: String(raw.header.prefix(Self.askFieldLimit)),
                question: question,
                options: kept.map(\.label),
                multiSelect: raw.multiSelect,
                field: raw.field,
                optionDescriptions: kept.map(\.described)
            )
        }
        guard !questions.isEmpty, let index = sessions.firstIndex(where: { $0.id == sessionID })
        else { return false }
        sessions[index].ask = Ask(
            id: askID, questions: questions, askedAt: Date(),
            elicitation: elicitation, intercepted: intercepted, server: server)
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

    /// The single-question shape everything before bundled asks used:
    /// `ActivityServer`'s `POST /ask`, `scripts/chalant ask`, and every
    /// test written against one question. Builds the one-element array
    /// the overload above expects, so none of those callers change.
    @discardableResult
    func attach(
        askID: String, to sessionID: String, header: String, question: String,
        options: [String], multiSelect: Bool
    ) -> Bool {
        attach(
            askID: askID, to: sessionID,
            questions: [Ask.Question(header: header, question: question, options: options, multiSelect: multiSelect)]
        )
    }

    /// Records what the user chose for one question inside the ask,
    /// independent of the others. A bundle two of three questions
    /// answered stays right there — needs-input — until the last one
    /// lands: `isFullyAnswered` below is what decides that, not this
    /// single question's own answer. Only once every question has one
    /// does the session go back to working and `onAnswered` fire, which
    /// is what hands a held ask's answers to the hook suspended on
    /// them.
    @discardableResult
    func answerQuestion(sessionID: String, questionIndex: Int, with choices: [String]) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              var ask = sessions[index].ask,
              ask.questions.indices.contains(questionIndex)
        else { return false }
        ask.questions[questionIndex].answer = choices
        sessions[index].ask = ask
        if ask.isFullyAnswered {
            sessions[index].state = .working
        }
        sessions[index].updatedAt = Date()
        sort()
        if ask.isFullyAnswered { onAnswered?(ask.id) }
        return true
    }

    /// The scripted `chalant ask` shape: always exactly one question,
    /// so answering it is answering the whole ask. The agent polls for
    /// this over `/ask/<session>`.
    @discardableResult
    func answer(sessionID: String, with choices: [String]) -> Bool {
        answerQuestion(sessionID: sessionID, questionIndex: 0, with: choices)
    }

    /// Told the moment an ask is fully answered, so an agent suspended
    /// inside an `Elicitation` hook can be handed the answer rather than
    /// coming back to poll for it. Carries the ask's own id, because by
    /// the time this fires the card may already be on its way out.
    var onAnswered: ((String) -> Void)?

    /// An MCP server's question, with its own hook waiting on the reply.
    ///
    /// Self-registering for the same reason a held prompt is: a `claude
    /// -p` run registers nowhere, and a question with no row to sit on
    /// is a question nobody can answer. The folder is the only name such
    /// a row will ever have.
    @discardableResult
    func holdForElicitation(
        sessionID: String, askID: String, questions: [Ask.Question], cwd: String?,
        server: String, intercepted: Bool = false
    ) -> Bool {
        if !sessions.contains(where: { $0.id == sessionID }) {
            sessions.append(Session(
                id: sessionID,
                title: cwd.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "An agent",
                cwd: cwd ?? "", branch: nil, lastPrompt: nil, activity: nil,
                agent: .claude, state: .needsInput, ask: nil,
                pid: nil, kind: nil, startedAt: Date(), updatedAt: Date()
            ))
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        // Same vouching a held call gets, and for the same reason: a
        // hook mid-question is a process talking to this app in real
        // time, which outranks a registry sweep that may be behind.
        sessions[index].vouchedByHookAt = Date()
        disownedByRegistry.remove(sessionID)
        revive(sessionID)
        // Never over the top of a question already being answered.
        guard sessions[index].ask == nil || sessions[index].ask?.isFullyAnswered == true else {
            return false
        }
        return attach(
            askID: askID, to: sessionID, questions: questions,
            elicitation: true, intercepted: intercepted, server: server)
    }

    func pendingAsk(sessionID: String) -> Ask? {
        sessions.first { $0.id == sessionID }?.ask
    }

    /// By the ask's own id rather than its session's, which is what a
    /// hook holding one knows: the id it minted is the only handle it
    /// has, and the session it belongs to may have been renamed, revived
    /// or re-sorted since.
    func ask(withID askID: String) -> Ask? {
        sessions.first { $0.ask?.id == askID }?.ask
    }

    func clearAsk(askID: String) {
        guard let index = sessions.firstIndex(where: { $0.ask?.id == askID }) else { return }
        sessions[index].ask = nil
        sessions[index].updatedAt = Date()
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

    /// Rank first, then `startedAt`, never `updatedAt`, within a rank.
    ///
    /// A rescan rewrites `updatedAt` on every session on every sweep, so
    /// sorting by it made two working rows trade places on a five-second
    /// clock for no reason a user could see (founder, 2026-08-02: "just
    /// dont make them change places"). `startedAt` is set once, when a
    /// session is first seen, and never touched again: a row only
    /// moves when its rank actually changes, which is the one kind of
    /// move that means something.
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
                : $0.startedAt > $1.startedAt
        }
    }

    // MARK: The record

    /// Put a session into the record, if it is the kind of ending the
    /// record is allowed to hold.
    ///
    /// Called from the two places a session can be observed leaving a
    /// live state, and from nowhere else. Both callers pass the state
    /// being left behind rather than checking it themselves, so the one
    /// rule that makes the record bounded ("only what this app watched
    /// end") lives in one place instead of being re-derived by each
    /// caller and eventually got wrong by one of them.
    private func remember(_ session: Session, leaving previous: State, as outcome: Finished.Outcome) {
        // The bound that does the real work. A session discovered from
        // a cold transcript is never live here, so it never reaches this
        // with a live `previous`, so a disk full of old transcripts
        // produces no rows at all.
        guard previous.isLive else { return }
        // Off means not kept, not merely not shown. A record nobody can
        // reach is not a record.
        guard let window = Self.historyWindow(in: defaults) else { return }
        finished.removeAll { $0.id == session.id }
        finished.insert(
            Finished(
                id: session.id, title: Self.displayTitle(for: session), cwd: session.cwd,
                branch: session.branch, agent: session.agent, outcome: outcome,
                lastMessage: session.lastMessage,
                transcriptPath: session.transcriptPath, finishedAt: Date()
            ),
            at: 0
        )
        prune(window: window)
    }

    /// What to call a session on screen.
    ///
    /// A session that never earned a title from its transcript falls
    /// back to its folder name, and for a headless process that folder
    /// is an implementation detail of whatever spawned it. Naming it for
    /// what it is beats naming it after a directory the person has never
    /// opened.
    ///
    /// A data rule rather than a view rule, and it lives here because
    /// two surfaces read it and a third writes it: the strip, the room's
    /// live rows, and `remember` below. It was the view's alone, and the
    /// record consequently stored the raw folder name, so the same
    /// session read "Background task" while running and
    /// "observer-sessions" once finished, four rows apart in the same
    /// rail (observed 2026-08-03).
    ///
    /// Only the fallback is replaced. A headless session that does have
    /// a real title keeps it, because that title is the one thing on the
    /// row worth reading.
    nonisolated static func displayTitle(for session: Session) -> String {
        let folder = session.cwd.split(separator: "/").last.map(String.init) ?? session.cwd
        guard session.hasTerminal == false, session.title == folder else { return session.title }
        return "Background task"
    }

    /// Take a session back out of the record, because it is alive again.
    ///
    /// The registry loses a session and finds it again more often than
    /// the word "finished" suggests: a transcript goes quiet through a
    /// long turn, `reconcileLive` disowns it, and the next sweep vouches
    /// for the same pid. Without this the room showed one session in
    /// Working and in Finished at the same moment, four rows apart
    /// (caught in pixels, 2026-08-03). Whatever else is true, a session
    /// that is running now has not finished.
    private func revive(_ id: String) {
        finished.removeAll { $0.id == id }
    }

    /// Drops what has aged out and what falls off the end of the cap.
    /// Run on every append and on every read, because a room left open
    /// overnight must not still be showing yesterday: nothing else is
    /// firing on this array's behalf.
    private func prune(window: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-window)
        finished.removeAll { $0.finishedAt < cutoff }
        if finished.count > Self.historyCap {
            finished.removeSubrange(Self.historyCap...)
        }
    }

    /// Backdate a row in the record.
    ///
    /// A testing seam and nothing else, the same shape `upsert`'s
    /// `updatedAt` and `startedAt` arguments are: aging out is the one
    /// behaviour here a test cannot reach by calling the real API, since
    /// the alternative is waiting an hour. Named so it cannot be
    /// mistaken for something production is allowed to call.
    func ageFinishedForTesting(id: String, to moment: Date) {
        guard let index = finished.firstIndex(where: { $0.id == id }) else { return }
        finished[index].finishedAt = moment
    }

    /// The record as a reader should see it: pruned first, so an expired
    /// row cannot be rendered by a view that happened to look before any
    /// append did the pruning.
    var history: [Finished] {
        guard let window = Self.historyWindow(in: defaults) else { return [] }
        let cutoff = Date().addingTimeInterval(-window)
        return finished.filter { $0.finishedAt >= cutoff }.prefix(Self.historyCap).map { $0 }
    }

    // MARK: Grouping

    /// The four bands the room's rail draws, in the order it draws them.
    enum Group: String, CaseIterable, Identifiable {
        case needsYou
        case working
        case atPrompt
        case finished

        var id: String { rawValue }

        var title: String {
            switch self {
            // Was "Needs you" until the founder called it vague
            // (2026-08-06) and they were right: it names a feeling the
            // app has about a row rather than the thing on the row. The
            // band is now an instruction, and every row under it carries
            // the actual question or the actual command, from
            // `SessionActivity`.
            //
            // The case keeps its name. `settingKey` is built from the
            // raw value and somebody's stored band visibility should not
            // reset because a label was reworded.
            case .needsYou: return "Answer this"
            case .working: return "Working"
            // The app's own existing phrasing, already in the row's
            // accessibility label. "Idle" is accurate and reads like a
            // complaint about the session.
            case .atPrompt: return "At its prompt"
            case .finished: return "Finished"
            }
        }

        /// Which of these a user is allowed to switch off.
        ///
        /// Needs you is not one of them. A band whose entire purpose is
        /// "something is blocked on you" being switchable off is a way
        /// to make this app quietly fail at its one job, so the setting
        /// renders disabled with a reason rather than silently missing.
        var canBeHidden: Bool { self != .needsYou }

        var settingKey: String { "sessionGroup.\(rawValue)" }
    }

    /// Which band a live session belongs in.
    ///
    /// A held approval or an unanswered question outranks the state:
    /// a session can be mid-turn and still be the thing standing still
    /// waiting for a human, and that is exactly the row the rail exists
    /// to float to the top.
    /// Something on this row is waiting on a person: a tool call held at
    /// the door, or a question with no answer yet. One predicate, read
    /// by both the band a row lands in and whether it may be hidden at
    /// all, so the two cannot come to different conclusions.
    static func wantsAHuman(_ session: Session) -> Bool {
        if let approval = session.approval, approval.decision == nil { return true }
        if let ask = session.ask, !ask.isFullyAnswered { return true }
        // Claude Code frozen at its own permission prompt. The island
        // cannot answer it, and that is not a reason to be quiet about
        // it: this band's promise is that nothing waiting on a person is
        // invisible, not that everything in it is answerable from here.
        if let prompt = session.pendingPrompt, !prompt.isStale { return true }
        return false
    }

    static func group(for session: Session) -> Group {
        if wantsAHuman(session) { return .needsYou }
        switch session.state {
        case .needsInput: return .needsYou
        case .working: return .working
        case .idle: return .atPrompt
        // Not drawn from `sessions` at all. A dead row that discovery
        // still has in hand is not the record, and showing it beside
        // rows this app watched end would break the one bound that
        // makes the record honest.
        case .done, .failed, .stale: return .finished
        }
    }

    /// The rail's contents: only non-empty bands, only ones the user
    /// left switched on, in `Group.allCases` order.
    ///
    /// The first three are cut out of `sessions`, which `sort()` has
    /// already put in an order that agrees with this one by
    /// construction, so nothing is sorted twice. Finished comes from the
    /// record and is already newest-first.
    func groups() -> [(group: Group, live: [Session], ended: [Finished])] {
        // `isLive`, or waiting on a human, which is a kind of alive this
        // store's state enum cannot express: `holdForApproval` and
        // `attach` both keep a row live now, but the belt is here as
        // well as the braces. A call held at the door or an unanswered
        // question is never allowed to be invisible, whatever any other
        // signal currently believes about the process.
        let visible = sessions.filter { $0.state.isLive || Self.wantsAHuman($0) }
        let banded = Dictionary(grouping: visible, by: Self.group(for:))
        // A session cannot be in two bands at once. Anything showing as
        // live wins over its own record row, which exists only because
        // some earlier sweep gave up on it.
        let liveIDs = Set(visible.map(\.id))
        let ended = history.filter { !liveIDs.contains($0.id) }
        return Group.allCases.compactMap { group in
            guard shows(group) else { return nil }
            if group == .finished {
                return ended.isEmpty ? nil : (group, [], ended)
            }
            let live = banded[group] ?? []
            return live.isEmpty ? nil : (group, live, [])
        }
    }

    /// Whether the user left this band switched on. Absent means on:
    /// nobody has opened the setting, and every band ships visible.
    func shows(_ group: Group) -> Bool {
        guard group.canBeHidden else { return true }
        return defaults.object(forKey: group.settingKey) as? Bool ?? true
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
    /// `hasTerminal` defaults to true so a caller that has not looked
    /// cannot accidentally demote a row: the registry, which is the one
    /// caller that does look, always passes what it found.
    /// `status` is optional because "this process is here" and "this is
    /// what it is doing" are two different claims, and the registry can
    /// make the first without the second. A file whose `status` this app
    /// does not recognise (background's "blocked", or whatever a later
    /// Claude Code writes) still proves the session exists, and that
    /// proof is now the only way onto the list at all — so it arrives
    /// here as nil rather than as a reason not to call.
    ///
    /// Nil leaves an existing row's state exactly as the transcript left
    /// it, and starts a new row at `.idle`: alive, with nothing known to
    /// be happening in it.
    func markLive(
        id: String, name: String, cwd: String, pid: pid_t, kind: Kind?,
        hasTerminal: Bool = true, status: State?, startedAt: Date? = nil,
        bridgeID: String? = nil
    ) {
        // Vouched for, so whatever the registry concluded last time it
        // could not find this session no longer holds. Including the row
        // it wrote into the record when it lost it: this is the same
        // registry saying the same process is there after all, and a
        // session cannot be both running and finished.
        disownedByRegistry.remove(id)
        if status?.isLive ?? true { revive(id) }
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].pid = pid
            // Same rule every other field here follows: only ever
            // replaced by something real. A registry file wearing a kind
            // this app has not learned yet must not blank one it already
            // read correctly.
            if let kind { sessions[index].kind = kind }
            // Same rule: only ever replaced by something real. A sweep
            // that read the file before Claude Code finished bridging
            // must not take the door away again.
            if let bridgeID { sessions[index].bridgeID = bridgeID }
            sessions[index].hasTerminal = hasTerminal
            // A fact about the session, replacing a fact about when this
            // app happened to open. `upsert`'s "first seen here" is an
            // honest substitute for a transcript, which carries no start
            // time; the registry does carry one, and at launch the
            // substitute is the same instant for every row on screen, so
            // it could not tell two identically-named sessions apart. It
            // is also what `sort()` orders by within a rank.
            if let startedAt { sessions[index].startedAt = startedAt }
            let questionOutstanding = sessions[index].ask.map { !$0.isFullyAnswered } ?? false
            if let status, !questionOutstanding {
                let previous = sessions[index].state
                let believed = Self.corroborated(
                    status, transcriptTouchedAt: sessions[index].transcriptTouchedAt)
                sessions[index].state = believed
                noteTransition(
                    from: previous, to: believed,
                    id: sessions[index].id, title: sessions[index].title
                )
            }
            sessions[index].updatedAt = Date()
        } else {
            var fresh = Session(
                id: id, title: name, cwd: cwd, branch: nil, lastPrompt: nil,
                activity: nil, agent: .claude, state: status ?? .idle, ask: nil,
                pid: pid, kind: kind, hasTerminal: hasTerminal,
                startedAt: startedAt ?? Date(), updatedAt: Date()
            )
            // Same rediscovery rule `upsert` follows: a row born here is
            // the registry vouching for a real, running process at this
            // id, which is what a restored outbox was waiting for.
            fresh.bridgeID = bridgeID
            fresh.outbox = restoredOutbox.removeValue(forKey: id)
            sessions.append(fresh)
        }
        sort()
    }

    /// How long a reported terminal prompt is still believed. Generous,
    /// because a person who walked away from one really is still stuck
    /// on it; the ordinary end is `clearPendingPrompt`, not this.
    static let pendingPromptExpiry: TimeInterval = 15 * 60

    /// Claude Code has put a permission prompt on screen in this
    /// session's own terminal.
    ///
    /// Reported by the `Notification` hook, which is already installed
    /// on machines that have ever set this app up and which fires for
    /// every agent including the ones inside editors this app cannot
    /// type into. That makes it the only verb here with no setup step,
    /// which matters more than it sounds: the approval gate has shipped
    /// twice now and its one button has never been pressed.
    ///
    /// Decoration, never creation, the same law `attach` follows.
    func notePendingPrompt(sessionID: String, tool: String, detail: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        // Both hooks fire for one permission prompt: `PermissionRequest`
        // holds it and puts a card with buttons on the row, and
        // `Notification` reports the same prompt a moment later. Without
        // this the row grows a second card about the same question, one
        // of which says it cannot be answered while the other is busy
        // answering it.
        guard sessions[index].approval == nil else { return }
        sessions[index].pendingPrompt = PendingPrompt(
            tool: tool, detail: detail, since: Date())
        sessions[index].updatedAt = Date()
        // Same reasoning as a held call: an agent standing at a prompt
        // has not finished, whatever a quiet transcript suggests.
        disownedByRegistry.remove(sessionID)
        revive(sessionID)
        if !sessions[index].state.isLive { sessions[index].state = .needsInput }
        sort()
    }

    /// The prompt is over.
    ///
    /// Two things prove it and both call this: the turn ending, since
    /// Claude Code cannot finish a turn while standing at a prompt, and
    /// the next tool call, since it does not reach for one while the
    /// last is unanswered.
    func clearPendingPrompt(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].pendingPrompt != nil
        else { return }
        sessions[index].pendingPrompt = nil
        sessions[index].updatedAt = Date()
        sort()
    }

    /// Hands a row what a background agent published about itself.
    ///
    /// Decoration, never creation: `markLive` is the only thing that can
    /// put a session on the list, and that rule is what stopped a warm
    /// file from inventing rows in the first place. A job for a session
    /// nobody vouches for is dropped on the floor here.
    func attach(job: JobState, to id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].job = job
    }

    /// Hands a row the to-do list the agent is working through.
    ///
    /// Takes an optional and writes it either way, because a plan that
    /// has just been finished has to be able to go away: leaving the
    /// last known step on the row is how a finished session ends up
    /// claiming to still be on step three.
    func attach(plan: PlanProgress?, to id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].plan != plan else { return }  // no needless publish
        sessions[index].plan = plan
    }

    /// The registry's status, held against what the transcript shows.
    ///
    /// Alive is knowledge: this app holds the pid and asked the kernel.
    /// Working is a claim, made by another program in a file it does not
    /// always remember to rewrite. The founder's own session claimed to be
    /// working for twenty-one hours, from the moment it parked a
    /// background job until the next morning, and the room said so the
    /// whole time.
    ///
    /// So a `busy` no moving transcript agrees with settles at `.idle`,
    /// which is the honest reading of what is actually known: the process
    /// is there, and nothing observable is happening in it. Never
    /// `.stale`, which would claim it had gone.
    ///
    /// Only ever demotes. Nothing here can promote a session to working
    /// that the registry did not already say was working, and a row with
    /// no transcript read yet is believed: having nothing to corroborate
    /// against is not the same as being contradicted.
    /// Takes the touch time rather than the row so both writers can ask
    /// the same question at the moment each of them learns the answer.
    /// `upsert` has a fresher `mtime` in hand than the row is carrying,
    /// and waiting for the next five-second sweep to apply it would leave
    /// the row claiming to work on evidence that had just been
    /// contradicted.
    private static func corroborated(_ status: State, transcriptTouchedAt touched: Date?) -> State {
        guard status == .working, let touched,
              -touched.timeIntervalSinceNow > workCorroborationWindow
        else { return status }
        return .idle
    }

    /// Ids the registry reported alive last time and does not report
    /// now: the process is gone. `.stale`, never `.done` — a killed
    /// session did not finish, and claiming an outcome this store
    /// cannot know is the kind of lie it does not tell anywhere else.
    /// A message still waiting in the outbox flips to undelivered
    /// rather than vanishing (EC-11).
    // MARK: Holding a tool call at the door

    /// Which calls the island is allowed to hold, one rule per line.
    /// Empty by default, so nothing about an existing install changes
    /// until someone asks for it, and a hook talking to an older
    /// Chalant is told "not interested" and gets out of the way.
    ///
    /// Deliberately its own policy rather than a mirror of Claude
    /// Code's. `PreToolUse` fires on every tool call and carries no way
    /// to know whether Claude Code was going to prompt, so the only
    /// honest thing to offer is "always ask me about these".
    ///
    /// Newline-separated rather than comma, because a pattern is
    /// allowed to contain a comma and a separator that can appear
    /// inside the thing it separates is a bug waiting for the first
    /// person who writes one.
    static let approvalRulesKey = "approvalRules"

    nonisolated static func approvalRules(in defaults: UserDefaults = .standard) -> [String] {
        (defaults.string(forKey: approvalRulesKey) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Whether one rule wants to hold one call.
    ///
    /// `Bash` holds every Bash call. `Bash(rm *)` holds only the ones
    /// whose command starts with `rm`. That is Claude Code's own
    /// permission-rule shape, on purpose: it is already in these users'
    /// settings files and already in their heads, and a second syntax
    /// for the same idea is a second thing to be wrong about.
    ///
    /// Gating by tool name alone is what made the first version of this
    /// unlivable. An agent runs dozens of `ls` and `grep` calls for
    /// every `rm`, and holding all of them to catch one means approving
    /// so much that you stop reading.
    nonisolated static func rule(_ rule: String, holds tool: String, _ detail: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
            return trimmed == tool
        }
        guard trimmed[trimmed.startIndex..<open] == tool else { return false }
        let pattern = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        return glob(pattern, matches: detail)
    }

    /// `*` stands for any run of characters, and nothing else does
    /// anything. No regex: these rules are typed by hand into a small
    /// field, and a language where a stray `.` or `?` quietly changes
    /// what gets held is the wrong language for deciding whether a
    /// command runs.
    nonisolated static func glob(_ pattern: String, matches text: String) -> Bool {
        // "git *" holds a bare "git" too, the way Claude Code's own
        // rules do: the space-star means "and anything after", not
        // "and something after".
        if pattern.hasSuffix(" *"), text == String(pattern.dropLast(2)) { return true }
        // Iterative rather than recursive, so a pattern that is mostly
        // stars cannot take the stack with it.
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                star = pi; pi += 1; mark = ti
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: Not asking twice
    //
    // The way out of a broad hold rule — "Yes, and don't ask again for:
    // git *" — is a Grant now, in PolicyStore. It used to be a second
    // store here (UserDefaults "exceptions", global and forever), which
    // meant the island's Always allow button and the approval card's
    // timed grants wrote to different places and only one of them was
    // ever consulted per pipeline. `PolicyStore.migrateLegacyExceptions`
    // moved the old key's contents into grants on first launch.

    /// The rule an "always allow this" button would write, in the same
    /// words the button says.
    ///
    /// Generalises a shell command to its first word, which is what
    /// Claude Code's own suggestion does ("git --version" offers
    /// "git *"). It refuses to generalise anything that is not a plain
    /// command name: a path, a pipe, an && chain, a variable. Widening
    /// `./scripts/deploy.sh prod` to `./*` would quietly hand over far
    /// more than the person reading the button agreed to, and a rule
    /// somebody did not understand is a rule that is not consent.
    nonisolated static func suggestedException(tool: String, detail: String) -> String {
        let command = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tool == "Bash" || tool == "BashOutput", !command.isEmpty else { return tool }
        // A chained or redirected command is not named by its first
        // word. "rm -rf / && echo done" starts with `rm`, and offering
        // "always allow rm *" for it would be reading somebody the first
        // clause of a sentence and asking them to sign the paragraph.
        guard !command.contains(where: { "&|;><`$()\n".contains($0) }) else {
            return "\(tool)(\(command))"
        }
        guard let first = command.split(separator: " ").first.map(String.init),
              first.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              first.count < command.count
        else { return "\(tool)(\(command))" }
        return "\(tool)(\(first) *)"
    }

    /// The rules a fresh install is offered, not the rules it gets.
    /// Every one of these is a thing that is hard to take back: it
    /// leaves the machine, rewrites history, or deletes something.
    nonisolated static let suggestedApprovalRules = [
        "Bash(rm *)",
        "Bash(sudo *)",
        "Bash(git push *)",
        "Bash(git reset --hard *)",
        "Bash(npm publish *)",
        "Bash(curl *)",
    ]

    /// Hold a tool call and light the row, or decline to.
    ///
    /// Declining is the common case and has to be cheap: a hook asks
    /// before every single tool call, and anything but an instant no
    /// here would put a pause on work nobody asked to supervise.
    ///
    /// Also declines when the session is unknown (nowhere to show it),
    /// and when one is already held for that session: two cards racing
    /// for the same row is worse than the second call falling through
    /// to the terminal, which is exactly what it did before any of this
    /// existed.
    func holdForApproval(
        sessionID: String, id: String, tool: String, detail: String,
        cwd: String? = nil, patience: TimeInterval = 600,
        rules: [String] = SessionStore.approvalRules()
    ) -> Bool {
        // Only the rules decide here. The way out of a broad rule — a
        // grant somebody made from an earlier card — is checked by the
        // caller (`settleGate`), where the policy store lives, before
        // this is ever reached.
        guard rules.contains(where: { Self.rule($0, holds: tool, detail) }) else { return false }
        return register(
            sessionID: sessionID, id: id, tool: tool, detail: detail, cwd: cwd,
            patience: patience)
    }

    /// A permission prompt Claude Code is putting on screen right now,
    /// with its own hook suspended inside this app waiting for an
    /// answer.
    ///
    /// No rules are consulted, and that is the point. The arming rules
    /// decide which calls to INTERRUPT, and this call was already
    /// interrupted: Claude Code decided it needs a person, and the
    /// person is being asked either way. Running it past the rules would
    /// mean the island stays silent about the one question that is
    /// definitely being asked, which is how 1.7.0 ended up reporting
    /// prompts it could not answer.
    func holdForPrompt(
        sessionID: String, id: String, tool: String, detail: String,
        cwd: String? = nil, patience: TimeInterval, agent: Agent = .claude
    ) -> Bool {
        register(
            sessionID: sessionID, id: id, tool: tool, detail: detail, cwd: cwd,
            patience: patience, alsoInTerminal: true, agent: agent)
    }

    /// The part both doors share: make a row if there is not one, vouch
    /// for it, and put the call on it.
    private func register(
        sessionID: String, id: String, tool: String, detail: String,
        cwd: String?, patience: TimeInterval, alsoInTerminal: Bool = false,
        agent: Agent = .claude
    ) -> Bool {
        // A session nobody has heard of, with a process standing in a
        // hook waiting on an answer.
        //
        // This used to be a dead end, and that was the gate's biggest
        // hole: a `claude -p` run leaves a transcript but never
        // registers in ~/.claude/sessions, so every headless agent on
        // the machine walked straight past a gate the user believed was
        // holding everything (found in the founder's own live test,
        // 2026-08-08).
        //
        // Making a row here is not the warm-file heresy it looks like.
        // The standing law is that a pid makes a session real and a file
        // does not; a hook mid-call is better than a pid, because it is
        // a process talking to this app in real time about something it
        // is doing this second. This file already says so where the hold
        // is recorded below.
        //
        // Only ever on a call that is actually held. Every tool call in
        // every session reaches this method, and inventing a row for all
        // of them would put every headless worker on the machine on the
        // rail, which is the thing `SessionRegistry.isHeadlessBot`
        // exists to prevent.
        if !sessions.contains(where: { $0.id == sessionID }) {
            sessions.append(Session(
                id: sessionID,
                title: cwd.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "An agent",
                cwd: cwd ?? "", branch: nil, lastPrompt: nil, activity: nil,
                agent: agent, state: .needsInput, ask: nil,
                // No pid and no terminal: nothing here has been checked,
                // and `hasTerminal` nil is the honest "nobody looked"
                // that keeps the composer's own rule working.
                pid: nil, kind: nil, startedAt: Date(), updatedAt: Date()
            ))
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        // Vouched for, by the strongest witness this store has. The
        // registry sweep lands every five seconds and would otherwise
        // file this row as lost while its agent is still at the door.
        sessions[index].vouchedByHookAt = Date()
        guard sessions[index].approval == nil else { return false }
        // A new call means the last prompt was answered: Claude Code
        // does not reach for another tool while standing at one.
        sessions[index].pendingPrompt = nil
        sessions[index].approval = Approval(
            id: id, tool: tool, detail: detail, askedAt: Date(), decision: nil,
            patience: patience, alsoInTerminal: alsoInTerminal)
        sessions[index].updatedAt = Date()
        // A held call is the strongest proof of life this store ever
        // gets: a `PreToolUse` hook is standing at the door right now,
        // in that process, waiting on an answer. It outranks the
        // registry, which reports on a sweep and can be a sweep behind,
        // and it certainly outranks a quiet transcript.
        //
        // Without this the room drew a session with a call held at the
        // door under "Finished" and its approval card was nowhere on
        // screen (observed 2026-08-03): the registry had lost the
        // process, the row was `.stale`, and an agent stood there until
        // its hook gave up. Whatever else is uncertain, a session asking
        // permission has not finished.
        disownedByRegistry.remove(sessionID)
        revive(sessionID)
        if !sessions[index].state.isLive { sessions[index].state = .needsInput }
        sort()
        return true
    }

    /// Told the instant somebody decides, so the agent suspended inside
    /// its hook is answered rather than left waiting on an answer
    /// nobody is going to deliver twice.
    var onDecided: ((String, Approval.Decision) -> Void)?

    func decide(approvalID: String, as decision: Approval.Decision) {
        guard let index = sessions.firstIndex(where: { $0.approval?.id == approvalID })
        else { return }
        sessions[index].approval?.decision = decision
        sessions[index].updatedAt = Date()
        onDecided?(approvalID, decision)
    }

    /// The answer landed somewhere that does not need collecting, so the
    /// card's work is done. Distinct from `abandonApproval` only in what
    /// it means; both take the card off the row.
    func clearApproval(id: String) {
        guard let index = sessions.firstIndex(where: { $0.approval?.id == id }) else { return }
        sessions[index].approval = nil
        sessions[index].updatedAt = Date()
    }

    /// The agent stopped waiting. Its hook timed out and the question
    /// went back to the terminal, so the card must go: a choice nobody
    /// is listening for any more is worse than no choice at all.
    func abandonApproval(id: String) {
        guard let index = sessions.firstIndex(where: { $0.approval?.id == id }) else { return }
        sessions[index].approval = nil
        sessions[index].updatedAt = Date()
    }

    /// The turn's closing words, straight off the Stop hook's own
    /// payload (`last_assistant_message`) rather than scraped from a
    /// transcript tail: the hook states what the assistant last said,
    /// where the scrape guessed at it and broke the day the format
    /// moved. This is what a finished row's summary is made of, and
    /// the words the came-to-rest announcement identifies a turn by.
    ///
    /// Bounded like everything else that arrives over the local API:
    /// this came from another process and lands in a one-line rail row.
    func noteLastWords(sessionID: String, _ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }
        sessions[index].lastMessage = String(trimmed.prefix(ActivityServer.maxDetail))
        sessions[index].updatedAt = Date()
    }

    /// Which application this session turned out to be running inside.
    ///
    /// Resolved once per session rather than per sweep: it means walking
    /// the whole process table, and a session does not change windows.
    /// The registry is the caller because it is the only thing that holds
    /// a pid.
    func noteOwningApp(id: String, bundleID: String, name: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].terminalApp = TerminalApp(bundleID: bundleID, name: name)
    }

    /// Every Claude Code session this store thinks is running, held
    /// against the registry's list of the ones that actually are.
    ///
    /// `markGone` answers "the registry used to report this and has
    /// stopped". This answers the case it never could: a session the
    /// registry has *never* reported, which discovery invented out of a
    /// warm transcript. That was the whole of the claude-mem indexer's
    /// hold on the strip.
    ///
    /// An empty list is not an answer. The registry directory is
    /// undocumented and a release that moves it would read as "nobody is
    /// running", which must cost a badge rather than empty the strip
    /// (the standing rule for this overlay). So the registry is only
    /// allowed to contradict discovery while it can show at least one
    /// session of its own.
    ///
    /// Claude Code only. Cursor keeps no such directory, so this
    /// registry has no standing to call a Cursor chat dead.
    func reconcileLive(against aliveIds: Set<String>) {
        guard !aliveIds.isEmpty else { return }
        let unvouched = sessions.filter {
            $0.agent == .claude && !aliveIds.contains($0.id) && !Self.isVouchedByHook($0)
        }
        disownedByRegistry.formUnion(unvouched.map(\.id))
        disownedByRegistry.subtract(aliveIds)
        disownedByRegistry.formIntersection(sessions.map(\.id))
        markGone(Set(unvouched.filter { $0.state.isLive }.map(\.id)))
    }

    /// How long a hook's word holds against a registry that has never
    /// heard of the session.
    ///
    /// Short on purpose. It covers a call being decided and the next one
    /// arriving, not an agent's whole afternoon: this is an exemption
    /// from the one rule that keeps dead rows off the rail, and an
    /// exemption nobody can outlive is just the rule repealed.
    static let hookVouchWindow: TimeInterval = 90

    nonisolated static func isVouchedByHook(_ session: Session) -> Bool {
        guard let at = session.vouchedByHookAt else { return false }
        return -at.timeIntervalSinceNow < hookVouchWindow
    }

    /// Age a vouch out immediately. Tests only: the window is wall-clock
    /// and this store deliberately holds no injectable clock, so the
    /// alternative is a test that sleeps for ninety seconds.
    func expireVouch(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].vouchedByHookAt = Date(timeIntervalSinceNow: -Self.hookVouchWindow - 1)
    }

    func markGone(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { continue }
            // Read before the write, and handed to `remember` rather
            // than checked here. The caller in `reconcile` already
            // filters to live ids, but this method is not private and a
            // second caller passing an already-dead id must not be able
            // to put a duplicate row in the record.
            let leaving = sessions[index].state
            sessions[index].pid = nil
            sessions[index].state = .stale
            sessions[index].updatedAt = Date()
            remember(sessions[index], leaving: leaving, as: .lost)
            failMessage(sessionID: id)
            announcedRest[id] = nil
            expiryWork[id]?.cancel()
            expiryWork[id] = nil
            onSessionGone?(id)
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

    /// Fired when a session stops working and comes to rest, which is
    /// the moment its turn ended and it is waiting on you.
    ///
    /// Not the same event as `onSessionWantsYou`: that one is a
    /// question, this one is an agent that simply finished. The founder
    /// wants both to reach them, since most turns end with an answer to
    /// read rather than a question to pick (2026-08-03).
    ///
    /// The transition is the event, never the state: a session sitting
    /// idle is idle on every rescan and every five second sweep, and
    /// firing on the state would announce the same finished turn
    /// forever.
    var onSessionCameToRest: ((_ id: String, _ title: String) -> Void)?

    /// The last words each session was already announced for, so the
    /// same finished turn is never announced twice.
    private var announcedRest: [String: String] = [:]

    /// One place decides what "came to rest" means, so the two writers
    /// that can move a session's state cannot drift on it.
    ///
    /// The transition alone was not enough, and the reason is worth
    /// keeping: two writers move a session's state. The registry sees a
    /// process sitting at its prompt and says idle; the scraper sees a
    /// transcript that was written to recently and says working. They
    /// disagree for a while after a turn ends, so the state flips back
    /// and forth and `working -> idle` happens several times for one
    /// finished turn. The island opened, collapsed and opened again
    /// while the founder was trying to type into it (2026-08-03).
    ///
    /// So the thing announced is the turn, identified by the last words
    /// it produced, not the edge. A new turn writes new words and is
    /// announced; the same turn flapping between two writers' opinions
    /// is announced once. A turn that ends with no text at all falls
    /// back to the state it landed in, which still collapses repeats
    /// because the value stops changing.
    private func noteTransition(from previous: State, to next: State, id: String, title: String) {
        guard previous == .working, next == .idle || next == .stale else { return }
        // A turn that ended a quarter of an hour ago is not news, and
        // announcing it is worse than saying nothing: the point of this
        // notification is "your agent just stopped, go and look".
        //
        // The case that made this necessary is launch. A session wearing a
        // day-old `busy` is believed for exactly as long as it takes
        // discovery to read its transcript, and the correction that
        // follows is a state change like any other. Without this, opening
        // the app announced a turn that had ended the previous morning.
        if let touched = sessions.first(where: { $0.id == id })?.transcriptTouchedAt,
           -touched.timeIntervalSinceNow > Self.workCorroborationWindow { return }
        let words = sessions.first { $0.id == id }?.lastMessage ?? "came to rest in \(next.rawValue)"
        guard announcedRest[id] != words else { return }
        announcedRest[id] = words
        onSessionCameToRest?(id, title)
    }

    /// Fired once per id in `markGone`, so anything keyed off the same
    /// session (the ActivityStore pill the Claude Code hook posts) can
    /// resolve itself instead of outliving the session it was about
    /// (H5). This store only ever says a session went `.stale`, never
    /// what became of whatever was waiting on it — that verdict belongs
    /// to whoever holds the other row.
    var onSessionGone: ((String) -> Void)?

    static let maxMessage = 2000
    /// A queue this deep is somebody holding the key down, not somebody
    /// with eight things to say.
    static let maxQueued = 8

    /// How long a queued message is trusted to still mean something.
    ///
    /// Persisting the outbox with no limit would be the exact failure
    /// the original decision to lose it on quit was avoiding (EC-9): a
    /// message typed Monday, injected into a turn on Thursday, when the
    /// person who wrote it has moved on and the agent has no way to
    /// know the instruction is stale. Twenty minutes, the founder's own
    /// suggestion, covers "Chalant relaunched between typing and the
    /// agent's next turn boundary," the case that was costing real
    /// messages, without covering "I stepped away for the afternoon."
    /// Measured from `queuedAt`, never from when this app happened to
    /// load the file: reopening Chalant does not refresh the clock on a
    /// message that was already stale, and a message queued and left
    /// untouched in a still-running app ages out on the same clock a
    /// restored one does, one rule, not two.
    static let outboxExpiry: TimeInterval = 20 * 60

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
        saveOutbox()
        return true
    }

    /// Drop one queued message without sending it.
    func cancelMessage(id: String, for sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].outbox?.pending.removeAll { $0.id == id }
        if sessions[index].outbox?.pending.isEmpty == true {
            sessions[index].outbox = nil
        }
        saveOutbox()
    }

    /// The user re-confirmed a message that aged out before a turn
    /// boundary came to collect it: its clock restarts here, exactly as
    /// if just typed, so the next boundary can hand it over. Only ever
    /// reached from the card's own "Send now" button, never automatic,
    /// because aging out is silent by nature and un-aging it should not be.
    func resendMessage(id: String, for sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let msgIndex = sessions[index].outbox?.pending.firstIndex(where: { $0.id == id })
        else { return }
        sessions[index].outbox?.pending[msgIndex].queuedAt = Date()
        saveOutbox()
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
    ///
    /// Refuses the head once it is `isExpired`, whether it rode out a
    /// relaunch or just aged out in a still-running app: this is the
    /// other half of persisting the outbox at all. Handing over a stale
    /// instruction silently is precisely the failure a lost message used
    /// to avoid by disappearing instead. The queue stays put, in order,
    /// until the card's own resend or drop resolves the head.
    func collectMessage(sessionID: String) -> String? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              var outbox = sessions[index].outbox,
              !outbox.undelivered,
              !outbox.pending.isEmpty,
              !outbox.pending[0].isExpired
        else { return nil }
        let next = outbox.pending.removeFirst()
        outbox.deliveredAt = Date()
        sessions[index].outbox = outbox
        saveOutbox()
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
        saveOutbox()
    }

    /// Drops whatever is in a session's outbox — queued, delivered or
    /// undelivered — so a composer can dismiss a card once its message
    /// has been seen.
    func clearMessage(sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].outbox = nil
        saveOutbox()
    }

    // MARK: Outbox persistence

    /// Same shape `ClipboardStore` uses: one JSON file under Application
    /// Support, written atomically so a crash mid-write cannot leave a
    /// torn file, read back with a graceful fallback to empty rather
    /// than a crash on anything that fails to parse. Not `private`:
    /// production passes this explicitly to opt in (see `outboxDir`).
    static func defaultOutboxDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chalant/Outbox", isDirectory: true)
    }

    /// Nil when this store was built with no `outboxDirectory`, which
    /// means persistence is off: nothing to read, nothing to write.
    private func outboxFile() -> URL? {
        guard let outboxDir else { return nil }
        try? FileManager.default.createDirectory(at: outboxDir, withIntermediateDirectories: true)
        return outboxDir.appendingPathComponent("outbox.json")
    }

    /// What a file read from disk is allowed to inject: exactly what
    /// `queue(message:for:)` already allows a message typed into the
    /// composer, no more. This file was never in front of the composer
    /// and this app did not write every byte of it: a hand-edited or
    /// corrupted entry must not be able to push oversized, control-
    /// character-laden, or arbitrarily deep text into an agent's
    /// context. Oversized text is dropped outright, same as a live
    /// queue refuses it, never silently truncated (EC-16); depth beyond
    /// `maxQueued` is dropped from the tail, the same limit a live queue
    /// enforces one message at a time.
    private static func boundedPending(_ raw: [QueuedMessage]) -> [QueuedMessage] {
        Array(raw.compactMap { message -> QueuedMessage? in
            let cleaned = sanitizeMessage(message.text)
            guard !cleaned.isEmpty, cleaned.count <= maxMessage else { return nil }
            return QueuedMessage(id: message.id, text: cleaned, queuedAt: message.queuedAt)
        }.prefix(maxQueued))
    }

    /// Reads whatever survived the last launch into `restoredOutbox`,
    /// bounded exactly as a live message would be. Nothing here attaches
    /// to a `Session` row yet: there are none at `init`, that only
    /// happens once `upsert` or `markLive` rediscovers the same id.
    private func loadOutbox() {
        guard let file = outboxFile(), let data = try? Data(contentsOf: file) else { return }
        guard let decoded = try? JSONDecoder().decode([String: Outbox].self, from: data) else {
            Self.log.error("outbox failed to decode, starting empty")
            return
        }
        for (id, outbox) in decoded {
            let bounded = Self.boundedPending(outbox.pending)
            guard !bounded.isEmpty else { continue }
            var restored = outbox
            restored.pending = bounded
            restoredOutbox[id] = restored
        }
    }

    /// Rewrites the whole file on every change, same as
    /// `ClipboardStore.saveIndex`, fine at the size an outbox reaches.
    /// Persists every live session's non-empty outbox, plus whatever in
    /// `restoredOutbox` has not yet been reattached to a rediscovered
    /// session, so a message from a session that has not reappeared yet
    /// this launch is not dropped out of the file just because some
    /// other session's outbox changed.
    private func saveOutbox() {
        guard let file = outboxFile() else { return }
        var toSave = restoredOutbox
        for session in sessions where session.outbox?.pending.isEmpty == false {
            toSave[session.id] = session.outbox
        }
        do {
            let data = try JSONEncoder().encode(toSave)
            try data.write(to: file, options: .atomic)
        } catch {
            Self.log.error("outbox failed to save: \(error, privacy: .public)")
        }
    }
}
