import AppKit
import Combine
import Foundation

/// Lifetime usage statistics.
///
/// Stored as JSON in Application Support rather than UserDefaults, for one
/// reason: it has to survive the app being deleted and reinstalled, which
/// happens constantly during development. This app is not sandboxed, so
/// `~/Library/Application Support/ASRs-R-US/` is a real user-level directory
/// and not a container that goes away with the bundle. The preferences plist
/// would mostly survive too, but it is cached by `cfprefsd`, tied to the bundle
/// identifier, and one stray `defaults delete` from wiping.
///
/// Counters only -- no transcript text is kept here. The one exception is the
/// correction list, which stores short before/after word pairs because knowing
/// *what* you keep fixing is the whole value of that statistic.
///
/// Recording is independent of the `logSessions` setting. That setting governs
/// the transcript corpus, which is genuinely sensitive; a count of how many
/// times you spoke is not, and gating stats on it would leave the tab empty for
/// anyone who turned logging off.
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    // MARK: - Stored shape

    /// Every field decodes defensively via `decodeIfPresent`. Swift's
    /// synthesized `init(from:)` ignores property defaults and fails the whole
    /// decode on one missing key, which would silently reset a user's lifetime
    /// history the first time this struct gained a field.
    struct Snapshot: Codable {
        var schemaVersion = 1

        var sessions = 0
        var words = 0
        var characters = 0
        var recordingSeconds: Double = 0
        /// Individual corrections made, across all sessions.
        var edits = 0
        /// Sessions the user corrected at all. Distinct from `edits`: fixing
        /// four words in one session is four edits but one edited session, and
        /// the edit *rate* only means anything against the latter.
        var sessionsEdited = 0
        var rewrites = 0
        var fillersRemoved = 0
        var longestSessionWords = 0

        var firstSessionAt: Date?
        var lastSessionAt: Date?

        /// `SessionLog.Outcome` raw value -> count.
        var outcomes: [String: Int] = [:]
        /// "yyyy-MM-dd" in local time -> sessions that day.
        var days: [String: Int] = [:]
        /// "weekday-hour", weekday 1...7 (Sunday = 1) -> count.
        var hours: [String: Int] = [:]
        /// Bundle identifier of the app dictated into -> count.
        var apps: [String: Int] = [:]
        /// Profile name -> count.
        var profiles: [String: Int] = [:]
        /// Engine raw value -> count.
        var engines: [String: Int] = [:]
        /// Transcript word count -> how many sessions came in at that length.
        /// A histogram rather than a sample buffer so the median stays exact
        /// however long the history grows.
        var lengths: [String: Int] = [:]
        /// "before\u{2192}after" -> times that correction was made.
        var corrections: [String: Int] = [:]

        /// Engine raw value -> histogram of milliseconds, bucketed by
        /// `latencyBucketMS`. Same reasoning as `lengths`: exact percentiles
        /// without keeping an unbounded list of samples.
        var firstTokenMS: [String: [String: Int]] = [:]
        var totalMS: [String: [String: Int]] = [:]

        /// Billed token counts, keyed by model ID. Kept per model because the
        /// rates differ per model and the mix changes over time.
        var inputTokens: [String: Int] = [:]
        var outputTokens: [String: Int] = [:]
        var cacheWriteTokens: [String: Int] = [:]
        var cacheReadTokens: [String: Int] = [:]
        /// Billed requests per model -- the denominator for cost-per-rewrite.
        var billedRequests: [String: Int] = [:]

        /// The same counts for the engines that cost nothing. Kept apart so
        /// they can never be mistaken for spend, and kept at all so the
        /// question "what would this have cost on a hosted model" has a real
        /// answer rather than an estimate from character counts.
        var freeInputTokens: [String: Int] = [:]
        var freeOutputTokens: [String: Int] = [:]
        var freeCachedTokens: [String: Int] = [:]
        var freeRequests: [String: Int] = [:]

        /// Set once the one-time import from `sessions.jsonl` has run, so a
        /// reinstall against an existing log does not double-count it.
        var backfilled = false

        /// Set once the fallback counts recorded before latency and quality
        /// fallbacks were told apart have been re-split from the log.
        var fallbacksSplit = false

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            /// Missing or malformed keys fall back instead of throwing, so a
            /// file written by an older build still loads every field it does
            /// have. `try?` on `decodeIfPresent` yields a double optional --
            /// the outer from the failure, the inner from absence -- and both
            /// collapse to the fallback.
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
            }
            func optional<T: Decodable>(_ key: CodingKeys) -> T? {
                (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
            }

            schemaVersion = value(.schemaVersion, 1)
            sessions = value(.sessions, 0)
            words = value(.words, 0)
            characters = value(.characters, 0)
            recordingSeconds = value(.recordingSeconds, 0)
            edits = value(.edits, 0)
            sessionsEdited = value(.sessionsEdited, 0)
            rewrites = value(.rewrites, 0)
            fillersRemoved = value(.fillersRemoved, 0)
            longestSessionWords = value(.longestSessionWords, 0)
            firstSessionAt = optional(.firstSessionAt)
            lastSessionAt = optional(.lastSessionAt)
            outcomes = value(.outcomes, [:])
            days = value(.days, [:])
            hours = value(.hours, [:])
            apps = value(.apps, [:])
            profiles = value(.profiles, [:])
            engines = value(.engines, [:])
            lengths = value(.lengths, [:])
            corrections = value(.corrections, [:])
            firstTokenMS = value(.firstTokenMS, [:])
            totalMS = value(.totalMS, [:])
            inputTokens = value(.inputTokens, [:])
            outputTokens = value(.outputTokens, [:])
            cacheWriteTokens = value(.cacheWriteTokens, [:])
            cacheReadTokens = value(.cacheReadTokens, [:])
            billedRequests = value(.billedRequests, [:])
            freeInputTokens = value(.freeInputTokens, [:])
            freeOutputTokens = value(.freeOutputTokens, [:])
            freeCachedTokens = value(.freeCachedTokens, [:])
            freeRequests = value(.freeRequests, [:])
            backfilled = value(.backfilled, false)
            fallbacksSplit = value(.fallbacksSplit, false)
        }
    }

    @Published private(set) var stats = Snapshot()

    /// `~/Library/Application Support/ASRs-R-US/stats.json`
    let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASRs-R-US", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stats.json")
    }()

    /// Latency histogram resolution. Fine enough that a median reads as a real
    /// number, coarse enough that the file stays small.
    private static let latencyBucketMS = 10
    /// Distinct correction pairs kept. Pruned to the most frequent when it
    /// grows past this, so a long history cannot bloat the file.
    private static let maxCorrections = 400

    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.stats.decode(Snapshot.self, from: data) {
            stats = decoded
        }
    }

    // MARK: - Recording

    /// Folds one finished session into the counters.
    func record(
        date: Date,
        transcript: String,
        rewrite: String,
        outcome: SessionLog.Outcome,
        profile: String,
        engine: String,
        bundleID: String?,
        recordingSeconds: Double,
        rewriteCount: Int,
        wasEdited: Bool
    ) {
        let wordCount = Self.wordCount(transcript)
        guard wordCount > 0 else { return }

        stats.sessions += 1
        if wasEdited { stats.sessionsEdited += 1 }
        stats.words += wordCount
        stats.characters += transcript.count
        stats.recordingSeconds += max(0, recordingSeconds)
        stats.rewrites += max(0, rewriteCount)
        stats.longestSessionWords = max(stats.longestSessionWords, wordCount)
        stats.fillersRemoved += Self.fillersRemoved(from: transcript, to: rewrite)

        if stats.firstSessionAt == nil || date < stats.firstSessionAt! { stats.firstSessionAt = date }
        if stats.lastSessionAt == nil || date > stats.lastSessionAt! { stats.lastSessionAt = date }

        stats.outcomes[outcome.rawValue, default: 0] += 1
        stats.days[Self.dayKey(date), default: 0] += 1
        stats.hours[Self.hourKey(date), default: 0] += 1
        stats.profiles[profile, default: 0] += 1
        stats.engines[engine, default: 0] += 1
        stats.lengths[String(wordCount), default: 0] += 1
        if let bundleID, !bundleID.isEmpty { stats.apps[bundleID, default: 0] += 1 }

        scheduleSave()
    }

    /// One hand-correction of the model's output.
    func recordEdit(before: String, after: String) {
        stats.edits += 1

        let from = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = after.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only pairs short enough to read as a correction are worth keeping.
        // Rewriting a whole paragraph is a real edit, but it is not a
        // "you keep getting this word wrong" signal, and storing it would put
        // sentences of dictated text in a file that is otherwise just counts.
        if !from.isEmpty, !to.isEmpty, from != to, from.count <= 40, to.count <= 40 {
            stats.corrections["\(from)\u{2192}\(to)", default: 0] += 1
            pruneCorrectionsIfNeeded()
        }
        scheduleSave()
    }

    /// One completed rewrite. Cancelled and superseded rewrites are not timed:
    /// they are abandoned mid-stream and their duration means nothing.
    func recordLatency(engine: String, firstTokenMS: Int?, totalMS: Int) {
        if let firstTokenMS {
            let bucket = String(Self.bucket(firstTokenMS))
            stats.firstTokenMS[engine, default: [:]][bucket, default: 0] += 1
        }
        let bucket = String(Self.bucket(totalMS))
        stats.totalMS[engine, default: [:]][bucket, default: 0] += 1
        scheduleSave()
    }

    /// One billed request's token counts, straight off the response.
    ///
    /// Only paid engines report usage -- the local model has no bill to track.
    func recordUsage(_ usage: TokenUsage) {
        let model = usage.model
        stats.inputTokens[model, default: 0] += usage.inputTokens
        stats.outputTokens[model, default: 0] += usage.outputTokens
        stats.cacheWriteTokens[model, default: 0] += usage.cacheWriteTokens
        stats.cacheReadTokens[model, default: 0] += usage.cacheReadTokens
        stats.billedRequests[model, default: 0] += 1
        scheduleSave()
    }

    /// One local request's token counts. Nothing is billed for these; they
    /// exist so the local engine's usage can be priced hypothetically.
    func recordLocalUsage(_ usage: TokenUsage) {
        let model = usage.model
        stats.freeInputTokens[model, default: 0] += usage.inputTokens
        stats.freeOutputTokens[model, default: 0] += usage.outputTokens
        stats.freeCachedTokens[model, default: 0] += usage.cacheReadTokens
        stats.freeRequests[model, default: 0] += 1
        scheduleSave()
    }

    // MARK: - Backfill

    /// Imports the existing session log once, so the tab does not open at zero
    /// on a machine that has been dictating for months.
    ///
    /// Latency cannot be recovered this way -- it was never recorded -- so
    /// those figures start accumulating from today regardless.
    func backfillFromSessionLogIfNeeded() {
        guard !stats.backfilled else { return }
        stats.backfilled = true

        defer { scheduleSave() }
        guard let text = try? String(contentsOf: SessionLog.shared.fileURL, encoding: .utf8) else { return }

        let decoder = JSONDecoder.stats
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(SessionLog.Record.self, from: data)
            else { continue }

            record(
                date: entry.startedAt,
                transcript: entry.transcript,
                rewrite: entry.rewrite,
                outcome: entry.outcome,
                profile: entry.profile,
                engine: entry.backend,
                bundleID: entry.targetBundleID,
                recordingSeconds: entry.recordingSeconds,
                rewriteCount: entry.rewriteCount,
                wasEdited: entry.editedRewrite != nil
            )
        }
    }

    /// Re-splits fallbacks recorded before the two kinds were told apart.
    ///
    /// Everything logged as `usedTranscript` up to now lumped together "the
    /// rewrite was wrong" and "no rewrite had arrived yet", and the second is
    /// by far the more common of the two. The session log holds the rewrite
    /// for each of those sessions, so the answer is on disk rather than
    /// guessed at: an empty rewrite means the user was waiting.
    ///
    /// Only sessions the log can actually account for are moved, capped at the
    /// counter itself. If logging was off for part of the history the log will
    /// be short, and the leftovers stay where they are -- undercounting the
    /// latency half rather than inventing sessions to fill it.
    func splitLegacyFallbacksIfNeeded() {
        guard !stats.fallbacksSplit else { return }
        stats.fallbacksSplit = true
        defer { scheduleSave() }

        let legacyKey = SessionLog.Outcome.usedTranscript.rawValue
        let legacy = stats.outcomes[legacyKey] ?? 0
        guard legacy > 0 else { return }
        guard let text = try? String(contentsOf: SessionLog.shared.fileURL, encoding: .utf8) else { return }

        let decoder = JSONDecoder.stats
        var waited = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(SessionLog.Record.self, from: data),
                  entry.outcome == .usedTranscript,
                  entry.rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            waited += 1
        }

        let moved = min(waited, legacy)
        guard moved > 0 else { return }
        stats.outcomes[legacyKey] = legacy - moved
        stats.outcomes[SessionLog.Outcome.usedTranscriptNoRewrite.rawValue, default: 0] += moved
    }

    // MARK: - Management

    func reset() {
        stats = Snapshot()
        // Keep the flag set: the log is still on disk, and a reset means "start
        // over", not "import all of it again".
        stats.backfilled = true
        scheduleSave()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    var fileSizeDescription: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: - Persistence

    /// Coalesces the writes from a burst of edits into one.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder.stats.encode(stats) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func pruneCorrectionsIfNeeded() {
        guard stats.corrections.count > Self.maxCorrections else { return }
        let kept = stats.corrections
            .sorted { $0.value > $1.value }
            .prefix(Self.maxCorrections / 2)
        stats.corrections = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    // MARK: - Helpers

    private static func bucket(_ ms: Int) -> Int {
        max(0, ms) / latencyBucketMS * latencyBucketMS
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static func hourKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.weekday, .hour], from: date)
        return "\(parts.weekday ?? 1)-\(parts.hour ?? 0)"
    }

    /// Disfluencies the prompt is allowed to delete. Counting how many vanished
    /// between transcript and rewrite is a decent proxy for how much noise the
    /// model cleaned up, without needing a real alignment.
    private static let fillerPattern = try? NSRegularExpression(
        pattern: "\\b(u+m+|u+h+|e+r+m?|h+m+)\\b",
        options: [.caseInsensitive]
    )

    private static func fillerCount(_ text: String) -> Int {
        guard let fillerPattern else { return 0 }
        return fillerPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func fillersRemoved(from transcript: String, to rewrite: String) -> Int {
        guard !rewrite.isEmpty else { return 0 }
        return max(0, fillerCount(transcript) - fillerCount(rewrite))
    }
}

