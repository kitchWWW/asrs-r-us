import AppKit
import Carbon.HIToolbox

/// A user-chosen key combination for opening the dictation window.
struct HotKeyBinding: Equatable, Codable {
    /// Virtual keycode (`kVK_*`).
    var keyCode: Int
    /// `CGEventFlags` raw value, already masked to the four modifiers we honor.
    var modifiers: UInt64

    static let f7 = HotKeyBinding(keyCode: kVK_F7, modifiers: 0)

    /// Only these participate in matching; caps lock, numeric pad, and the
    /// function-key flag would otherwise cause spurious mismatches.
    static let relevantMask: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    /// F7 with no modifiers also arrives as a media key on keyboards where the
    /// function row defaults to media controls, so that path stays claimed.
    var matchesMediaKeys: Bool { keyCode == kVK_F7 && modifiers == 0 }

    func matches(keyCode code: Int64, flags eventFlags: CGEventFlags) -> Bool {
        guard Int(code) == keyCode else { return false }
        let masked = eventFlags.intersection(Self.relevantMask).rawValue
        return masked == modifiers
    }

    // MARK: - Display

    var displayString: String {
        var result = ""
        let flags = self.flags
        if flags.contains(.maskControl)   { result += "⌃" }
        if flags.contains(.maskAlternate) { result += "⌥" }
        if flags.contains(.maskShift)     { result += "⇧" }
        if flags.contains(.maskCommand)   { result += "⌘" }
        return result + Self.name(for: keyCode)
    }

    static func name(for keyCode: Int) -> String {
        if let special = specialNames[keyCode] { return special }
        return character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    private static let specialNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    /// Resolves the printed character via the active keyboard layout, so the
    /// label is right on non-QWERTY layouts.
    private static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// Small indirection so the menu can show the current shortcut without the
/// delegate reaching into settings at build time.
@MainActor
enum ProfileStoreHotkeyLabel {
    static var current: String { AppSettings.shared.hotKey.displayString }
}
