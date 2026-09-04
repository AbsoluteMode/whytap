import AVFoundation
import XCTest
@testable import Sidekey

/// Threading contract for `MicCaptureSource`: the blocking engine/HAL work
/// (`MicEngineOperating.startCapture` / `stopCapture`) stalls for seconds
/// while a meeting's audio devices come up (Bluetooth switching to HFP,
/// Zoom claiming the input device), so it must never run on the main
/// thread — running it there froze the UI right after clicking Take notes.
@MainActor
final class MicCaptureSourceTests: XCTestCase {

    func testEngineStartRunsOffMainThread() async throws {
        let engineOperator = ThreadRecordingMicOperator()
        let source = MicCaptureSource(
            engineOperator: engineOperator,
            ensureAccess: {}
        )

        try await source.start()

        XCTAssertEqual(
            engineOperator.startThread.get(), false,
            "engine start must run off the main thread (nil = never ran)"
        )
        await source.stop()
    }

    func testEngineStopRunsOffMainThread() async throws {
        let engineOperator = ThreadRecordingMicOperator()
        let source = MicCaptureSource(
            engineOperator: engineOperator,
            ensureAccess: {}
        )
        try await source.start()

        await source.stop()

        XCTAssertEqual(
            engineOperator.stopThread.get(), false,
            "engine stop must run off the main thread (nil = never ran)"
        )
    }

    /// `stop()` racing a suspended `start()` must not leave a live capture
    /// behind. Whichever way the race resolves — start bails before touching
    /// the engine, or starts and is torn back down — the invariant is
    /// "every startCapture is matched by a stopCapture".
    func testStopDuringStartLeavesNoLiveCapture() async throws {
        let engineOperator = ThreadRecordingMicOperator()
        let gate = AsyncGate()
        let source = MicCaptureSource(
            engineOperator: engineOperator,
            ensureAccess: { await gate.wait() }
        )

        let startTask = Task { try await source.start() }
        // Let start() reach and suspend inside the permission gate before
        // stop() arrives, so the race is really "stop during start".
        await Task.yield()
        await source.stop()
        gate.open()
        try await startTask.value

        XCTAssertEqual(
            engineOperator.startCallCount.get(),
            engineOperator.stopCallCount.get(),
            "a capture started concurrently with stop() must be torn back down"
        )
    }
}

// MARK: - Test doubles

/// Records which thread each engine operation ran on. First value wins so a
/// later legitimate off-main call cannot mask an initial main-thread one.
private final class ThreadRecordingMicOperator: MicEngineOperating, @unchecked Sendable {
    let startThread = FirstBoolBox()
    let stopThread = FirstBoolBox()
    let startCallCount = CounterBox()
    let stopCallCount = CounterBox()

    var configurationChangeObject: AnyObject { self }

    func startCapture(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        startThread.set(Thread.isMainThread)
        startCallCount.increment()
    }

    func stopCapture() {
        stopThread.set(Thread.isMainThread)
        stopCallCount.increment()
    }
}

private final class FirstBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = newValue }
    }

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Suspends waiters until opened — lets a test hold `start()` inside its
/// permission gate while `stop()` slips in.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func open() {
        Task { await self.openInside() }
    }

    private func openInside() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
