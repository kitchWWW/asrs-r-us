import AppKit
import Combine
import Foundation
import SwiftUI

/// Which rewrite profile to use for which application.
///
/// The profile that suits a message to a friend is not the one that suits a
/// shell command, and the app being dictated into already says which is which
/// -- so it picks, rather than the user remembering to. Terminal takes Default,
/// iMessage takes Personal, and nothing has to be switched by hand.
///
/// Only apps actually dictated into are listed. Enumerating installed
/// applications would be a wall of names that mostly never receive dictation;
/// the list earns its entries instead.
@MainActor
final class AppProfileMap: ObservableObject {
    static let shared = AppProfileMap()

    struct KnownApp: Identifiable, Codable, Hashable {
        var bundleID: String
        var name: String
        var lastUsed: Date

        var id: String { bundleID }
    }

    /// Apps dictated into, most recently used first.
    @Published private(set) var recentApps: [KnownApp] = []

    /// Bundle identifier to profile. Kept separate from `recentApps` so a
    /// choice survives the app dropping off the end of the list and coming back.
    @Published private(set) var assignments: [String: Profile.ID] = [:]

    /// How many apps the settings list shows. Long enough to cover what someone
    /// dictates into in practice, short enough to stay a list rather than a log.
    private let maxRecents = 12

    private enum Key {
        static let recents = "appProfileRecents"
        static let assignments = "appProfileAssignments"
        static let backfilled = "appProfileBackfilledV2"
    }

    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: Key.recents),
           let decoded = try? JSONDecoder().decode([KnownApp].self, from: data) {
            recentApps = decoded
        }
        if let data = defaults.data(forKey: Key.assignments),
           let decoded = try? JSONDecoder().decode([String: Profile.ID].self, from: data) {
            assignments = decoded
        }
        backfillFromSessionLogIfNeeded()
    }

    /// Seeds the list from apps already dictated into.
    ///
    /// The session log has recorded `targetBundleID` since long before this
    /// feature existed, so the setting can arrive already populated instead of
    /// empty -- which would otherwise make it look broken until enough new
    /// sessions had accumulated to fill it.
    ///
    /// Only `recentApps` is seeded. Assignments are left alone deliberately:
    /// `record` gives an app its default the first time it is really dictated
    /// into, and doing it here would mean reading `ProfileStore.shared` from
    /// inside this singleton's own initializer.
    private func backfillFromSessionLogIfNeeded() {
        guard !defaults.bool(forKey: Key.backfilled) else { return }
        defaults.set(true, forKey: Key.backfilled)

        guard let text = try? String(contentsOf: SessionLog.shared.fileURL, encoding: .utf8) else {
            return
        }
        let stamps = ISO8601DateFormatter()
        // The log is append-only, so later lines are more recent and a plain
        // walk leaves the last sighting of each app as the one that counts.
        var lastSeen: [String: Date] = [:]
        var order: [String: Int] = [:]
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bundleID = object["targetBundleID"] as? String,
                  !bundleID.isEmpty
            else { continue }
            order[bundleID] = index
            if let ended = object["endedAt"] as? String, let date = stamps.date(from: ended) {
                lastSeen[bundleID] = date
            }
        }

        let seeded = order.sorted { $0.value > $1.value }.prefix(maxRecents).map {
            KnownApp(
                bundleID: $0.key,
                name: Self.displayName(for: $0.key),
                lastUsed: lastSeen[$0.key] ?? .distantPast
            )
        }
        guard !seeded.isEmpty else { return }
        recentApps = seeded
        persist()
    }

    /// The name shown in Settings. Resolved from the bundle identifier, since
    /// that is all the log kept.
    private static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        let name = FileManager.default.displayName(atPath: url.path)
        // `displayName` keeps the ".app" when the user has Finder set to show
        // all file extensions, which is how "Terminal.app" ended up in the list.
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Notes that a session is going into `app`, assigning it `fallback` the
    /// first time it is seen so its dropdown has a real value to show.
    func record(_ app: NSRunningApplication, fallback: Profile.ID) {
        guard let bundleID = app.bundleIdentifier else { return }
        let name = app.localizedName ?? bundleID

        var updated = recentApps.filter { $0.bundleID != bundleID }
        updated.insert(KnownApp(bundleID: bundleID, name: name, lastUsed: Date()), at: 0)
        recentApps = Array(updated.prefix(maxRecents))

        if assignments[bundleID] == nil { assignments[bundleID] = fallback }
        persist()
    }

    /// The profile assigned to `bundleID`, if that profile still exists.
    ///
    /// The existence check matters: deleting a profile would otherwise leave
    /// apps pointing at nothing and silently produce no switch at all.
    func profileID(for bundleID: String, among profiles: [Profile]) -> Profile.ID? {
        guard let assigned = assignments[bundleID],
              profiles.contains(where: { $0.id == assigned }) else { return nil }
        return assigned
    }

    func assign(_ profileID: Profile.ID, to bundleID: String) {
        guard assignments[bundleID] != profileID else { return }
        assignments[bundleID] = profileID
        persist()
    }

    func forget(_ bundleID: String) {
        recentApps.removeAll { $0.bundleID == bundleID }
        assignments[bundleID] = nil
        persist()
    }

    /// Picker binding for one app's row in Settings.
    func binding(for bundleID: String, fallback: Profile.ID) -> Binding<Profile.ID> {
        Binding(
            get: { self.assignments[bundleID] ?? fallback },
            set: { self.assign($0, to: bundleID) }
        )
    }

    /// The app's icon, for scanning the list by sight rather than by reading.
    /// Looked up from the bundle identifier, so it survives the app not running.
    static func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    /// Icons are fetched from a SwiftUI body, which runs often; disk lookups
    /// there would be repeated for every row on every redraw.
    private static var iconCache: [String: NSImage] = [:]

    private func persist() {
        if let data = try? JSONEncoder().encode(recentApps) {
            defaults.set(data, forKey: Key.recents)
        }
        if let data = try? JSONEncoder().encode(assignments) {
            defaults.set(data, forKey: Key.assignments)
        }
    }
}