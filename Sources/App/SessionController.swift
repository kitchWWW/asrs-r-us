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

    init() {
        dictation.onTranscriptChange = { [weak self] transcript in
            self?.rewriter.transcriptChanged(transcript)
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
    }

    var isRecording: Bool { dictation.isRecording }
    var transcript: String { dictation.transcript }
    var canInsert: Bool {
        !rewriter.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Session lifecycle

    /// Begins a fresh session. `target` is captured *before* our panel steals
    /// focus, so we know where to paste.
    func beginSession(target: NSRunningApplication?) {
        targetApp = target
        lastError = nil
        didInsert = false
        hasUserEdited = false
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
            // Let any final result the flush produced land before wiping, so it
            // is discarded rather than arriving after the reset.
            await Task.yield()

            dictation.reset()
            rewriter.reset()
            editTracker.reset()
            lastUserEdit = nil
            hasUserEdited = false
            lastError = nil

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
        }
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

    func useOutput() async -> Bool {
        await use(rewriter.output)
    }

    /// Escape hatch: insert the raw transcript instead of the rewrite, for when
    /// the model's version is not what the user wants.
    func useTranscript() async -> Bool {
        await use(dictation.transcript)
    }

    var canInsertTranscript: Bool {
        !dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func use(_ candidate: String) async -> Bool {
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
            didInsert = true
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
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
