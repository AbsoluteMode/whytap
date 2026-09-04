import Foundation

/// Smoothly fades a device's output volume from one level to another over a
/// duration via a ~60 fps repeating timer, sampling `VolumeFadeRamp`. Starting
/// a new fade cancels any in-flight one, so a restore that begins mid-duck-down
/// never fights it. The actual write is injected (production: a
/// `SystemOutputVolume`).
///
/// Every fade is PINNED to the device it started on: `write` receives the
/// `deviceID` given to `fade(on:)`, never "the current default output" — so an
/// output switch mid-fade cannot redirect gain writes onto another device
/// (e.g. an external DAC that clicks on them).
@MainActor
final class VolumeFader {
    private let write: (Float, UInt32) -> Void
    private var timer: Timer?
    /// Last level actually written this fade. Near-equal repeats are dropped so
    /// a fade never streams redundant hardware-gain writes (external DACs can
    /// click on every write; a no-op fade must not emit ~60 writes/s).
    private var lastSent: Float?
    /// Target + device of the in-flight fade; `nil` when idle. The duck
    /// controller reads this to recover the true baseline when a new duck
    /// starts while a restore is still running.
    private(set) var active: (target: Float, deviceID: UInt32)?

    /// ~60 fps so a ~1 s fade reads as smooth, not stepped.
    private let stepInterval: TimeInterval = 1.0 / 60.0
    /// Below the ~1/256 quantum most scalar volumes resolve to.
    private let minStep: Float = 0.004

    init(write: @escaping (Float, UInt32) -> Void) {
        self.write = write
    }

    deinit { timer?.invalidate() }

    func fade(from: Float, to: Float, duration: TimeInterval, on deviceID: UInt32) {
        cancel()
        lastSent = nil
        guard duration > 0 else { send(to, on: deviceID, force: true); return }

        active = (target: to, deviceID: deviceID)
        let ramp = VolumeFadeRamp(from: from, to: to, duration: duration)
        let startedAt = Date()
        // No synchronous write here: the first ~60 fps tick lands within one
        // frame anyway, and the immediate write was one more hardware-gain
        // command than needed.

        let timer = Timer(timeInterval: stepInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = Date().timeIntervalSince(startedAt)
                let finished = elapsed >= duration
                // The final write is forced and sends the exact target (not a
                // ramp sample, which can differ by one Float ULP) so the fade
                // always lands precisely on `to`.
                self.send(finished ? to : ramp.volume(at: elapsed), on: deviceID, force: finished)
                if finished {
                    self.cancel()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func send(_ value: Float, on deviceID: UInt32, force: Bool) {
        if let last = lastSent {
            if last == value { return }                       // exact repeat — never resend
            if !force, abs(value - last) < minStep { return } // sub-quantum step — skip
        }
        write(value, deviceID)
        lastSent = value
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        active = nil
    }
}
