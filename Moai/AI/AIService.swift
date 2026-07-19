import Foundation

/// Which cloud brain answers in the Do tab. Fast, cheap tiers across
/// the board — notch questions want snappy answers, not dissertations.
enum AIProvider: String, CaseIterable {
    case claude
    case openai
    case gemini

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "GPT"
        case .gemini: return "Gemini"
        }
    }

    var model: String {
        switch self {
        case .claude: return "claude-haiku-4-5"
        case .openai: return "gpt-5-mini"
        // Alias tracks Google's current Flash model, so it never goes
        // stale the way a pinned version (2.5-flash) did for new users.
        case .gemini: return "gemini-flash-latest"
        }
    }

    var keychainAccount: String {
        switch self {
        case .claude: return "anthropicKey"
        case .openai: return "openaiKey"
        case .gemini: return "geminiKey"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .claude: return "sk-ant-..."
        case .openai: return "sk-..."
        case .gemini: return "AIza..."
        }
    }

    /// The user's current pick, shared by typed and spoken input.
    static var current: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "")
            ?? .claude
    }

    var next: AIProvider {
        let all = AIProvider.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

enum AIError: LocalizedError {
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let message):
            return message
        }
    }
}

/// One streaming surface over three providers. Everything speaks SSE;
/// only the framing differs per vendor.
struct AIService {
    static let systemPrompt =
        "You are Moai, a tiny assistant living in the Mac notch. Answer in as few words as possible. Plain text only, no markdown."

    /// Streams the answer as text deltas so the island can type it out
    /// live instead of sitting on ThinkingDots until the whole reply lands.
    static func stream(
        prompt: String,
        provider: AIProvider,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        prompt: prompt, provider: provider, apiKey: apiKey
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw AIError.badResponse(
                            errorMessage(from: data, provider: provider, status: http.statusCode)
                        )
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }

                        if let error = streamError(from: data, provider: provider) {
                            throw AIError.badResponse(error)
                        }
                        if let text = delta(from: data, provider: provider), !text.isEmpty {
                            continuation.yield(text)
                        }
                        if provider == .claude, isClaudeStop(data) {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Request framing per provider

    private static func makeRequest(
        prompt: String,
        provider: AIProvider,
        apiKey: String
    ) throws -> URLRequest {
        let urlString: String
        switch provider {
        case .claude:
            urlString = "https://api.anthropic.com/v1/messages"
        case .openai:
            urlString = "https://api.openai.com/v1/chat/completions"
        case .gemini:
            urlString =
                "https://generativelanguage.googleapis.com/v1beta/models/\(provider.model):streamGenerateContent?alt=sse"
        }
        guard let url = URL(string: urlString) else {
            throw AIError.badResponse("Bad URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any]
        switch provider {
        case .claude:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": provider.model,
                "max_tokens": 1024,
                "stream": true,
                "system": systemPrompt,
                "messages": [["role": "user", "content": prompt]],
            ]
        case .openai:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": provider.model,
                "stream": true,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": prompt],
                ],
            ]
        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [
                    ["role": "user", "parts": [["text": prompt]]]
                ],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Stream parsing per provider

    private struct ClaudeEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        struct APIError: Decodable { let message: String }
        let type: String
        let delta: Delta?
        let error: APIError?
    }

    private struct OpenAIChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    private struct GeminiChunk: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
        }
        let candidates: [Candidate]?
    }

    private static func delta(from data: Data, provider: AIProvider) -> String? {
        switch provider {
        case .claude:
            guard let event = try? JSONDecoder().decode(ClaudeEvent.self, from: data),
                  event.type == "content_block_delta",
                  event.delta?.type == "text_delta"
            else { return nil }
            return event.delta?.text
        case .openai:
            guard let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data) else {
                return nil
            }
            return chunk.choices?.first?.delta?.content
        case .gemini:
            guard let chunk = try? JSONDecoder().decode(GeminiChunk.self, from: data) else {
                return nil
            }
            return chunk.candidates?.first?.content?.parts?
                .compactMap(\.text).joined()
        }
    }

    private static func isClaudeStop(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(ClaudeEvent.self, from: data))?.type == "message_stop"
    }

    private static func streamError(from data: Data, provider: AIProvider) -> String? {
        guard provider == .claude,
              let event = try? JSONDecoder().decode(ClaudeEvent.self, from: data),
              event.type == "error"
        else { return nil }
        return event.error?.message ?? "Stream error"
    }

    // MARK: Error envelopes

    private struct AnthropicErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError?
    }

    private struct OpenAIErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String? }
        let error: APIError?
    }

    private struct GeminiErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String? }
        let error: APIError?
    }

    private static func errorMessage(
        from data: Data, provider: AIProvider, status: Int
    ) -> String {
        let message: String?
        switch provider {
        case .claude:
            message = (try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data))?
                .error?.message
        case .openai:
            message = (try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data))?
                .error?.message
        case .gemini:
            message = (try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data))?
                .error?.message
        }
        return message ?? "\(provider.displayName) error (\(status))"
    }
}
