import Foundation
import os

/// Turns a live ASR transcript into polished text by streaming rewrites from
/// Claude, debounced so a fast talker does not open a request per syllable.
@MainActor
final class RewriteService: ObservableObject {

    enum Status: Equatable {
        case idle
        case rewriting
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// The rewritten text, updated live as tokens stream in.
    @Published var output: String = ""

    /// Newest transcript the recognizer has produced, whether or not a rewrite
    /// has run for it yet.
    @Published private(set) var latestTranscript: String = ""
    /// The transcript that the current `output` actually reflects. When this
    /// trails `latestTranscript`, what is on screen is stale.
    @Published private(set) var settledTranscript: String = ""

    /// Set while the user is typing in the output box; suppresses clobbering.
    var isUserEditing: () -> Bool = { false }
    /// Called whenever a rewrite finishes cleanly, with the final text.
    var onRewriteCompleted: ((String) -> Void)?

    /// How many rewrite requests this session has issued. Logged so a session
    /// that churned through twenty rewrites is distinguishable from one that
    /// needed a single pass.
    private(set) var rewriteCount = 0

    private let settings: AppSettings
    private let profiles: ProfileStore
    private let editTracker: EditTracker
    private let server: LlamaServerManager
    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "rewrite")

    /// True when speech has been captured that the visible output does not
    /// yet account for -- either waiting out the debounce or mid-request.
    /// False means: everything you have said has been rewritten, you are clear
    /// to hit Enter.
    var isPending: Bool {
        if case .failed = status { return false }   // the error bar says it instead
        if status == .rewriting { return true }
        guard !latestTranscript.isEmpty else { return false }
        return latestTranscript != settledTranscript
    }

    private var debounceTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var lastRequestedTranscript = ""

    /// One provider per profile, kept so the credential cache survives between
    /// rewrites -- otherwise every rewrite would shell out to the AWS CLI.
    private var credentialProviders: [String: AWSCredentialProvider] = [:]

    private func credentialProvider(for profile: String) -> AWSCredentialProvider {
        if let existing = credentialProviders[profile] { return existing }
        let made = AWSCredentialProvider(profile: profile)
        credentialProviders[profile] = made
        return made
    }

    init(
        settings: AppSettings,
        profiles: ProfileStore,
        editTracker: EditTracker,
        server: LlamaServerManager
    ) {
        self.settings = settings
        self.profiles = profiles
        self.editTracker = editTracker
        self.server = server
    }

    /// The engine for the current settings, or an error explaining what is
    /// missing (no API key / local server not up).
    private enum BackendResolution {
        case ready(RewriteBackend)
        case unavailable(String)
    }

    private func makeBackend() -> BackendResolution {
        switch settings.backend {
        case .local:
            guard server.state.isReady else {
                switch server.state {
                case let .failed(message):
                    return .unavailable(message)
                case .preparingModel:
                    return .unavailable("Downloading the local model…")
                case .stopped:
                    // Should be transient: selecting the local backend kicks off
                    // a start. Saying so beats an indefinite "starting up".
                    return .unavailable("Starting the local model server…")
                default:
                    return .unavailable("Local model is still starting up…")
                }
            }
            return .ready(server.client)
        case .bedrock:
            return .ready(BedrockClient(
                modelID: settings.bedrockModelID,
                region: settings.bedrockRegion,
                credentials: credentialProvider(for: settings.awsProfile)
            ))
        case .appleIntelligence:
            if let reason = AppleIntelligenceBackend.unavailableReason {
                return .unavailable(reason)
            }
            return .ready(AppleIntelligenceBackend())
        case .anthropic:
            guard settings.hasAPIKey else {
                return .unavailable(AnthropicClient.ClientError.missingAPIKey.localizedDescription)
            }
            return .ready(AnthropicClient(apiKey: settings.apiKey, model: settings.model))
        }
    }

    // MARK: - Entry points

    /// Called on every ASR update.
    ///
    /// The debounce exists to stop a request going out per syllable while the
    /// recognizer is still revising its guess. Once a result comes back final,
    /// there is nothing left to wait for -- those words are settled, and
    /// holding them for another half second only adds latency to a rewrite
    /// that was going to happen anyway. So finals fire immediately and only
    /// volatile updates are debounced.
    ///
    /// Either way the request is skipped when the text is unchanged from the
    /// one already sent, so a final that merely confirms the volatile tail
    /// costs nothing.
    func transcriptChanged(_ transcript: String, isFinal: Bool = false) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestTranscript = trimmed
        guard trimmed != lastRequestedTranscript else { return }

