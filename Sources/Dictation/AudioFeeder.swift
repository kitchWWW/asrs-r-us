import AVFoundation
import Foundation
import Speech

/// Bridges the real-time audio thread to the speech analyzer's input stream.
///
/// This exists as a separate object so the render callback never has to touch
/// `DictationEngine`, which is `@MainActor`. Hopping actors -- or calling
/// `MainActor.assumeIsolated` -- from the audio thread would trap.
final class AudioFeeder: @unchecked Sendable {

    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    /// Set when the session is being recorded. It receives the same buffer the
    /// analyzer does, after conversion, so the file on disk is exactly what
    /// the recogniser worked from.
    var recorder: SessionAudioRecorder?
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let needsConversion: Bool

    /// Most recent peak level, 0...1. Written from the audio thread and read
    /// from the main thread; a torn read of a `Double` is harmless here since
    /// it only drives a level meter.
    private var level: Double = 0
    var currentLevel: Double { level }

    /// Fails when the device's format cannot be converted to what the analyzer
    /// wants -- multi-channel virtual devices are the usual cause. Returning nil
    /// lets the caller report that instead of feeding the recognizer a buffer
    /// whose layout it does not expect, which crashes inside the framework.
    init?(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        self.continuation = continuation
        self.targetFormat = targetFormat
        self.needsConversion = inputFormat != targetFormat

        if needsConversion {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                return nil
            }
            converter.primeMethod = .none
            self.converter = converter
        } else {
            self.converter = nil
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        level = Self.peakLevel(of: buffer)

        guard needsConversion else {
            recorder?.append(buffer)
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        // `converter` is non-nil whenever needsConversion is true; init fails
        // otherwise. Belt and braces: drop the buffer rather than yield a
        // mismatched one.
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else { return }
        recorder?.append(output)
        continuation.yield(AnalyzerInput(buffer: output))
    }

    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        var samples = 0
        for i in stride(from: 0, to: count, by: 8) {
            sum += channel[i] * channel[i]
            samples += 1
        }
        let rms = sqrt(sum / Float(max(1, samples)))
        // Map roughly -50 dBFS...0 dBFS onto 0...1.
        let db = 20 * log10(max(rms, 1e-7))
        return Double(min(max((db + 50) / 50, 0), 1))
    }
}
