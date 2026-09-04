import Foundation

/// Snapshot of the default output device taken around a duck transition:
/// identity (so a restore never writes to a *different* device than the one
/// we lowered), the transport gate (`isDuckable`, decided by
/// `VolumeDuckTransportPolicy` — wired external DACs audibly click on
/// hardware-gain writes and are never touched), and the current scalar
/// volume. `deviceID` is the CoreAudio `AudioObjectID` kept as a plain
/// `UInt32` so consumers stay CoreAudio-free.
struct OutputDeviceVolume: Equatable {
    let deviceID: UInt32
    let isDuckable: Bool
    let volume: Float
}
