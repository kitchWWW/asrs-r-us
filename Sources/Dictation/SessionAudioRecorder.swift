import AppKit
import AVFoundation
import Foundation
import OSLog

/// Writes the audio a session was recognised from to a file, one file per
/// session.
///
/// It records at the point the buffer has already been converted into the
/// analyzer's own format, which is the whole reason the corpus is worth
/// keeping: what lands on disk is exactly what the recogniser was handed, so a
/// session can be replayed through a different transcriber later and the
/// comparison means something. Capturing the device's raw stream instead would
/// leave the conversion out of the experiment.
///
/// FLAC, not a lossy format, for the same reason -- re-running recognition over
/// audio an encoder has already discarded information from measures the encoder
/// as much as the recogniser. It costs about half of raw PCM.
///
/// Writes happen on a private queue. `feed` is called from the audio tap, and
/// a tap that blocks on disk I/O drops buffers, which would corrupt the
/// recognition this file exists to study.
final class SessionAudioRecorder: @unchecked Sendable {

    private let url: URL
    private let queue = DispatchQueue(label: "com.brianellis.ASRs-R-US.audio-recorder")
    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "audio")

    /// Opened on the first buffer rather than at init: the file's format has
    /// to match what is actually arriving, and only the first buffer settles
    /// that.
    private var file: AVAudioFile?
    private var failed = false
    private var frames: AVAudioFramePosition = 0

    init(url: URL) {
        self.url = url
    }

    /// Hands one buffer to the writer. Returns immediately; the copy is made
    /// here because the caller's buffer may be reused as soon as this returns.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard !failed, let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in
            self?.write(copy)
        }
    }

    /// Closes the file and reports where it landed, or nil if nothing was ever
    /// written -- a session cancelled before the first buffer leaves no file
    /// rather than an empty one.
    func finish() -> URL? {
        queue.sync {
            let wrote = file != nil && frames > 0
            file = nil
            if !wrote {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return url
        }
    }

    var recordedSeconds: Double {
        queue.sync {
            guard let file, frames > 0 else { return 0 }
            return Double(frames) / file.fileFormat.sampleRate
        }
    }

    // MARK: - Writing

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        if file == nil {
            file = makeFile(for: buffer.format)
            guard file != nil else {
                failed = true
                return
            }
        }
        do {
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // One failed write means the rest will fail too -- a full disk, a
            // deleted directory. Stop trying rather than logging per buffer.
            log.error("stopped recording session audio: \(error.localizedDescription)")
            failed = true
            file = nil
        }
    }

    /// FLAC first, WAV if the encoder will not take this format. Both are
    /// lossless, so a fallback costs disk space and nothing else.
    private func makeFile(for format: AVAudioFormat) -> AVAudioFile? {
        let flac: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
        if let file = try? AVAudioFile(
            forWriting: url, settings: flac,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        ) {
            return file
        }

        let wavURL = url.deletingPathExtension().appendingPathExtension("wav")
        let wav: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        guard let file = try? AVAudioFile(
            forWriting: wavURL, settings: wav,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        ) else {
            log.error("could not open a session audio file at \(self.url.path)")
            return nil
        }
        log.info("FLAC unavailable for this format; recording WAV instead")
        return file
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }
        return copy
    }
}

/// Where session recordings live, and the housekeeping the settings pane needs.
///
/// A sibling of `sessions.jsonl` rather than a subfolder of it, so the corpus
/// is one directory: a line of JSON per session, and the audio it came from
/// under the same identifier.
@MainActor
enum SessionAudio {

