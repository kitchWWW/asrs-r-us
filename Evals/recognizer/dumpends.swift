import AVFoundation
import Foundation
import Speech

/// Prints, as JSON, the moment each word's audio ends in every recording.
/// This is the shared clock both recognisers are scored against.
@main
struct DumpEnds {
    static func main() async throws {
        let loc = Locale(identifier: "en-US")
        _ = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        var out: [String: [Double]] = [:]
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let t = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                      reportingOptions: [], attributeOptions: [.audioTimeRange])
            guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { continue }
            let analyzer = SpeechAnalyzer(modules: [t])
            let task = Task { () -> [Double] in
                var ends: [Double] = []
                for try await r in t.results where r.isFinal {
                    for run in r.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        let piece = String(r.text[run.range].characters)
                        let count = piece.split(separator: " ").count
                        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                        ends.append(contentsOf: Array(repeating: end, count: max(count, 0)))
                    }
                }
                return ends
            }
            try await feed(url, into: analyzer, format: fmt)
            out[url.lastPathComponent] = try await task.value
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: .prettyPrinted)
        FileHandle.standardOutput.write(data)
    }
}
