import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIError: LocalizedError {
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let message):
            return message
        }
    }
}

/// One brain, keyless: Apple's on-device model answers quick
/// questions and translates loose phrasings into verbs. Long-form
/// conversation belongs to the Chat tab, where the user's own
/// Claude, ChatGPT, or Gemini subscription does the heavy lifting.
/// The API-key era (three cloud SSE providers, Keychain fields)
/// was removed 2026-07-21: two ways to the same answer, one of
/// them worse.
struct AIService {
    static let systemPrompt =
        "You are Moai, a tiny assistant living in the Mac notch. Answer in as few words as possible. Plain text only, no markdown."

    /// True when Apple's on-device model can answer right now:
    /// Apple Silicon, new-enough macOS, Apple Intelligence turned on.
    static var localModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    /// Map a loose phrasing onto one canonical command, or nil. Runs
    /// when the deterministic verbs miss; the reply goes back through
    /// the same engine, so natural language still ends in real
    /// actions and nobody memorizes a vocabulary.
    static func translateToVerb(_ utterance: String) async -> String? {
        let prompt = """
        Translate the request into exactly one Moai command from this list, \
        filling in the user's own words and times:
        remind me to <thing> at <time> / schedule <thing> <day> at <time> / \
        cancel <event> / move <event> to <time> / what's next / agenda / \
        what's new / join (opens the next meeting's video link) / \
        read my screen / \
        what's due / done with <reminder> / undo / focus <minutes> / \
        timer <minutes> / stopwatch / stop stopwatch / reset stopwatch / \
        stop focus / \
        stop timer / rain / fire / cafe / \
        brown noise / stop noise / play / pause / next / previous / \
        open <app or folder> / quit <app> / left half / right half / fill / \
        center / note: <text> / notes / find <words> / screenshot / \
        screen record / lock screen / dark mode / light mode / \
        run <name of one of the user's Shortcuts.app shortcuts> / \
        text <person>: <their message, word for word> / send / \
        don't send
        Reply with one command copied exactly from the list, no other \
        words, no quotes, no explanation. If nothing fits, reply NONE.
        Request: \(utterance)
        """
        do {
            var reply = ""
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    var collected = ""
                    for try await delta in stream(prompt: prompt) {
                        collected += delta
                        if collected.count > 200 { break }
                    }
                    return collected
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    throw CancellationError()
                }
                reply = try await group.next() ?? ""
                group.cancelAll()
            }
            let line = reply
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).first ?? ""
            let cleaned = line.trimmingCharacters(
                in: CharacterSet(charactersIn: " \"'`.")
            )
            guard !cleaned.isEmpty,
                  cleaned.uppercased() != "NONE",
                  cleaned.count < 120
            else { return nil }
            return rescueParaphrase(cleaned)
        } catch {
            return nil
        }
    }

    /// Fixed-form commands the engine accepts verbatim. The small
    /// model sometimes wraps one in its own words ("set screen to
    /// light mode"); the longest command found inside the reply is
    /// the intent. Parameterized commands (remind, note:, open) are
    /// left untouched, their own words are the payload.
    // "join" and "read my screen" are deliberately NOT here: the
    // word-set rescue below is order-blind containment, and a chatty
    // reply that merely mentions joining or reading would snap to an
    // action that opens meetings or captures screens unasked
    // (review-caught). Their exact forms pass through via the prefix
    // guard instead.
    private static let canonicalCommands = [
        "what's next", "what's due", "what's new",
        "stop focus", "stop timer",
        "stop stopwatch", "reset stopwatch", "stopwatch", "brown noise", "stop noise",
        "left half", "right half", "screen record", "lock screen",
        "dark mode", "light mode", "screenshot", "previous", "agenda",
        "center", "notes", "pause", "next", "play", "rain", "fire",
        "cafe", "fill", "undo",
    ]

    private static let parameterizedPrefixes = [
        "remind", "schedule", "cancel", "move", "done with",
        "focus", "timer", "open", "quit", "note", "find", "run",
        "text", "message", "imessage", "send", "join", "read",
        "summarize", "explain", "translate", "describe",
    ]

    static func rescueParaphrase(_ reply: String) -> String {
        let lowered = reply.lowercased()
        guard !canonicalCommands.contains(lowered),
              !parameterizedPrefixes.contains(where: { lowered.hasPrefix($0) })
        else { return reply }
        // Word-set containment, order-blind: "change screen mode to
        // light" holds every word of "light mode" even though the
        // phrase never appears. The command with the most matched
        // words wins; whole words only, so display never plays.
        let words = Set(
            lowered.split(whereSeparator: { !$0.isLetter && $0 != "'" })
                .map(String.init)
        )
        let rescued = canonicalCommands
            .filter { command in
                command.split(separator: " ")
                    .allSatisfy { words.contains(String($0)) }
            }
            .max { a, b in
                let aRank = (a.split(separator: " ").count, a.count)
                let bRank = (b.split(separator: " ").count, b.count)
                return aRank < bRank
            }
        return rescued ?? reply
    }

    /// Streams the answer as text deltas so the island can type it
    /// out live instead of sitting on ThinkingDots until the whole
    /// reply lands. Apple's local model streams cumulative snapshots,
    /// not deltas; diff against the last snapshot.
    static func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if canImport(FoundationModels)
                    if #available(macOS 26.0, *) {
                        guard case .available = SystemLanguageModel.default.availability else {
                            throw AIError.badResponse(
                                "The Mac's on-device model isn't ready. Turn on Apple Intelligence in System Settings."
                            )
                        }
                        let session = LanguageModelSession(instructions: systemPrompt)
                        var previous = ""
                        for try await snapshot in session.streamResponse(to: prompt) {
                            let text = snapshot.content
                            if text.hasPrefix(previous) {
                                let delta = String(text.dropFirst(previous.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                            } else {
                                continuation.yield(text)
                            }
                            previous = text
                        }
                        continuation.finish()
                        return
                    }
                    #endif
                    throw AIError.badResponse(
                        "The on-device model needs a newer macOS."
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
