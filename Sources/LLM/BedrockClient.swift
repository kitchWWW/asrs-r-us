import Foundation

/// Rewrites via Claude on Amazon Bedrock.
///
/// Uses the non-streaming `invoke` endpoint. Bedrock's streaming variant frames
/// its output in the binary `vnd.amazon.eventstream` format, which would be a
/// lot of parsing for no benefit here: the rewrite is a couple of hundred
/// tokens and the panel already renders a whole snapshot at a time, exactly as
/// it does for Apple Intelligence.
///
/// The system prompt is marked for caching. It is ~2,500 tokens of rulebook and
/// vocabulary that never changes between rewrites, and a session fires ten or
/// more of them, so caching it is the difference between paying for the prompt
/// once and paying for it every time the user pauses.
struct BedrockClient: RewriteBackend {

    enum ClientError: LocalizedError {
        case http(status: Int, body: String)
        case noAccess(model: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case let .noAccess(model):
                return "This AWS account has not been granted access to \(model). "
                     + "In the Bedrock console, open Model access and submit the "
                     + "Anthropic use case details."
            case let .http(status, body):
                let detail = body.prefix(240).trimmingCharacters(in: .whitespacesAndNewlines)
                return "Bedrock error \(status): \(detail)"
            case .malformedResponse:
                return "Unreadable response from Bedrock."
            }
        }
    }

    var modelID: String
    var region: String
    var credentials: AWSCredentialProvider
    var maxTokens: Int = 1024
    var session: URLSession = .shared

    private var invokeURL: URL {
        // The model ID contains ':' and must stay escaped in the path.
        let escaped = modelID.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? modelID
        return URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(escaped)/invoke")!
    }

    private func body(system: String, user: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": maxTokens,
            // No `temperature`: it is deprecated on the newer models and a
            // 400 rather than a warning, so sending it would break the moment
            // the model setting is pointed at anything current.
            // Sent as a block rather than a bare string purely so it can carry
            // `cache_control`.
            "system": [[
                "type": "text",
                "text": system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": user]],
        ])
    }

    /// One request, one emission. The stream shape exists for the local
    /// backend's benefit; here it just delivers the finished rewrite.
    func streamText(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await complete(system: system, user: user)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(system: String, user: String, retryOnAuthFailure: Bool = true) async throws -> String {
        let payload = try body(system: system, user: user)
        var request = URLRequest(url: invokeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = payload
        request.timeoutInterval = 60

        let resolved = try await credentials.credentials()
        SigV4.sign(request: &request, payload: payload, service: "bedrock",
                   region: region, credentials: resolved)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }

        if http.statusCode == 403, retryOnAuthFailure {
            // Almost always credentials that lapsed between resolution and use.
            await credentials.invalidate()
            return try await complete(system: system, user: user, retryOnAuthFailure: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            // Bedrock reports an un-accepted model agreement as a 404 whose
            // message is about a form, which is worth translating.
            if http.statusCode == 404, text.contains("use case details") {
                throw ClientError.noAccess(model: modelID)
            }
            throw ClientError.http(status: http.statusCode, body: text)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw ClientError.malformedResponse }

        return content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func ping() async throws -> String {
        try await complete(
            system: "You are a connectivity check. Reply with exactly: OK",
            user: "Reply with exactly: OK",
            retryOnAuthFailure: true
        )
    }
}