// MARK: - Derived figures

extension StatsStore {

    var sessionsToday: Int { stats.days[Self.dayKey(Date())] ?? 0 }

    /// Days between the first session and now, so "per day" means per day of
    /// ownership rather than per day of use.
    var daysSinceFirstUse: Int {
        guard let first = stats.firstSessionAt else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
        return max(1, days + 1)
    }

    var sessionsPerDay: Double {
        guard stats.sessions > 0 else { return 0 }
        return Double(stats.sessions) / Double(daysSinceFirstUse)
    }

    /// Averaged over days it was actually used, which is the number that feels
    /// true when you have owned it for a year and used it in bursts.
    var sessionsPerActiveDay: Double {
        let active = stats.days.values.filter { $0 > 0 }.count
        guard active > 0 else { return 0 }
        return Double(stats.sessions) / Double(active)
    }

    var averageWordsPerSession: Double {
        guard stats.sessions > 0 else { return 0 }
        return Double(stats.words) / Double(stats.sessions)
    }

    var medianWordsPerSession: Int { percentile(0.5, of: stats.lengths) ?? 0 }

    var wordsPerMinute: Double {
        guard stats.recordingSeconds > 1 else { return 0 }
        return Double(stats.words) / (stats.recordingSeconds / 60)
    }

    var editRate: Double {
        guard stats.sessions > 0 else { return 0 }
        return Double(stats.sessionsEdited) / Double(stats.sessions)
    }

