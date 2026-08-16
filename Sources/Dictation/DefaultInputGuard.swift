import CoreAudio
import Foundation
import OSLog

/// Keeps the system default input off Bluetooth for as long as the app runs.
///
/// macOS hands the default input to a Bluetooth headset the moment one
/// connects, and that is the one state this app cannot tolerate. Opening such a
/// device forces the headset into its hands-free profile, which collapses
/// *playback* on the same headset to 1 ch / 16 kHz -- measured on a QC45, and it
/// does not recover when the stream closes. Worse, opening it is easy to do by
/// accident: reading `AVAudioEngine.inputNode` binds to whatever holds the
/// default, so the profile can flip before a single line of capture code runs.
///
/// The engine used to work around this per session and hand the default back
/// afterwards. This replaces that entirely. The default is corrected at launch
/// and again whenever anything moves it, so there is no window in which a
/// headset holds it -- and nothing to restore later, which is what used to
/// re-trigger the profile switch at the end of every session.
///
/// The cost is deliberate and worth stating: while this app runs, the headset
/// microphone cannot be made the system default, even on purpose. Choosing it
/// in System Settings will be undone within a moment.
@MainActor
final class DefaultInputGuard {
    static let shared = DefaultInputGuard()

    private var listener: AudioObjectPropertyListenerBlock?
    /// Timestamps of recent corrections, for the tug-of-war check below.
    private var corrections: [Date] = []

    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "audio")

    private init() {}

    /// Corrects the default now and keeps correcting it. Idempotent.
    func start() {
        guard listener == nil else { return }
        enforce()

        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in DefaultInputGuard.shared.enforce() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    /// Moves the default input to the built-in mic when a Bluetooth device holds
    /// it. Safe to call redundantly; a non-Bluetooth default is left alone.
    func enforce() {
        guard let current = AudioDevices.defaultInputDeviceID(),
              AudioDevices.isBluetooth(current) else { return }

        // `inputDevices()` already excludes Bluetooth, so either branch lands on
        // something safe to open.
        guard let target = AudioDevices.builtInInput() ?? AudioDevices.inputDevices().first else {
            // A headset is the only microphone on this machine. Fighting over
            // the default would leave the user with no input at all, which is a
            // worse outcome than a degraded one.
            log.error("default input is Bluetooth and there is no other mic to move it to")
            return
        }
        guard allowCorrection() else { return }

        if AudioDevices.setDefaultInputDevice(target.id) {
            log.info("moved system default input off Bluetooth to \(target.name)")
        } else {
            log.error("could not move system default input off Bluetooth")
        }
    }

    /// Stops an unbounded tug of war.
    ///
    /// Something else may be insisting on the headset -- a reconnect storm, or
    /// the Sound pane open and being clicked. Correcting a few times a second
    /// forever would be worse than losing, so back off and let the next quiet
    /// stretch reset the count.
    private func allowCorrection() -> Bool {
        let now = Date()
        corrections.removeAll { now.timeIntervalSince($0) > 10 }
        guard corrections.count < 5 else {
            log.error("default input keeps returning to Bluetooth; backing off")
            return false
        }
        corrections.append(now)
        return true
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
