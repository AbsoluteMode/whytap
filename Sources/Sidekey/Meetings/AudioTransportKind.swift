import CoreAudio
import Foundation

/// Privacy-safe transport classification (inv. #3: enum string, never a
/// device name). This is the ONLY thing meeting-health telemetry ever
/// reports about the active input/output device.
enum AudioTransportKind: String, Sendable, Codable {
    case bluetooth, builtin, usb, other

    /// Maps CoreAudio `kAudioDevicePropertyTransportType` values.
    static func from(transportType: UInt32) -> AudioTransportKind {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtin
        case kAudioDeviceTransportTypeUSB:
            return .usb
        default:
            return .other
        }
    }

    /// Reads the default input (`isInput=true`) or output device's
    /// transport type directly off CoreAudio. Returns `nil` if any
    /// CoreAudio call fails (no default device resolved, property
    /// unreadable, etc.) — callers treat that as "unknown", not `.other`.
    static func defaultDevice(isInput: Bool) -> AudioTransportKind? {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: isInput
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress, 0, nil, &deviceSize, &deviceID
        )
        guard deviceStatus == noErr, deviceID != 0 else { return nil }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddress, 0, nil, &transportSize, &transportType
        )
        guard transportStatus == noErr else { return nil }

        return from(transportType: transportType)
    }
}
