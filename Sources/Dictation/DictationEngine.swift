import AVFoundation
import Foundation
import Speech
import os

/// Number of level samples kept for the waveform display. File scope because
/// `Self` cannot be referenced from a stored property initializer.
let waveformSampleCount = 22

/// Streaming speech recognition, whichever recogniser is selected.
///
/// This owns the microphone, the device binding, the level meter and the
/// session recording. Which recogniser turns the audio into words is behind
/// `RecognizerBackend`, so Apple's in-process modules and the sidecar models
/// swap without any of that changing. `configurePipeline()` is the only place
/// that knows the difference.
///
/// A recogniser emits two kinds of result: *volatile* (a best guess for
/// audio still in flight, replaced as more arrives) and *final* (locked in).
/// We keep them separate so the UI can show settled text plainly and in-flight
/// text dimmed, and so downstream consumers can debounce on the combined value.
@MainActor
final class DictationEngine: ObservableObject {

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Text the recognizer has committed to.
    @Published private(set) var finalizedText: String = ""
    /// Current best guess for audio still being processed.
    @Published private(set) var volatileText: String = ""
    /// Rough input level, 0...1, for the level meter.
    @Published private(set) var inputLevel: Double = 0
    /// Name of the microphone actually in use, once resolved.
    @Published private(set) var activeInputDeviceName: String?
    /// Rolling window of recent levels, oldest first, for the waveform display.
    @Published private(set) var levelHistory: [Double] = Array(repeating: 0, count: waveformSampleCount)

    /// The cross-check recogniser's reading, split the same way, for the
    /// panel's transcript box only. Purely cosmetic: `transcript`, the rewrite,
    /// Use transcript and the session log all stay on the record recogniser.
    @Published private(set) var shownFinalizedText: String = ""
    @Published private(set) var shownVolatileText: String = ""

    var transcript: String {
        volatileText.isEmpty
            ? finalizedText
            : (finalizedText.isEmpty ? volatileText : finalizedText + " " + volatileText)
    }

    var isRecording: Bool { state == .recording }

