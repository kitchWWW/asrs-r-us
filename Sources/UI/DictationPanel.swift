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
    private var keyMonitor: Any?

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
        session.beginSession(target: currentTarget())
        showPanel()
    }

    /// Opens the panel on a finished dictation instead of an empty one: both
    /// boxes come back as they were and the microphone picks up where it left
    /// off. The window is identical either way -- a restored session is a
    /// session, not a viewer.
    func reopen(_ entry: DictationHistory.Entry) {
        session.resumeSession(from: entry, target: currentTarget())
        showPanel()
    }

    /// The tracker, not `frontmostApplication`: opening from the status menu
    /// can leave us frontmost, which would record ASRs-R-US as its own paste
    /// target.
    private func currentTarget() -> NSRunningApplication? {
        FrontmostAppTracker.shared.target
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel

        positionOnActiveScreen(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Do not hand first responder to the output editor on open, so the
        // caret is not sitting in the text box before the user asks for it.
        panel.makeFirstResponder(nil)
        installKeyMonitor()
        session.isPanelVisible = true
    }

    func dismiss(activatingTarget: Bool = false) {
        removeKeyMonitor()
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

    /// The panel's two bare-key shortcuts: Return inserts, Right Arrow runs.
    ///
    /// Both are handled with a local event monitor rather than a SwiftUI
    /// `.keyboardShortcut`, for the same reason: once an `NSTextView` has
    /// focus it consumes plain keys first and the shortcut never fires. Which
    /// also means the monitor, not SwiftUI, is responsible for giving them
    /// back when the caret genuinely wants them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            switch Int(event.keyCode) {
            case kVK_Return:
                let isCommandReturn = modifiers == .command
                guard isCommandReturn || modifiers.isEmpty else { return event }
                // Once edited, only Cmd-Return inserts; bare Return types a newline.
                if !isCommandReturn && self.session.hasUserEdited { return event }
                guard self.session.canInsert else { return event }
                Task { await self.performUse() }
                return nil          // swallow

            case kVK_RightArrow:
                // "I have stopped talking, take it from here." Does exactly
                // what the Run button does: freeze the transcript, drain the
                // recogniser, and send the moment the tail comes back.
                //
                // Only when the caret is not in the rewritten-text box. There
                // the arrow keys belong to the caret, and swallowing one would
                // leave the box impossible to navigate -- which is a worse bug
                // than not having the shortcut.
                //
                // Arrow keys are never "unmodified": the window server stamps
                // every one with .function and .numericPad, so the plain
                // `modifiers.isEmpty` test used for Return rejects all of them
                // and the key falls through the responder chain as a beep.
                // Only the modifiers a user could actually hold disqualify it.
                let held: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                guard modifiers.intersection(held).isEmpty, !self.isEditingText else { return event }

                // Swallowed either way. Run can be unavailable -- nothing said
                // yet, or a run already in flight -- and a disabled button does
                // not beep at whoever presses it.
                if self.session.canRunNow, !self.session.isRunningNow {
                    Task { await self.session.runRewriteNow() }
                }
                return nil

            default:
                return event
            }
        }
    }

    /// True while the caret is in the rewritten-text box, which owns the arrow
    /// keys for as long as it has focus.
    private var isEditingText: Bool {
        panel?.firstResponder is NSTextView
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
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
        // Glass only reads as glass over a genuinely transparent window;
        // otherwise the system background sits behind it and flattens it out.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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

    /// The panel stays up until the insertion has actually landed.
    ///
    /// It would be faster to close it first -- the window holds key while the
    /// target is trying to come forward -- but a failure would then take the
    /// text away with nothing on screen to say why. The panel is where errors
    /// are visible, so it waits.
    private func finishInsertion(succeeded: Bool) async {
        guard succeeded else { return }
        removeKeyMonitor()
        panel?.orderOut(nil)
        session.isPanelVisible = false
    }
}