        debounceTask?.cancel()

        if isFinal {
            Task { [weak self] in await self?.rewrite(transcript: trimmed) }
            return
        }
        let delay = UInt64(max(120, settings.debounceMilliseconds)) * 1_000_000
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.rewrite(transcript: trimmed)
        }
    }

    /// Forces an immediate rewrite, ignoring the debounce (used when recording
    /// stops, so the final transcript always gets one last pass).
    func flush(transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestTranscript = trimmed
        debounceTask?.cancel()
        Task { await rewrite(transcript: trimmed, force: true) }
    }

    func cancel() {
        debounceTask?.cancel()
        streamTask?.cancel()
        debounceTask = nil
        streamTask = nil
        if status == .rewriting { status = .idle }
    }

    func reset() {
        cancel()
        output = ""
        lastRequestedTranscript = ""
        latestTranscript = ""
        settledTranscript = ""
        rewriteCount = 0
        status = .idle
    }

    // MARK: - Core

    private func rewrite(transcript: String, force: Bool = false) async {
        rewriteCount += 1
        let backend: RewriteBackend
        switch makeBackend() {
        case let .ready(value): backend = value
        case let .unavailable(message):
            status = .failed(message)
            return
        }

        // Supersede any rewrite still in flight: its transcript is now stale.
        streamTask?.cancel()
        lastRequestedTranscript = transcript
        status = .rewriting

        // Appended rather than prepended: the base prompt defines the task and
        // the hard preservation rule, and should lead. A reference list reads
        // better close to the input, and keeping it in the system prompt (not
        // the user turn) leaves llama.cpp a longer stable prefix to cache.
        var system = profiles.activePrompt
        if let vocabulary = settings.dictionaryPromptSection {
            system += "\n\n" + vocabulary
        }
        let user = buildUserMessage(transcript: transcript)

        streamTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            // Timed from just before the request so the figure includes
            // connection setup, which is exactly what the wait feels like.
            let startedAt = Date()
            var firstChunkAt: Date?
            do {
                // Accumulate silently. Writing each chunk straight to `output`
                // blanks the box and retypes it on every rewrite, which reads as
                // flicker -- and every ASR update triggers a rewrite. The
                // previous text stays put until the replacement is complete.
                for try await chunk in backend.streamText(system: system, user: user) {
                    try Task.checkCancellation()
                    if firstChunkAt == nil { firstChunkAt = Date() }
                    accumulated += chunk
                }
                guard !Task.isCancelled else { return }

                // Only completed rewrites are timed. A superseded one is
                // abandoned mid-stream, so its duration measures how fast the
                // user kept talking, not how fast the engine is.
                StatsStore.shared.recordLatency(
                    engine: self.settings.backend.rawValue,
                    firstTokenMS: firstChunkAt.map { Int($0.timeIntervalSince(startedAt) * 1000) },
                    totalMS: Int(Date().timeIntervalSince(startedAt) * 1000)
                )

                let rewritten = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rewritten.isEmpty {
                    // Corrections reach the model through the prompt only --
                    // see `EditTracker.promptContext`. They used to also be
                    // replayed over the result in code, which a capable model
                    // no longer needs and which could corrupt a rewrite that
                    // was already correct: the replay was a global regex, so a
                    // one-off fix like "the" -> "a" rewrote every later "the"
                    // as well.
                    if !self.isUserEditing() {
                        self.output = rewritten
                        self.editTracker.setBaseline(rewritten)
                    }
                    self.onRewriteCompleted?(rewritten)
                }
                // This transcript is now reflected on screen; the pending
                // indicator can clear unless more speech has arrived since.
                self.settledTranscript = transcript
                self.status = .idle
            } catch is CancellationError {
                // Superseded by a newer transcript; not an error.
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.log.error("rewrite failed: \(message)")
                self.status = .failed(message)
            }
        }
    }

    private func buildUserMessage(transcript: String) -> String {
        // Collapse repeated spoken punctuation before the model sees it.
        let cleaned = TranscriptNormalizer.normalize(transcript)

        var parts: [String] = []
        parts.append("""
        Live dictation transcript:
        <transcript>
        \(cleaned)
        </transcript>
        """)

        if let editContext = editTracker.promptContext {
            parts.append(editContext)
        }

        parts.append("Rewrite the transcript. Output only the rewritten text.")
        return parts.joined(separator: "\n\n")
    }
}
