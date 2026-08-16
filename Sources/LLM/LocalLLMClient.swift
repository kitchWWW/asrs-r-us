import Foundation

/// Streaming client for any local OpenAI-compatible chat endpoint.
///
/// Written against the shared `/v1/chat/completions` shape rather than
/// llama.cpp specifically, so Ollama, LM Studio, and `mlx_lm.server` all work
/// against the same code if the user points the app at them.
struct LocalLLMClient: RewriteBackend {

    enum ClientError: LocalizedError {
        case notRunning
        case http(status: Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "The local model server is not running."
            case let .http(status, body):
                let detail = body.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines)
                return "Local model error \(status): \(detail)"
            case .malformedResponse:
                return "Unreadable response from the local model server."
            }
        }
    }

    var endpoint: URL
    var modelName: String
    var maxTokens: Int = 1024
    var session: URLSession = .shared

    private var chatURL: URL {
        endpoint.appendingPathComponent("v1/chat/completions")
    }

    func streamText(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: chatURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 60
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": modelName,
                        "max_tokens": maxTokens,
                        "temperature": 0.2,
                        "stream": true,
                        // llama.cpp only reports token counts if asked. They
                        // are not billed, but they are what the "if this had
                        // gone to a hosted model" figure is computed from.
                        "stream_options": ["include_usage": true],
                        "messages": [
                            ["role": "system", "content": system],
                            ["role": "user", "content": user],
                        ],
                    ])

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.malformedResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw ClientError.http(status: http.statusCode, body: body)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        // The usage chunk arrives last and carries no choices.
                        if let usage = event["usage"] as? [String: Any] {
                            let sample = TokenUsage(
                                model: self.modelName,
                                inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                                outputTokens: usage["completion_tokens"] as? Int ?? 0,
                                cacheWriteTokens: 0,
                                cacheReadTokens: (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                            )
                            Task { @MainActor in StatsStore.shared.recordLocalUsage(sample) }
                            continue
                        }

                        guard let choices = event["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String,
                              !text.isEmpty
                        else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func ping() async throws -> String {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "max_tokens": 16,
            "temperature": 0,
            "messages": [["role": "user", "content": "Reply with exactly: OK"]],
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode,
                                   body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String
        else { throw ClientError.malformedResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
