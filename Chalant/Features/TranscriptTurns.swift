import Foundation

/// Reading a session's conversation out of the transcript Claude Code
/// already writes.
///
/// Deliberately a second pass rather than an extension of
/// `parseMetadata`'s fold, which is the tempting design because that
/// fold already reads the tail and already walks these same blocks.
/// The sweep runs `parseMetadata` over up to twelve transcripts every
/// five seconds; folding turns into it would build a sixty-entry
/// conversation for eleven sessions nobody is looking at. This runs for
/// the one session somebody has open, on demand, and never on the
/// sweep. The 0.35%-core idle baseline is worth more than the
/// convenience of one loop instead of two.
///
/// It does share the machinery that matters: `SessionDiscovery.tail`,
/// so the two cannot drift on how much of a file is read or on what
/// happens to the partial first line.
extension SessionDiscovery {
    /// One entry in the conversation: somebody said something, or the
    /// agent did something.
    struct Turn: Equatable, Identifiable {
        enum Speaker: String, Equatable {
            case you
            case agent
        }

        enum Kind: Equatable {
            case said(who: Speaker, text: String)
            /// `finishedAt` nil means no `tool_result` for this call is
            /// in the tail, which is how the live one is known.
            case did(tool: String, detail: String, callID: String, finishedAt: Date?)
        }

        /// The record's own `uuid` where there is one, so a row keeps
        /// its identity across re-reads. Index-based ids would look new
        /// to SwiftUI every time the tail's start moved, which it does
        /// the moment a transcript grows past `tailBytes`.
        let id: String
        var kind: Kind
        var at: Date

        var isLive: Bool {
            if case let .did(_, _, _, finishedAt) = kind { return finishedAt == nil }
            return false
        }
    }

    /// Enough scroll for anyone in a notch, and a hard stop on a
    /// session mid-compaction or one whose last turn ran to pages.
    nonisolated static let maxTurns = 60

    /// The conversation at a path, or nil if the file could not be read.
    ///
    /// A pure function of a path on purpose: the decision about *when*
    /// to call this (the mtime gate, the cadence that follows the
    /// session's state) belongs to the room, not here, and a reader with
    /// a clock in it is a reader a test has to fake time for.
    nonisolated static func turns(atTranscript path: String) -> [Turn]? {
        guard let tail = tail(at: path) else { return nil }
        return parseTurns(tail.text, skippingFirstLine: tail.beganMidLine)
    }

    /// Walks the tail in file order, which is turn order.
    ///
    /// Every line is independent: one truncated or malformed line is
    /// skipped and never takes the rest of the file down with it, the
    /// same law `parseMetadata` holds.
    nonisolated static func parseTurns(
        _ text: String, skippingFirstLine skipFirst: Bool = false
    ) -> [Turn] {
        // Built once per call rather than per line. One call happens
        // every couple of seconds at most; one formatter per line would
        // be the expensive part of this whole function.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        var turns: [Turn] = []
        /// `tool_use_id` -> when its result landed. Applied in a second
        /// pass because a result always follows its call, so the call is
        /// already in `turns` by the time this is known.
        var resolved: [String: Date] = [:]

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        if skipFirst { lines = lines.dropFirst() }
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant"
            else { continue }
            // A subagent's own turns. A `Task` call in the main thread
            // already produces a line saying one was dispatched;
            // threading its whole conversation in here would make the
            // pane unreadable in exactly the sessions where reading it
            // matters most.
            guard object["isSidechain"] as? Bool != true else { continue }
            let stamp = (object["timestamp"] as? String)
                .flatMap { withFraction.date(from: $0) ?? plain.date(from: $0) }
                ?? Date()
            let uuid = object["uuid"] as? String
            let message = object["message"] as? [String: Any]

            // A human turn arrives with `content` as a bare string.
            if type == "user", let spoken = message?["content"] as? String {
                append(&turns, said: spoken, by: .you, at: stamp, id: uuid ?? "\(stamp)-you")
                continue
            }
            guard let blocks = message?["content"] as? [[String: Any]] else { continue }
            for (index, block) in blocks.enumerated() {
                let blockID = "\(uuid ?? "\(stamp.timeIntervalSince1970)").\(index)"
                switch block["type"] as? String {
                case "text":
                    guard let body = block["text"] as? String else { break }
                    // `user` here is a turn typed (or queued) by a
                    // person whose content arrived as blocks rather
                    // than as a bare string. The test for a human turn
                    // is the absence of a tool_result, never
                    // `promptSource == "typed"`: a message this app
                    // queued through the outbox and Claude Code
                    // collected is equally the user's turn, and
                    // filtering on how it was typed would drop it.
                    append(&turns, said: body, by: type == "user" ? .you : .agent,
                           at: stamp, id: blockID)
                case "tool_use":
                    guard let name = block["name"] as? String, !name.isEmpty else { break }
                    let callID = block["id"] as? String ?? blockID
                    turns.append(
                        Turn(
                            id: callID,
                            kind: .did(
                                tool: name,
                                detail: toolDetail(tool: name, input: block["input"] as? [String: Any]),
                                callID: callID, finishedAt: nil
                            ),
                            at: stamp
                        )
                    )
                case "tool_result":
                    // The same mechanism `parseMetadata` uses to notice
                    // a native ask stopped being live: Claude Code
                    // writes the result back wearing the call's own id.
                    if let callID = block["tool_use_id"] as? String { resolved[callID] = stamp }
                // Never shown. Thinking is not something the agent said.
                default:
                    break
                }
            }
        }

