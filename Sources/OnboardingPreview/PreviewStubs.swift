import Foundation

// Minimal stand-ins for the audio-pipeline singletons that `VoiceOrbView`
// reads inside `displayEnergy`. The real implementations live in the
// Sidekey target alongside the audio pipeline; the preview executable
// has no audio input and feeds fake levels directly, so trivial
// pass-through is enough to satisfy the orb's gating + smoothing call
// sites without dragging FluidAudio / Soniox / NSWorkspace dependencies
// into the preview build.

@MainActor
final class NoiseFloorEstimator {
    static let shared = NoiseFloorEstimator()

    /// Fixed floor — keeps `dynamicGate = max(0.02, min(0.1, floor + 0.01))`
    /// pinned at 0.02 so any reasonable fake level passes the gate.
    var floor: Float = 0.0

    func normalize(_ value: Float) -> Float { value }

    private init() {}
}

@MainActor
final class AudioEnergyFollower {
    static let shared = AudioEnergyFollower()

    /// Pass-through follower — the synthetic envelope already carries
    /// the desired shape, no further smoothing needed.
    func observe(_ value: Float) -> Float { value }

    private init() {}
}
