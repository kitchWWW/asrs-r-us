import AppKit
import Combine
import Foundation

/// The last N things the user actually inserted, kept so they can be recalled
/// from the menu bar without redictating.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()

    struct Entry: Identifiable, Codable, Hashable {
        var id: UUID
        var text: String
        var date: Date
        var profileName: String

        init(id: UUID = UUID(), text: String, date: Date = Date(), profileName: String) {
            self.id = id
            self.text = text
            self.date = date
            self.profileName = profileName
        }

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
    func record(_ text: String, profileName: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard entries.first?.text != trimmed else { return }

        entries.removeAll { $0.text == trimmed }
        entries.insert(Entry(text: trimmed, profileName: profileName), at: 0)
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
