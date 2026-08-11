import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let session = SessionController()
    private let hotKey = HotKeyMonitor()
    private lazy var windowController = DictationWindowController(session: session)

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var permissionPollTimer: Timer?

    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

        // Touch the tracker now so it starts observing app activations
        // immediately. Left lazy, it would not exist until the first menu click
        // and would have missed every activation before that -- including the
        // app the user was actually in.
        _ = FrontmostAppTracker.shared

        installMainMenu()
        installStatusItem()
        installHotKey()

        // Warm the local model at launch so the first dictation is not spent
        // waiting for a server boot (and, on first ever run, a model download).
        if session.settings.backend == .local {
            Task { await session.server.start() }
        }

        // Debug affordance: VOICEEDIT_AUTOSHOW=1 opens the panel at launch so
        // the UI path can be exercised without a keypress.
        if ProcessInfo.processInfo.environment["VOICEEDIT_AUTOSHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.server.stop()
        hotKey.stop()
        permissionPollTimer?.invalidate()
    }


    // MARK: - Main menu

    /// An `.accessory` app never *shows* a menu bar, but AppKit still routes
    /// command-key equivalents through `NSApp.mainMenu`. Without one, Cut /
    /// Copy / Paste / Select All / Undo do nothing in any of our text fields --
    /// including the API key field and the rewrite editor. So we install a
    /// menu purely for keyboard routing.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // Application menu.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide ASRs-R-US",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        appMenu.addItem(NSMenuItem(
            title: "Quit ASRs-R-US",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu. These all dispatch to the first responder, which is what
        // makes them work inside the text views. They are deliberately kept
        // when other menu shortcuts are removed: an .accessory app has no menu
        // bar, and AppKit routes Cut/Copy/Paste/Select All *through* the main
        // menu, so dropping them silently breaks editing everywhere in the app.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pasteMatch = NSMenuItem(
            title: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "v"
        )
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pasteMatch)
        editMenu.addItem(NSMenuItem(
            title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu -- gives us Close (Cmd-W) for the settings window.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.badge.mic",
            accessibilityDescription: "ASRs-R-US"
        )
        item.button?.image?.isTemplate = true
        let menu = buildMenu()
        // Rebuilt on open so the history and profile lists are always current.
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let start = NSMenuItem(
            title: "Start Dictation",
            action: #selector(showPanel),
            keyEquivalent: ""
        )
        start.target = self
        menu.addItem(start)

        let hint = NSMenuItem(
            title: "Hotkey: \(ProfileStoreHotkeyLabel.current)",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        addProfileItems(to: menu)
        menu.addItem(.separator())
        addHistoryItems(to: menu)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit ASRs-R-US",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(quit)

        return menu
    }

    /// Lets the active profile be switched without opening Settings.
    private func addProfileItems(to menu: NSMenu) {
        let header = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let store = ProfileStore.shared
        for profile in store.profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == store.selectedID ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
    }

    /// The last 10 insertions; clicking one copies it back to the clipboard.
    private func addHistoryItems(to menu: NSMenu) {
        let header = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let history = DictationHistory.shared
        guard !history.entries.isEmpty else {
            let empty = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
            return
        }

        for (index, entry) in history.entries.enumerated() {
            let item = NSMenuItem(
                title: entry.menuTitle,
                action: #selector(copyHistoryEntry(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id
            item.indentationLevel = 1
            item.toolTip = entry.text
            // Wording matches what the click now does.
            menu.addItem(item)
        }

        let clear = NSMenuItem(
            title: "Clear Recent Dictations",
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clear.target = self
        clear.indentationLevel = 1
        menu.addItem(clear)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        let rebuilt = buildMenu()
        for item in rebuilt.items {
            rebuilt.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - Menu actions

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Profile.ID else { return }
        ProfileStore.shared.selectedID = id
    }

    /// Inserts the entry where the user was working, rather than only copying
    /// it and making them paste. Falls back to the clipboard when there is no
    /// app to target.
    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? DictationHistory.Entry.ID,
              let entry = DictationHistory.shared.entries.first(where: { $0.id == id })
        else { return }

        guard let target = FrontmostAppTracker.shared.target else {
            DictationHistory.shared.copyToClipboard(entry)
            return
        }

        Task {
            do {
                try await TextInserter.insert(
                    entry.text,
                    into: target,
                    method: session.settings.insertionMethod,
                    restorePasteboard: session.settings.restorePasteboard
                )
            } catch {
                // Anything that stops insertion still leaves it on the
                // clipboard, so the click is never a dead end.
                DictationHistory.shared.copyToClipboard(entry)
                self.log.error("history insert failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func clearHistory() {
        DictationHistory.shared.clear()
    }

    @objc private func showPanel() {
        windowController.present()
    }

    @objc private func showSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ASRs-R-US Settings"
        window.contentView = NSHostingView(rootView: SettingsView(server: session.server))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Hotkey

    private func installHotKey() {
        hotKey.update(binding: session.settings.hotKey)
        session.settings.onHotKeyChanged = { [weak self] binding in
            self?.hotKey.update(binding: binding)
            self?.statusItem?.menu?.update()
        }
        hotKey.onHotKey = { [weak self] in
            self?.windowController.toggle()
        }

        guard !hotKey.start() else { return }

        // Tap creation failed => Accessibility not granted yet. Prompt, then
        // poll until the user grants it and install the tap for real.
        log.notice("requesting Accessibility permission for the F7 hotkey")
        HotKeyMonitor.requestAccessibilityPermission()
        presentPermissionAlert()

        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard HotKeyMonitor.hasAccessibilityPermission else { return }
                if self.hotKey.start() {
                    self.log.info("hotkey installed after permission grant")
                    timer.invalidate()
                    self.permissionPollTimer = nil
                }
            }
        }
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "ASRs-R-US needs Accessibility access"
        alert.informativeText = """
        Accessibility access lets ASRs-R-US capture the F7 key before macOS \
        does, and paste text into whatever app you are working in.

        Enable ASRs-R-US under Privacy & Security > Accessibility, then come \
        back — no restart needed.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            HotKeyMonitor.openAccessibilitySettings()
        }
    }
}
