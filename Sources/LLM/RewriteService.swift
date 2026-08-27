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
    /// What the other recognisers heard, supplied by the session so this
    /// service does not need to know the dictation engine exists.
    var alternateTranscripts: () -> [(name: String, text: String)] = { [] }

    private var lastRequestedTranscript = ""
    /// When the last billed rewrite went out, for the minimum-interval floor.
    private var lastRequestStartedAt: Date?

    /// One provider per credential source, kept so the credential cache
    /// survives between rewrites -- otherwise every rewrite would shell out to
    /// the AWS CLI. Keyed by `cacheID`, which omits the secret.
    private var credentialProviders: [String: AWSCredentialProvider] = [:]

    private func credentialProvider(for source: AWSCredentialSource) -> AWSCredentialProvider {
        if let existing = credentialProviders[source.cacheID] { return existing }
        let made = AWSCredentialProvider(source: source)
        credentialProviders[source.cacheID] = made
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
                credentials: credentialProvider(for: settings.awsCredentialSource)
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
    /// Two separate protections, because they solve different problems and
    /// only one of them was ever doing much:
    ///
    /// The **debounce** stops a request going out per syllable while the
    /// recognizer is still revising its guess. A final normally skips it --
    /// settled words are not speculative, and holding them adds latency to a
    /// rewrite that was going to happen anyway. That reasoning depends on the
    /// recogniser actually revising, which is why it is asked: the NeMo
    /// transducer only ever appends, so every one of its updates is already
    /// settled and letting "finals" bypass the wait would just bill more.
    ///
    /// The **minimum interval** is the real ceiling on spend, and exists
    /// because the debounce turns out to be nearly inert for the sidecar
    /// recognisers. They emit an update every second or so, so almost every
    /// update outlives any debounce worth having and becomes a request. Only a
    /// floor on the gap between billed requests bounds that. It delays rather
    /// than drops: the newest text still gets rewritten, just no sooner than
    /// the engine allows.
    ///
    /// The two combine with `max`, not `+`. They are clocks from different
    /// origins -- the debounce runs from the last update, the throttle from
    /// the last request -- and quiet time accrues perfectly well while the
    /// throttle is still counting down. Adding them made the two waits
    /// sequential: a 700 ms floor on top of Bedrock's 1500 ms interval put
    /// 2200 ms between rewrites and capped the rate at 27 a minute, where the
    /// interval alone says 40. The extra 700 ms coalesced nothing and was paid
    /// on every rewrite; the session log shows live rewrites landing 2.3 s
    /// apart, pinned to that stacked floor rather than to either limit.
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

        let recognizer = RecognizerChoice.record
        let treatAsFinal = isFinal && recognizer.revisesText

        let debounce = treatAsFinal
            ? 0
            : max(120, max(settings.debounceMilliseconds, recognizer.debounceFloorMilliseconds))
        let delay = UInt64(max(debounce, throttleMilliseconds())) * 1_000_000

        guard delay > 0 else {
            Task { [weak self] in await self?.rewrite(transcript: trimmed) }
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            // Send the newest text, not the text that started this timer: more
            // may have arrived while it ran, and rewriting the stale version
            // would spend a request on something already superseded.
            guard let self else { return }
            let latest = self.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latest.isEmpty, latest != self.lastRequestedTranscript else { return }
            await self.rewrite(transcript: latest)
        }
    }

    /// How much longer this request has to wait to respect the engine's
    /// minimum gap between billed rewrites. Zero when the engine is free or
    /// enough time has already passed.
    private func throttleMilliseconds() -> Int {
        let minimum = settings.backend.minimumRewriteIntervalMilliseconds
        guard minimum > 0, let last = lastRequestStartedAt else { return 0 }
        let elapsed = Int(Date().timeIntervalSince(last) * 1000)
        return max(0, minimum - elapsed)
    }

    /// Forces an immediate rewrite, ignoring the debounce (used when recording
    /// stops, so the final transcript always gets one last pass).
    ///
    /// `force` separates the two callers. Stopping wants the tail polished,
    /// and if a rewrite of exactly this text is already streaming or already
    /// on screen then it is polished -- see `rewrite`. Run Now is an explicit
    /// press and re-runs regardless, rather than reading as a dead button.
    func flush(transcript: String, force: Bool = false) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestTranscript = trimmed
        debounceTask?.cancel()
        Task { await rewrite(transcript: trimmed, force: force) }
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

    /// Puts a finished session's rewrite back on screen without billing for it.
    ///
    /// The transcript is recorded as already settled *and* as already
    /// requested, which is what stops a rewrite firing the moment the panel
    /// opens: `rewrite` returns early for a transcript that is on screen
    /// unchanged, so the restored text sits there costing nothing until the
    /// user says something new -- and then the next rewrite covers the whole
    /// thing, old words included.
    func seed(output restored: String, transcript: String) {
        reset()
        output = restored
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        latestTranscript = trimmed
        settledTranscript = trimmed
        lastRequestedTranscript = trimmed
    }

    // MARK: - Core

    private func rewrite(transcript: String, force: Bool = false) async {
        // Nothing to do when this exact text is already in flight or already
        // settled on screen. Below, this method cancels whatever is streaming,
        // so coming through here again for the same words threw away a request
        // that was most of the way done and billed a replacement producing the
        // identical result -- and it was paid at the worst possible moment,
        // right after the user pressed stop and started watching the spinner.
        // A failed attempt is not settled, so it still retries.
        if !force, transcript == lastRequestedTranscript,
           status == .rewriting || settledTranscript == transcript {
            return
        }
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
        lastRequestStartedAt = Date()
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
        let cleaned = transcript

        var parts: [String] = []
        parts.append("""
        Live dictation transcript:
        <transcript>
        \(cleaned)
        </transcript>
        """)

        // Other recognisers' readings of the same audio, when cross-checking is
        // on. Placed after the transcript and clearly subordinate to it: these
        // are evidence about individual words, not competing drafts.
        let alternates = alternateTranscripts()
        if !alternates.isEmpty {
            log.info("""
                cross-checking against \(alternates.count, privacy: .public) other \
                recogniser(s): \(alternates.map(\.name).joined(separator: ", "), privacy: .public)
                """)
            let listed = alternates
                .map { "<\($0.name)>\n\($0.text)\n</\($0.name)>" }
                .joined(separator: "\n")
            parts.append("""
            The same audio, as heard by a different speech recogniser:
            \(listed)

            This is not a second draft to choose between, and not a vote. It is \
            evidence about individual words, from a model that mishears \
            different things than the one above, so the two disagreeing tells \
            you where to look.

            How to use it:
            - Where both readings say the same word, there is nothing to decide.
            - Where they differ, ask which one the sentence can actually \
            support, and write that. This is how "comma" against "karma" \
            against "carmin" gets settled: one recogniser reaches for a real \
            word, the other for a different real word, and only the sentence \
            says which sound was meant.
            - When neither reading makes sense, the speaker probably said \
            something neither model caught. Prefer the main transcript and \
            leave it alone rather than inventing a third option.
            - Take single words, never structure. Do not adopt the other \
            transcript's phrasing, word order, sentence breaks, or any content \
            that appears only there. The main transcript remains the record of \
            what was said and in what order.
            - Ignore its punctuation and capitalisation completely. That \
            recogniser adds marks at pauses rather than at grammar and converts \
            spoken punctuation words into symbols, so its formatting is noise \
            here even when its words are right. Punctuate from the rules above, \
            not from what it did.
            """)
        }

        if let editContext = editTracker.promptContext {
            parts.append(editContext)
        }

        parts.append("Rewrite the transcript. Output only the rewritten text.")
        return parts.joined(separator: "\n\n")
    }
}
