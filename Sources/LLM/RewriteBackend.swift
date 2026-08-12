import Foundation

/// Where rewrites are generated. The app defaults to a local model so it works
/// with no API key and no network; Anthropic remains available for anyone who
/// wants a frontier model instead.
enum RewriteBackendKind: String, CaseIterable, Identifiable, Codable {
    case local
    case bedrock
    case appleIntelligence
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:             return "Local model (llama.cpp)"
        case .bedrock:           return "Claude on Amazon Bedrock"
        case .appleIntelligence: return "Apple Intelligence"
        case .anthropic:         return "Anthropic API"
        }
    }
}

/// Minimal surface the rewriter needs. Both backends stream text so the
/// service layer does not care which is in use.
protocol RewriteBackend {
    func streamText(system: String, user: String) -> AsyncThrowingStream<String, Error>
    /// Hello-world round trip used by Settings to confirm the backend works.
    @discardableResult
    func ping() async throws -> String
}
