import Foundation
import Network

/// The open door: a tiny HTTP server on localhost that lets any local
/// process push a status pill onto the island. Claude Code hooks,
/// build scripts, cron jobs, download watchers; one curl and the
/// island knows. Loopback only, nothing ever leaves the machine.
///
///   curl -s localhost:4242/activity -d '{"id":"deploy",
///        "title":"Deploying site","state":"working"}'
///   curl -s localhost:4242/activity -d '{"id":"deploy",
///        "title":"Deployed","state":"done"}'
///   curl -s localhost:4242/activities        # inspect
///   curl -s -X DELETE localhost:4242/activity/deploy
///
/// States: working · needs-input · done · failed. Port configurable
/// via `defaults write com.cj.moai activityPort -int <port>`.
final class ActivityServer: @unchecked Sendable {
    private var listener: NWListener?
    private weak var store: ActivityStore?
    private let queue = DispatchQueue(label: "moai.activity.server")

    static var port: UInt16 {
        let configured = UserDefaults.standard.integer(forKey: "activityPort")
        return configured > 0 ? UInt16(clamping: configured) : 4242
    }

    @MainActor
    func start(store: ActivityStore) {
        self.store = store
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
            guard data.count <= 512 * 1024 else {
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

    private struct Request {
        var method: String
        var path: String
        var body: Data
    }

    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.components(separatedBy: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let contentLength = lines
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return Request(method: parts[0], path: parts[1], body: Data(body.prefix(contentLength)))
    }

    private func route(_ request: Request, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("POST", "/activity"):
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let title = object["title"] as? String, !title.isEmpty
            else {
                respond(connection, status: "400 Bad Request",
                        body: #"{"ok":false,"error":"need title"}"#)
                return
            }
            let id = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
            let detail = object["detail"] as? String
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