    var editsPerEditedSession: Double {
        guard stats.sessionsEdited > 0 else { return 0 }
        return Double(stats.edits) / Double(stats.sessionsEdited)
    }

    func outcomeCount(_ outcome: SessionLog.Outcome) -> Int {
        stats.outcomes[outcome.rawValue] ?? 0
    }

    /// Sessions that ended with the raw transcript rather than the rewrite,
    /// for either reason.
    var fallbackRate: Double {
        guard stats.sessions > 0 else { return 0 }
        let fallbacks = outcomeCount(.usedTranscript) + outcomeCount(.usedTranscriptNoRewrite)
        return Double(fallbacks) / Double(stats.sessions)
    }

    /// Fallbacks that happened with an empty output box, over all fallbacks.
    /// High means the engine is too slow, not that it is writing badly -- the
    /// fix is a faster engine or a shorter debounce, not a better prompt.
    var latencyFallbackShare: Double {
        let waited = outcomeCount(.usedTranscriptNoRewrite)
        let total = waited + outcomeCount(.usedTranscript)
        guard total > 0 else { return 0 }
        return Double(waited) / Double(total)
    }

    var outcomeCounts: [(outcome: SessionLog.Outcome, count: Int)] {
        let order: [SessionLog.Outcome] = [
            .used, .usedTranscriptNoRewrite, .usedTranscript, .cleared, .abandoned,
        ]
        return order.map { ($0, stats.outcomes[$0.rawValue] ?? 0) }
    }

