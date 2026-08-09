import Foundation
import Network
import os
import Security

/// The open door: a tiny HTTP server on localhost that lets any local
/// process push a status pill onto the island. Claude Code hooks,
/// build scripts, cron jobs, download watchers; one curl and the
/// island knows. Loopback only, nothing ever leaves the machine.
///
///   T=$(cat ~/Library/Application\ Support/Chalant/api-token)
///   curl -s localhost:4242/activity -H "X-Chalant-Token: $T" \
///        -d '{"id":"deploy","title":"Deploying site","state":"working"}'
///   curl -s localhost:4242/activities -H "X-Chalant-Token: $T"
///   curl -s -X DELETE localhost:4242/activity/deploy -H "X-Chalant-Token: $T"
///
/// States: working · needs-input · done · failed. Port configurable
/// via `defaults write com.cj.chalant activityPort -int <port>`.
///
/// The token exists because loopback is not a wall. Every process on
/// the machine can reach this port, including other logged-in accounts,
/// and "anything on your Mac can put a pill on the island" also meant
/// anything could put a convincing one there: a needs-input row sorts
/// to the top and wears the app's own chrome, which is a good place to
/// ask somebody for a password. Reading was worth closing too, since
/// the list names whatever your tooling is doing. It is a file anyone
/// who is already you can read, so it stops impersonation, not you.
final class ActivityServer: @unchecked Sendable {
    private var listener: NWListener?
    private weak var store: ActivityStore?
    private let queue = DispatchQueue(label: "chalant.activity.server")

    static var port: UInt16 {
        let configured = UserDefaults.standard.integer(forKey: "activityPort")
        return configured > 0 ? UInt16(clamping: configured) : 4242
    }

    static let tokenHeader = "x-chalant-token:"

    /// Claude Code's HTTP hooks send `Authorization: Bearer <token>` and
    /// have no way to send anything else, so the same door has to answer
    /// to both names. The scripted callers (`chalant`, `chalant-hook`,
    /// every curl in this file's header) keep the header they have
    /// always used.
    static let bearerHeader = "authorization:"

    static var tokenURL: URL {
        support.appendingPathComponent("api-token")
    }

    /// Where the resolved port and token are published, so a hook does
    /// not have to guess either. The port is only 4242 until something
    /// else is already on 4242.
    static var configURL: URL {
        support.appendingPathComponent("server.json")
    }

