import AppKit
import Combine
import Foundation

/// Coordinates one dictation session: which app to paste back into, the
/// recognizer, the rewriter, and the user's manual edits.
@MainActor
final class SessionController: ObservableObject {

    let settings = AppSettings.shared
    let dictation = DictationEngine()
    let profiles = ProfileStore.shared
    let editTracker = EditTracker()
    lazy var server = LlamaServerManager(settings: settings)
    lazy var rewriter = RewriteService(
        settings: settings,
        profiles: profiles,
        editTracker: editTracker,
        server: server
    )

    /// The app that was frontmost when the panel opened -- the paste target.
    @Published private(set) var targetApp: NSRunningApplication?
    @Published private(set) var lastError: String?
    @Published private(set) var didInsert = false
    /// True while text is being delivered to the target app. Published rather
    /// than held as view state because Enter reaches insertion through the
    /// window's key monitor, not the button's action.
    @Published private(set) var isInserting = false
    /// True once the user has typed into the rewritten box. Gates plain-Enter.
    @Published private(set) var hasUserEdited = false

    /// Panel visibility, driven by the window controller.
    @Published var isPanelVisible = false

    /// True while the user has been typing recently, so streaming rewrites
    /// don't yank text out from under them mid-word.
    private var lastUserEdit: Date?
    private let userEditGrace: TimeInterval = 1.5

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Session logging
    //
    // Identity and timing for the session currently on screen, so the finished
    // session can be written out as one record. `loggedCurrentSession` stops a
    // session being written twice when the panel closes after an insertion.
    private var sessionID = UUID()
    private var sessionStartedAt = Date()
    private var loggedCurrentSession = false

