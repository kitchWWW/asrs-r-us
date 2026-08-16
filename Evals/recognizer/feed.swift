import AVFoundation
import Foundation
import Speech

func note(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Feeds a file through the analyzer the same way the app feeds the microphone.
func feed(_ url: URL, into analyzer: SpeechAnalyzer, format: AVAudioFormat) async throws {
    let src = try AVAudioFile(forReading: url)
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let converter = AVAudioConverter(from: src.processingFormat, to: format)!
    converter.primeMethod = .none

    do { try await analyzer.prepareToAnalyze(in: format) }
    catch { note("prepareToAnalyze failed: \(error)"); throw error }
    do { try await analyzer.start(inputSequence: stream) }
    catch { note("start failed: \(error)"); throw error }
    note("analyzer started; feeding \(src.length) frames")

    while true {
        let inBuf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 4096)!
        do { try src.read(into: inBuf) }
        catch { note("read stopped: \(error)"); break }
        if inBuf.frameLength == 0 { break }
        let ratio = format.sampleRate / src.processingFormat.sampleRate
        let outBuf = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 2048)!
        var done = false
        var err: NSError?
        _ = converter.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        if outBuf.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: outBuf)) }
    }
    continuation.finish()
    note("fed all buffers")
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    note("finalized")
}

