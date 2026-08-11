import AVFoundation
import Foundation
import Speech
import os

/// Number of level samples kept for the waveform display. File scope because
/// `Self` cannot be referenced from a stored property initializer.
let waveformSampleCount = 22

/// Streaming on-device speech recognition built on macOS 26's `SpeechAnalyzer`
/// / `SpeechTranscriber`.
///
/// The transcriber emits two kinds of result: *volatile* (a best guess for
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

    var transcript: String {
        volatileText.isEmpty
            ? finalizedText
            : (finalizedText.isEmpty ? volatileText : finalizedText + " " + volatileText)
    }

    var isRecording: Bool { state == .recording }

    /// Called on every transcript change so callers can kick off a rewrite.
    var onTranscriptChange: ((String) -> Void)?

    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "dictation")

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
    /// System default input to put back when the session ends, if we changed it.
    private var defaultInputToRestore: AudioDeviceID?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var feeder: AudioFeeder?
    private var levelTimer: Timer?

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
        if case .failed = state {} else { state = .idle }
        log.info("dictation stopped")
    }

    func reset() {
        finalizedText = ""
        volatileText = ""
        if case .failed = state { state = .idle }
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
        guard SpeechTranscriber.isAvailable else { throw DictationError.unavailable }

        let locale = await Self.resolveLocale()

        // `.progressiveTranscription` is the preset that emits volatile results
        // as you speak; the plain `.transcription` preset only reports finals.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        try await ensureModelInstalled(for: transcriber, locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else { throw DictationError.noCompatibleAudioFormat }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Bias the recognizer toward the user's vocabulary. Fixing a term here
        // means the wrong word is never produced, which beats asking the
        // rewrite model to detect and repair it afterwards -- especially for
        // acronyms and proper nouns, where it has no context to work from.
        let terms = AppSettings.shared.dictionaryTerms
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            do {
                try await analyzer.setContext(context)
                log.info("biasing recognizer with \(terms.count) dictionary terms")
            } catch {
                // Biasing is an enhancement; a failure here must not stop
                // dictation from working.
                log.error("could not set contextual strings: \(error.localizedDescription)")
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)

        recognizerTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        if result.isFinal {
                            self.appendFinalized(text)
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        self.onTranscriptChange?(self.transcript)
                    }
                }
            } catch {
                await MainActor.run {
                    self.log.error("recognizer stream ended: \(error.localizedDescription)")
                    self.state = .failed(Self.describe(error))
                }
            }
        }
    }

    private func appendFinalized(_ text: String) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        finalizedText = finalizedText.isEmpty ? piece : finalizedText + " " + piece
    }

    /// The first run on a given locale may need to download the speech model.
    private func ensureModelInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let alreadyInstalled = installed.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        guard !alreadyInstalled else { return }

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            log.info("downloading speech model for \(locale.identifier)")
            try await request.downloadAndInstall()
        }
        // Reserving keeps the model resident so later sessions start instantly.
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    private static func resolveLocale() async -> Locale {
        let current = Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            return match
        }
        return Locale(identifier: "en-US")
    }

    // MARK: - Audio

    private func startAudio() async throws {
        guard let analyzerFormat, let continuation = inputBuilder else {
            throw DictationError.noCompatibleAudioFormat
        }

        // A fresh engine per session. An AVAudioEngine that has already been
        // started keeps its input unit bound to the device it first resolved,
        // and setDeviceID is then ignored -- which is why switching microphones
        // did nothing, and why a connected Bluetooth headset left the engine
        // pointed at a device that produced no audio.
        audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode

        // Bind the device *before* querying the format: the input node reports
        // the format of whichever device it is currently attached to.
        guard let device = AudioDevices.resolve(preferredUID: AppSettings.shared.inputDeviceUID) else {
            throw DictationError.noAudioInput
        }
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
        // Align the system default with the device we are about to record from.
        // CoreAudio starves a non-default input while a Bluetooth headset holds
        // the default -- about one buffer per ten seconds, which reads as "the
        // microphone stopped working" the moment headphones connect. The
        // previous value is restored when the session ends.
        if let currentDefault = AudioDevices.defaultInputDeviceID(), currentDefault != device.id {
            if AudioDevices.setDefaultInputDevice(device.id) {
                defaultInputToRestore = currentDefault
                log.info("temporarily set system default input to \(device.name)")
                // Give CoreAudio a moment to settle before opening the stream.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
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
        guard let feeder = AudioFeeder(
            continuation: continuation,
            inputFormat: inputFormat,
            targetFormat: analyzerFormat
        ) else {
            throw DictationError.incompatibleInputDevice(
                name: activeInputDeviceName ?? "This microphone",
                channels: Int(inputFormat.channelCount)
            )
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

    /// Synchronous safety net for app termination: `teardown` is async and may
    /// not finish if we are being torn down, and leaving the user's default
    /// input pointing somewhere they did not choose would outlive the app.
    func restoreDefaultInputIfNeeded() {
        guard let restore = defaultInputToRestore else { return }
        AudioDevices.setDefaultInputDevice(restore)
        defaultInputToRestore = nil
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
        inputBuilder?.finish()
        inputBuilder = nil

        // Flush trailing audio through the analyzer before dropping it, so the
        // tail of the last sentence still lands as a final result.
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil

        recognizerTask?.cancel()
        recognizerTask = nil
        transcriber = nil
        if let restore = defaultInputToRestore {
            AudioDevices.setDefaultInputDevice(restore)
            defaultInputToRestore = nil
        }

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
        case noCompatibleAudioFormat
        case noAudioInput
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
            case .noCompatibleAudioFormat:
                return "Could not negotiate an audio format with the speech recognizer."
            case .noAudioInput:
                return "No audio input device is available."
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
