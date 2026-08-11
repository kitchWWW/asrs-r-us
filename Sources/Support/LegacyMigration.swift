import Foundation

/// Carries settings across the VoiceEdit -> ASRs-R-US rename.
///
/// Preferences and keychain items are scoped to the bundle identifier, so
/// changing it would otherwise silently reset every profile, setting, and the
/// stored API key. Runs once, before anything reads its own defaults.
enum LegacyMigration {
    private static let legacyBundleID = "com.brianellis.VoiceEdit"
    private static let migratedFlag = "migratedFromVoiceEdit"

    /// Explicit list rather than copying the whole domain: a bulk copy would
    /// drag in inherited global-domain keys as app-local overrides.
    private static let keys = [
        "model", "debounceMilliseconds", "restorePasteboard", "insertionMethod",
        "rewriteBackend", "localModelRepo", "localPort", "llamaServerPath",
        "profiles", "selectedProfileID", "systemPrompt", "prunedSeedProfiles",
        "dictationHistory",
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlag) else { return }
        defer { defaults.set(true, forKey: migratedFlag) }

        if let legacy = UserDefaults(suiteName: legacyBundleID) {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }

        // The keychain item is scoped by service name, which also changed.
        let account = "anthropic-api-key"
        if Keychain.string(for: account) == nil,
           let carried = Keychain.string(for: account, service: legacyBundleID) {
            Keychain.set(carried, for: account)
        }
    }
}
