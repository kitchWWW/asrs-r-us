import AVFoundation
import Foundation
import Speech

@main
struct Real {
    static func run(_ url: URL, _ module: any SpeechModule) async throws -> String {
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            return "<none>"
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let task = Task { () -> String in
            var parts: [String] = []
            if let t = module as? SpeechTranscriber {
                for try await r in t.results where r.isFinal { parts.append(String(r.text.characters)) }
            } else if let t = module as? DictationTranscriber {
                for try await r in t.results where r.isFinal { parts.append(String(r.text.characters)) }
            }
            return parts.joined(separator: " ")
        }
        try await feed(url, into: analyzer, format: fmt)
        return try await task.value
    }

    static func main() async throws {
        let loc = Locale(identifier: "en-US")
        _ = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        let marks = CharacterSet(charactersIn: ".,;:!?")
        let spokenWords = ["comma", "period", "colon", "quote", "parenthes", "paren"]

        var totals: [String: (marks: Int, words: Int, tokens: Int)] = [:]
        for file in files {
            print("\n══ \(file.lastPathComponent)")
            for (label, module) in [
                ("volatile only (now)", SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []) as any SpeechModule),
                ("+ fastResults (before)", SpeechTranscriber(locale: loc, preset: .progressiveTranscription)),
                ("DictationTranscriber", DictationTranscriber(locale: loc, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [])),
            ] {
                let out = try await run(file, module)
                let m = out.unicodeScalars.filter { marks.contains($0) }.count
                let lower = out.lowercased()
                let w = spokenWords.reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
                let tokens = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                let prev = totals[label] ?? (0, 0, 0)
                totals[label] = (prev.marks + m, prev.words + w, prev.tokens + tokens)
                print("  \(label.padding(toLength: 24, withPad: " ", startingAt: 0)) marks=\(m) punctuation-words=\(w)")
                if ProcessInfo.processInfo.environment["VERBOSE"] != nil {
                    print("      \(out.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(300))")
                }
            }
        }
        print("\n══ totals across \(files.count) recordings")
        for (label, t) in totals.sorted(by: { $0.key < $1.key }) {
            let rate = t.tokens > 0 ? Double(t.marks) / Double(t.tokens) * 100 : 0
            print(String(format: "  %-24@ marks=%4d (%.1f per 100 words)  punctuation-words=%3d  words=%5d",
                         label as NSString, t.marks, rate, t.words, t.tokens))
        }
    }
}