    /// Called on every transcript change so callers can kick off a rewrite.
    ///
    /// `isFinal` marks a result the recognizer has committed to: those words
    /// will not be revised, so a rewrite of them is not speculative and does
    /// not need to wait out a debounce.
    var onTranscriptChange: ((_ transcript: String, _ isFinal: Bool) -> Void)?

    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "dictation")

    /// Supervises the sidecar process for the recognisers that need one.
    /// Held here rather than created per session so the model is not reloaded
    /// on every press of F7.
    let serverManager: RecognizerServerManager

    init(serverManager: RecognizerServerManager) {
        self.serverManager = serverManager
    }

    /// Recreated for every session -- see `startAudio()`.
    private var audioEngine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var isRestartingForConfigChange = false
    /// The device the running engine is actually bound to.
    private var boundDeviceID: AudioDeviceID?
    /// When capture last came up, used to ignore the engine's own start-up churn.
    private var audioStartedAt: Date?
    private var rebuildCount = 0
    private var lastRebuildAt: Date?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    /// The recogniser doing the work this session. Rebuilt per session, so
    /// changing the setting between sessions takes effect without a restart.
    private var backend: (any RecognizerBackend)?
    /// Which recogniser `backend` is, kept for the session log and so the
    /// rewrite service can ask about revision behaviour.
    private(set) var activeRecognizer: RecognizerChoice = .punctuated
    private var analyzerFormat: AVAudioFormat?
    private var feeder: AudioFeeder?
    /// Text finalised by earlier start/stop cycles in this same session, which
    /// the current backend knows nothing about. See `handle(text:isFinal:)`.
    private var carriedText = ""
    /// Set when several recognisers are running, so their disagreement can be
    /// read off when a rewrite is assembled.
    private weak var alternateSource: FanOutRecognizerBackend?
    /// The same idea as `carriedText`, for the recognisers that ride along:
    /// what they heard before the current backend existed, keyed by display
    /// name. Filled when a backend is torn down and when a stored session is
    /// restored, so a second opinion survives a stop/start pair instead of
    /// vanishing with the object that produced it -- `alternateSource` is weak,
    /// and teardown is the moment it goes.
    private var carriedAlternates: [String: String] = [:]

    /// What the other recognisers heard, for the rewrite prompt. Empty unless
    /// cross-checking is on.
    var alternateTranscripts: [(name: String, text: String)] {
        var merged = carriedAlternates
        for (choice, text) in alternateSource?.alternates ?? [:] {
            let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let name = choice.shortName
            if let carried = merged[name], !carried.isEmpty {
                merged[name] = carried + " " + piece
            } else {
                merged[name] = piece
            }
        }
        return merged
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (name: $0.key, text: $0.value) }
            .sorted { $0.name < $1.name }
    }
    private var levelTimer: Timer?

    /// Lives across a stop/start pair so pressing Run mid-dictation does not
    /// split the session into two files -- the same rule `finalizedText`
    /// follows. `finishRecording` is what ends it.
    private var recorder: SessionAudioRecorder?

    // MARK: - Control

    /// Starts, or resumes, recognition.
    ///
    /// Resuming *appends* to whatever has already been transcribed: pressing
    /// Stop and then Record again continues the same dictation instead of
    /// starting over. Only `reset()` clears the transcript, and a new session
    /// calls it explicitly.
    func start() async {
        guard state != .recording && state != .preparing else { return }
        state = .preparing
        // Deliberately does not touch `finalizedText` -- see the note above.
        // The volatile tail belongs to the previous recognizer instance, which
        // is gone, so it is dropped.
        volatileText = ""
        inputLevel = 0

        do {
            try await authorize()
            try await configurePipeline()
            try await startAudio()
            // A stop can land while the awaits above are suspended: `stop()`
            // accepts `.preparing`, and starting up yields more than once (asset
            // reservation, the CoreAudio settling sleep). Coming back to find
            // the session already cancelled means everything just built is
            // orphaned -- an engine nobody will ever stop, holding an open input
            // node. Undo it instead of declaring ourselves live.
            guard state == .preparing else {
                await teardown()
                return
            }
            state = .recording
            log.info("dictation started")
        } catch {
            log.error("dictation failed to start: \(error.localizedDescription)")
            await teardown()
            state = .failed(Self.describe(error))
        }
    }

    /// Stops the microphone and waits for the recognizer to flush any audio it
    /// is still holding, so the last words are not dropped.
    func stop() async {
        guard state == .recording || state == .preparing else { return }
        await teardown()
        // Whatever this backend produced becomes the prefix the next one
        // continues from.
        carriedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .failed = state {} else { state = .idle }
        log.info("dictation stopped")
    }

    /// Closes the session's recording and reports where it landed. Called when
    /// the session is written to the log, so the two land together.
    @discardableResult
    func finishRecording() -> URL? {
        defer { recorder = nil }
        return recorder?.finish()
    }

    func reset() {
        // A session nobody logged still has to release its file.
        finishRecording()
        carriedText = ""
        carriedAlternates = [:]
        finalizedText = ""
        volatileText = ""
        shownFinalizedText = ""
        shownVolatileText = ""
        if case .failed = state { state = .idle }
    }

    /// Restores a finished dictation so speaking again continues it.
    ///
    /// Exactly what a stop/start pair leaves behind, assembled from a stored
    /// session instead of from a backend that has just been torn down: the old
    /// words become the prefix every future result is appended to, and the old
    /// second opinions become the prefix of the new ones. Call after `reset()`
    /// and before `start()`.
    func seed(transcript: String, alternates: [(name: String, text: String)]) {
        let restored = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        carriedText = restored
        finalizedText = restored
        volatileText = ""
        carriedAlternates = Dictionary(
            alternates.map { ($0.name, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
        shownFinalizedText = carriedAlternates[RecognizerChoice.crossCheck.shortName] ?? ""
        shownVolatileText = ""
    }

    // MARK: - Permissions

    private func authorize() async throws {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { throw DictationError.microphoneDenied }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { throw DictationError.speechDenied }
    }

    // MARK: - Pipeline

    private func configurePipeline() async throws {
        // Both recognisers, every session. There is no setting: the pair was
        // chosen by measurement and there is nothing left to pick between.
        // The record's text drives the rewrite; the cross-check's reaches the
        // rewrite prompt as evidence about individual words. The panel shows the
        // cross-check's -- a display choice only, see `showCrossCheck`.
        func make(_ choice: RecognizerChoice) -> any RecognizerBackend {
            choice.isSidecar
                ? SocketRecognizerBackend(choice: choice, manager: serverManager)
                : AppleRecognizerBackend()
        }

        activeRecognizer = .record
        let fanOut = FanOutRecognizerBackend(
            primary: make(.record),
            secondaries: [(.crossCheck, make(.crossCheck))]
        )
        alternateSource = fanOut
        fanOut.onAlternateResult = { [weak self] choice, result in
            guard choice == .crossCheck else { return }
            self?.showCrossCheck(text: result.text, isFinal: result.isFinal)
        }
        let backend: any RecognizerBackend = fanOut
        self.backend = backend

        try await backend.prepare()
        guard let format = backend.inputFormat else {
            throw DictationError.noCompatibleAudioFormat
        }
        analyzerFormat = format

        try await backend.start { [weak self] result in
            self?.handle(text: result.text, isFinal: result.isFinal)
        }
    }

    /// A backend always reports the whole utterance, never a delta -- see the
    /// note on `RecognizerResult`. So this assigns rather than appends; the
    /// accumulation that used to live here moved into the Apple backend, which
    /// is the only one that receives segments.
    ///
    /// `carriedText` is what makes resuming work. A backend is built per
    /// session and starts with nothing, so without this, pressing Stop and then
    /// Record again would replace the dictation so far instead of continuing
    /// it -- the behaviour `start()` promises and `reset()` is the only thing
    /// allowed to undo.
    private func handle(text: String, isFinal: Bool) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = carriedText.isEmpty
            ? piece
            : (piece.isEmpty ? carriedText : carriedText + " " + piece)

        if isFinal {
            finalizedText = whole
            volatileText = ""
        } else {
            // Nothing new yet: leave what is already on screen alone rather
            // than blanking it, which some recognisers would do between
            // utterances.
            guard !piece.isEmpty else { return }
            finalizedText = ""
            volatileText = whole
        }
        onTranscriptChange?(transcript, isFinal)
    }

    /// `handle(text:isFinal:)` for the cross-check's reading, minus everything
    /// downstream: it only updates what the transcript box shows. The prefix
    /// from earlier start/stop cycles is the one `alternateTranscripts` uses.
    private func showCrossCheck(text: String, isFinal: Bool) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let carried = carriedAlternates[RecognizerChoice.crossCheck.shortName] ?? ""
        let whole = carried.isEmpty
            ? piece
            : (piece.isEmpty ? carried : carried + " " + piece)

        if isFinal {
            shownFinalizedText = whole
            shownVolatileText = ""
        } else {
            guard !piece.isEmpty else { return }
            shownFinalizedText = ""
            shownVolatileText = whole
        }
    }

    // MARK: - Audio

    private func startAudio() async throws {
        guard let analyzerFormat, let backend else {
            throw DictationError.noCompatibleAudioFormat
        }

        // Resolve the device before the engine exists: the ordering below turns
        // on already knowing where we are going to record from.
        guard let device = AudioDevices.resolve(preferredUID: AppSettings.shared.inputDeviceUID) else {
            // Distinguish "nothing is plugged in" from "the only thing plugged
            // in is a headset we refuse to open", which is a dead end the user
            // can actually do something about.
            throw AudioDevices.hasWithheldBluetoothInput()
                ? DictationError.onlyBluetoothInputs
                : DictationError.noAudioInput
        }

        // Make certain the default input is not a Bluetooth device *before* an
        // input node exists. `DefaultInputGuard` normally has this handled
        // already; this is the synchronous belt-and-braces for the case where a
        // headset connected moments ago and the guard's listener has not run.
        //
        // The ordering is the entire point, and having it backwards is what
        // quietly degraded the headphones for as long as the app was running:
        // `AVAudioEngine.inputNode` instantiates its audio unit already bound to
        // whatever holds the default input, so merely reading that property
        // while a headset holds it opens the headset microphone and flips it
        // into hands-free. Measured on a QC45: reading `inputNode` dropped its
        // output from 2 ch / 44.1 kHz to 1 ch / 16 kHz instantly, before any
        // setDeviceID call, and it stayed there after the engine stopped. The
        // later `setDeviceID` cannot undo it -- by then the profile has flipped.
        //
        // Nothing is recorded for a later restore. The default belongs on a
        // non-Bluetooth mic permanently; handing it back is what used to
        // re-trigger the very profile switch this avoids.
        if let currentDefault = AudioDevices.defaultInputDeviceID(),
           AudioDevices.isBluetooth(currentDefault) {
            DefaultInputGuard.shared.enforce()
            // Let CoreAudio settle before the input node latches onto it.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // A fresh engine per session. An AVAudioEngine that has already been
        // started keeps its input unit bound to the device it first resolved,
        // and setDeviceID is then ignored -- which is why switching microphones
        // did nothing, and why a connected Bluetooth headset left the engine
        // pointed at a device that produced no audio.
        audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode

        // Bind the device explicitly anyway: the default is not always ours,
        // and the node reports the format of whichever device it is attached
        // to, so this has to happen before the format is queried.
        do {
            try input.auAudioUnit.setDeviceID(device.id)
        } catch {
            throw DictationError.deviceUnavailable(name: device.name)
        }
        // Confirm it actually took. Silently recording from the wrong device --
        // or from one that yields silence -- is a worse failure than saying so.
        guard input.auAudioUnit.deviceID == device.id else {
            throw DictationError.deviceUnavailable(name: device.name)
        }

        activeInputDeviceName = device.name
        boundDeviceID = device.id
        log.info("capturing from \(device.name)")

        // `inputFormat`, not `outputFormat`. After switching devices the node's
        // *output* format still describes the previous default device, and
        // installing a tap with it delivers nothing at all -- measured: with a
        // 16 kHz device as the system default, outputFormat reported
        // 44100 Hz / 2 ch and zero buffers arrived, while inputFormat reported
        // the true 48 kHz / 1 ch and audio flowed. This is what broke capture
        // whenever Bluetooth headphones were connected, since macOS makes the
        // headset the default input and its hands-free profile runs at 16 kHz.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw DictationError.noAudioInput }

        // Everything the audio thread touches is captured into this object up
        // front. The render callback must never hop actors or take locks, so
        // it deliberately holds no reference back to DictationEngine.
        // Before the tap, never inside it: any converter a backend needs is
        // built here, off the real-time audio thread. Note that this changes
        // nothing about the device itself -- the engine, the inputNode read and
        // the tap below are exactly as they were with a single recogniser.
        backend.prepareToReceive(analyzerFormat)

        guard let feeder = AudioFeeder(
            sink: backend.sink,
            inputFormat: inputFormat,
            targetFormat: analyzerFormat
        ) else {
            throw DictationError.incompatibleInputDevice(
                name: activeInputDeviceName ?? "This microphone",
                channels: Int(inputFormat.channelCount)
            )
        }
        if AppSettings.shared.recordSessionAudio {
            if recorder == nil { recorder = SessionAudioRecorder(url: SessionAudio.newFileURL()) }
            feeder.recorder = recorder
        }
        self.feeder = feeder

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            feeder.feed(buffer)
        }

        // Poll the level on the main actor instead of dispatching from the
        // audio thread once per buffer.
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let feeder = self.feeder else { return }
                let level = feeder.currentLevel
                self.inputLevel = level
                self.levelHistory.removeFirst()
                self.levelHistory.append(level)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        audioStartedAt = Date()

        installDefaultInputListener()

        // Connecting or removing an audio device invalidates the engine's
        // configuration; without rebuilding it the taps keep firing but deliver
        // nothing. This is what made plugging in headphones mid-session kill
        // capture with no visible error.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleConfigurationChange() }
        }
    }

    /// Watches for another device seizing the system default input.
    ///
    /// Connecting headphones mid-session does not change *our* device, so the
    /// engine's own configuration-change notification is not enough to catch it
    /// -- but it does hand the default to the headset, which starves whatever
    /// else is recording. This is the signal that matters.
    private func installDefaultInputListener() {
        guard defaultInputListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in await self?.handleDefaultInputChanged() }
        }
        defaultInputListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        defaultInputListener = nil
    }

    /// Takes the default back and rebuilds when something else claims it.
    private func handleDefaultInputChanged() async {
        guard state == .recording, !isRestartingForConfigChange, let bound = boundDeviceID,
              let current = AudioDevices.defaultInputDeviceID(), current != bound
        else { return }

        if let last = lastRebuildAt, Date().timeIntervalSince(last) > 10 { rebuildCount = 0 }
        guard rebuildCount < 3 else {
            log.error("default input kept changing; leaving capture alone")
            return
        }
        rebuildCount += 1
        lastRebuildAt = Date()

        isRestartingForConfigChange = true
        defer { isRestartingForConfigChange = false }

        log.info("another device took the default input; reclaiming it and rebuilding")
        await stop()
        await start()
    }

    /// Rebuilds capture after the audio hardware changes underneath us,
    /// keeping whatever has already been transcribed.
    private func handleConfigurationChange() async {
        guard state == .recording, !isRestartingForConfigChange else { return }

        // Bringing an engine up emits a configuration change of its own. Without
        // this settling window the rebuild retriggers itself immediately and the
        // engine thrashes: the notification arrives after the in-flight guard
        // has already been cleared, so the guard alone cannot stop it.
        if let started = audioStartedAt, Date().timeIntervalSince(started) < 2 { return }

        // Rebuild only when something that matters actually moved -- the device
        // we are on has disappeared, or the one we should be on is now a
        // different device. Any other configuration churn is none of our
        // business, and reacting to it is what caused the thrashing.
        let available = AudioDevices.inputDevices()
        let boundStillExists = available.contains { $0.id == boundDeviceID }
        let desired = AudioDevices.resolve(preferredUID: AppSettings.shared.inputDeviceUID)
        guard !boundStillExists || desired?.id != boundDeviceID else { return }

        // A device that keeps reconfiguring should not take the app with it.
        if let last = lastRebuildAt, Date().timeIntervalSince(last) > 10 { rebuildCount = 0 }
        guard rebuildCount < 3 else {
            log.error("audio kept reconfiguring; leaving capture alone")
            return
        }
        rebuildCount += 1
        lastRebuildAt = Date()

        isRestartingForConfigChange = true
        defer { isRestartingForConfigChange = false }

        log.info("input device changed; rebuilding capture")
        await stop()
        await start()
    }

    // MARK: - Teardown

    private func teardown() async {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        removeDefaultInputListener()

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        levelTimer?.invalidate()
        levelTimer = nil
        feeder = nil

        // Flush trailing audio through the recogniser before dropping it, so
        // the tail of the last sentence still lands as a final result. Each
        // backend knows what that means for itself.
        await backend?.finish()
        // Read the second opinions out *before* the backend goes: they live on
        // the fan-out object, which `alternateSource` only holds weakly, so a
        // moment from now there is nothing left to read them from.
        carriedAlternates = Dictionary(
            alternateTranscripts.map { ($0.name, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
        backend = nil
        // Drop the input node along with the engine. A stopped AVAudioEngine is
        // not an inert one -- its node stays instantiated and re-resolves when
        // the default input changes underneath it, which would open whatever
        // arrived next. The replacement is safe to hold: an engine only binds to
        // a device once `inputNode` is read, and that does not happen again
        // until the next session.
        audioEngine = AVAudioEngine()

        analyzerFormat = nil
        boundDeviceID = nil
        audioStartedAt = nil
        inputLevel = 0
        levelHistory = Array(repeating: 0, count: waveformSampleCount)
    }

    // MARK: - Errors

    enum DictationError: LocalizedError {
        case microphoneDenied
        case speechDenied
        case unavailable
        /// A sidecar recogniser could not be brought up. Carries the manager's
        /// own message, which usually names the setup step that is missing.
        case recognizerUnavailable(String)
        case noCompatibleAudioFormat
        case noAudioInput
        case onlyBluetoothInputs
        case deviceUnavailable(name: String)
        case incompatibleInputDevice(name: String, channels: Int)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
            case .speechDenied:
                return "Speech recognition access denied. Enable it in System Settings > Privacy & Security > Speech Recognition."
            case .unavailable:
                return "On-device speech recognition is unavailable on this Mac."
            case let .recognizerUnavailable(message):
                return message
            case .noCompatibleAudioFormat:
                return "Could not negotiate an audio format with the speech recognizer."
            case .noAudioInput:
                return "No audio input device is available."
            case .onlyBluetoothInputs:
                return "The only microphone available is a Bluetooth one, which this app will not record from — using it would drop your headphones to call quality. Connect a wired or built-in mic."
            case let .deviceUnavailable(name):
                return "Could not record from \(name). Choose a different microphone." 
            case let .incompatibleInputDevice(name, channels):
                return "\(name) (\(channels) channels) cannot be used for speech recognition. Choose a different microphone."
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
