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

    /// How long the transcript must be quiet before a rewrite fires.
    ///
    /// A rewrite goes out on *every* pause in speech, so the debounce is
    /// really a rate limit, and the right rate depends on what a request
    /// costs. Local inference costs nothing but electricity, so it can afford
    /// to fire often and feel instant. A hosted model is billed per call, and
    /// most of the calls a fast debounce buys are superseded a second later by
    /// the next one -- paying for tokens nobody reads.
    var defaultDebounceMilliseconds: Int {
        switch self {
        case .local:             return 200
        case .appleIntelligence: return 300
        case .bedrock:           return 600
        case .anthropic:         return 600
        }
    }

    /// Shortest gap allowed between two billed rewrites.
    ///
    /// The debounce above assumes updates arrive faster than it -- true of
    /// Apple's recogniser, and false of the sidecar ones, which emit only
    /// every one to two seconds and so sail through any debounce worth
    /// having. Measured update rates are in `RecognizerChoice`. Without a
    /// floor here, a minute of speech through NeMo is about 29 hosted
    /// requests; with it, at most 40 and in practice far fewer, since the
    /// throttle also lets several updates collapse into the newest one.
    ///
    /// Zero for anything running on this Mac: there is nothing to protect.
    var minimumRewriteIntervalMilliseconds: Int {
        switch self {
        case .local:             return 0
        case .appleIntelligence: return 0
        case .bedrock:           return 1500
        case .anthropic:         return 1500
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