    init() {
        dictation.onTranscriptChange = { [weak self] transcript, isFinal in
            self?.rewriter.transcriptChanged(transcript, isFinal: isFinal)
        }
        rewriter.isUserEditing = { [weak self] in
            guard let self, let last = self.lastUserEdit else { return false }
            return Date().timeIntervalSince(last) < self.userEditGrace
        }

        // Surface recognizer failures in the same place as rewrite failures.
        dictation.$state
            .sink { [weak self] state in
                if case let .failed(message) = state { self?.lastError = message }
            }
            .store(in: &cancellables)

        rewriter.$status
            .sink { [weak self] status in
                if case let .failed(message) = status { self?.lastError = message }
            }
            .store(in: &cancellables)

        // Bring the local server up whenever the backend becomes local, no
        // matter which control changed it. Previously this happened only at
        // launch and only if local was already selected, so switching to it
        // afterwards left the server stopped and every rewrite reporting that
        // the model was "still starting up" forever.
        settings.$backend
            .filter { $0 == .local }
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.server.start() }
            }
            .store(in: &cancellables)
    }

    var isRecording: Bool { dictation.isRecording }
    var transcript: String { dictation.transcript }
    /// Enabled once there is anything at all to insert, since Use falls back
    /// to the transcript when the rewrite has not landed.
    var canInsert: Bool {
        !rewriter.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || canInsertTranscript
    }

    // MARK: - Session lifecycle

    /// Begins a fresh session. `target` is captured *before* our panel steals
    /// focus, so we know where to paste.
    func beginSession(target: NSRunningApplication?) {
        targetApp = target
        lastError = nil
        didInsert = false
        hasUserEdited = false
        sessionID = UUID()
        sessionStartedAt = Date()
        loggedCurrentSession = false
        lastUserEdit = nil
        dictation.reset()
        rewriter.reset()
        editTracker.reset()
        Task { await dictation.start() }
    }

    /// Wipes the session and starts listening again from scratch.
    ///
    /// Stopping before clearing is the whole point: the recognizer holds
    /// buffered audio, and tearing it down flushes that audio as one last
    /// finalized result. Clearing first would let those stale words land in the
    /// supposedly-fresh transcript a moment later.
    func clearAndRestart() {
        Task {
            await dictation.stop()
            // Log before wiping: a cleared session is still a record of how the
            // user speaks, and the fact that it was thrown away is itself a
            // signal worth keeping.
            logSession(outcome: .cleared)
            // Let any final result the flush produced land before wiping, so it
            // is discarded rather than arriving after the reset.
            await Task.yield()

            dictation.reset()
            rewriter.reset()
            editTracker.reset()
            lastUserEdit = nil
            hasUserEdited = false
            lastError = nil
            sessionID = UUID()
            sessionStartedAt = Date()
            loggedCurrentSession = false

            await dictation.start()
        }
    }

    /// F7 while the panel is open: stop if recording, resume if not.
    func toggleRecording() {
        Task {
            if dictation.isRecording {
                await stopRecording()
            } else {
                lastError = nil
                await dictation.start()
            }
        }
    }

    func stopRecording() async {
        await dictation.stop()
        // One final pass so the tail of the dictation gets polished even if the
        // debounce window never elapsed.
        rewriter.flush(transcript: dictation.transcript)
    }

    func endSession() {
        Task {
            await dictation.stop()
            rewriter.cancel()
            // Only reached as `.abandoned` if nothing was inserted -- a used
            // session has already logged itself with the outcome that matters.
            logSession(outcome: .abandoned)
        }
    }

    // MARK: - Run now

    /// Freezes the transcript where it stands and rewrites it immediately.
    ///
    /// Stopping the recognizer is what makes the transcript trustworthy at the
    /// moment Run is pressed. `stop()` flushes the audio still buffered inside
    /// it and turns the volatile tail -- the words it was still free to revise
    /// -- into finalized text, so what gets sent is exactly what is on screen.
    /// Starting again resumes the same dictation rather than beginning a new
    /// one: `DictationEngine.start()` deliberately appends to `finalizedText`.
    ///
    /// The rewrite is fired between the two, so the request is already in
    /// flight while the recogniser is coming back up.
    func runRewriteNow() async {
        guard !isRunningNow else { return }
        isRunningNow = true
        defer { isRunningNow = false }

        let wasRecording = dictation.isRecording
        if wasRecording { await dictation.stop() }

        let frozen = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !frozen.isEmpty {
            // Supersedes whatever is in flight or still waiting out the
            // debounce; `flush` cancels both.
            rewriter.flush(transcript: frozen)
        }

        if wasRecording { await dictation.start() }
    }

    /// True while `runRewriteNow` is tearing the recogniser down and back up,
    /// so the button can't be pressed twice through that gap.
    @Published private(set) var isRunningNow = false

    var canRunNow: Bool {
        !dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - User edits

    /// Called from the output editor whenever the user types.
    func userDidEdit(_ text: String) {
        lastUserEdit = Date()
        hasUserEdited = true
        rewriter.output = text
        editTracker.record(edited: text)
    }

    // MARK: - Insertion

    /// The Use button and its ⌘↩ shortcut.
    ///
    /// Falls through to the raw transcript when no rewrite has arrived yet.
    /// Speaking quickly outruns the rewriter, and the alternative was watching
    /// a dead button and then reaching for a second one -- so Use means "take
    /// what is on screen", and what is on screen when the bottom box is empty
    /// is the transcript. It is logged as the latency fallback it is, which is
    /// what keeps the statistics honest about how often this happens.
    func useOutput() async -> Bool {
        let rewritten = rewriter.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rewritten.isEmpty else { return await use(rewriter.output) }
        return await use(dictation.transcript, outcome: .usedTranscriptNoRewrite)
    }

    /// Escape hatch: insert the raw transcript instead of the rewrite, for when
    /// the model's version is not what the user wants -- or has not arrived.
    ///
    /// Which of those two it was has to be settled here, before `use` cancels
    /// the rewriter: with something in the output box the user read a rewrite
    /// and rejected it, with an empty box they gave up waiting for one. Only a
    /// completely empty box counts as waiting; a rewrite that is still
    /// streaming is a rewrite the user could see and judge.
    func useTranscript() async -> Bool {
        await use(
            dictation.transcript,
            outcome: canInsert ? .usedTranscript : .usedTranscriptNoRewrite
        )
    }

    var canInsertTranscript: Bool {
        !dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func use(_ candidate: String, outcome: SessionLog.Outcome = .used) async -> Bool {
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isInserting else { return false }

        isInserting = true
        defer { isInserting = false }

        // Stop the mic first: pasting into the target while still recording
        // would keep appending transcript into a session the user is done with.
        if dictation.isRecording { await dictation.stop() }
        rewriter.cancel()

        do {
            try await TextInserter.insert(
                text,
                into: targetApp,
                method: settings.insertionMethod,
                restorePasteboard: settings.restorePasteboard
            )
            DictationHistory.shared.record(text, profileName: profiles.active.name)
            logSession(outcome: outcome)
            didInsert = true
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: - Logging

    /// Ends the recording, hands it to the compressor, and reports the name
    /// the log should remember it by.
    ///
    /// Compression runs off the main actor because it shells out to a
    /// converter, and dictation has just ended -- the panel is animating away
    /// and nothing should be waiting on an encoder.
    private func recordedAudioStem() -> String? {
        guard let url = dictation.finishRecording() else { return nil }
        Task.detached(priority: .utility) {
            SessionAudio.compress(url)
            let days = await AppSettings.shared.audioRetentionDays
            let cap = await Int64(AppSettings.shared.audioMaxMegabytes) * 1_048_576
            let policy = await AppSettings.shared.audioEvictionPolicy
            SessionAudio.prune(olderThanDays: days, maxBytes: cap, policy: policy)
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Writes the session that is on screen to the local log, once.
    ///
    /// Deliberately records the transcript and the rewrite as different kinds
    /// of thing: the transcript is evidence of how the user speaks, while the
    /// rewrite is only evidence of what the model did with it. The edited
    /// rewrite is stored separately again, because an edit is the one moment
    /// the user tells us the model was wrong.
    private func logSession(outcome: SessionLog.Outcome) {
        guard !loggedCurrentSession else { return }
        let transcript = dictation.transcript
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        loggedCurrentSession = true

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        SessionLog.shared.append(
            SessionLog.Record(
                id: sessionID,
                startedAt: sessionStartedAt,
                endedAt: Date(),
                outcome: outcome,
                transcript: transcript,
                normalizedTranscript: TranscriptNormalizer.normalize(transcript),
                rewrite: rewriter.output,
                editedRewrite: hasUserEdited ? rewriter.output : nil,
                profile: profiles.active.name,
                backend: settings.backend.rawValue,
                model: settings.backend == .local ? settings.localModelRepo : settings.model,
                rewriteCount: rewriter.rewriteCount,
                recordingSeconds: Date().timeIntervalSince(sessionStartedAt),
                targetBundleID: targetApp?.bundleIdentifier,
                inputDevice: dictation.activeInputDeviceName,
                // Closes the recording here so the file and the line of JSON
                // that describes it are written from the same moment. The name
                // recorded is the stem: the file is lossless for another
                // second or so and then becomes the compressed one.
                audioFile: recordedAudioStem(),
                appVersion: version ?? "0"
            )
        )

        // Counters are recorded whether or not transcript logging is on: the
        // log holds everything the user said and is a real privacy decision,
        // while a count of how often they said something is not.
        let stats = StatsStore.shared
        stats.record(
            date: sessionStartedAt,
            transcript: transcript,
            rewrite: rewriter.output,
            outcome: outcome,
            profile: profiles.active.name,
            engine: settings.backend.rawValue,
            bundleID: targetApp?.bundleIdentifier,
            recordingSeconds: Date().timeIntervalSince(sessionStartedAt),
            rewriteCount: rewriter.rewriteCount,
            wasEdited: hasUserEdited
        )
        // Recorded here rather than as the user types: `EditTracker` collapses
        // consecutive keystrokes in the same region, so only at the end of the
        // session does an edit hold the word the user actually settled on.
        for edit in editTracker.edits {
            stats.recordEdit(before: edit.before, after: edit.after)
        }
    }

    /// Changing engine mid-session re-rewrites what has been said so far, so
    /// the new engine's version replaces the old one on screen instead of the
    /// change only showing up in whatever is dictated next.
    func switchBackend(to kind: RewriteBackendKind) {
        guard kind != settings.backend else { return }
        settings.backend = kind
        lastError = nil
        lastUserEdit = nil
        // The server is started by the `settings.$backend` observer in `init`,
        // which also covers the Settings picker.
        rewriter.flush(transcript: dictation.transcript)
    }

    /// Changing profile mid-session re-rewrites what has been said so far,
    /// so the new style is applied to the existing text rather than only to
    /// whatever is dictated next.
    func switchProfile(to id: Profile.ID) {
        guard id != profiles.selectedID else { return }
        profiles.selectedID = id
        // An explicit profile change is an explicit request for new output, so
        // drop the typing grace period that would otherwise suppress it.
        lastUserEdit = nil
        let text = dictation.transcript
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rewriter.flush(transcript: text)
        }
    }

    /// Changing microphone restarts capture if we are live, so the switch takes
    /// effect immediately instead of at the next session.
    func changeInputDevice(uid: String) {
        guard uid != settings.inputDeviceUID else { return }
        settings.inputDeviceUID = uid
        guard dictation.isRecording else { return }
        Task {
            await dictation.stop()
            await dictation.start()
        }
    }

    func clearError() { lastError = nil }
}
