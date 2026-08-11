import AppKit
import Combine

/// Remembers the last application the user was actually working in.
///
/// Reading `NSWorkspace.frontmostApplication` at the moment a menu item fires
/// is unreliable: interacting with the status item can make us the frontmost
/// app, so the answer would sometimes be ourselves. Tracking activations as
/// they happen and ignoring our own keeps a usable target at all times.
@MainActor
final class FrontmostAppTracker: ObservableObject {
    static let shared = FrontmostAppTracker()

    @Published private(set) var lastExternalApp: NSRunningApplication?

    private var observer: NSObjectProtocol?
    private let selfBundleID = Bundle.main.bundleIdentifier

    private init() {
        lastExternalApp = Self.externalApp(NSWorkspace.shared.frontmostApplication,
                                           excluding: selfBundleID)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let external = Self.externalApp(app, excluding: self.selfBundleID) {
                    self.lastExternalApp = external
                }
            }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// The best current guess at where text should be inserted.
    var target: NSRunningApplication? {
        if let app = lastExternalApp, !app.isTerminated { return app }
        return Self.externalApp(NSWorkspace.shared.frontmostApplication, excluding: selfBundleID)
    }

    private static func externalApp(
        _ app: NSRunningApplication?,
        excluding bundleID: String?
    ) -> NSRunningApplication? {
        guard let app, app.bundleIdentifier != bundleID else { return nil }
        return app
    }
}
