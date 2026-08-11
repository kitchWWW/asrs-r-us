import Foundation
import FoundationModels

/// Rewrites using Apple's on-device model, built into macOS 26.
///
/// No server process, no model download, no API key -- and nothing leaves the
/// machine. Requires Apple Intelligence to be switched on in System Settings;
/// until it is, `SystemLanguageModel` reports itself unavailable.
struct AppleIntelligenceBackend: RewriteBackend {

    enum BackendError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(reason): return reason
            }
        }
    }

    /// Human-readable reason the model cannot be used, or nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case let .unavailable(reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is off. Turn it on in System Settings › Apple Intelligence & Siri."
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence."
            case .modelNotReady:
                return "Apple Intelligence is still downloading its model."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        @unknown default:
            return "Apple Intelligence is unavailable."
        }
    }

    static var isAvailable: Bool { unavailableReason == nil }

    func streamText(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailableReason {
                        throw BackendError.unavailable(reason)
                    }

                    let session = LanguageModelSession(instructions: system)
                    var latest = ""

                    // Snapshots are cumulative, not incremental -- each one is
                    // the whole response so far, and the model may revise text
                    // it already emitted. Forwarding them as deltas would
                    // duplicate output, so the final snapshot is emitted once
                    // at the end. Nothing is lost: partial rewrites are not
                    // displayed anyway.
                    for try await snapshot in session.streamResponse(to: user) {
                        try Task.checkCancellation()
                        latest = snapshot.content
                    }

                    let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { continuation.yield(text) }
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
        if let reason = Self.unavailableReason {
            throw BackendError.unavailable(reason)
        }
        let session = LanguageModelSession(
            instructions: "You reply with exactly what the user asks for, nothing more."
        )
        let response = try await session.respond(to: "Reply with exactly: OK")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
