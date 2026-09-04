import CoreAudio
import Foundation
import os.log

/// Metadata-only probe that decides whether the system's default input device
/// is in use by any process. **Does not consume mic content.** This is the
/// privacy invariant for Stage 2: the detector trigger arm reads the same
/// signal the system menu bar shows for the orange microphone dot, never
/// the audio samples behind it.
///
/// Polling cadence is intentionally a 2-second tick rather than a CoreAudio
/// property listener (`AudioObjectAddPropertyListener`). Listener-driven
/// notifications fan out across multiple notification queues that are
/// awkward to inject in tests; polling at 2 Hz costs ~negligible CPU and
/// keeps the stub seam trivial. See `MicInUseQuerying` below for the test
/// injection point.
///
/// Emission contract:
/// - The first value placed on the stream is the **current** mic-in-use
///   state at subscription time. Downstream needs that "current" reading
///   to seed its rolling-window logic, not just notifications of change.
/// - Every subsequent emission is a **transition** — i.e. the stream does
///   not retick when consecutive polls return the same value. This keeps
///   the detector / coordinator off a hot loop of no-op recomputations.
@MainActor
final class MicInUseProbe: MicInUseProbing {

    /// os_log surface for the mic-probe category. Spec / plan call out
    /// "mic-probe" as one of the meetings log categories so Console.app
    /// can filter the polling-cadence diagnostics from the rest.
    private static let log = OSLog(
        subsystem: "com.sidekey.meetings",
        category: "mic-probe"
    )

    private let query: MicInUseQuerying
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    /// PoC multi-consumer broadcast: detector + recorder both subscribe.
    /// Each subscription gets its own AsyncStream; poll task is shared.
    /// Prior single-consumer logic killed detector when recorder subscribed.
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var lastEmitted: Bool?

    /// - Parameters:
    ///   - query: CoreAudio-backed reader of the "is the default input
    ///     device running somewhere" property. Tests inject
    ///     `StubbedMicQuery` so the suite never touches real hardware.
    ///   - pollInterval: How often `query` is sampled. Production: 2s.
    init(
        query: MicInUseQuerying = DefaultInputRunningQuery(),
        pollInterval: TimeInterval = 2.0
    ) {
        self.query = query
        self.pollInterval = pollInterval
    }

    /// Begins polling and returns a stream of mic-in-use state changes.
    /// Each call returns a fresh AsyncStream; poll task is shared across
    /// all subscribers. Detector + recorder + any future consumer all
    /// receive the same transition events. Drops continuation when its
    /// consumer Task terminates.
    func subscribe() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuations[id] = continuation
        // Seed new subscribers with current state so they don't wait for
        // next transition to learn whether mic is on or off.
        if let lastEmitted {
            continuation.yield(lastEmitted)
        }
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        if pollTask == nil {
            startPollTask()
        }
        return stream
    }

    private func startPollTask() {
        let interval = pollInterval
        let query = self.query
        pollTask = Task.detached(priority: .utility) { [weak self] in
            let intervalNs = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                let current = query.isDefaultInputRunningSomewhere()
                await self?.handlePoll(current)
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    private func handlePoll(_ current: Bool) {
        guard lastEmitted == nil || lastEmitted != current else { return }
        lastEmitted = current
        for cont in continuations.values {
            cont.yield(current)
        }
    }

    /// Cancels the polling task and terminates the stream. Safe to call
    /// when no subscription is active. The detector / coordinator calls
    /// this on tear-down so the polling task does not outlive the probe.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for cont in continuations.values { cont.finish() }
        continuations.removeAll()
        lastEmitted = nil
    }

    deinit {
        // `stop()` is MainActor-isolated; cancel the task directly here
        // because deinit can run off the MainActor. Cancellation is
        // sufficient to terminate the polling loop; continuations will
        // finish on their own once their consumer Tasks observe the
        // upstream task cancellation.
        pollTask?.cancel()
        for cont in continuations.values { cont.finish() }
    }
}

// MARK: - Protocols

/// Test seam over the CoreAudio query. Returning a plain `Bool` keeps
/// the protocol minimal so stubs are trivial to write; the production
/// implementation translates a small set of CoreAudio errors into
/// `false` (we do not crash if HAL momentarily refuses to answer).
///
/// `Sendable` because the probe samples this from a background `Task`
/// without bouncing back to the MainActor for each poll.
protocol MicInUseQuerying: Sendable {
    func isDefaultInputRunningSomewhere() -> Bool
}

/// Test seam over the polling probe itself. The detector subscribes to
/// `MicInUseProbing` so unit tests can substitute a hand-driven stream.
@MainActor
protocol MicInUseProbing: AnyObject {
    func subscribe() -> AsyncStream<Bool>
    func stop()
}

// MARK: - CoreAudio implementation

/// Real CoreAudio query backing `MicInUseProbe` in production.
///
/// Walks two HAL properties:
/// 1. `kAudioHardwarePropertyDefaultInputDevice` on `kAudioObjectSystemObject`
///    to discover which device is currently the user's default input.
/// 2. `kAudioDevicePropertyDeviceIsRunningSomewhere` on that device id to
///    learn whether any process has the device open.
///
/// Both reads are `AudioObjectGetPropertyData` with the 6-arg signature
/// (no qualifier). Errors translate to `false` because "we cannot tell" is
/// indistinguishable from "no-one is using it" for the detector's purpose,
/// and the polling loop will retry on the next tick.
struct DefaultInputRunningQuery: MicInUseQuerying {
    /// PoC fix: enumerate **all** input devices and report true if any of
    /// them has an active client. Previously we only polled the default
    /// input, which missed users on Bluetooth headsets / external mics
    /// while the system default stayed on the built-in MacBook microphone.
    /// Method name kept for protocol compatibility — implementation now
    /// returns "any input device is running somewhere".
    func isDefaultInputRunningSomewhere() -> Bool {
        for deviceID in allInputDeviceIDs() where isDeviceRunningSomewhere(deviceID) {
            return true
        }
        return false
    }

    private func allInputDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        )
        guard status == noErr else { return [] }
        // Filter to devices that expose at least one input stream — output-only
        // devices (speakers, virtual loopback sinks) would always answer
        // "not running" for input but waste a property read each tick.
        return devices.filter { hasInputStreams($0) }
    }

    private func hasInputStreams(_ deviceID: AudioObjectID) -> Bool {
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize)
        guard status == noErr else { return false }
        return streamSize > 0
    }

    private func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &isRunning
        )
        guard status == noErr else { return false }
        return isRunning != 0
    }
}
