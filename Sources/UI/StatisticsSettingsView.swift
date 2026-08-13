import AppKit
import SwiftUI

/// Lifetime usage statistics, read from `StatsStore`.
///
/// Everything here is derived from counters the app already keeps; the tab does
/// no parsing of its own, so opening it stays instant however long the history
/// gets.
struct StatisticsSettingsView: View {
    @ObservedObject private var store = StatsStore.shared
    @State private var confirmingReset = false

    private var stats: StatsStore.Snapshot { store.stats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if stats.sessions == 0 {
                    empty
                } else {
                    headline
                    tiles
                    activity
                    quality
                    latency
                    places
                    rhythm
                    corrections
                }
                footer
            }
            .padding(14)
        }
    }

    // MARK: - Empty

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No dictation yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Statistics start counting from your first session.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(stats.sessions.formatted())")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text(stats.sessions == 1 ? "dictation" : "dictations")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            if let first = stats.firstSessionAt {
                Text("since \(first.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            StatTile(
                value: Self.compact(stats.words),
                label: "words spoken",
                caption: Self.pages(stats.words)
            )
            StatTile(
                value: Self.duration(stats.recordingSeconds),
                label: "time recording",
                caption: stats.sessions > 0
                    ? "\(Self.duration(stats.recordingSeconds / Double(stats.sessions))) per session"
                    : nil
            )
            // Not a speaking rate: a session is timed from panel open to panel
            // close, so it includes reading and correcting the result. Labelled
            // for what it actually measures rather than compared against
            // conversational speech, which would flatter it by half.
            StatTile(
                value: store.wordsPerMinute > 0 ? "\(Int(store.wordsPerMinute))" : "--",
                label: "words per minute",
                caption: "of panel time, not speech"
            )
            StatTile(
                value: "\(store.medianWordsPerSession)",
                label: "median length",
                caption: "average \(Int(store.averageWordsPerSession.rounded())) words"
            )
            StatTile(
                value: String(format: "%.1f", store.sessionsPerActiveDay),
                label: "per active day",
                caption: "\(store.sessionsToday) today"
            )
            // Rate leads rather than the raw count: the backfill can recover
            // which sessions were edited but not the individual corrections
            // inside them, so on first run the count is honestly low while the
            // rate is already meaningful.
            StatTile(
                value: String(format: "%.0f%%", store.editRate * 100),
                label: "sessions you corrected",
                caption: stats.edits > 0
                    ? "\(stats.edits.formatted()) corrections logged"
                    : "correction detail starts now"
            )
        }
    }

    // MARK: - Activity

    private var activity: some View {
        StatSection(title: "Last 30 days", trailing: streakLabel) {
            let days = store.recentDays(30)
            let peak = max(days.map(\.count).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.date) { day in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(day.count == 0 ? Color.secondary.opacity(0.12) : Color.accentColor)
                        .frame(height: max(3, CGFloat(day.count) / CGFloat(peak) * 40))
                        .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.count)")
                }
            }
            .frame(height: 40)
        }
    }

    private var streakLabel: String? {
        guard store.longestStreak > 0 else { return nil }
        return "streak \(store.currentStreak) · best \(store.longestStreak)"
    }

    // MARK: - Quality

    private var quality: some View {
        StatSection(title: "How the rewrites land") {
            VStack(alignment: .leading, spacing: 8) {
                let counts = store.outcomeCounts
                let total = max(counts.reduce(0) { $0 + $1.count }, 1)

                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(counts, id: \.outcome) { entry in
                            Rectangle()
                                .fill(Self.color(for: entry.outcome))
                                .frame(width: max(0, geometry.size.width * CGFloat(entry.count) / CGFloat(total)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 10)

                HStack(spacing: 12) {
                    ForEach(counts, id: \.outcome) { entry in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Self.color(for: entry.outcome))
                                .frame(width: 7, height: 7)
                            Text("\(Self.label(for: entry.outcome)) \(entry.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(qualityNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var qualityNote: String {
        let fallback = store.fallbackRate * 100
        let edited = store.editRate * 100
        var parts: [String] = []
        parts.append(String(format: "You took the raw transcript instead %.0f%% of the time", fallback))
        parts.append(String(format: "corrected the rewrite in %.0f%% of sessions", edited))
        if stats.fillersRemoved > 0 {
            let noun = stats.fillersRemoved == 1 ? "filler word" : "filler words"
            parts.append("and had \(stats.fillersRemoved.formatted()) \(noun) cleaned out")
        }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Latency

    @ViewBuilder
    private var latency: some View {
        let engines = store.enginesWithLatency
        if engines.isEmpty {
            StatSection(title: "Speed") {
                Text("No rewrites timed yet. Latency is measured from this version onward and cannot be reconstructed from older sessions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            StatSection(title: "Speed by engine") {
                VStack(spacing: 6) {
                    HStack {
                        Text("Engine").frame(width: 130, alignment: .leading)
                        Text("First token").frame(width: 80, alignment: .trailing)
                        Text("Median").frame(width: 70, alignment: .trailing)
                        Text("p95").frame(width: 70, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                    ForEach(engines, id: \.self) { engine in
                        if let figures = store.latency(for: engine) {
                            HStack {
                                Text(Self.engineName(engine))
                                    .frame(width: 130, alignment: .leading)
                                    .lineLimit(1)
                                Text(Self.ms(figures.firstToken)).frame(width: 80, alignment: .trailing)
                                Text(Self.ms(figures.median)).frame(width: 70, alignment: .trailing)
                                Text(Self.ms(figures.p95)).frame(width: 70, alignment: .trailing)
                                Text("\(figures.samples)")
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .font(.system(size: 11, design: .rounded))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Places

    @ViewBuilder
    private var places: some View {
        let apps = store.topApps(5)
        if !apps.isEmpty {
            StatSection(title: "Where you dictate") {
                VStack(spacing: 5) {
                    let peak = max(apps.map(\.count).max() ?? 1, 1)
                    ForEach(apps, id: \.bundleID) { entry in
                        let info = Self.appInfo(entry.bundleID)
                        HStack(spacing: 7) {
                            if let icon = info.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 15, height: 15)
                            } else {
                                Image(systemName: "app.dashed")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 15)
                            }
                            Text(info.name)
                                .font(.system(size: 11))
                                .frame(width: 130, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(2, geometry.size.width * CGFloat(entry.count) / CGFloat(peak)))
                            }
                            .frame(height: 9)
                            Text("\(entry.count)")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rhythm

    private var rhythm: some View {
        StatSection(title: "When you dictate", trailing: busiestLabel) {
            let map = store.hourHeatmap
            let peak = max(map.flatMap { $0 }.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<7, id: \.self) { weekday in
                    HStack(spacing: 2) {
                        Text(Self.weekdayNames[weekday])
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let count = map[weekday][hour]
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(count == 0
                                      ? Color.secondary.opacity(0.1)
                                      : Color.accentColor.opacity(0.25 + 0.75 * Double(count) / Double(peak)))
                                .frame(height: 11)
                                .help("\(Self.weekdayNames[weekday]) \(Self.hourLabel(hour)): \(count)")
                        }
                    }
                }
            }
        }
    }

    private var busiestLabel: String? {
        guard let busiest = store.busiestHour, busiest.count > 0 else { return nil }
        return "busiest \(Self.weekdayNames[busiest.weekday - 1]) \(Self.hourLabel(busiest.hour))"
    }

    // MARK: - Corrections

    @ViewBuilder
    private var corrections: some View {
        let pairs = store.topCorrections(6)
        if !pairs.isEmpty {
            StatSection(title: "What you keep fixing") {
                VStack(alignment: .leading, spacing: 4) {
                    // Keyed on both halves: the same word can be corrected to
                    // two different things, and `before` alone would collide.
                    ForEach(pairs) { pair in
                        HStack(spacing: 6) {
                            Text(pair.before)
                                .strikethrough(color: .secondary)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                            Text(pair.after)
                            Spacer()
                            Text("\(pair.count)x")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                    }
                    Text("Words you correct often are good candidates for the Dictionary tab.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Stored locally in \(store.fileURL.path) · \(store.fileSizeDescription)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
            Button("Reveal") { store.revealInFinder() }
            Button("Reset") { confirmingReset = true }
        }
        .controlSize(.small)
        .padding(.top, 4)
        .confirmationDialog(
            "Reset all statistics?",
            isPresented: $confirmingReset
        ) {
            Button("Reset Statistics", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every counter permanently. Your session log and dictation history are not affected.")
        }
    }

    // MARK: - Formatting

    private static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return String(format: "%.0fk", Double(value) / 1_000)
        case 1_000...: return String(format: "%.1fk", Double(value) / 1_000)
        default: return "\(value)"
        }
    }

    /// A word count is hard to feel. Roughly 500 words to a paperback page.
    private static func pages(_ words: Int) -> String? {
        guard words >= 500 else { return nil }
        return "about \((words / 500).formatted()) pages"
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private static func ms(_ value: Int?) -> String {
        guard let value else { return "--" }
        return value >= 1000 ? String(format: "%.1fs", Double(value) / 1000) : "\(value)ms"
    }

    private static func engineName(_ raw: String) -> String {
        RewriteBackendKind(rawValue: raw)?.displayName ?? raw
    }

    private static func color(for outcome: SessionLog.Outcome) -> Color {
        switch outcome {
        case .used: return .accentColor
        case .usedTranscript: return .orange
        case .cleared: return .secondary.opacity(0.5)
        case .abandoned: return .secondary.opacity(0.25)
        }
    }

    private static func label(for outcome: SessionLog.Outcome) -> String {
        switch outcome {
        case .used: return "used"
        case .usedTranscript: return "fell back"
        case .cleared: return "cleared"
        case .abandoned: return "abandoned"
        }
    }

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12am"
        case 1..<12: return "\(hour)am"
        case 12: return "12pm"
        default: return "\(hour - 12)pm"
        }
    }

    private static func appInfo(_ bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        // `displayName` keeps the ".app" extension when the user has Finder set
        // to show extensions, which reads as clutter in a list of app names.
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
}

// MARK: - Pieces

/// One headline number with its label.
private struct StatTile: View {
    let value: String
    let label: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// Titled block, so every section on the tab lines up the same way.
private struct StatSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content

    init(title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}