    /// Session counts for the last `days` days, oldest first, including zeros.
    func recentDays(_ days: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date, stats.days[Self.dayKey(date)] ?? 0)
        }
    }

    /// Consecutive days up to today with at least one session.
    var currentStreak: Int {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date())
        // Today not being used yet should not end a streak that is otherwise
        // alive, so start counting from yesterday when today is empty.
        if (stats.days[Self.dayKey(day)] ?? 0) == 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while (stats.days[Self.dayKey(day)] ?? 0) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    var longestStreak: Int {
        let calendar = Calendar.current
        let used = stats.days.filter { $0.value > 0 }.keys.compactMap(Self.dayFormatterParse).sorted()
        guard !used.isEmpty else { return 0 }

        var best = 1
        var run = 1
        for index in 1..<used.count {
            let gap = calendar.dateComponents([.day], from: used[index - 1], to: used[index]).day ?? 0
            run = gap == 1 ? run + 1 : 1
            best = max(best, run)
        }
        return best
    }

    /// weekday (1...7) x hour (0...23) counts.
    var hourHeatmap: [[Int]] {
        (1...7).map { weekday in
            (0..<24).map { hour in stats.hours["\(weekday)-\(hour)"] ?? 0 }
        }
    }

    var busiestHour: (weekday: Int, hour: Int, count: Int)? {
        var best: (Int, Int, Int)?
        for (key, count) in stats.hours {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            if best == nil || count > best!.2 { best = (parts[0], parts[1], count) }
        }
        return best.map { (weekday: $0.0, hour: $0.1, count: $0.2) }
    }

    func topApps(_ limit: Int) -> [(bundleID: String, count: Int)] {
        stats.apps.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    /// One recurring correction. A named type rather than a tuple so it can
    /// carry a stable identity into `ForEach`: the same word is often corrected
    /// to two different things, so `before` alone is not unique.
    struct Correction: Identifiable, Hashable {
        let before: String
        let after: String
        let count: Int
        var id: String { "\(before)\u{2192}\(after)" }
    }

    func topCorrections(_ limit: Int) -> [Correction] {
        stats.corrections
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .compactMap { pair in
                let parts = pair.key.components(separatedBy: "\u{2192}")
                guard parts.count == 2 else { return nil }
                return Correction(before: parts[0], after: parts[1], count: pair.value)
            }
    }

    func profileShare() -> [(name: String, count: Int)] {
        stats.profiles.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Median and p95 latency in milliseconds for one engine.
    func latency(for engine: String) -> (firstToken: Int?, median: Int?, p95: Int?, samples: Int)? {
        let total = stats.totalMS[engine] ?? [:]
        let samples = total.values.reduce(0, +)
        guard samples > 0 else { return nil }
        return (
            firstToken: percentile(0.5, of: stats.firstTokenMS[engine] ?? [:]),
            median: percentile(0.5, of: total),
            p95: percentile(0.95, of: total),
            samples: samples
        )
    }

    var enginesWithLatency: [String] {
        stats.totalMS.keys.sorted()
    }

    /// Per-model spend, most expensive first. `cost` is nil for a model with
    /// no rate on file -- tokens are still counted and shown.
    struct Spend: Identifiable {
        let model: String
        let input: Int
        let output: Int
        let cacheWrite: Int
        let cacheRead: Int
        let requests: Int
        let cost: Double?
        var id: String { model }

        var totalTokens: Int { input + output + cacheWrite + cacheRead }
    }

    var spendByModel: [Spend] {
        let models = Set(stats.inputTokens.keys)
            .union(stats.outputTokens.keys)
            .union(stats.billedRequests.keys)

        return models.map { model in
            let usage = TokenUsage(
                model: model,
                inputTokens: stats.inputTokens[model] ?? 0,
                outputTokens: stats.outputTokens[model] ?? 0,
                cacheWriteTokens: stats.cacheWriteTokens[model] ?? 0,
                cacheReadTokens: stats.cacheReadTokens[model] ?? 0
            )
            return Spend(
                model: model,
                input: usage.inputTokens,
                output: usage.outputTokens,
                cacheWrite: usage.cacheWriteTokens,
                cacheRead: usage.cacheReadTokens,
                requests: stats.billedRequests[model] ?? 0,
                cost: ModelPricing.cost(of: usage)
            )
        }
        .sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }
    }

    /// What the free engines' work would have cost on a hosted model.
    ///
    /// Priced on the local model's own token counts, which is the honest
    /// version of this number and also its main weakness: Qwen and Claude
    /// tokenise differently, so the counts are the right order of magnitude
    /// rather than exact.
    ///
    /// Caching is modelled from what actually happens on Bedrock rather than
    /// assumed away. The app sends the same preamble every time behind a
    /// `cache_control` block, so most input would be served from cache at a
    /// tenth of the price -- ignoring that would overstate the figure several
    /// times over. Where there is real Bedrock history the observed hit rate
    /// is used; otherwise it falls back to the share the local server itself
    /// reports reusing.
    func projectedSpend(onModel modelID: String) -> (cost: Double, requests: Int, hitRate: Double)? {
        guard let rates = ModelPricing.forModel(modelID) else { return nil }
        let input = stats.freeInputTokens.values.reduce(0, +)
        let output = stats.freeOutputTokens.values.reduce(0, +)
        let requests = stats.freeRequests.values.reduce(0, +)
        guard requests > 0, input + output > 0 else { return nil }

        let observed = cacheHitRate
        let localReuse = input > 0
            ? Double(stats.freeCachedTokens.values.reduce(0, +)) / Double(input)
            : 0
        let hitRate = observed > 0 ? observed : localReuse

        let cached = Double(input) * hitRate
        let fresh = Double(input) - cached
        let million = 1_000_000.0
        let cost = fresh / million * rates.inputPerMTok
            + cached / million * rates.cacheReadPerMTok
            + Double(output) / million * rates.outputPerMTok
        return (cost, requests, hitRate)
    }

    var freeRequestCount: Int {
        stats.freeRequests.values.reduce(0, +)
    }

    /// Total estimated spend across every model with a known rate.
    var totalSpend: Double {
        spendByModel.compactMap(\.cost).reduce(0, +)
    }

    var totalBilledRequests: Int {
        stats.billedRequests.values.reduce(0, +)
    }

    /// Share of input tokens served from cache. The preamble is deliberately
    /// cached, so a low number here means the cache is being invalidated.
    var cacheHitRate: Double {
        let read = stats.cacheReadTokens.values.reduce(0, +)
        let fresh = stats.inputTokens.values.reduce(0, +)
            + stats.cacheWriteTokens.values.reduce(0, +)
        let total = read + fresh
        guard total > 0 else { return 0 }
        return Double(read) / Double(total)
    }

    /// Exact percentile from a `value -> frequency` histogram.
    private func percentile(_ p: Double, of histogram: [String: Int]) -> Int? {
        let entries = histogram
            .compactMap { key, count in Int(key).map { ($0, count) } }
            .sorted { $0.0 < $1.0 }
        let total = entries.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }

        let target = max(1, Int((Double(total) * p).rounded(.up)))
        var cumulative = 0
        for (value, count) in entries {
            cumulative += count
            if cumulative >= target { return value }
        }
        return entries.last?.0
    }

    private static func dayFormatterParse(_ key: String) -> Date? {
        dayFormatter.date(from: key)
    }
}

private extension JSONEncoder {
    static let stats: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

private extension JSONDecoder {
    static let stats: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
