import XCTest
@testable import Sidekey

/// Stage 2 tests for `MicInUseProbe`. The probe polls a CoreAudio property
/// every 2s to decide whether the system's default input device is in use by
/// any process (`kAudioDevicePropertyDeviceIsRunningSomewhere`). We inject a
/// stubbed query function so the tests run without touching real CoreAudio
/// hardware or relying on the host machine's mic state.
///
/// Contract pinned here:
/// 1. Stream emits the initial mic-in-use state and only emits on TRANSITIONS
///    thereafter — every poll is intentionally NOT a tick into the stream.
/// 2. Polling cadence is configurable (`MeetingsConfig.detectorMicPollSeconds`
///    in production; 50 ms in tests to keep the suite fast).
/// 3. The probe is cancellable and stops polling when its `Task` is cancelled,
///    so the detector / coordinator can tear it down without leaks.
@MainActor
final class MicInUseProbeTests: XCTestCase {

    // MARK: - Test helpers

    /// Reads the next value from an async stream within a deadline. Returns
    /// `nil` on timeout. Wraps the stream iterator in a detached task so the
    /// MainActor isolation of the test does not deadlock the producer that
    /// also runs on the MainActor (the probe).
    private func nextValue<T: Sendable>(
        from stream: AsyncStream<T>,
        within seconds: Double
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Drains a stream into an array, stopping after `count` values or a
    /// deadline. Lets the tests assert on a sequence (e.g. transitions
    /// false→true→false) rather than only the first value.
    private func collect<T: Sendable>(
        _ stream: AsyncStream<T>,
        count: Int,
        within seconds: Double
    ) async -> [T] {
        await withTaskGroup(of: [T].self) { group in
            group.addTask {
                var collected: [T] = []
                for await value in stream {
                    collected.append(value)
                    if collected.count >= count { return collected }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    // MARK: - Behaviour

    /// When the stubbed CoreAudio query reports the input device as running,
    /// the probe's first emission is `true`. The "first emission is the
    /// initial sample" contract matters because the detector wires up after
    /// the probe might already be running and needs the current state, not
    /// just the next change.
    func test_emits_true_when_device_running_somewhere() async {
        let stub = StubbedMicQuery(values: [true])
        let probe = MicInUseProbe(
            query: stub,
            pollInterval: 0.05
        )

        let stream = probe.subscribe()
        defer { probe.stop() }

        let first = await nextValue(from: stream, within: 1.0)
        XCTAssertEqual(first, true)
    }

    /// Symmetric to the `_running_` case: stubbed `false` reading means the
    /// probe's first emission is `false`. This is the YouTube / browsing
    /// baseline that the detector consumes to know mic is idle.
    func test_emits_false_when_device_not_running() async {
        let stub = StubbedMicQuery(values: [false])
        let probe = MicInUseProbe(
            query: stub,
            pollInterval: 0.05
        )

        let stream = probe.subscribe()
        defer { probe.stop() }

        let first = await nextValue(from: stream, within: 1.0)
        XCTAssertEqual(first, false)
    }

    /// Polling tick != stream tick. The stream emits the initial value once,
    /// then only on `Bool` transitions — so `[true, true, true, false, false]`
    /// should produce `[true, false]`, not five emissions. This is critical
    /// because the detector aggregates this stream with the VAD stream and
    /// we'd otherwise burn CPU on no-op state recomputations.
    func test_only_emits_on_transition_not_every_poll() async {
        let stub = StubbedMicQuery(
            values: [true, true, true, false, false, true]
        )
        let probe = MicInUseProbe(
            query: stub,
            pollInterval: 0.02
        )

        let stream = probe.subscribe()
        defer { probe.stop() }

        // We expect exactly three emissions: initial true, then false, then
        // true. Collect with a generous deadline to avoid flakes on slow CI.
        let values = await collect(stream, count: 3, within: 2.0)
        XCTAssertEqual(values, [true, false, true])
    }
}

// MARK: - Stubs

/// Replays a scripted sequence of `Bool` readings as the probe polls. After
/// the script exhausts we keep returning the last value (matches the real
/// CoreAudio contract: the device state doesn't disappear, it just stays
/// where it was). Thread-safe via `NSLock` because the probe polls from a
/// background `Task` even though we construct the stub on the MainActor.
final class StubbedMicQuery: MicInUseQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    private var lastValue: Bool

    init(values: [Bool]) {
        precondition(!values.isEmpty, "StubbedMicQuery needs at least one value")
        self.values = values
        self.lastValue = values[0]
    }

    func isDefaultInputRunningSomewhere() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if values.isEmpty {
            return lastValue
        }
        let next = values.removeFirst()
        lastValue = next
        return next
    }
}
