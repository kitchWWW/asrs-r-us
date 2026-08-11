import AVFoundation
import CoreAudio
import Foundation

/// Enumerates CoreAudio input devices.
///
/// `AVAudioEngine` does not expose device selection directly -- the input node's
/// underlying audio unit does, by `AudioDeviceID` -- so this works at the HAL
/// level rather than through `AVCaptureDevice`.
enum AudioDevices {

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        /// Stable across reboots and reconnects; `AudioDeviceID` is not, so this
        /// is what gets persisted.
        let uid: String
        let name: String
        let isBuiltIn: Bool
    }

    static func inputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let name = stringProperty(id, kAudioObjectPropertyName) else {
                return nil
            }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? name
            return Device(id: id, uid: uid, name: name, isBuiltIn: isBuiltIn(id))
        }
    }

    /// The Mac's own microphone. Preferred over the system default input, which
    /// is often whatever headset or interface was plugged in last.
    static func builtInInput() -> Device? {
        let devices = inputDevices()
        return devices.first { $0.isBuiltIn }
            ?? devices.first { $0.name.localizedCaseInsensitiveContains("built-in") }
    }

    static func device(uid: String) -> Device? {
        inputDevices().first { $0.uid == uid }
    }

    /// Resolves the configured device, falling back to the built-in mic and then
    /// to whatever input exists.
    static func resolve(preferredUID: String) -> Device? {
        if !preferredUID.isEmpty, let match = device(uid: preferredUID) { return match }
        return builtInInput() ?? inputDevices().first
    }

    // MARK: - Property helpers

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, buffer) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}

/// Cached list of input devices, refreshed when the hardware set changes.
///
/// The panel header redraws ~30 times a second to animate the waveform, so the
/// device list cannot be enumerated from a SwiftUI body -- that would run a
/// burst of CoreAudio queries per second. A HAL property listener keeps this
/// current without polling, so hot-plugged microphones still appear.
@MainActor
final class AudioDeviceStore: ObservableObject {
    static let shared = AudioDeviceStore()

    @Published private(set) var devices: [AudioDevices.Device] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        devices = AudioDevices.inputDevices()
        installListener()
    }

    func refresh() {
        devices = AudioDevices.inputDevices()
    }

    /// The device a given stored preference resolves to, for display.
    func resolvedUID(for preferredUID: String) -> String {
        if !preferredUID.isEmpty, devices.contains(where: { $0.uid == preferredUID }) {
            return preferredUID
        }
        return AudioDevices.builtInInput()?.uid ?? devices.first?.uid ?? ""
    }

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in AudioDeviceStore.shared.refresh() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }
}
