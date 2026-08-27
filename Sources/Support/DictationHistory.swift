import AppKit
import Combine
import Foundation

/// The last N things the user actually inserted, kept so they can be recalled
/// from the menu bar without redictating.
///
/// An entry holds the *whole* session, not just the text that was inserted:
/// both recognisers' readings and the rewrite are stored alongside it, because
/// clicking one in the menu reopens the dictation window rather than pasting.
/// A restored session that only knew the final string could not offer the
/// transcript as an alternative, and could not carry the second recogniser's
/// reading into the next rewrite -- the very evidence that settles a misheard
/// word.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()

    /// One other recogniser's reading of the same audio, kept by display name
    /// rather than by `RecognizerChoice` so a stored entry survives the set of
    /// recognisers changing.
    struct AlternateReading: Codable, Hashable {
        var name: String
        var text: String
    }

    struct Entry: Identifiable, Codable, Hashable {
        var id: UUID
        /// What was actually inserted into the target app.
        var text: String
        var date: Date
        var profileName: String

        // Everything below arrived with reopenable sessions and is absent from
        // entries recorded before it, hence optional: the synthesized decoder
        // tolerates a missing key only for an optional. Read them through the
        // `restored*` accessors, which fall back to the inserted text.

        /// The recording recogniser's raw output.
        var transcript: String?
        /// What the other recogniser(s) heard, for the rewrite prompt.
        var alternates: [AlternateReading]?
        /// The model's version at the moment of insertion, including any edits
        /// the user had made to it.
        var rewrite: String?

        init(
            id: UUID = UUID(),
            text: String,
            date: Date = Date(),
            profileName: String,
            transcript: String? = nil,
            alternates: [AlternateReading]? = nil,
            rewrite: String? = nil
        ) {
            self.id = id
            self.text = text
            self.date = date
            self.profileName = profileName
            self.transcript = transcript
            self.alternates = alternates
            self.rewrite = rewrite
        }

        /// The transcript to reopen with. Older entries have none, so the
        /// inserted text stands in: it keeps the restored session speaking
        /// about the same thing when more is dictated onto the end, which is
        /// the closest an entry from before this existed can get.
        var restoredTranscript: String { transcript ?? text }
        var restoredRewrite: String { rewrite ?? text }
        var restoredAlternates: [AlternateReading] { alternates ?? [] }

        /// One-line label for the menu.
        var menuTitle: String {
            let collapsed = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = 52
            guard collapsed.count > limit else { return collapsed }
            return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
        }
    }

    static let maxEntries = 10

    @Published private(set) var entries: [Entry] = [] {
        didSet { persist() }
    }

    private let defaultsKey = "dictationHistory"
    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    /// Newest first. A repeat of the most recent entry is not re-added.
    func record(
        _ text: String,
        transcript: String,
        alternates: [AlternateReading],
        rewrite: String,
        profileName: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard entries.first?.text != trimmed else { return }

        entries.removeAll { $0.text == trimmed }
        entries.insert(
            Entry(
                text: trimmed,
                profileName: profileName,
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                alternates: alternates,
                rewrite: rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            at: 0
        )
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    /// Copies an entry to the clipboard as a normal copy -- this one *should*
    /// land in the user's clipboard-manager history, unlike the transient item
    /// used during paste-insertion.
    func copyToClipboard(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    func clear() {
        entries.removeAll()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
