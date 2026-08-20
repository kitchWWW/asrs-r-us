import AVFoundation
import Foundation
import Speech
import os

/// macOS 26's `SpeechTranscriber`, behind `RecognizerBackend`.
///
/// Runs as the cross-check rather than as the transcript: it punctuates and
/// capitalises on its own, which is exactly what this app does not want from a
/// recogniser, but it mishears different words than the transducer does and
/// that disagreement is what settles them.
@MainActor
final class AppleRecognizerBackend: RecognizerBackend {

    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "recognizer.apple")

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var task: Task<Void, Never>?

    private(set) var inputFormat: AVAudioFormat?

    /// Captured once so the audio thread never reads `self`.
    private var continuationBox: AsyncStream<AnalyzerInput>.Continuation?

    /// Converts whatever arrives into the format the analyzer was prepared
    /// for. Idle when this backend is the only one running, because then it is
    /// fed its own format; load-bearing when it rides along behind another
    /// recogniser, because `SpeechAnalyzer` traps rather than tolerates a
    /// format it did not negotiate.
    private nonisolated let resampler = Resampler()

    nonisolated var sink: @Sendable (AVAudioPCMBuffer) -> Void {
        // The continuation is `Sendable` and safe to yield to from any thread,
        // which is the whole reason the analyzer takes an AsyncStream.
        let continuation = MainActor.assumeIsolated { self.continuationBox }
        let resampler = self.resampler
        return { buffer in
            guard let ready = resampler.convert(buffer) else { return }
            continuation?.yield(AnalyzerInput(buffer: ready))
        }
    }

    func prepareToReceive(_ format: AVAudioFormat) {
        guard let target = inputFormat else { return }
        if format != target {
            // Spell out the whole description, not the sample rate and channel
            // count. Those matched exactly in the case that crashed -- 16 kHz
            // mono both sides -- and the incompatibility was in the sample
            // format underneath, which is precisely the part a summary hides.
            log.info("""
                converting capture \(String(describing: format), privacy: .public) \
                into analyzer \(String(describing: target), privacy: .public)
                """)
        }
        resampler.prepare(from: format, to: target)
    }

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else { throw DictationEngine.DictationError.unavailable }

        let locale = await Self.resolveLocale()

        // `.progressiveTranscription` is `[.volatileResults, .fastResults]`.
        // `fastResults` finalises sooner by committing sooner, which costs a
        // little accuracy -- measured over 19 real recordings it kept 10 spoken
        // punctuation words where volatile alone kept 12, with the same mark
        // density. It stays on: this recogniser is now the cross-check, and a
        // reading that lags the transcript by the 2.0s volatile-only costs is
        // a reading of different words than the ones being checked.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        self.transcriber = transcriber
        let module: any SpeechModule = transcriber
        try await ensureModelInstalled(module: transcriber, locale: locale,
                                       installed: await SpeechTranscriber.installedLocales)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else { throw DictationEngine.DictationError.noCompatibleAudioFormat }
        inputFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation
        continuationBox = continuation

        let analyzer = SpeechAnalyzer(modules: [module])
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
    }

    func start(onResult: @escaping (RecognizerResult) -> Void) async throws {
        // Apple's modules deliver *segments*: a final closes one and the next
        // starts empty. Accumulating here keeps the protocol's promise that
        // `text` is always the whole utterance.
        var settled = ""

        task = Task { [weak self] in
            guard let self else { return }
            func publish(_ text: String, _ isFinal: Bool) {
                let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isFinal {
                    if !piece.isEmpty {
                        settled = settled.isEmpty ? piece : settled + " " + piece
                    }
                    onResult((settled, true))
                } else {
                    let combined = settled.isEmpty
                        ? piece
                        : (piece.isEmpty ? settled : settled + " " + piece)
                    onResult((combined, false))
                }
            }

            do {
                if let t = await self.transcriber {
                    for try await result in t.results {
                        await MainActor.run {
                            publish(String(result.text.characters), result.isFinal)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.log.error("recognizer stream ended: \(error.localizedDescription)")
                }
            }
        }
    }

    func finish() async {
        inputBuilder?.finish()
        inputBuilder = nil
        continuationBox = nil
        // Let the analyzer drain what it is still holding so the last words
        // are not dropped.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        task?.cancel()
        task = nil
        analyzer = nil
        transcriber = nil
    }

    // MARK: - Assets

    /// The first run on a given locale may need to download the speech model.
    private func ensureModelInstalled(
        module: any SpeechModule,
        locale: Locale,
        installed: [Locale]
    ) async throws {
        let alreadyInstalled = installed.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        guard !alreadyInstalled else { return }

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module]
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
}
