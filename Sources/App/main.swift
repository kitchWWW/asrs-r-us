import AppKit

// Explicit setup rather than @main + SwiftUI App: this is a menu-bar agent
// that owns its own NSPanel, so there is no SwiftUI scene to declare.
//
// Top-level code in main.swift is not main-actor-isolated, but it does run on
// the main thread before the run loop starts, so assuming isolation here is
// sound.
MainActor.assumeIsolated {
    // Must run before AppSettings/ProfileStore read their defaults.
    LegacyMigration.runIfNeeded()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Keep the delegate alive for the process lifetime (NSApp holds it weakly).
    objc_setAssociatedObject(app, "ASRs-R-USDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
