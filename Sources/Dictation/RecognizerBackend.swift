import AVFoundation
import Foundation

/// One recogniser, behind one interface.
///
/// `DictationEngine` owns the microphone, the device selection, the level
/// meter and the session recording; none of that changes when the recogniser
/// does. What changes is only this: what audio format to convert to, where the
/// buffers go, and how results come back. Keeping the boundary here is what
/// lets Apple's in-process modules and a sidecar model be swapped from a
/// picker without the audio path knowing which is running.
///
/// The contract deliberately does not include a "final" concept beyond the
/// flag on `Result`. Whether finals mean anything at all is a property of the
/// recogniser -- an append-only transducer never revises, so every result of
/// its is already permanent -- and `RewriteService` reads
/// `RecognizerChoice.revisesText` to decide what to do about that, rather than
/// each backend pretending to a distinction it does not have.
/// A transcript update.
///
/// `text` is always the complete transcript for the utterance so far, not a
/// delta. Backends that receive deltas accumulate internally, because every
/// consumer wants the whole thing and reassembling it in three places invites
/// three different bugs.
///
/// Named rather than nested, so it does not shadow Swift's own `Result` inside
/// every conforming type.
typealias RecognizerResult = (text: String, isFinal: Bool)

@MainActor
protocol RecognizerBackend: AnyObject {

    /// The audio format this recogniser wants to be fed, resolved during
    /// `prepare()`. `AudioFeeder` converts the microphone's format to it.
    var inputFormat: AVAudioFormat? { get }

    /// Loads models, starts processes, and works out `inputFormat`.
    /// Throws if the recogniser cannot be brought up at all.
    func prepare() async throws

    /// Tells the backend what format buffers will actually arrive in.
    ///
    /// Only meaningful when several recognisers share one capture: they cannot
    /// all be fed their preferred format, so whoever is fussiest wins and the
    /// rest adapt here. Called once, before the tap is installed, so any
    /// converter is built off the audio thread rather than inside it.
    func prepareToReceive(_ format: AVAudioFormat)

    /// Begins recognition. Results arrive on the main actor until `finish()`.
    func start(onResult: @escaping (RecognizerResult) -> Void) async throws

    /// Where converted audio buffers should be delivered.
    ///
    /// Called on the real-time audio thread, so implementations must not hop
    /// actors, allocate unboundedly, or take a lock that anything else holds.
    nonisolated var sink: @Sendable (AVAudioPCMBuffer) -> Void { get }

    /// Flushes any audio still held and stops. Must be safe to call twice.
    func finish() async
}

extension RecognizerBackend {
    /// Most backends are fed exactly what they asked for and need nothing here.
    func prepareToReceive(_ format: AVAudioFormat) {}
}

/// Converts a float PCM buffer to the interleaved 16-bit little-endian bytes
/// every sidecar recogniser expects.
///
/// Shared rather than duplicated per backend: getting the scaling or the
/// clamping subtly wrong produces audio that still transcribes, just worse,
/// which is exactly the kind of bug that survives review.
@inline(__always)
func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return nil }

    if let ints = buffer.int16ChannelData {
        return Data(bytes: ints[0], count: frames * MemoryLayout<Int16>.size)
    }
    guard let floats = buffer.floatChannelData else { return nil }

    var out = [Int16](repeating: 0, count: frames)
    let channel = floats[0]
    for i in 0..<frames {
        // Clamp before scaling: a converter can overshoot slightly past 1.0,
        // and letting that wrap turns a loud syllable into a burst of noise.
        let clamped = max(-1.0, min(1.0, channel[i]))
        out[i] = Int16(clamped * 32767.0)
    }
    return out.withUnsafeBufferPointer { Data(buffer: $0) }
}

/// Converts capture buffers to the format one recogniser expects.
///
/// Exists because several recognisers share one microphone tap and cannot all
/// be fed their preferred format: the fan-out converts once to the primary's
/// format, and every other backend closes the remaining gap here.
///
/// Every backend that can receive a format it did not choose needs one of
/// these, and Apple's needs it most. `SpeechAnalyzer` is prepared for exactly
/// the format it negotiated and traps inside the framework when handed
/// anything else -- an `EXC_BREAKPOINT` with a stack entirely inside Speech,
/// which is what pressing F7 produced when Apple ran as a secondary and was
/// fed the transducer's 16 kHz mono.
///
/// It is deliberately a plain software converter: nothing here opens, selects,
/// or configures an audio device, so adding recognisers cannot disturb the
/// carefully-ordered device handling in `DictationEngine.startAudio()` -- and
/// in particular cannot cause the implicit `inputNode` read that flips a
/// Bluetooth headset into hands-free.
final class Resampler: @unchecked Sendable {

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?

    /// Called before the tap is installed, so nothing is allocated on the
    /// real-time audio thread.
    func prepare(from source: AVAudioFormat, to target: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.target = target
        guard source != target else {
            converter = nil
            return
        }
        let converter = AVAudioConverter(from: source, to: target)
        converter?.primeMethod = .none
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let target else { return buffer }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
