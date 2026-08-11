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
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let needsConversion: Bool

    /// Most recent peak level, 0...1. Written from the audio thread and read
    /// from the main thread; a torn read of a `Double` is harmless here since
    /// it only drives a level meter.
    private var level: Double = 0
    var currentLevel: Double { level }

    init(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) {
        self.continuation = continuation
        self.targetFormat = targetFormat
        self.needsConversion = inputFormat != targetFormat
        if needsConversion {
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converter?.primeMethod = .none
            self.converter = converter
        } else {
            self.converter = nil
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        level = Self.peakLevel(of: buffer)

        guard needsConversion, let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

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
