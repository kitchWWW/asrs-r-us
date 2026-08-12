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
                if case let .failed(message) = server.state { return .unavailable(message) }
                return .unavailable("Local model is still starting up…")
            }
            return .ready(server.client)
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

    /// Called on every ASR update. Debounces, then rewrites.
    func transcriptChanged(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestTranscript = trimmed
        guard trimmed != lastRequestedTranscript else { return }

        debounceTask?.cancel()
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
            do {
                // Accumulate silently. Writing each chunk straight to `output`
                // blanks the box and retypes it on every rewrite, which reads as
                // flicker -- and every ASR update triggers a rewrite. The
                // previous text stays put until the replacement is complete.
                for try await chunk in backend.streamText(system: system, user: user) {
                    try Task.checkCancellation()
                    accumulated += chunk
                }
                guard !Task.isCancelled else { return }

                let rewritten = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rewritten.isEmpty {
                    // Replay the user's corrections onto the new text, so an
                    // edit survives even when the model ignores the note about
                    // it in the prompt.
                    let finalText = self.editTracker.applying(to: rewritten)
                    if !self.isUserEditing() {
                        self.output = finalText
                        self.editTracker.setBaseline(finalText)
                    }
                    self.onRewriteCompleted?(finalText)
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
