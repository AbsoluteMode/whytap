import CoreAudio
import Foundation

/// Which output transports volume ducking may touch. Pure so the gate is
/// unit-testable without CoreAudio devices.
///
/// Allowed: built-in (codec never clicked on volume writes) and Bluetooth /
/// Bluetooth LE (volume there is handled digitally, e.g. AVRCP absolute
/// volume, rather than as the analog hardware-gain step that made wired
/// DACs click — and empirically ducking worked on Bluetooth for the
/// feature's whole pre-#516 life). Everything else — wired external DACs
/// (USB/HDMI/DisplayPort/...), the confirmed "pop" source, and `nil`
/// (missing/unreadable transport) — is refused fail-safe: never touch
/// hardware we can't identify.
/// WHY: docs/decisions/2026-07-16-volume-duck-allow-bluetooth.md
enum VolumeDuckTransportPolicy {
    /// `true` when ducking is allowed to write this device's volume.
    static func allowsDucking(transportType: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
            || transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Reads the default output device's state (`currentOutput()`) and writes the
/// scalar volume (`kAudioDevicePropertyVolumeScalar`) of an explicitly given
/// device — reads resolve the default, writes are pinned to the device the
/// caller captured. This is device-volume control — moving the same slider the
/// user does — NOT audio capture, so it needs no TCC grant.
///
/// Tries the master element first; some devices (notably built-in speakers)
/// expose no settable master scalar and only per-channel volumes, so reads
/// average the available channels and writes fan out across them. Returns `nil`
/// when nothing is READABLE (some Bluetooth / HDMI outputs) — the caller then
/// skips ducking rather than touching a volume it cannot control. Settability
/// is re-checked per write: a readable-but-read-only device schedules fades
/// whose writes are silently rejected at the is-settable check.
@MainActor
final class SystemOutputVolume {
    /// Channels probed for the per-channel fallback (stereo covers the common
    /// built-in / USB DAC case).
    private static let fallbackChannels: [UInt32] = [1, 2]

    /// Snapshot of the default output for duck decisions: device identity,
    /// transport gate (`VolumeDuckTransportPolicy`) and current level.
    /// `isDuckable` is `false` whenever the transport type is missing or
    /// unreadable — fail-safe: unknown hardware is treated as external and
    /// left untouched.
    func currentOutput() -> OutputDeviceVolume? {
        guard let device = Self.defaultOutputDevice(),
              let volume = Self.readVolume(device) else { return nil }
        return OutputDeviceVolume(
            deviceID: device,
            isDuckable: VolumeDuckTransportPolicy.allowsDucking(
                transportType: Self.transportType(device)
            ),
            volume: volume
        )
    }

    private static func readVolume(_ device: AudioObjectID) -> Float? {
        if let master = readScalar(device, element: kAudioObjectPropertyElementMain) {
            return master
        }
        let perChannel = fallbackChannels.compactMap { readScalar(device, element: $0) }
        guard !perChannel.isEmpty else { return nil }
        return perChannel.reduce(0, +) / Float(perChannel.count)
    }

    /// Writes the scalar volume of a SPECIFIC device (never "the current
    /// default output"): fades are pinned to the device they started on, so an
    /// output switch mid-fade cannot redirect gain writes onto another device.
    /// Writes to a since-unplugged device fail silently at the has-property
    /// check.
    func setVolume(_ value: Float, device: AudioObjectID) {
        let clamped = min(1, max(0, value))
        if Self.writeScalar(device, element: kAudioObjectPropertyElementMain, value: clamped) {
            return
        }
        for channel in Self.fallbackChannels {
            _ = Self.writeScalar(device, element: channel, value: clamped)
        }
    }

    // MARK: - CoreAudio HAL helpers

    private static func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    private static func readScalar(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    /// Returns `true` when the write actually happened (property settable + ok).
    private static func writeScalar(
        _ device: AudioObjectID,
        element: AudioObjectPropertyElement,
        value: Float
    ) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var scalar = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalar) == noErr
    }

    /// `kAudioDevicePropertyTransportType` of the device, or `nil` when the
    /// property is absent/unreadable (virtual devices, some aggregates).
    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != 0 else { return nil }
        return device
    }
}