        for index in turns.indices {
            guard case let .did(tool, detail, callID, _) = turns[index].kind,
                  let finishedAt = resolved[callID]
            else { continue }
            turns[index].kind = .did(
                tool: tool, detail: detail, callID: callID, finishedAt: finishedAt)
        }
        return turns.suffix(maxTurns)
    }

    /// Blank text is not a turn. Claude Code writes empty text blocks
    /// routinely (alongside a tool call, most often), and a quoted block
    /// containing nothing is a hole in the conversation.
    private nonisolated static func append(
        _ turns: inout [Turn], said text: String, by who: Turn.Speaker, at: Date, id: String
    ) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        turns.append(Turn(id: id, kind: .said(who: who, text: body), at: at))
    }

    /// The one short line that says what a tool call was about.
    ///
    /// Never the raw input JSON. Every recognised tool has one field
    /// that is the answer to "what is it doing"; everything else in the
    /// input is noise at this size. An unrecognised tool gets nothing
    /// rather than a guess, which is the right way to be wrong here: a
    /// line reading "Ran" is honest about knowing only the verb, and a
    /// wrong guess about a tool's shape reads as a fact.
    nonisolated static func toolDetail(tool: String, input: [String: Any]?) -> String {
        guard let input else { return "" }
        let raw: String
        switch tool {
        case "Bash", "BashOutput":
            raw = input["command"] as? String ?? ""
        case "Read", "Edit", "Write", "NotebookEdit":
            raw = (input["file_path"] as? String).map(shortPath) ?? ""
        case "Grep", "Glob":
            raw = input["pattern"] as? String ?? ""
        case "Task", "Agent":
            raw = input["description"] as? String ?? ""
        case "WebFetch":
            raw = input["url"] as? String ?? ""
        case "WebSearch":
            raw = input["query"] as? String ?? ""
        default:
            raw = ""
        }
        // First line only. A heredoc or a multi-line command would
        // otherwise turn one row of the conversation into a page of it.
        let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > detailLimit else { return trimmed }
        return trimmed.prefix(detailLimit - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    nonisolated static let detailLimit = 80

    /// The last two path components, which is what the eye actually
    /// matches a file against. A full path at this width would push the
    /// filename, the only part anyone reads, off the end.
    private nonisolated static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    /// The verb, in the tense the call is actually in.
    ///
    /// Separate from `activityPhrase(forTool:)`, which answers a
    /// different question ("what is this session doing", as a standalone
    /// sentence, so "Running a command"). Here the verb is followed by
    /// its object, so it has to be "Ran" and "git rebase", not "Running
    /// a command" and "git rebase".
    nonisolated static func turnVerb(forTool tool: String, live: Bool) -> String {
        switch tool {
        case "Edit", "Write", "NotebookEdit": return live ? "Editing" : "Edited"
        case "Read": return live ? "Reading" : "Read"
        case "Bash", "BashOutput": return live ? "Running" : "Ran"
        case "Grep", "Glob": return live ? "Searching" : "Searched"
        case "Task", "Agent": return live ? "Running an agent" : "Ran an agent"
        case "WebFetch", "WebSearch": return live ? "Looking up" : "Looked up"
        case "TodoWrite": return live ? "Planning" : "Planned"
        case "AskUserQuestion": return live ? "Asking you" : "Asked you"
        default: return tool
        }
    }
}