    /// `~/Library/Application Support/ASRs-R-US/audio/`
    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASRs-R-US", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Named for when it was recorded, so the directory sorts chronologically
    /// and two sessions in the same second still get their own file.
    static func newFileURL() -> URL {
        let stamp = ISO8601DateFormatter.audioStamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return directory
            .appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(4))")
            .appendingPathExtension("flac")
    }

    /// `~/Library/Application Support/ASRs-R-US/annotated/`
    ///
    /// A recording moves here once someone has written down what it *should*
    /// have transcribed to. That answer took human attention to produce and
    /// cannot be regenerated, so the audio it refers to stops being expendable:
    /// nothing here is ever pruned, and none of it counts toward the ceiling on
    /// the ordinary corpus. A sibling of `audio/` rather than a folder inside
    /// it, so the eviction pass cannot see it at all.
    nonisolated static let annotatedDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASRs-R-US", isDirectory: true)
            .appendingPathComponent("annotated", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Moves a recording into the protected set. Returns where it ended up, or
    /// nil if there was nothing by that name to move.
    @discardableResult
    nonisolated static func promote(stem: String) -> URL? {
        guard let source = url(named: stem) else { return nil }
        guard source.deletingLastPathComponent() != annotatedDirectory else { return source }
        let destination = annotatedDirectory.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Returns a promoted recording to the ordinary corpus, where it is once
    /// again subject to the ceiling.
    @discardableResult
    nonisolated static func demote(stem: String) -> URL? {
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: annotatedDirectory.path)) ?? []
        guard let name = candidates.first(where: { ($0 as NSString).deletingPathExtension == stem }) else {
            return nil
        }
        let source = annotatedDirectory.appendingPathComponent(name)
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    nonisolated static var annotatedCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: annotatedDirectory.path)) ?? []).count
    }

    static var annotatedSizeDescription: String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: annotatedDirectory.path)) ?? []
        let bytes = names.reduce(into: Int64(0)) { total, name in
            let path = annotatedDirectory.appendingPathComponent(name).path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func revealAnnotatedInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([annotatedDirectory])
    }

    /// Finds a session's audio whatever state it is in.
    ///
    /// A recording is written lossless and compressed afterwards, so the same
    /// session is a `.flac` for a second and a `.caf` from then on. The log
    /// stores the stem and this resolves it, which also keeps every record
    /// written before compression existed working.
    nonisolated static func url(named name: String) -> URL? {
        let stem = (name as NSString).deletingPathExtension
        for folder in [annotatedDirectory, directory] {
            for ext in ["caf", "flac", "wav"] {
                let candidate = folder.appendingPathComponent(stem).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// Re-encodes a finished recording to Opus and drops the lossless copy.
    ///
    /// Recording stays lossless because the audio thread should not be running
    /// a lossy encoder, and because a failed encode mid-session would lose the
    /// session. Compression happens once, afterwards, when nothing is waiting
    /// on it.
    ///
    /// Opus at 24 kbit/s rather than MP3: measured over six of these
    /// recordings it came out a quarter the size of the lossless original
    /// where MP3 at 32 kbit/s was 41%, and the transcripts the recogniser
    /// produced from it were 99.2% identical to the ones from the original --
    /// the same figure MP3 managed at nearly twice the size.
    @discardableResult
    nonisolated static func compress(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() != "caf" else { return url }
        let destination = url.deletingPathExtension().appendingPathExtension("caf")

        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "caff", "-d", "opus", "-b", "24000", url.path, destination.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        do {
            try convert.run()
            convert.waitUntilExit()
        } catch {
            return url
        }

        // Only drop the original once there is something to replace it.
        guard convert.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber,
              size.intValue > 0
        else {
            try? FileManager.default.removeItem(at: destination)
            return url
        }
        try? FileManager.default.removeItem(at: url)
        return destination
    }

    /// Keeps the folder inside its ceiling while preserving a spread of dates.
    ///
    /// Evicting the oldest first is wrong here: the archive exists to be tested
    /// against, and a year of speech would decay into a record of last month.
    ///
    /// Evicting purely at random is wrong too, though less obviously. Every new
    /// recording gives each survivor another chance to be picked, so a file's
    /// odds of lasting fall geometrically with the ones that come after it --
    /// uniform eviction looks fair on any single day and still empties the far
    /// end of the archive over a year.
    ///
    /// So the folder is divided into age bands -- this week, this month, this
    /// quarter, this year, older -- and each band gets a share of the ceiling
    /// it is allowed to fill. A band under its share gives the remainder back
    /// to the others, so nothing is wasted holding space for months that do not
    /// exist yet. Within a band, eviction is random, which is what keeps the
    /// sample varied rather than clustered.
    nonisolated static func prune(olderThanDays days: Int, maxBytes: Int64) {
        var files = contents()

        if days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            for file in files where file.modified < cutoff {
                try? FileManager.default.removeItem(at: file.url)
            }
            files = files.filter { $0.modified >= cutoff }
        }

        guard maxBytes > 0 else { return }
        guard files.reduce(Int64(0), { $0 + $1.size }) > maxBytes else { return }

        let now = Date()
        var bands: [[(url: URL, size: Int64, modified: Date)]] = Array(repeating: [], count: Self.bandEdges.count + 1)
        for file in files {
            let age = now.timeIntervalSince(file.modified) / 86_400
            let index = Self.bandEdges.firstIndex { age < $0 } ?? Self.bandEdges.count
            bands[index].append(file)
        }

        for (band, quota) in zip(bands.indices, Self.quotas(for: bands.map { $0.reduce(Int64(0)) { $0 + $1.size } }, ceiling: maxBytes)) {
            var kept = bands[band]
            var total = kept.reduce(Int64(0)) { $0 + $1.size }
            while total > quota, !kept.isEmpty {
                let victim = kept.remove(at: Int.random(in: 0..<kept.count))
                try? FileManager.default.removeItem(at: victim.url)
                total -= victim.size
            }
        }
    }

    /// Upper edges in days. Anything older than the last one lands in its own
    /// band, so the earliest recordings always have somewhere to live.
    private nonisolated static let bandEdges: [Double] = [7, 30, 90, 365]

    /// Splits the ceiling between the bands, max-min fair: every band that
    /// wants less than an equal share takes what it needs and the rest is
    /// shared out again among the bands that are still over.
    nonisolated static func quotas(for sizes: [Int64], ceiling: Int64) -> [Int64] {
        var quotas = [Int64](repeating: 0, count: sizes.count)
        var remaining = ceiling
        var contenders = Set(sizes.indices.filter { sizes[$0] > 0 })

        while !contenders.isEmpty {
            let share = remaining / Int64(contenders.count)
            let satisfied = contenders.filter { sizes[$0] <= share }
            guard !satisfied.isEmpty else {
                for index in contenders { quotas[index] = share }
                break
            }
            for index in satisfied {
                quotas[index] = sizes[index]
                remaining -= sizes[index]
                contenders.remove(index)
            }
        }
        return quotas
    }

    private nonisolated static func contents() -> [(url: URL, size: Int64, modified: Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let modified = attrs[.modificationDate] as? Date
            else { return nil }
            return (url, size, modified)
        }
    }

    static var fileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    static var totalBytes: Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        return names.reduce(into: Int64(0)) { total, name in
            let path = directory.appendingPathComponent(name).path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    static var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    static func deleteAll() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

private extension ISO8601DateFormatter {
    /// "2026-08-14T011530Z" -- colons are legal in a file name but make the
    /// path awkward to pass to anything shell-shaped.
    static let audioStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
