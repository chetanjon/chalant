import Foundation
import os

/// A tool call an agent is standing still for.
///
/// The difference between this and everything else this app knows about
/// a session is that the agent is not doing anything else right now. It
/// asked, and its own process is suspended inside an HTTP request until
/// this app answers or its patience runs out. Nothing here is inferred,
/// polled for, or read off a file: it arrived, in the words of the
/// process that is waiting.
struct HeldCall: Sendable, Identifiable, Equatable {
    /// `tool_use_id` where the agent sent one. It is the only id that
    /// means the same thing on both sides of the wire, which is what
    /// makes an answer land on the call it was meant for.
    let id: String
    let sessionID: String
    let tool: String
    /// What is actually about to happen, in the words of the thing about
    /// to do it. Never summarised: a paraphrase of a command you are
    /// being asked to authorise is a paraphrase of the wrong thing.
    let detail: String
    let cwd: String
    let permissionMode: String
    let transcriptPath: String
    /// Which hook event carried it, so a `PermissionRequest` and a
    /// `PreToolUse` about the same call can be told apart.
    let event: String
    let askedAt: Date
}

/// What somebody decided about a held call.
enum GateDecision: Sendable, Equatable {
    case allow
    case deny
    /// Say nothing. The agent's own permission flow runs exactly as it
    /// would have if this app were not installed, which is the answer
    /// every ungated call gets and the answer everything gets when this
    /// app is not sure.
    case abstain
}

/// The held calls, and the suspended agents waiting on them.
///
/// An actor rather than a lock because the thing being guarded is not
/// data, it is a set of continuations: resuming one twice is a trap,
/// not a race you can lose quietly, and every path that could do it
/// (two taps, a tap racing a hang-up, a hang-up racing a quit) has to
/// be serialised against the others.
actor PendingDecisionStore {
    private struct Waiting {
        let call: HeldCall
        let continuation: CheckedContinuation<GateDecision, Never>
    }

    private var waiting: [String: Waiting] = [:]

    /// Registers the call and suspends until somebody decides.
    ///
    /// No thread is held here. The connection this was called for is a
    /// callback on a serial queue that has already returned; what is
    /// suspended is one Swift task and one agent process, and this app
    /// carries on exactly as if nobody were waiting.
    func hold(_ call: HeldCall) async -> GateDecision {
        await withCheckedContinuation { continuation in
            // The same id twice is not a second question, it is the same
            // question arriving again. Answering "not interested" hands
            // it to the agent's own permission flow, which is strictly
            // better than displacing the first waiter and stranding it
            // forever.
            guard waiting[call.id] == nil else {
                continuation.resume(returning: .abstain)
                return
            }
            waiting[call.id] = Waiting(call: call, continuation: continuation)
        }
    }

    /// Resumes exactly once.
    ///
    /// Removing before resuming is the whole of the idempotency: a
    /// second tap, or a hang-up arriving a millisecond after a tap,
    /// finds nothing and does nothing. Returns whether this call was the
    /// one that answered, which is what lets a caller tell "decided" from
    /// "already gone".
    @discardableResult
    func resolve(_ id: String, as decision: GateDecision) -> Bool {
        guard let entry = waiting.removeValue(forKey: id) else { return false }
        entry.continuation.resume(returning: decision)
        return true
    }

    /// The agent stopped listening: its hook timed out, or the process
    /// went away. Nobody is going to read the answer, so the only thing
    /// left to do is stop waiting and let the card go.
    @discardableResult
    func abandon(_ id: String) -> Bool {
        resolve(id, as: .abstain)
    }

    /// Everything standing at the door right now, oldest first.
    var held: [HeldCall] {
        waiting.values.map(\.call).sorted { $0.askedAt < $1.askedAt }
    }

    func isHeld(_ id: String) -> Bool { waiting[id] != nil }

    var count: Int { waiting.count }
}

