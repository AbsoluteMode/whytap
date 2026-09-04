import Foundation

/// Lowers the system output volume while the user records voice, then restores
/// it. On recording start (feature on, output readable, duckable transport) it
/// remembers the current level and fades down to `duckFactor` of it; on
/// recording end it fades back to the saved level — but ONLY if WE were the
/// ones who lowered it AND the default output is still the same device: a
/// volume this controller never ducked is never touched, and a level captured
/// on one device is never written to another. (A manual volume change made
/// DURING a ducked recording is overwritten by the restore — tracking user
/// intent mid-fade is not worth the complexity.)
///
/// Duck engages only on transports `VolumeDuckTransportPolicy` allows:
/// built-in and Bluetooth. Wired external DACs audibly click ("pop") on
/// hardware-gain writes — the restore ramp fired one on every drop release —
/// and unknown/unreadable transports count as external (fail-safe: never
/// touch hardware we can't identify).
/// WHY: docs/decisions/2026-07-10-volume-duck-builtin-only.md
/// WHY: docs/decisions/2026-07-16-volume-duck-allow-bluetooth.md
///
/// `readOutput` / `fade` are injected so the transition logic is unit-tested
/// without CoreAudio or a real timer. `readOutput` returns `nil` when there is
/// no default output or it has no settable scalar volume (some Bluetooth /
/// HDMI devices) — then ducking is skipped entirely.
@MainActor
final class VolumeDuckController {
    /// Fraction of the original volume to duck down to (e.g. 0.35 = 35%).
    private let duckFactor: Float
    private let fadeDownDuration: TimeInterval
    private let fadeUpDuration: TimeInterval

    private let toggleEnabled: () -> Bool
    private let readOutput: () -> OutputDeviceVolume?
    private let fade: (_ from: Float, _ to: Float, _ duration: TimeInterval, _ deviceID: UInt32) -> Void
    /// Target + device of the fader's in-flight fade (`VolumeFader.active`),
    /// `nil` when idle.
    private let activeFade: () -> (Float, UInt32)?
    /// Stops the fader's in-flight fade without starting a new one.
    private let cancelFade: () -> Void

    /// The level we captured before ducking, to restore to. Non-nil only while
    /// a duck WE issued is outstanding.
    private var savedVolume: Float?
    /// The device the saved level belongs to. Restore is skipped when the
    /// default output changed mid-recording.
    private var savedDeviceID: UInt32?
    /// True only while our duck is outstanding. Restore is gated on this so we
    /// never raise a volume the user had set themselves.
    private var duckedByUs = false

    init(
        toggleEnabled: @escaping () -> Bool,
        readOutput: @escaping () -> OutputDeviceVolume?,
        fade: @escaping (Float, Float, TimeInterval, UInt32) -> Void,
        activeFade: @escaping () -> (Float, UInt32)?,
        cancelFade: @escaping () -> Void,
        duckFactor: Float = 0.35,
        fadeDownDuration: TimeInterval = 1.2,
        fadeUpDuration: TimeInterval = 1.0
    ) {
        self.toggleEnabled = toggleEnabled
        self.readOutput = readOutput
        self.fade = fade
        self.activeFade = activeFade
        self.cancelFade = cancelFade
        self.duckFactor = duckFactor
        self.fadeDownDuration = fadeDownDuration
        self.fadeUpDuration = fadeUpDuration
    }

    /// Drive from recording state. Idempotent: duck fires once per recording
    /// session, restore fires once and only if we ducked.
    func update(recording: Bool) {
        if recording {
            guard !duckedByUs, toggleEnabled(), let output = readOutput(),
                  output.isDuckable else { return }
            // If a restore fade toward the true baseline is still running on
            // THIS device (rapid drop after drop), adopt its target as the
            // baseline — reading the mid-fade level would ratchet the volume
            // down a notch per recording. A fade on some other device says
            // nothing about this one.
            let baseline: Float
            if let active = activeFade(), active.1 == output.deviceID {
                baseline = active.0
            } else {
                baseline = output.volume
            }
            savedVolume = baseline
            savedDeviceID = output.deviceID
            duckedByUs = true
            fade(output.volume, baseline * duckFactor, fadeDownDuration, output.deviceID)
        } else {
            guard duckedByUs, let saved = savedVolume, let savedDevice = savedDeviceID else { return }
            duckedByUs = false
            savedVolume = nil
            savedDeviceID = nil
            // Restore only onto the device we actually lowered, from wherever
            // the fade currently sits. If the default output changed
            // mid-recording or became unreadable, leave it alone — never write
            // a level captured on one device to another — and stop the
            // in-flight duck-down fade so it does not keep writing either.
            guard let output = readOutput(), output.deviceID == savedDevice else {
                cancelFade()
                return
            }
            fade(output.volume, saved, fadeUpDuration, savedDevice)
        }
    }
}
