import Foundation

/// One line per hook event, appended where a person can tail it:
///
///     ~/Library/Application Support/Chalant/wire.log
///     (or just: chalant tail)
///
/// The island can only render what an agent actually sends, and the
/// strings that matter (a Notification's `notification_type`, the
/// exact tool names, what this app answered) are only knowable by
/// reading them off a live session. This is the reading surface:
/// timestamp, event, the type string verbatim where there is one, the
/// tool where there is one, and the answer that went back on the wire.
///
/// Always on rather than behind a switch: the volume is one short line
/// per hook event on a loopback port, the file is trimmed at launch,
/// and a debug surface nobody can find is a debug surface nobody uses.
/// (`hookPayloadLog` remains the separate, off-by-default capture for
/// FULL payloads; this is the glanceable line, that is the evidence
/// file.)
enum WireLog {
    static var url: URL { ActivityServer.support.appendingPathComponent("wire.log") }

    /// A debug tail, not an archive: past this size the launch trim
    /// starts the file over rather than rotating it.
    static let cap = 2 * 1024 * 1024

    /// Lines arrive from the server queue and from held tasks
    /// answering minutes later, so writes are serialised here.
    private static let queue = DispatchQueue(label: "chalant.wirelog")

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// The line itself, pure so a test can hold it still: timestamp,
    /// event, `type=` and `tool=` only when they exist, then the
    /// response verbatim (flattened and cut, because a response is
    /// JSON and a tail is lines).
    static func line(
        at date: Date, event: String, ntype: String? = nil, tool: String? = nil,
        response: String
    ) -> String {
        var parts = [stamp.string(from: date), event]
        if let ntype, !ntype.isEmpty { parts.append("type=\(ntype)") }
        if let tool, !tool.isEmpty { parts.append("tool=\(tool)") }
        let flattened = response
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("-> " + (flattened.isEmpty
            ? "(empty 200, no opinion)" : String(flattened.prefix(300))))
        return parts.joined(separator: "  ")
    }

    static func note(
        event: String, ntype: String? = nil, tool: String? = nil, response: String
    ) {
        let written = line(at: Date(), event: event, ntype: ntype, tool: tool,
                           response: response) + "\n"
        queue.async {
            guard let data = written.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    /// Called once at server start: an oversized log starts over.
    static func trim() {
        queue.async {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[FileAttributeKey.size] as? Int) ?? 0
            guard size > cap else { return }
            try? Data().write(to: url)
        }
    }
}
