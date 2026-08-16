import AVFoundation
import Foundation
import Speech

/// Two passes over the same recording.
///
/// Pass one runs offline with `audioTimeRange` attributes, which gives the
/// moment each word's audio *ends*. Pass two plays the file at wall-clock
/// speed and notes when the recogniser first commits to that word. The
/// difference is the delay you actually feel while dictating.
@main
struct Latency {

    struct Config {
        let name: String
        let reporting: Set<SpeechTranscriber.ReportingOption>
    }

    /// Feeds the file as fast as the machine allows.
    static func wordEndTimes(_ url: URL, _ loc: Locale) async throws -> [Double] {
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { return [] }
        let analyzer = SpeechAnalyzer(modules: [t])
        let task = Task { () -> [Double] in
            var ends: [Double] = []
            for try await r in t.results where r.isFinal {
                for run in r.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(r.text[run.range].characters)
                    // One run can cover several words; the end time is shared.
                    let count = piece.split(separator: " ").count
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                    ends.append(contentsOf: Array(repeating: end, count: max(count, 0)))
                }
            }
            return ends
        }
        try await feed(url, into: analyzer, format: fmt)
        return try await task.value
    }

    /// Plays the file in real time and records when each word first appears.
    static func arrivalTimes(_ url: URL, _ config: Config, _ loc: Locale) async throws -> [Double] {
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                  reportingOptions: config.reporting, attributeOptions: [])
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { return [] }
        let analyzer = SpeechAnalyzer(modules: [t])

        let src = try AVAudioFile(forReading: url)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let converter = AVAudioConverter(from: src.processingFormat, to: fmt)!
        converter.primeMethod = .none
        try await analyzer.prepareToAnalyze(in: fmt)
        try await analyzer.start(inputSequence: stream)

        let started = Date()
        let collector = Task { () -> [Double] in
            var firstSeen: [Double] = []      // firstSeen[i] = when word i+1 first existed
            var finalized = ""
            for try await r in t.results {
                let text = r.isFinal ? (finalized + " " + String(r.text.characters))
                                     : (finalized + " " + String(r.text.characters))
                if r.isFinal { finalized += " " + String(r.text.characters) }
                let count = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                let now = Date().timeIntervalSince(started)
                while firstSeen.count < count { firstSeen.append(now) }
            }
            return firstSeen
        }

        // Pace the feed to the audio's own clock.
        var fed: Double = 0
        while true {
            let inBuf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 2048)!
            do { try src.read(into: inBuf) } catch { break }
            if inBuf.frameLength == 0 { break }
            let ratio = fmt.sampleRate / src.processingFormat.sampleRate
            let outBuf = AVAudioPCMBuffer(pcmFormat: fmt,
                frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 2048)!
            var done = false
            var err: NSError?
            _ = converter.convert(to: outBuf, error: &err) { _, status in
                if done { status.pointee = .noDataNow; return nil }
                done = true; status.pointee = .haveData; return inBuf
            }
            if outBuf.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: outBuf)) }
            fed += Double(inBuf.frameLength) / src.processingFormat.sampleRate
            let ahead = fed - Date().timeIntervalSince(started)
            if ahead > 0 { try? await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000_000)) }
        }
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    static func main() async throws {
        let loc = Locale(identifier: "en-US")
        _ = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        let configs = [
            Config(name: "fastResults on", reporting: [.volatileResults, .fastResults]),
            Config(name: "fastResults off", reporting: [.volatileResults]),
        ]
        var all: [String: [Double]] = [:]

        for file in files {
            let ends = try await wordEndTimes(file, loc)
            guard !ends.isEmpty else { continue }
            for config in configs {
                let arrivals = try await arrivalTimes(file, config, loc)
                var lags: [Double] = []
                for i in 0..<min(ends.count, arrivals.count) {
                    let lag = arrivals[i] - ends[i]
                    if lag > -2, lag < 30 { lags.append(lag) }   // drop nonsense
                }
                all[config.name, default: []].append(contentsOf: lags)
                let mean = lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count)
                FileHandle.standardError.write(
                    "  \(file.lastPathComponent) \(config.name): \(lags.count) words, mean \(String(format: "%.2f", mean))s\n"
                        .data(using: .utf8)!)
            }
        }

        print("\n══ word-appearance delay across \(files.count) recordings")
        for (name, lags) in all.sorted(by: { $0.key < $1.key }) {
            guard !lags.isEmpty else { continue }
            let sorted = lags.sorted()
            let mean = lags.reduce(0, +) / Double(lags.count)
            func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }
            print(String(format: "  %-18@ n=%4d  mean %.2fs  median %.2fs  p90 %.2fs  p99 %.2fs",
                         name as NSString, lags.count, mean, pct(0.5), pct(0.9), pct(0.99)))
        }
    }
}
