import Foundation

/// Linear interpolation for the volume fade — duck-down on speech start,
/// restore-up on speech end. Pure + testable; the fader samples `volume(at:)`
/// with the wall-clock elapsed since the fade began, clamps outside the range,
/// and snaps to the target when duration is 0.
struct VolumeFadeRamp {
    let from: Float
    let to: Float
    let duration: TimeInterval

    func volume(at elapsed: TimeInterval) -> Float {
        guard duration > 0 else { return to }
        let t = min(1, max(0, elapsed / duration))
        return from + (to - from) * Float(t)
    }
}
