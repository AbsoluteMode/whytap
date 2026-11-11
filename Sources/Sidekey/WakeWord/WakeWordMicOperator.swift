import AVFoundation
import CoreAudio
import Foundation

/// Microphone engine for the always-on wake word listener.
///
/// It never opens a Bluetooth microphone: holding one open switches the
/// headphones to the low-quality call profile for as long as Whytap listens.
/// It listens on the default input only when that is built in or USB;
/// otherwise on the Mac's built-in microphone, and fails (the listener stays
/// off) on a Mac without one.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
final class WakeWordMicOperator: MicEngineOperating, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noUsableMicrophone
    }

    private let engine = AVAudioEngine()

    var configurationChangeObject: AnyObject { engine }

    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let device = Self.listeningDevice() else { throw Failure.noUsableMicrophone }
        let inputNode = engine.inputNode
        // Always pinned explicitly: a previous start may have left the built-in
        // microphone selected after the default moved back off Bluetooth.
        try inputNode.auAudioUnit.setDeviceID(device)

        let tapFormat = MicTapFormatSelector.preferredTapFormat(
            inputFormat: inputNode.inputFormat(forBus: 0),
            outputFormat: inputNode.outputFormat(forBus: 0)
        )
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            onBuffer(buffer)
        }
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            engine.reset()
            throw error
        }
    }

    func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.reset()
    }

    // MARK: - Device choice

    /// The default input, or the built-in microphone when the default is
    /// Bluetooth; nil when neither can be used.
    static func listeningDevice() -> AudioDeviceID? {
        guard let preferred = defaultInputDevice() else { return builtInInputDevice() }
        return chooseDevice(
            defaultInput: preferred,
            defaultTransport: transport(of: preferred),
            builtIn: builtInInputDevice()
        )
    }

    /// Pure choice, separated for tests.
    static func chooseDevice(
        defaultInput: AudioDeviceID, defaultTransport: AudioTransportKind?, builtIn: AudioDeviceID?
    ) -> AudioDeviceID? {
        // Wired inputs only. Bluetooth, a Continuity iPhone microphone and
        // anything unidentified are never held open in the background.
        defaultTransport == .builtin || defaultTransport == .usb ? defaultInput : builtIn
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private static func transport(of device: AudioDeviceID) -> AudioTransportKind? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return AudioTransportKind.from(transportType: value)
    }

    private static func builtInInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { transport(of: $0) == .builtin && hasInputStreams($0) }
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
