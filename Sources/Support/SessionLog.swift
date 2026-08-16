import AppKit
import Foundation

/// Append-only record of every dictation session, kept so the way the user
/// actually speaks can be studied instead of guessed at.
///
/// Only the transcript side is corpus material. The rewrite and the user's
/// edits are recorded for diagnosis -- to see *what* the model did on real
/// input -- but neither is a gold standard: the user does not correct the
/// rewritten box often enough for its contents to mean "this was right".
/// Anything scoring real sessions has to derive its expectations from the
/// transcript alone.
///
/// The file never leaves this machine. It is plain text containing everything
/// dictated, which is exactly as sensitive as that sounds, so logging is a
/// setting and the file is easy to reveal and delete.
@MainActor
final class SessionLog {
    static let shared = SessionLog()

    enum Outcome: String, Codable {
        /// Inserted the rewritten text.
        case used
        /// Inserted the raw transcript with a rewrite sitting right there --
        /// a signal the rewrite was wrong.
        case usedTranscript
        /// Inserted the raw transcript because no rewrite had arrived yet.
        /// Kept apart from `usedTranscript` because the two say opposite
        /// things about the model: one is a verdict on the rewrite, the other
        /// is impatience with how long it was taking to produce one.
        case usedTranscriptNoRewrite
        /// Wiped mid-session with the Clear button.
        case cleared
        /// Panel closed without inserting anything.
        case abandoned
    }

    struct Record: Codable {
        var id: UUID
        var startedAt: Date
        var endedAt: Date
        var outcome: Outcome

        /// Raw recognizer output. This is the corpus.
        var transcript: String
        /// Transcript after the deterministic pre-model pass, so the two can be
        /// diffed to see what that layer is and isn't catching.
        var normalizedTranscript: String
        /// What the model returned. Diagnostic only -- not a reference answer.
        var rewrite: String
        /// The rewrite as the user left it. Non-nil only when they actually
        /// typed in the box; when present it is the closest thing to a
        /// correction that exists, but it is still not a full gold standard,
        /// since they only fix what bothers them enough to fix.
        var editedRewrite: String?

        var profile: String
        var backend: String
        var model: String
        var rewriteCount: Int
        var recordingSeconds: Double
        var targetBundleID: String?
        var inputDevice: String?
        /// File name inside the audio directory, when the session was
        /// recorded. Optional so every record written before recording existed
        /// still decodes.
        var audioFile: String?
        var appVersion: String
    }

    /// `~/Library/Application Support/ASRs-R-US/sessions.jsonl`
    let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASRs-R-US", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sessions.jsonl")
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// Writes happen off the main actor: dictation ends at the same moment the
    /// panel animates away, and a synchronous file write there is visible.
    private let queue = DispatchQueue(label: "com.brianellis.ASRs-R-US.sessionlog", qos: .utility)

    private init() {}

    func append(_ record: Record) {
        guard AppSettings.shared.logSessions else { return }
        guard !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)  // newline: one JSON object per line

        let url = fileURL
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Management

    var sessionCount: Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    var fileSizeDescription: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func deleteLog() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
