import AppKit
import Combine
import Foundation
import os

/// Coordinates one dictation session: which app to paste back into, the
/// recognizer, the rewriter, and the user's manual edits.
@MainActor
final class SessionController: ObservableObject {

    let settings = AppSettings.shared
    lazy var recognizerServer = RecognizerServerManager(settings: settings)
    lazy var dictation = DictationEngine(serverManager: recognizerServer)
    let profiles = ProfileStore.shared
    let appProfiles = AppProfileMap.shared
    let editTracker = EditTracker()
    lazy var server = LlamaServerManager(settings: settings)
    lazy var rewriter = RewriteService(
        settings: settings,
        profiles: profiles,
        editTracker: editTracker,
        server: server
    )

    /// Brings the sidecar up ahead of the first press of F7, so a model is not
    /// being paged in while the user is already talking.
    private func startRecognizerServer() {
        Task { await recognizerServer.start(for: .record) }
    }

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
    private static let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "session")

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
    /// The history entry the session on screen was reopened from, if any.
    /// Recorded in the log so a resumed session, whose transcript repeats the
    /// earlier one's words, is not read as a second independent sample.
    private var resumedFrom: DictationHistory.Entry.ID?

    init() {
        startRecognizerServer()
        dictation.onTranscriptChange = { [weak self] transcript, isFinal in
            self?.rewriter.transcriptChanged(transcript, isFinal: isFinal)
        }
        rewriter.alternateTranscripts = { [weak self] in
            self?.dictation.alternateTranscripts ?? []
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
        applyProfile(for: target)
        lastError = nil
        didInsert = false
        hasUserEdited = false
        sessionID = UUID()
        sessionStartedAt = Date()
        loggedCurrentSession = false
        resumedFrom = nil
        lastUserEdit = nil
        dictation.reset()
        rewriter.reset()
        editTracker.reset()
        Task { await dictation.start() }
    }

    /// Reopens a finished dictation from the menu bar: both boxes come back as
    /// they were, and the microphone starts again with the restored words as
    /// the prefix, so anything said now is appended to the end.
    ///
    /// The point is that the rewrite is no longer the only thing that survived
    /// a session. Pasting it directly forced the model's version on the user
    /// even when the transcript held something it had dropped; with both boxes
    /// back, Use and Use Transcript mean what they always meant, and the
    /// rewritten box can simply be edited.
    func resumeSession(from entry: DictationHistory.Entry, target: NSRunningApplication?) {
        Task { await resume(entry, target: target) }
    }

    private func resume(_ entry: DictationHistory.Entry, target: NSRunningApplication?) async {
        // Anything still live has to be torn down *before* the restored text is
        // put in place, for the reason `clearAndRestart` spells out: stopping a
        // recogniser flushes its buffered audio as one last result, and doing
        // that afterwards would drop stale words into the middle of the
        // session we are trying to restore.
        if dictation.isRecording || dictation.state == .preparing {
            await dictation.stop()
            logSession(outcome: .abandoned)
            await Task.yield()
        }

        targetApp = target
        // The profile the session was dictated under, not the one the target
        // app maps to: this is a continuation of that dictation, and a rewrite
        // of the restored words in some other voice is not what reopening it
        // means.
        if let id = profiles.profiles.first(where: { $0.name == entry.profileName })?.id {
            profiles.selectedID = id
        }
        lastError = nil
        didInsert = false
        hasUserEdited = false
        sessionID = UUID()
        sessionStartedAt = Date()
        loggedCurrentSession = false
        resumedFrom = entry.id
        lastUserEdit = nil

        dictation.reset()
        dictation.seed(
            transcript: entry.restoredTranscript,
            alternates: entry.restoredAlternates.map { (name: $0.name, text: $0.text) }
        )
        rewriter.seed(output: entry.restoredRewrite, transcript: entry.restoredTranscript)
        editTracker.reset()
        // The restored text *is* the model's last word on this dictation, so it
        // is the baseline every edit is measured against. Without this the box
        // starts full while the tracker believes it is empty, and the first
        // keystroke reads as "the user inserted <the entire text>" -- which
        // then goes into the next prompt as a binding correction.
        editTracker.setBaseline(entry.restoredRewrite)

        await dictation.start()
    }

    /// Switches to the profile this app is mapped to, and remembers the app so
    /// it appears in Settings with a dropdown of its own.
    ///
    /// Done here, once, rather than continuously: the panel's own profile menu
    /// has to keep working, and a mapping that reasserted itself mid-session
    /// would undo the user's pick the moment they made it.
    private func applyProfile(for target: NSRunningApplication?) {
        guard let target else { return }
        appProfiles.record(target, fallback: profiles.defaultProfileID)
        guard let bundleID = target.bundleIdentifier,
              let assigned = appProfiles.profileID(for: bundleID, among: profiles.profiles),
              assigned != profiles.selectedID
        else { return }
        profiles.selectedID = assigned
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
            // Whatever was restored has just been wiped, so this is no longer
            // a continuation of it.
            resumedFrom = nil

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
            // debounce; `flush` cancels both. Forced, because this is an
            // explicit press: a rewrite that is already streaming this exact
            // text would otherwise make the button a no-op.
            rewriter.flush(transcript: frozen, force: true)
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
    /// Takes whatever is in the output box the instant it is pressed. A rewrite
    /// still streaming is cancelled by `use`, not waited for: Use means "send
    /// what I can see", and a press that stalls on the model is a press the
    /// user has to sit through with their cursor parked in another app. If the
    /// rewriter is slow, the fix belongs in the rewriter's pacing, not here.
    ///
    /// Falls through to the raw transcript when the box is empty. That is
    /// logged as `usedTranscriptNoRewrite` so the statistics stay honest about
    /// how often the model never got a word in.
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
        rewriter.cancel()

        // The recogniser flush and the paste have nothing to do with each
        // other: the text being inserted is already a string in hand, and
        // stopping only matters so the session log gets the final transcript
        // and the mic stops listening. Started here and awaited after the
        // paste, the drain hides behind the activation wait instead of the two
        // adding up.
        let stopping = Task { @MainActor [weak self] in
            guard let self, self.dictation.isRecording else { return }
            await self.dictation.stop()
        }

        let useStarted = ContinuousClock.now
        do {
            try await TextInserter.insert(
                text,
                into: targetApp,
                method: settings.insertionMethod,
                restorePasteboard: settings.restorePasteboard
            )
            // Only after this does the transcript stop changing, so nothing
            // that reads it may run before it.
            let pasted = ContinuousClock.now
            await stopping.value
            let ms = { (d: Duration) -> Int in
                Int(Double(d.components.seconds) * 1000
                    + Double(d.components.attoseconds) / 1e15)
            }
            Self.log.info("""
                use: insert \(ms(pasted - useStarted), privacy: .public)ms, \
                recogniser drain a further \
                \(ms(ContinuousClock.now - pasted), privacy: .public)ms
                """)
            DictationHistory.shared.record(
                text,
                transcript: dictation.transcript,
                alternates: dictation.alternateTranscripts.map {
                    DictationHistory.AlternateReading(name: $0.name, text: $0.text)
                },
                rewrite: rewriter.output,
                profileName: profiles.active.name
            )
            logSession(outcome: outcome)
            didInsert = true
            return true
        } catch {
            // Still let the recogniser finish: the session is over either way,
            // and leaving the microphone open on a failed insertion would be a
            // worse bug than the one that just happened.
            await stopping.value
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
                alternateTranscripts: Dictionary(
                    dictation.alternateTranscripts.map { ($0.name, $0.text) },
                    uniquingKeysWith: { first, _ in first }
                ),
                // Nothing pre-processes the transcript any more, so this is the
                // transcript. Kept as a field because the log format is append-only
                // and older lines still carry a genuinely different value.
                normalizedTranscript: transcript,
                rewrite: rewriter.output,
                editedRewrite: hasUserEdited ? rewriter.output : nil,
                resumedFrom: resumedFrom,
                profile: profiles.active.name,
                backend: settings.backend.rawValue,
                model: {
                    switch settings.backend {
                    case .local:   return settings.localModelRepo
                    case .bedrock: return settings.bedrockModelID
                    default:       return settings.model
                    }
                }(),
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

    /// A panel engine entry: the backend, plus the Bedrock model when the entry
    /// names one. Like any switch, it re-runs the rewrite on what is on screen,
    /// which is what makes alternating Sonnet and Haiku a real comparison.
    func switchEngine(to choice: EngineChoice) {
        if let model = choice.bedrockModelID, model != settings.bedrockModelID {
            settings.bedrockModelID = model
            if settings.backend == choice.backend {
                lastError = nil
                lastUserEdit = nil
                // Forced: the text on screen is usually already settled, and an
                // unforced flush treats that as nothing to do -- so the other
                // model would never get a turn at it.
                rewriter.flush(transcript: dictation.transcript, force: true)
                return
            }
        }
        switchBackend(to: choice.backend)
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
