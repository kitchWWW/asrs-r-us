import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A floating panel that can take keyboard focus (so the user can edit the
/// bottom box) while still looking like an overlay rather than a document
/// window.
final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel's lifecycle and the focus hand-off with whatever app was
/// frontmost when the hotkey fired.
@MainActor
final class DictationWindowController: NSObject, NSWindowDelegate {

    private let session: SessionController
    private var panel: DictationPanel?
    private var returnMonitor: Any?

    init(session: SessionController) {
        self.session = session
        super.init()
    }

    /// Clicking the panel's close button must tear the session down too,
    /// otherwise the microphone keeps running behind a hidden window.
    func windowWillClose(_ notification: Notification) {
        session.endSession()
        session.isPanelVisible = false
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Opens the panel and starts a new session targeting whatever app is
    /// frontmost right now.
    func present() {
        // Capture the target BEFORE activating ourselves, or we'd record
        // ASRs-R-US as its own paste target.
        let target = NSWorkspace.shared.frontmostApplication
        session.beginSession(target: target)

        let panel = panel ?? makePanel()
        self.panel = panel

        positionOnActiveScreen(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Do not hand first responder to the output editor on open, so the
        // caret is not sitting in the text box before the user asks for it.
        panel.makeFirstResponder(nil)
        installReturnMonitor()
        session.isPanelVisible = true
    }

    func dismiss(activatingTarget: Bool = false) {
        removeReturnMonitor()
        session.endSession()
        panel?.orderOut(nil)
        session.isPanelVisible = false
        if activatingTarget, let target = session.targetApp, !target.isTerminated {
            target.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    func toggle() {
        if isVisible {
            // Panel already up: F7 toggles the mic rather than the window.
            session.toggleRecording()
        } else {
            present()
        }
    }

    /// Plain Return means "use this" until the user starts editing the
    /// rewritten text, at which point it belongs to the editor as a newline.
    ///
    /// Handled with a local event monitor rather than a SwiftUI
    /// `.keyboardShortcut`: once an `NSTextView` has focus it consumes Return
    /// first, and the shortcut never fires.
    private func installReturnMonitor() {
        guard returnMonitor == nil else { return }
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            guard event.keyCode == UInt16(kVK_Return) else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandReturn = modifiers == .command
            guard isCommandReturn || modifiers.isEmpty else { return event }

            // Once edited, only Cmd-Return inserts; bare Return types a newline.
            if !isCommandReturn && self.session.hasUserEdited { return event }
            guard self.session.canInsert else { return event }

            Task { await self.performUse() }
            return nil          // swallow
        }
    }

    private func removeReturnMonitor() {
        if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
        returnMonitor = nil
    }

    // MARK: - Construction

    private func makePanel() -> DictationPanel {
        let panel = DictationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive --
        // NSWindow raises an assertion if both are set. canJoinAllSpaces is the
        // one we want: the panel follows the user to whatever Space they are on.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 460, height: 320)
        panel.delegate = self
        // No fade on close -- dismissing should feel instant.
        panel.animationBehavior = .none

        // onEscape/onUse are DictationView-returning helpers, so they must be
        // applied before any modifier that erases to `some View`.
        let root = DictationView(session: session)
            .onEscape { [weak self] in self?.dismiss(activatingTarget: true) }
            .onUse { [weak self] in await self?.performUse() }
            .onUseTranscript { [weak self] in await self?.performUseTranscript() }
            .environmentObject(session)
            .environmentObject(session.settings)
            // The panel uses fullSizeContentView, but SwiftUI still insets for
            // the titlebar safe area, which reintroduces the dead strip at the
            // top. The header carries its own leading inset to stay clear of
            // the close button.
            .ignoresSafeArea()

        panel.contentView = NSHostingView(rootView: root)
        return panel
    }

    /// Puts the panel slightly above center on whichever screen has the mouse.
    private func positionOnActiveScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + frame.height * 0.12
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - Use

    private func performUse() async {
        await finishInsertion(succeeded: await session.useOutput())
    }

    private func performUseTranscript() async {
        await finishInsertion(succeeded: await session.useTranscript())
    }

    private func finishInsertion(succeeded: Bool) async {
        guard succeeded else { return }
        removeReturnMonitor()
        panel?.orderOut(nil)
        session.isPanelVisible = false
    }
}