    static var support: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Chalant")
    }

    /// Minted once and kept at 0600. Read fresh rather than cached so
    /// deleting the file and relaunching is a working revoke.
    static func loadOrCreateToken() -> String {
        let url = tokenURL
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let minted = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
            ? Data(bytes).base64EncodedString()
            : UUID().uuidString + UUID().uuidString
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? minted.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        return minted
    }

    /// Length-first, then every byte: an early return on the first
    /// mismatch would time the answer.
    static func tokenMatches(_ offered: String, _ expected: String) -> Bool {
        let a = Array(offered.utf8), b = Array(expected.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static let log = Logger(subsystem: "com.cj.chalant", category: "activityserver")

    /// Held so a session's question can be answered from the island and
    /// collected by the agent that asked it.
    private var sessions: SessionStore?

    private var token = ""

    /// The agents suspended inside a hook request right now, each one
    /// waiting on an answer this app has not given yet.
    let gate = PendingDecisionStore()

    /// The grants, and the account of everything settled without anybody
    /// being asked.
    private var policy: PolicyStore?

    /// The ports this app will try, in order. 4242 is the one every
    /// hook and script already installed on this machine knows by
    /// heart, so it stays first and stays the answer in every ordinary
    /// case; the rest only matter when something else got there first.
    static func portCandidates(from preferred: UInt16 = port) -> [UInt16] {
        [preferred] + (1...10).compactMap { step in
            let next = Int(preferred) + step
            return next <= Int(UInt16.max) ? UInt16(next) : nil
        }
    }

    private let lock = NSLock()
    private var openPort: UInt16?

    /// The port the door actually opened on. Nil until a listener has
    /// reached `.ready`, which is the only moment either fact is known.
    var resolvedPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return openPort
    }

    /// Touched only on `queue`, which is serial and is also where every
    /// state update lands.
    private var remainingPorts: [UInt16] = []

    @MainActor
    func start(store: ActivityStore, sessions: SessionStore? = nil,
               policy: PolicyStore? = nil) {
        self.store = store
        self.sessions = sessions
        self.policy = policy
        token = Self.loadOrCreateToken()
        // A tap on the island reaching an agent suspended inside a hook.
        // `resolve` returning false means nobody was waiting on that id
        // over HTTP, which is the ordinary case for a call held by the
        // polling shim: that one collects its own answer on its own
        // schedule, so the card has to stay put for it.
        sessions?.onDecided = { [weak self] id, decision in
            guard let self else { return }
            Task { await self.gate.resolve(id, as: decision == .allow ? .allow : .deny) }
        }
        queue.async { [self] in
            remainingPorts = Self.portCandidates()
            bindNext()
        }
    }

    /// Tries candidates until one opens.
    ///
    /// It has to be a walk rather than a loop because NWListener reports
    /// a taken port asynchronously, not from the initializer: the whole
    /// reason the state handler exists is that a second instance used to
    /// leave the door dead while the app looked perfectly healthy, and
    /// every `chalant` command failed with nothing anywhere saying why.
    private func bindNext() {
        guard !remainingPorts.isEmpty else {
            Self.log.error(
                "activity door could not be opened on any port from \(Self.port); nothing local can reach Chalant")
            return
        }
        let candidate = remainingPorts.removeFirst()
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: candidate) else {
            bindNext()
            return
        }
        // Bound to 127.0.0.1 itself, not to the wildcard with a
        // loopback interface asked for politely alongside it. Those are
        // not the same thing and `lsof` says so: the shipped 1.7.1
        // listens on `*:4242`, which is a socket on every interface the
        // machine has, kept honest only by the interface requirement
        // above. Naming the local endpoint makes the kernel the one
        // enforcing it, so a wrong assumption about `requiredInterfaceType`
        // cannot quietly put this port on the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do {
            // No `on:` here. The port is already named by the required
            // local endpoint above, and giving it twice leaves a
            // listener that never reaches `.ready` and never reports a
            // failure either: no socket, no log line, and an app that
            // looks perfectly healthy while nothing local can reach it.
            // That is the exact symptom this file's state handler was
            // written for, arrived at from the opposite direction.
            listener = try NWListener(using: parameters)
        } catch {
            Self.log.error(
                "activity door could not be opened on \(candidate): \(error.localizedDescription, privacy: .public)")
            bindNext()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                lock.lock()
                openPort = candidate
                lock.unlock()
                publish(port: candidate)
                Self.log.notice("activity door open on \(candidate)")
            case .failed(let error):
                Self.log.error(
                    "activity door failed on \(candidate): \(error.localizedDescription, privacy: .public). Trying the next port.")
                listener.cancel()
                if self.listener === listener { self.listener = nil }
                bindNext()
            case .cancelled:
                Self.log.notice("activity door closed")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Publish the port and the token together, so a hook has to read
    /// exactly one file to reach this app and can never hold a fresh
    /// token against a stale port.
    private func publish(port: UInt16) {
        let payload: [String: Any] = ["port": Int(port), "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? FileManager.default.createDirectory(
            at: Self.support, withIntermediateDirectories: true)
        let url = Self.configURL
        try? data.write(to: url, options: .atomic)
        // After the write, never before: an atomic write lands a new
        // file, and a new file arrives with the umask's permissions
        // rather than the ones the old one had. This file names the
        // token, so 0600 is the point of it.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        // An installed hook carries this app's address inside somebody
        // else's config file, where it will sit until it is rewritten.
        // If the port moved because something else had 4242, every
        // prompt would post into a closed door and the island would go
        // quiet with nothing anywhere saying why. Only ever a refresh of
        // an entry that is already there: this never arms anybody.
        guard HookInstall.answersPrompts() else { return }
        HookInstall.armPrompts(port: port, token: token)
    }

    func stop() {
        lock.lock()
        openPort = nil
        lock.unlock()
        // On `queue` because that is where every other write to these
        // two lands, and quit is the one moment this can be called from
        // somewhere else.
        queue.async { [self] in
            remainingPorts = []
            listener?.cancel()
            listener = nil
        }
    }

    /// Whether a connection got as far as a whole request. Touched only
    /// on `queue`, which is serial and is where both writers live.
    private final class Arrival {
        var routed = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that opens a socket and never finishes its header
        // block would pin the connection and its buffer forever
        // (review-caught). Five seconds is a lifetime for a loopback
        // request of a few hundred bytes.
        //
        // It is a deadline on ARRIVING, not on being answered. A held
        // tool call is a whole request that arrived in a millisecond and
        // is then deliberately left unanswered for as long as it takes
        // somebody to decide, which is minutes. Cancelling those at five
        // seconds would have made the entire gate a slightly slower way
        // of doing nothing.
        let arrival = Arrival()
        queue.asyncAfter(deadline: .now() + 5) { [weak connection] in
            guard !arrival.routed else { return }
            connection?.cancel()
        }
        receive(connection, buffer: Data(), arrival: arrival)
    }

    /// Accumulate until the header block and Content-Length body are
    /// whole; requests here are a few hundred bytes, one read usually
    /// does it.
    private func receive(_ connection: NWConnection, buffer: Data, arrival: Arrival) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var data = buffer
            if let chunk { data.append(chunk) }
            guard data.count <= Self.maxBody else {
                self.respond(connection, status: "413 Payload Too Large", body: #"{"ok":false}"#)
                return
            }
            if let request = Self.parse(data) {
                arrival.routed = true
                self.route(request, on: connection)
            } else if complete {
                self.respond(connection, status: "400 Bad Request", body: #"{"ok":false}"#)
            } else {
                self.receive(connection, buffer: data, arrival: arrival)
            }
        }
    }

    /// The largest request the server will hold in memory, and the
    /// ceiling every declared Content-Length is measured against.
    static let maxBody = 512 * 1024

    /// A pill is a glance, not a document. These are the widest a
    /// caller's strings can be before they are cut.
    static let maxTitle = 200
    static let maxDetail = 400
    static let maxID = 128

    /// Hold a caller's strings to a width a pill can lay out. The body
    /// cap is half a megabyte and all of it could arrive as one
    /// unbroken line; the row count was bounded and the strings were
    /// not. An absent or empty id falls back to the title, itself cut
    /// to id width so the fallback cannot smuggle a longer key in.
    static func capped(
        title rawTitle: String, detail rawDetail: String?, id rawID: String?
    ) -> (title: String, detail: String?, id: String) {
        let title = String(rawTitle.prefix(maxTitle))
        let id = rawID.flatMap { $0.isEmpty ? nil : String($0.prefix(maxID)) }
            ?? String(title.prefix(maxID))
        return (title, rawDetail.map { String($0.prefix(maxDetail)) }, id)
    }

    struct Request {
        var method: String
        var path: String
        var body: Data
        /// A browser attaches Origin to every cross-site fetch; a curl
        /// or a build script never does. Its mere presence marks a
        /// request that came from a web page, which has no business
        /// pushing pills onto the island (a site you visit could
        /// otherwise spoof one). Mutating routes refuse it.
        var fromBrowser: Bool
        /// Whatever the caller offered, verified against the real one
        /// by route(), which is the only place that holds it.
        var offeredToken: String
    }

    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.components(separatedBy: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let fromBrowser = lines.contains {
            let lower = $0.lowercased()
            return lower.hasPrefix("origin:") || lower.hasPrefix("sec-fetch-mode:")
        }
        // A header carries at most one value; splitting on the FIRST
        // colon and taking the tail is crash-proof where index [1] was
        // not: "Content-Length:" with an empty value once trapped and
        // took the whole app down (review-caught, reproduced). A
        // missing or unparseable value reads as zero.
        let contentLength = lines
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                return Int(value)
            } ?? 0
        // Int() accepts a sign, so "-1" parsed cleanly and then sailed
        // past a guard written for non-negative lengths; prefix() traps
        // on a negative, so one line of nc from any local process took
        // the whole app down. The cap is the same one receive() holds
        // the buffer to, so a length no body could ever satisfy is
        // refused here rather than waited on.
        guard contentLength >= 0, contentLength <= Self.maxBody else { return nil }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return Request(
            method: parts[0], path: parts[1],
            body: Data(body.prefix(contentLength)), fromBrowser: fromBrowser,
            offeredToken: offeredToken(in: lines)
        )
    }

    /// A header carries at most one value, and splitting on the FIRST
    /// colon is what makes an empty one read as empty rather than trap
    /// (the crash this file already paid for once, at Content-Length).
    static func headerValue(_ name: String, in lines: [String]) -> String? {
        lines
            .first { $0.lowercased().hasPrefix(name) }
            .flatMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    /// Whichever of the two headers the caller brought. The scheme word
    /// is matched case-insensitively because it is Claude Code writing
    /// it, not this app, and an `Authorization` carrying anything other
    /// than Bearer reads as no token at all rather than as its own tail.
    static func offeredToken(in lines: [String]) -> String {
        if let direct = headerValue(tokenHeader, in: lines), !direct.isEmpty {
            return direct
        }
        guard let offered = headerValue(bearerHeader, in: lines) else { return "" }
        let scheme = "bearer "
        guard offered.count > scheme.count,
              offered.prefix(scheme.count).lowercased() == scheme
        else { return "" }
        return String(offered.dropFirst(scheme.count))
            .trimmingCharacters(in: .whitespaces)
    }

    private func route(_ request: Request, on connection: NWConnection) {
        // A web page can reach a loopback port, but it must never move
        // the island. Reading (GET) is already walled off by the
        // browser's own same-origin policy; the writing routes refuse
        // anything wearing browser headers outright.
        //
        // Three GETs are writes in disguise: `/outbox/<id>`, `/ask/<id>`
        // and `/permission/<id>` each hand over something exactly once
        // and clear it in the same breath, so a page that guessed an id
        // could otherwise consume a queued message, a pending answer, or
        // an authorisation that was never meant for it. All three need
        // the real token too, but this is the second wall, not the only
        // one (EC-14).
        let consumesGET = request.method == "GET"
            && (request.path.hasPrefix("/outbox/") || request.path.hasPrefix("/ask/")
                || request.path.hasPrefix("/permission/"))
        if request.fromBrowser, request.method != "GET" || consumesGET {
            respond(connection, status: "403 Forbidden",
                    body: #"{"ok":false,"error":"cross-origin writes refused"}"#)
            return
        }
        // Kept after the browser check so a web page still gets told it
        // is the wrong kind of caller rather than being handed a hint
        // about what a right one would carry.
        guard Self.tokenMatches(request.offeredToken, token) else {
            respond(connection, status: "401 Unauthorized",
                    body: #"{"ok":false,"error":"send X-Chalant-Token or Authorization: Bearer, see ~/Library/Application Support/Chalant/server.json"}"#)
            return
        }
        switch (request.method, request.path) {
        case ("POST", "/activity"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let rawTitle = object["title"] as? String, !rawTitle.isEmpty
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need title"}"#)
                return
            }
            let (title, detail, id) = Self.capped(
                title: rawTitle,
                detail: object["detail"] as? String,
                id: object["id"] as? String
            )
            let raw = (object["state"] as? String ?? "working").lowercased()
            if raw == "clear" {
                Task { @MainActor in self.store?.clear(id: id) }
                respond(connection, status: "200 OK", body: #"{"ok":true}"#)
                return
            }
            guard let state = ActivityStore.State(rawValue: raw) else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"state is working|needs-input|done|failed|clear"}"#)
                return
            }
            Task { @MainActor in
                self.store?.push(id: id, title: title, detail: detail, state: state)
            }
            respond(connection, status: "200 OK", body: #"{"ok":true}"#)

        // The other half of a session's question. The agent posts what
        // it wants to know, then polls /ask/<session> until an answer
        // appears — the island cannot reach into a running agent, so the
        // agent has to come and collect.
        case ("POST", "/ask"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let session = object["session"] as? String, !session.isEmpty,
                  let question = object["question"] as? String, !question.isEmpty
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need session and question"}"#)
                return
            }
            let askID = object["id"] as? String ?? UUID().uuidString
            let header = object["header"] as? String ?? "Question"
            let options = (object["options"] as? [String]) ?? []
            let multi = object["multiSelect"] as? Bool ?? false
            Task { @MainActor in
                let attached = self.sessions?.attach(
                    askID: askID, to: session, header: header, question: question,
                    options: options, multiSelect: multi
                ) ?? false
                // A question for a session Chalant has never seen has
                // nowhere to appear; saying so beats accepting it and
                // leaving the agent polling an answer that never comes.
                self.respond(
                    connection,
                    status: attached ? "200 OK" : "404 Not Found",
                    body: attached ? #"{"ok":true}"# : #"{"ok":false,"error":"no such session"}"#
                )
            }

        // Queue a message for a session, the same thing the island's
        // composer does. It exists because everything else in this app
        // can be driven from a terminal and checked, and this could
        // not: the only way to prove a message reaches a running agent
        // was to type one by hand and watch, which also means a test
        // costs somebody their real message (2026-08-02).
        case ("POST", "/outbox"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let session = object["session"] as? String, !session.isEmpty,
                  let message = object["message"] as? String, !message.isEmpty
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need session and message"}"#)
                return
            }
            Task { @MainActor in
                // `queue` does the bounding: it refuses a session that
                // has ended, one that cannot receive, and anything past
                // the cap. Refusing loudly here beats accepting and
                // dropping, which is the failure this whole feature
                // keeps being about.
                let queued = self.sessions?.queue(message: message, for: session) ?? false
                self.respond(
                    connection,
                    status: queued ? "200 OK" : "404 Not Found",
                    body: queued
                        ? #"{"ok":true}"#
                        : #"{"ok":false,"error":"no such session, or the message was refused"}"#
                )
            }

        // Claude Code is standing at its own permission prompt, in its
        // own terminal, right now.
        //
        // Reported rather than held: nothing here can answer it (proven
        // 2026-08-06, a decision returned on `PermissionRequest` is
        // ignored). The value is that this arrives with no setup at all,
        // from the `Notification` hook that is already installed, and it
        // arrives for agents inside editors this app cannot type into,
        // which is where the founder actually works.
        case ("POST", "/prompt"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let session = object["session"] as? String, !session.isEmpty
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need session"}"#)
                return
            }
            let tool = object["tool"] as? String ?? ""
            let detail = object["detail"] as? String ?? ""
            Task { @MainActor in
                self.sessions?.notePendingPrompt(sessionID: session, tool: tool, detail: detail)
                self.respond(connection, status: "200 OK", body: #"{"ok":true}"#)
            }

        // The prompt is over: the turn ended, or the agent moved on.
        case ("DELETE", let path) where path.hasPrefix("/prompt/"):
            let session = String(path.dropFirst("/prompt/".count)).removingPercentEncoding ?? ""
            Task { @MainActor in
                self.sessions?.clearPendingPrompt(sessionID: session)
                self.respond(connection, status: "200 OK", body: #"{"ok":true}"#)
            }

        // A tool call at the door. The one route in this app that can
        // change what a running agent does, so it answers the common
        // case first and fastest: "not interested", which is what every
        // ungated tool gets, in one loopback round trip and no wait.
        //
        // Only a `gate: true` answer means the hook should stand there
        // and poll. Anything else, including this app not running at
        // all, and the call goes to Claude Code's own permission layer
        // exactly as it always did.
        case ("POST", "/permission"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let session = object["session"] as? String, !session.isEmpty,
                  let id = object["id"] as? String, !id.isEmpty,
                  let tool = object["tool"] as? String, !tool.isEmpty
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need session, id and tool"}"#)
                return
            }
            let detail = object["detail"] as? String ?? ""
            // Only used when this session has no row yet, which happens
            // for anything headless: it is the only name such a row will
            // ever have. Ignored entirely for a session already on the
            // rail, whose folder came from a source that checked it.
            let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
            Task { @MainActor in
                let held = self.sessions?.holdForApproval(
                    sessionID: session, id: id, tool: tool, detail: detail, cwd: cwd) ?? false
                self.respond(
                    connection, status: "200 OK",
                    body: held ? #"{"ok":true,"gate":true}"# : #"{"ok":true,"gate":false}"#)
            }

        // The hook standing at the door, asking whether it may come in
        // yet. `null` means still waiting; the hook keeps polling until
        // its own patience runs out, then withdraws the card itself.
        case ("GET", let path) where path.hasPrefix("/permission/"):
            let id = String(path.dropFirst("/permission/".count)).removingPercentEncoding ?? ""
            Task { @MainActor in
                guard let decision = self.sessions?.collectDecision(approvalID: id) else {
                    self.respond(connection, status: "200 OK",
                                 body: #"{"ok":true,"decision":null}"#)
                    return
                }
                self.respond(connection, status: "200 OK",
                             body: #"{"ok":true,"decision":"\#(decision.rawValue)"}"#)
            }

        // What is being held right now, and deciding it from outside the
        // island. Here for the same reason `/outbox` is: everything else
        // in this app can be driven from a terminal and checked, and a
        // feature whose only proof is a person clicking a button is a
        // feature nobody can test without spending somebody's real
        // authorisation on it.
        case ("GET", "/permissions"):
            Task { @MainActor in
                let held = (self.sessions?.sessions ?? []).compactMap { session -> [String: Any]? in
                    guard let approval = session.approval, approval.decision == nil else { return nil }
                    return [
                        "id": approval.id, "session": session.id,
                        "tool": approval.tool, "detail": approval.detail,
                    ]
                }
                let body = (try? JSONSerialization.data(
                    withJSONObject: ["ok": true, "held": held]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":true,"held":[]}"#
                self.respond(connection, status: "200 OK", body: body)
            }

        case ("PUT", let path) where path.hasPrefix("/permission/"):
            let id = String(path.dropFirst("/permission/".count)).removingPercentEncoding ?? ""
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let raw = object["decision"] as? String,
                  let decision = SessionStore.Approval.Decision(rawValue: raw)
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need decision: allow or deny"}"#)
                return
            }
            Task { @MainActor in
                self.sessions?.decide(approvalID: id, as: decision)
                self.respond(connection, status: "200 OK", body: #"{"ok":true}"#)
            }

        // The hook gave up and handed the question back to the terminal.
        // The card goes with it: a choice nobody is listening for is a
        // button that does nothing.
        case ("DELETE", let path) where path.hasPrefix("/permission/"):
            let id = String(path.dropFirst("/permission/".count)).removingPercentEncoding ?? ""
            Task { @MainActor in
                self.sessions?.abandonApproval(id: id)
                self.respond(connection, status: "200 OK", body: #"{"ok":true}"#)
            }

        case ("GET", let path) where path.hasPrefix("/ask/"):
            let session = String(path.dropFirst("/ask/".count)).removingPercentEncoding ?? ""
            Task { @MainActor in
                guard let ask = self.sessions?.pendingAsk(sessionID: session) else {
                    self.respond(connection, status: "404 Not Found",
                                 body: #"{"ok":false,"error":"no question outstanding"}"#)
                    return
                }
                // A bundled ask (several questions in one `AskUserQuestion`
                // call) is only ever resolved through the outbox, one
                // queued message once every question in it is done —
                // never through this route. Reporting one "answered" here
                // before all of them are would hand a hook polling for a
                // single pick a half-filled one, and this shape has only
                // ever meant one question's answer. So this only ever
                // resolves the scripted `chalant ask` shape: exactly one.
                guard ask.questions.count == 1, let answer = ask.answer else {
                    self.respond(connection, status: "200 OK", body: #"{"ok":true,"answered":false}"#)
                    return
                }
                // Handed over exactly once: the agent has it now, and a
                // question already answered must stop being offered.
                self.sessions?.clearAsk(sessionID: session)
                let body = (try? JSONSerialization.data(
                    withJSONObject: ["ok": true, "answered": true, "answer": answer]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":true,"answered":false}"#
                self.respond(connection, status: "200 OK", body: body)
            }

        // The outbox's other half: a Stop hook comes to collect
        // whatever the user left for this session, exactly the same
        // shape as /ask/<session> above — the island cannot reach into
        // a running agent, so the agent has to come and collect.
        case ("GET", let path) where path.hasPrefix("/outbox/"):
            let session = String(path.dropFirst("/outbox/".count)).removingPercentEncoding ?? ""
            Task { @MainActor in
                // Collected once: read, clear, respond, in that order,
                // the same ordering clearAsk gets above, so a Stop hook
                // that fires twice cannot hand the model the same
                // instruction twice (EC-7).
                let message = self.sessions?.collectMessage(sessionID: session)
                let body = (try? JSONSerialization.data(
                    withJSONObject: ["ok": true, "message": (message ?? NSNull()) as Any]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":true,"message":null}"#
                // Never a 404 for an empty outbox: this route is hit at
                // the end of every turn of every session on the
                // machine, and a 404 as the normal case would make a
                // real failure unreadable.
                self.respond(connection, status: "200 OK", body: body)
            }

        // An agent standing inside its own hook, waiting on this app.
        //
        // Nothing polls here and nothing sleeps: the request arrives
        // whole, this handler returns, and the answer is written onto
        // the same connection whenever somebody decides, which may be
        // minutes later. What is suspended is one Swift task and one
        // agent process, and neither is holding a thread of this app's.
        //
        // Not answering at all is a supported outcome and the safest
        // one. A hook that hears nothing back before its own timeout
        // treats it as a non-blocking error and falls through to the
        // agent's own permission flow, which is exactly what happened
        // before any of this existed.
        case ("POST", "/hook/permission-request"):
            hold(request, on: connection, event: "PermissionRequest")

        // Every tool call, before there is a prompt to answer.
        //
        // This one never holds anything and never waits. It fires for
        // calls nobody asked to supervise, dozens per turn, so the only
        // acceptable shape is to decide in microseconds and get out of
        // the way. Silence is the answer almost every time, and silence
        // means the agent's own permission flow runs untouched.
        case ("POST", "/hook/pre-tool-use"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let call = HookPayload.call(from: object, fallbackID: UUID().uuidString)
            else {
                respond(connection, status: "200 OK", body: "")
                return
            }
            Task { @MainActor in
                let verdict = PolicyEngine.evaluate(
                    tool: call.tool, detail: call.detail, cwd: call.cwd,
                    grants: self.policy?.live() ?? [])
                self.respond(
                    connection, status: "200 OK", body: self.settle(verdict, for: call) ?? "")
            }

        // Deciding a held call from outside the island, and seeing what
        // is held. Here for the same reason `/outbox` and `/permissions`
        // are: a feature whose only proof is a person clicking a button
        // is a feature nobody can test without spending somebody's real
        // authorisation on it.
        case ("GET", "/debug/pending"):
            Task {
                let held = await self.gate.held.map { call in
                    [
                        "id": call.id, "session": call.sessionID, "tool": call.tool,
                        "detail": call.detail, "cwd": call.cwd, "event": call.event,
                        "permissionMode": call.permissionMode,
                        "askedAt": ISO8601DateFormatter().string(from: call.askedAt),
                    ]
                }
                let body = (try? JSONSerialization.data(
                    withJSONObject: ["ok": true, "held": held]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":true,"held":[]}"#
                self.respond(connection, status: "200 OK", body: body)
            }

        // What was settled without anybody being asked. Readable from a
        // terminal for the same reason `/permissions` is: an account
        // whose only surface is a settings page nobody has open is an
        // account nobody can check.
        case ("GET", "/debug/audit"):
            Task { @MainActor in
                let entries = (self.policy?.audit ?? []).prefix(100).map { entry in
                    [
                        "at": ISO8601DateFormatter().string(from: entry.at),
                        "tool": entry.tool, "detail": entry.detail, "folder": entry.folder,
                        "allowed": entry.allowed, "rule": entry.rule, "reason": entry.reason,
                    ] as [String: Any]
                }
                let body = (try? JSONSerialization.data(
                    withJSONObject: ["ok": true, "decided": entries]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":true,"decided":[]}"#
                self.respond(connection, status: "200 OK", body: body)
            }

        case ("POST", "/debug/resolve"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let id = object["id"] as? String, !id.isEmpty,
                  let raw = object["decision"] as? String,
                  let decision = Self.decision(named: raw)
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need id and decision: allow, deny or abstain"}"#)
                return
            }
            Task {
                // False means nobody was waiting on that id: it was
                // answered already, or its agent walked away. Reported
                // rather than swallowed, because "the button did
                // nothing" and "the button worked" must not look alike.
                let answered = await self.gate.resolve(id, as: decision)
                let body = (try? JSONSerialization.data(
                    withJSONObject: ["ok": true, "resolved": answered]
                )).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":true}"#
                self.respond(connection, status: "200 OK", body: body)
            }

        // Is anybody home, and which Chalant is it. Behind the token
        // like everything else: an unauthenticated liveness probe is
        // also an unauthenticated "is this app installed, and which
        // version" for anything on the machine that fancies knowing.
        case ("GET", "/health"):
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "0"
            let body = (try? JSONSerialization.data(
                withJSONObject: ["ok": true, "app": "Chalant", "version": version]
            )).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":true}"#
            respond(connection, status: "200 OK", body: body)

        case ("GET", "/activities"):
            Task { @MainActor in
                let list = (self.store?.activities ?? []).map { activity -> [String: Any] in
                    var entry: [String: Any] = [
                        "id": activity.id,
                        "title": activity.title,
                        "state": activity.state.rawValue,
                        "updatedAt": ISO8601DateFormatter().string(from: activity.updatedAt),
                    ]
                    if let detail = activity.detail { entry["detail"] = detail }
                    return entry
                }
                let body = (try? JSONSerialization.data(withJSONObject: list))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                self.respond(connection, status: "200 OK", body: body)
            }

        case ("DELETE", let path) where path.hasPrefix("/activity/"):
            let id = String(path.dropFirst("/activity/".count))
                .removingPercentEncoding ?? ""
            Task { @MainActor in self.store?.clear(id: id) }
            respond(connection, status: "200 OK", body: #"{"ok":true}"#)

        default:
            respond(connection, status: "404 Not Found", body: #"{"ok":false}"#)
        }
    }

    static func decision(named raw: String) -> GateDecision? {
        switch raw {
        case "allow": return .allow
        case "deny": return .deny
        case "abstain": return .abstain
        default: return nil
        }
    }

    /// Turn a verdict into the body of a `PreToolUse` answer, and write
    /// it down.
    ///
    /// Everything decided here was decided without asking anybody, which
    /// is exactly why it is all recorded. A gate that quietly answers on
    /// your behalf and keeps no account of it is not supervision.
    @MainActor
    private func settle(_ verdict: PolicyEngine.Verdict, for call: HeldCall) -> String? {
        switch verdict {
        case .silent:
            return nil
        case .allow(let rule, let reason):
            policy?.note(
                tool: call.tool, detail: call.detail, folder: call.cwd,
                allowed: true, rule: rule, reason: reason)
            return HookPayload.preToolUse(decision: "allow", reason: reason)
        case .ask(let rule, let reason):
            policy?.note(
                tool: call.tool, detail: call.detail, folder: call.cwd,
                allowed: false, rule: rule, reason: reason)
            // `ask` rather than `deny`, deliberately. This app's job at
            // this point is to make sure a person sees the question, not
            // to answer it for them in the other direction: a deny here
            // would take the choice away just as completely as an allow.
            return HookPayload.preToolUse(decision: "ask", reason: reason)
        }
    }

    /// Register a held call and answer whenever somebody decides.
    ///
    /// A payload this app cannot read is answered immediately with an
    /// empty 200, which means "no opinion" rather than approval. That is
    /// the common case by a wide margin and it costs one loopback round
    /// trip, because this fires for calls nobody asked to supervise.
    private func hold(_ request: Request, on connection: NWConnection, event: String) {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let call = HookPayload.call(from: object, fallbackID: UUID().uuidString)
        else {
            respond(connection, status: "200 OK", body: "")
            return
        }
        // However long the hook says it will wait, so the card counts
        // down the truth rather than a number this app made up. A hook
        // that sends no timeout is on Claude Code's default of 600.
        let patience = (object["timeout"] as? TimeInterval) ?? 600
        watchForHangup(connection, id: call.id)
        Task { [weak self] in
            guard let self else { return }
            // A grant is a person who already answered this exact
            // question in this exact folder, and it is the only thing
            // allowed to settle a prompt without showing it. The general
            // read-only list is not consulted here on purpose: Claude
            // Code has decided this call needs somebody, and a list of
            // commands this app thinks are boring has no business
            // overruling that.
            let granted = await MainActor.run { () -> String? in
                let verdict = PolicyEngine.evaluateGrantsOnly(
                    tool: call.tool, detail: call.detail, cwd: call.cwd,
                    grants: self.policy?.live() ?? [])
                guard case .allow(let rule, let reason) = verdict else { return nil }
                self.policy?.note(
                    tool: call.tool, detail: call.detail, folder: call.cwd,
                    allowed: true, rule: rule, reason: reason)
                return reason
            }
            if granted != nil {
                self.respond(
                    connection, status: "200 OK",
                    body: HookPayload.response(for: .allow, event: event) ?? "")
                return
            }
            // The card first, then the wait. A card that appeared after
            // the agent was already suspended would be a race with
            // nothing to win: the answer cannot arrive before the
            // question is on screen.
            let surfaced = await MainActor.run {
                self.sessions?.holdForPrompt(
                    sessionID: call.sessionID, id: call.id, tool: call.tool,
                    detail: call.detail, cwd: call.cwd.isEmpty ? nil : call.cwd,
                    patience: patience) ?? false
            }
            // Nowhere to show it, so nothing can answer it. Falling
            // straight through hands the question to the terminal, which
            // is where it already is.
            guard surfaced else {
                self.respond(connection, status: "200 OK", body: "")
                return
            }
            let decision = await gate.hold(call)
            await MainActor.run { self.sessions?.clearApproval(id: call.id) }
            // Nil is `.abstain`: an empty 200, and the agent's own
            // permission flow runs untouched.
            self.respond(
                connection, status: "200 OK",
                body: HookPayload.response(for: decision, event: event) ?? "")
        }
    }

    /// The agent's side of the wire going quiet.
    ///
    /// A hook that gave up, or a terminal that was closed, leaves a card
    /// offering a choice nobody is listening for, which is worse than no
    /// choice at all. The request is already whole, so this read can
    /// never return more of it: anything it reports is the connection
    /// ending, which is the one thing worth knowing.
    ///
    /// Harmless when the answer got there first. This also fires on the
    /// cancel that follows a successful response, and by then the id is
    /// gone from the store and abandoning it does nothing.
    private func watchForHangup(_ connection: NWConnection, id: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            [weak self] _, _, complete, error in
            guard complete || error != nil else { return }
            Task { [weak self] in
                guard let self, await gate.abandon(id) else { return }
                // Only when the abandon actually found something. After
                // a normal answer this fires too, on the cancel that
                // follows the response, and the card is already gone.
                await MainActor.run { self.sessions?.abandonApproval(id: id) }
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
