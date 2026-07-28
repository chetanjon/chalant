import Foundation
import Network
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

    static var tokenURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Chalant/api-token")
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

    private var token = ""

    @MainActor
    func start(store: ActivityStore) {
        self.store = store
        token = Self.loadOrCreateToken()
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: parameters, on: port)
        else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that opens a socket and never finishes its header
        // block would pin the connection and its buffer forever
        // (review-caught). Five seconds is a lifetime for a loopback
        // request of a few hundred bytes.
        queue.asyncAfter(deadline: .now() + 5) { [weak connection] in
            connection?.cancel()
        }
        receive(connection, buffer: Data())
    }

    /// Accumulate until the header block and Content-Length body are
    /// whole; requests here are a few hundred bytes, one read usually
    /// does it.
    private func receive(_ connection: NWConnection, buffer: Data) {
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
                self.route(request, on: connection)
            } else if complete {
                self.respond(connection, status: "400 Bad Request", body: #"{"ok":false}"#)
            } else {
                self.receive(connection, buffer: data)
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
        let offeredToken = lines
            .first { $0.lowercased().hasPrefix(tokenHeader) }
            .flatMap { line -> String? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            } ?? ""
        return Request(
            method: parts[0], path: parts[1],
            body: Data(body.prefix(contentLength)), fromBrowser: fromBrowser,
            offeredToken: offeredToken
        )
    }

    private func route(_ request: Request, on connection: NWConnection) {
        // A web page can reach a loopback port, but it must never move
        // the island. Reading (GET) is already walled off by the
        // browser's own same-origin policy; the writing routes refuse
        // anything wearing browser headers outright.
        if request.fromBrowser, request.method != "GET" {
            respond(connection, status: "403 Forbidden",
                    body: #"{"ok":false,"error":"cross-origin writes refused"}"#)
            return
        }
        // Kept after the browser check so a web page still gets told it
        // is the wrong kind of caller rather than being handed a hint
        // about what a right one would carry.
        guard Self.tokenMatches(request.offeredToken, token) else {
            respond(connection, status: "401 Unauthorized",
                    body: #"{"ok":false,"error":"send X-Chalant-Token, see ~/Library/Application Support/Chalant/api-token"}"#)
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
