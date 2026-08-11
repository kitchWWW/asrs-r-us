import Foundation

/// Minimal streaming client for the Anthropic Messages API.
///
/// This is a hand-rolled SSE reader rather than the Swift SDK because there is
/// no official Anthropic Swift SDK; raw HTTP is the documented path for
/// languages without one.
struct AnthropicClient: RewriteBackend {

    struct Request {
        var model: String
        var system: String
        var userMessage: String
        var maxTokens: Int = 2048
    }

    enum ClientError: LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key set. Add one in ASRs-R-US > Settings."
            case let .http(status, body):
                if status == 401 { return "Anthropic rejected the API key (401)." }
                if status == 429 { return "Rate limited by Anthropic (429). Try again shortly." }
                let detail = Self.extractMessage(from: body) ?? body.prefix(200).description
                return "Anthropic API error \(status): \(detail)"
            case .malformedResponse:
                return "Unreadable response from Anthropic."
            }
        }

        private static func extractMessage(from body: String) -> String? {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = object["error"] as? [String: Any],
                  let message = error["message"] as? String
            else { return nil }
            return message
        }
    }

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, model: String = "claude-haiku-4-5", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

/// Minimal round-trip used to confirm a key (and model) actually work.
    /// Returns the model's reply so the caller can show something concrete.
    /// Model used when this client is driven through the `RewriteBackend`
    /// protocol, where the caller does not pass one per request.
    var model: String

    func streamText(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        streamText(Request(model: model, system: system, userMessage: user))
    }

    @discardableResult
    func ping() async throws -> String { try await ping(model: model) }

    @discardableResult
    func ping(model: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.timeoutInterval = 20

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16,
            "messages": [["role": "user", "content": "Reply with exactly: OK"]],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw ClientError.malformedResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Streams the assistant's text back as it is generated. Each yielded
    /// element is an incremental chunk, not the accumulated string.
    func streamText(_ request: Request) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

                    var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    urlRequest.timeoutInterval = 60

                    let body: [String: Any] = [
                        "model": request.model,
                        "max_tokens": request.maxTokens,
                        "stream": true,
                        "system": request.system,
                        "messages": [
                            ["role": "user", "content": request.userMessage]
                        ],
                    ]
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.malformedResponse
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw ClientError.http(status: http.statusCode, body: errorBody)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String
                        else { continue }

                        switch type {
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "error":
                            let message = (event["error"] as? [String: Any])?["message"] as? String
                            throw ClientError.http(status: 0, body: message ?? "stream error")
                        default:
                            break
                        }
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
}
