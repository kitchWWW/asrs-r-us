import AppKit
import Carbon.HIToolbox
import os

/// Captures F7 globally and swallows it so macOS never sees it.
///
/// F7 arrives in one of two shapes depending on the "Use F1, F2, etc. keys as
/// standard function keys" setting:
///
///   * standard-function-keys ON  -> a normal `.keyDown` with virtual keycode 98
///   * standard-function-keys OFF -> an `NSSystemDefined` (type 14) event whose
///     `data1` encodes a media key (rewind / previous track)
///
/// We tap both and consume the event, which is what "take over from whatever
/// the system command is" requires. This needs Accessibility permission; a
/// `.listenOnly` tap would see the key but could not stop iTunes/Music from
/// also reacting to it.
@MainActor
final class HotKeyMonitor {
    /// The combination we currently claim. Read from the tap callback, which
    /// runs on the main run loop.
    private(set) nonisolated(unsafe) static var binding: HotKeyBinding = .f7

    /// NX_KEYTYPE_REWIND (20) and NX_KEYTYPE_PREVIOUS (18). Which one F7 emits
    /// varies by keyboard generation, so we claim both.
    private static let mediaKeyCodes: Set<Int32> = [18, 20]

    private static let systemDefinedEventType = CGEventType(rawValue: 14)!

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private static let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "hotkey")
    /// Set by the tap callback so Settings can show what the last key press looked like.
    private(set) nonisolated(unsafe) static var lastObservedEvent: String = "none yet"

    /// Fired on the main actor when F7 goes down.
    var onHotKey: (() -> Void)?

    private(set) var isRunning = false

    // MARK: - Lifecycle

    /// - Returns: `false` when the tap could not be created, which in practice
    ///   always means Accessibility permission has not been granted yet.
    /// Swaps the claimed combination without tearing down the tap.
    func update(binding: HotKeyBinding) {
        Self.binding = binding
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << Self.systemDefinedEventType.rawValue)

        // `self` is passed unretained: HotKeyMonitor is owned by the app
        // delegate for the whole process lifetime, and stop() tears the tap
        // down before the object could ever be deallocated.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // .defaultTap => we may swallow events
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Self.log.error("CGEvent.tapCreate failed - Accessibility permission missing?")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        Self.log.info("hotkey tap installed")
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - Tap callback

    /// Runs on the run loop the tap was added to (the main run loop), but is
    /// reached through a C function pointer, so it must be `nonisolated`.
    private nonisolated func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or when input is
        // re-secured. Re-enabling is the documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            Self.log.debug("keyDown keycode=\(keyCode, privacy: .public)")
            Self.lastObservedEvent = "keyDown keycode \(keyCode)"
            if Self.binding.matches(keyCode: keyCode, flags: event.flags) {
                // Ignore auto-repeat so holding F7 does not thrash the toggle.
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                    return nil
                }
                MainActor.assumeIsolated { onHotKey?() }
                return nil                              // swallow
            }
            return Unmanaged.passUnretained(event)
        }

        if type == Self.systemDefinedEventType {
            guard let nsEvent = NSEvent(cgEvent: event),
                  nsEvent.subtype.rawValue == 8         // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            else { return Unmanaged.passUnretained(event) }

            let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
            let keyFlags = nsEvent.data1 & 0x0000_FFFF
            let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
            let isRepeat = (keyFlags & 0x1) == 1
            Self.log.debug("systemDefined mediaKey=\(keyCode, privacy: .public) down=\(isKeyDown, privacy: .public)")
            if isKeyDown { Self.lastObservedEvent = "media key \(keyCode)" }

            // Only claim the media-key form when the binding is bare F7.
            guard Self.binding.matchesMediaKeys, Self.mediaKeyCodes.contains(keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            if isKeyDown && !isRepeat {
                MainActor.assumeIsolated { onHotKey?() }
            }
            return nil                                  // swallow down *and* up
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Permission

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system "grant Accessibility access" prompt.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}