/// Reading an agent's hook payload, and writing back the one shape it
/// will act on.
///
/// Every field name here was read off a live payload from the installed
/// Claude Code (2.1.226), not from memory: `session_id`, `prompt_id`,
/// `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`,
/// `tool_name`, `tool_input`, `tool_use_id`.
enum HookPayload {
    private static let log = Logger(subsystem: "com.cj.chalant", category: "hookgate")

    /// The keys a tool's input is worth naming, in the order a person
    /// would want to see them. Same list the shell shim uses, kept the
    /// same on purpose so a call reads identically whichever door it
    /// came through.
    static let detailKeys = ["command", "file_path", "path", "url", "pattern", "query"]

    static func detail(from input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        for key in detailKeys {
            guard let value = input[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(ActivityServer.maxDetail)) }
        }
        return ""
    }

    /// A held call, or nil when the payload is not one this app can act
    /// on. Nil is never an error worth interrupting anybody over: it
    /// means the agent carries on through its own permission flow.
    static func call(from object: [String: Any], fallbackID: String) -> HeldCall? {
        guard let sessionID = (object["session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty
        else { return nil }
        guard let tool = (object["tool_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty
        else { return nil }
        // Sanitised because it becomes part of a URL path on the way
        // back out, and because an id that round-trips differently from
        // the one stored would have the island answering a call nobody
        // is holding.
        let offered = (object["tool_use_id"] as? String) ?? ""
        let id = sanitised(offered).isEmpty ? fallbackID : sanitised(offered)
        // Only ever trusted when absolute. A relative cwd is the kind of
        // thing that reads fine and then names the wrong repo.
        let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? ""
        return HeldCall(
            id: id,
            sessionID: String(sessionID.prefix(ActivityServer.maxID)),
            tool: String(tool.prefix(ActivityServer.maxTitle)),
            detail: detail(from: object["tool_input"]),
            cwd: cwd,
            permissionMode: (object["permission_mode"] as? String) ?? "",
            transcriptPath: (object["transcript_path"] as? String) ?? "",
            event: (object["hook_event_name"] as? String) ?? "",
            askedAt: Date()
        )
    }

    static func sanitised(_ raw: String) -> String {
        String(raw.prefix(ActivityServer.maxID)).map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
                ? character : "-"
        }.reduce(into: "") { $0.append($1) }
    }

    /// The answer, in the exact shape the event expects.
    ///
    /// `PermissionRequest` and `PreToolUse` do NOT share a schema, and
    /// this app has already paid for believing they did: the shipped
    /// card says a decision on `PermissionRequest` is ignored, and the
    /// note behind it says a `permissionDecision` was what got returned.
    /// That is the `PreToolUse` field. `PermissionRequest` wants a
    /// `decision` object with a `behavior` inside it. Same words, same
    /// event family, different shape, and the wrong one is accepted in
    /// silence and simply does nothing.
    static func response(for decision: GateDecision, event: String) -> String? {
        switch decision {
        case .abstain:
            // An empty 200 is "no opinion", which is not the same as
            // approval and must never be written as one.
            return nil
        case .allow, .deny:
            break
        }
        let output: [String: Any]
        switch event {
        case "PermissionRequest":
            output = [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": decision == .allow ? "allow" : "deny"],
            ]
        default:
            output = [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision == .allow ? "allow" : "deny",
                // Shown to the model, so it is written as a statement of
                // what happened rather than as an instruction about what
                // to do next.
                "permissionDecisionReason": decision == .allow
                    ? "Allowed from the Chalant island."
                    : "Denied from the Chalant island.",
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["hookSpecificOutput": output])
        else {
            log.error("could not encode a \(event, privacy: .public) decision")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The policy engine's answer, which has one more word available to
    /// it than a person's does: `ask` sends the call to the permission
    /// prompt whatever any saved rule would otherwise have said.
    static func preToolUse(decision: String, reason: String) -> String? {
        let data = try? JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                // Shown to the model. A statement of what happened, not
                // an instruction about what to do next.
                "permissionDecisionReason": reason,
            ],
        ])
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
}
