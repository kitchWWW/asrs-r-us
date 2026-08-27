import AppKit
import Carbon.HIToolbox
import os

/// Puts text where the cursor was, by reactivating the app that was frontmost
/// before our panel appeared and delivering the text to it.
///
/// Two strategies:
///
///   * `.paste` (default) -- put the text on the pasteboard and synthesize
///     Cmd-V. Fast and works essentially everywhere, including Electron apps,
///     browser rich-text editors, and terminals, where the Accessibility API's
///     value-setting silently fails or mangles text.
///   * `.type` -- synthesize the characters directly as keyboard events. Never
///     touches the pasteboard at all, at the cost of being slower and less
///     reliable in apps that debounce or reinterpret rapid input.
@MainActor
enum TextInserter {

    enum Method: String, CaseIterable, Identifiable {
        case paste
        case type
        var id: String { rawValue }
    }

    private static let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "insert")

    enum InsertError: LocalizedError {
        case noTargetApp
        case accessibilityDenied

        var errorDescription: String? {
            switch self {
            case .noTargetApp:
                return "No app to paste into -- ASRs-R-US did not see a frontmost app when it opened."
            case .accessibilityDenied:
                return "Accessibility permission is required to insert text into other apps."
            }
        }
    }

    /// Everything that can be known to fail before any slow work starts.
    ///
    /// Split out so the caller can dismiss the panel the instant it knows the
    /// insertion will be attempted, instead of holding it on screen through
    /// activation and paste and only then finding out.
    static func precheck(_ target: NSRunningApplication?) throws {
        guard AXIsProcessTrusted() else { throw InsertError.accessibilityDenied }
        guard let target, !target.isTerminated else { throw InsertError.noTargetApp }
    }

    static func insert(
        _ text: String,
        into target: NSRunningApplication?,
        method: Method,
        restorePasteboard: Bool
    ) async throws {
        try precheck(target)
        guard let target else { throw InsertError.noTargetApp }

        let started = ContinuousClock.now
        target.activate()

        // Wait for the target to actually come forward. Delivering input to an
        // app that is not yet key drops it on the floor.
        await waitUntilFrontmost(target, timeout: .milliseconds(900))
        let activated = ContinuousClock.now

        switch method {
        case .type:
            typeText(text)
        case .paste:
            await pasteText(text, restorePasteboard: restorePasteboard)
        }

        // Timed because this is the part the user watches. Split at activation
        // so a slow target app is distinguishable from a slow paste.
        let ms = { (d: Duration) -> Int in
            Int(Double(d.components.seconds) * 1000
                + Double(d.components.attoseconds) / 1e15)
        }
        log.info("""
            inserted \(text.count) characters into \
            \(target.bundleIdentifier ?? "unknown") via \(method.rawValue) -- \
            activate \(ms(activated - started), privacy: .public)ms, \
            deliver \(ms(ContinuousClock.now - activated), privacy: .public)ms
            """)
    }

    // MARK: - Paste strategy

    private static func pasteText(_ text: String, restorePasteboard: Bool) async {
        let pasteboard = NSPasteboard.general
        let saved = restorePasteboard ? snapshot(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.writeObjects([transientItem(for: text)])
        let ourChangeCount = pasteboard.changeCount

        postCommandV()

        guard let saved else { return }

        // The restore has to wait for the target to consume the pasteboard, but
        // the caller must not: awaiting it here kept the panel on screen for an
        // extra ~0.7 s after the paste had already landed.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            // If something else wrote to the pasteboard meanwhile, that write is
            // newer than ours and the user meant it -- do not stomp it.
            guard pasteboard.changeCount == ourChangeCount else {
                log.info("pasteboard changed during paste; skipping restore")
                return
            }
            restore(saved, to: pasteboard)
        }
    }

    /// Builds a pasteboard item flagged as transient so clipboard managers keep
    /// it out of the user's history.
    ///
    /// These marker types are the nspasteboard.org convention, honored by
    /// Jumpcut, Flycut, Maccy, Clipy, Copied, Pastebot and others. Without them,
    /// every dictation would leave a junk entry in the clipboard history --
    /// twice, since restoring the previous contents is itself a write.
    private static func transientItem(for text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        // Legacy spelling, still checked by older managers.
        item.setString("", forType: NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"))
        // Courtesy: lets a manager attribute the write if it wants to.
        item.setString(
            Bundle.main.bundleIdentifier ?? "com.brianellis.ASRs-R-US",
            forType: NSPasteboard.PasteboardType("org.nspasteboard.source")
        )
        return item
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Typing strategy

    /// Synthesizes the text as Unicode keyboard events, bypassing the
    /// pasteboard entirely. `keyboardSetUnicodeString` ignores the active
    /// keyboard layout, so accented and non-Latin characters survive.
    private static func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let units = Array(text.utf16)
        // Small chunks: a single event carrying a very long string is dropped
        // or truncated by some applications.
        let chunkSize = 16
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            index = end
            usleep(1_200)   // let the target's input queue keep up
        }
    }

    // MARK: - Helpers

    private static func waitUntilFrontmost(
        _ app: NSRunningApplication,
        timeout: Duration
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if app.isActive {
                // Small settle so the app's key window finishes taking focus.
                try? await Task.sleep(nanoseconds: 60_000_000)
                return
            }
            // Polled tightly: the caller dismisses its own window before
            // getting here, so activation usually completes within a frame or
            // two and a coarse interval would spend most of the wait asleep
            // after the target was already ready.
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        log.warning("target app never became frontmost; inserting anyway")
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        }
        return PasteboardSnapshot(items: items)
    }

    private static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            // Mark the restore transient too: putting the user's own clipboard
            // back is not a new copy and must not create a duplicate entry.
            item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setString("", forType: NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"))
            return item
        }
        pasteboard.writeObjects(items)
    }
}
