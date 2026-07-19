import Foundation

enum ClaudeError: LocalizedError {
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let message):
            return message
        }
    }
}

struct ClaudeService {
    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        struct APIError: Decodable {
            let message: String
        }
        let type: String
        let delta: Delta?
        let error: APIError?
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String
        }
        let error: APIError?
    }

    /// Streams the answer as text deltas so the island can type it out
    /// live instead of sitting on ThinkingDots until the whole reply
    /// lands.
    static func stream(prompt: String, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                        throw ClaudeError.badResponse("Bad URL")
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let body: [String: Any] = [
                        "model": "claude-sonnet-4-6",
                        "max_tokens": 1024,
                        "stream": true,
                        "system": "You are Moai, a tiny assistant living in the Mac notch. Answer in as few words as possible. Plain text only, no markdown.",
                        "messages": [
                            ["role": "user", "content": prompt]
                        ]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?
                            .error?.message ?? "API error (\(http.statusCode))"
                        throw ClaudeError.badResponse(message)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "),
                              let data = line.dropFirst(6).data(using: .utf8),
                              let event = try? JSONDecoder().decode(StreamEvent.self, from: data)
                        else { continue }

                        switch event.type {
                        case "content_block_delta":
                            if event.delta?.type == "text_delta", let text = event.delta?.text {
                                continuation.yield(text)
                            }
                        case "error":
                            throw ClaudeError.badResponse(
                                event.error?.message ?? "Stream error"
                            )
                        case "message_stop":
                            continuation.finish()
                            return
                        default:
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
}
