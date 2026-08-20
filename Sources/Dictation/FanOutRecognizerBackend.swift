import AVFoundation
import Foundation
import os

/// Runs several recognisers over one microphone and reports them all.
///
/// The point is disagreement. Independent recognisers make independent
/// mistakes: the same second of audio comes back as "comma" from one, "karma"
/// from another and "colin" from a third, and three readings that differ tell
/// the rewrite model far more than one confident wrong one. Only the primary
/// is shown in the panel -- the rest ride along as evidence, reaching the model
/// through the prompt.
///
/// **This does not touch the audio device.** There is still exactly one
/// `AVAudioEngine`, one read of `inputNode`, one tap, and one device
/// resolution, all of it left in `DictationEngine.startAudio()` exactly as it
/// was. The fan-out happens strictly downstream: a buffer that has already
/// been captured and converted is handed to each child's `sink`. That ordering
/// is not an implementation detail -- reading `inputNode` a second time, or
/// standing up a second engine, is what silently flips a Bluetooth headset
/// into hands-free and leaves it there. Children adapt to the format they are
/// given, in software, and never ask the system for anything.
@MainActor
final class FanOutRecognizerBackend: RecognizerBackend {

    /// The recogniser whose text fills the panel and drives the rewrite.
    private let primary: any RecognizerBackend
    /// Everyone else, kept for their disagreement.
    private let secondaries: [(choice: RecognizerChoice, backend: any RecognizerBackend)]
    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "recognizer.fanout")

    /// Latest text from each secondary, by recogniser. Read when a rewrite is
    /// assembled; never shown in the panel.
    private(set) var alternates: [RecognizerChoice: String] = [:]

    var inputFormat: AVAudioFormat? { primary.inputFormat }

    init(primary: any RecognizerBackend,
         secondaries: [(choice: RecognizerChoice, backend: any RecognizerBackend)]) {
        self.primary = primary
        self.secondaries = secondaries
    }

    func prepare() async throws {
        // The primary must come up or there is no dictation. A secondary that
        // fails is a lost second opinion, not a lost session, so it is logged
        // and dropped rather than thrown.
        try await primary.prepare()

        for (choice, backend) in secondaries {
            do {
                try await backend.prepare()
            } catch {
                log.error("""
                    \(choice.shortName, privacy: .public) is not available and will \
                    not contribute: \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    func prepareToReceive(_ format: AVAudioFormat) {
        // Everyone is fed whatever the primary negotiated; the children adapt.
        primary.prepareToReceive(format)
        for (_, backend) in secondaries { backend.prepareToReceive(format) }
    }

    func start(onResult: @escaping (RecognizerResult) -> Void) async throws {
        try await primary.start(onResult: onResult)

        for (choice, backend) in secondaries {
            do {
                try await backend.start { [weak self] result in
                    self?.alternates[choice] = result.text
                }
            } catch {
                log.error("""
                    \(choice.shortName, privacy: .public) failed to start: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    nonisolated var sink: @Sendable (AVAudioPCMBuffer) -> Void {
        // Resolved once, here, rather than per buffer: `sink` is a computed
        // property on each child and the audio thread must not be paying for
        // that lookup, nor for touching this object at all.
        let sinks = MainActor.assumeIsolated {
            [primary.sink] + secondaries.map(\.backend.sink)
        }
        return { buffer in
            for sink in sinks { sink(buffer) }
        }
    }

    func finish() async {
        await primary.finish()
        for (_, backend) in secondaries { await backend.finish() }
    }
}
