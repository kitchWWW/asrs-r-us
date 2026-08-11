import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, then press a combination. Captures the next key press as the new
/// hotkey.
///
/// Uses a local `NSEvent` monitor rather than SwiftUI key handling because we
/// need the raw virtual keycode and modifier flags, and we need to swallow the
/// press so it does not also act on the window behind it.
struct ShortcutRecorder: View {
    @Binding var binding: HotKeyBinding
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Press a key…" : binding.displayString)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 90)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Ignore modifier-only presses: wait for a real key so ⌘ alone
            // cannot be bound.
            guard event.type == .keyDown else { return nil }

            if event.keyCode == UInt16(kVK_Escape),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()          // Escape cancels rather than binding Escape
                return nil
            }

            binding = HotKeyBinding(
                keyCode: Int(event.keyCode),
                modifiers: Self.cgFlags(from: event.modifierFlags).rawValue
            )
            stop()
            return nil          // swallow
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    /// `NSEvent.ModifierFlags` and `CGEventFlags` are different bit layouts.
    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command)  { result.insert(.maskCommand) }
        if flags.contains(.option)   { result.insert(.maskAlternate) }
        if flags.contains(.control)  { result.insert(.maskControl) }
        if flags.contains(.shift)    { result.insert(.maskShift) }
        return result
    }
}
