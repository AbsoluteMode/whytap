import AVFoundation
import CoreMedia
import Foundation
import os.log

// MARK: - MeetingPillBufferAttaching

/// Narrow seam the pill controller / coordinator use to drive the buffer
/// without depending on the concrete `PrerecordBuffer` type. Lets the
/// Stage 3 wiring tests inject a stub that records `start` / `snapshot` /
/// `gc` calls instead of allocating a real 1.9 MB ring buffer.
///
/// Sendable so the pill controller (MainActor) can call `start()` /
/// `gc()` / `snapshot()` across the actor boundary without compiler
/// complaints.
protocol MeetingPillBufferAttaching: AnyObject, Sendable {
    /// Idempotent. Marks the buffer as "currently accepting audio". The
    /// real wiring (mic + system audio stream consumers) lives in
    /// Stage 4 — Stage 3 only needs an observable started state so the
    /// detector→pill wiring tests can assert it.
    func start() async

    /// Atomically copies the currently-retained samples into a
    /// self-contained 16 kHz mono PCM16 WAV blob. The returned `Data`
    /// is independent of the buffer (subsequent `gc()` / `append()`
    /// does not mutate it).
    func snapshot() async -> Data

    /// Privacy invariant. Zeroes the underlying byte storage in place
    /// before dropping it, then resets the buffer to an empty (and
    /// no-longer-accepting) state. Called on pill dismiss / timeout.
    func gc() async
}

// MARK: - PrerecordBuffer

/// 60-second RAM ring buffer for raw 16 kHz mono PCM16 audio captured
/// between the moment `MeetingDetector` emits `.triggered` and the moment
/// the user accepts / dismisses the `MeetingPill` suggestion. Sits between
/// the detector and `MeetingRecorder` (Stage 4) so the recorder, when it
/// finally starts, can splice the pre-trigger window onto the head of the
/// recording — otherwise the first ~1 minute of every meeting would be
/// lost (5s detector window + up to 20s pill decision = ~25s gap minimum,
/// up to ~95s in the worst case with the rolling speech window).
///
/// Privacy contract (Stage 3 invariant):
///
/// - Audio lives in RAM only while the pill is on screen.
/// - On dismiss / timeout, `gc()` zeroes the underlying allocation in
///   place (`Data.resetBytes`) before releasing it. A test-only
///   "zeroed-history" snapshot proves the wipe ran (see
///   `_testZeroedHistorySnapshot`).
/// - The buffer never persists anything to disk.
///
/// Storage layout: a single `Data` of interleaved Int16 little-endian
/// samples. We chose `Data` over `[Int16]` because:
///
/// 1. `Data.resetBytes(in:)` is the documented way to zero a buffer in
///    place — Array's storage may be relocated during append, leaving
///    the previous block on the heap with non-zero bytes the GC can't
///    reach.
/// 2. WAV body is just the same bytes — no extra serialisation step.
///
/// Capacity is measured in seconds (the spec talks in seconds; tests
/// pass `MeetingsConfig.prerecordBufferCapacitySeconds`); we materialise
/// it as `capacitySeconds × sampleRate × 2` bytes once at init.
///
/// Concurrency: `actor` keeps `append` / `snapshot` / `gc` race-free.
/// `MeetingsCoordinator` (MainActor) calls into it via `await`. Stage 4's
/// MeetingRecorder will pump samples in from the audio-output streams.
actor PrerecordBuffer: MeetingPillBufferAttaching {

    /// os_log surface — spec / plan call out `pill` and `buffer` as
    /// observability categories. Buffer-specific events route through
    /// `pill` since the buffer's lifecycle is owned by the pill.
    private static let log = OSLog(
        subsystem: "com.sidekey.meetings",
        category: "pill"
    )

    /// Byte length of a `snapshot()` taken with zero samples retained —
    /// the canonical 44-byte RIFF/WAVE/fmt /data header and no PCM body.
    /// Lives here (next to the header math in `snapshot()`) so consumers
    /// that need to distinguish a real pre-record from an empty one —
    /// `MeetingRecorder.start` gates its prerecord persist on
    /// `count > emptySnapshotByteCount` — share the buffer's own
    /// definition of "empty" instead of re-deriving the header size.
    static let emptySnapshotByteCount = 44

    /// Hard-pinned to 16 000 in production; the init takes it as a
    /// parameter only so tests can pass a smaller rate if they want.
    /// Stored separately from the byte capacity so the WAV header can
    /// emit the correct sample rate field.
    private let sampleRate: Int

    /// Pre-computed maximum byte length. At 16 kHz × 60 s × 2 bytes =
    /// 1 920 000 bytes (~1.83 MiB). Once `storage.count` would exceed
    /// this on append, the oldest bytes are evicted FIFO.
    private let capacityBytes: Int

    /// Live PCM16 storage. Mutated in-place on `append` (FIFO eviction)
    /// and on `gc` (zeroed then replaced with an empty `Data`).
    private var storage = Data()

    /// True between `start()` and `gc()`. Stage 3 has no `stop()` /
    /// `accept()` method on the buffer itself — `gc()` covers both the
    /// dismiss path AND any future tear-down. The flag is exposed only
    /// through the test accessor.
    private var isStartedFlag = false

    /// Test-only snapshot of the most-recently-zeroed allocation. The
    /// production code only reads from `storage` (the live buffer);
    /// `_testZeroedHistorySnapshot()` returns this so the gc-zeroing
    /// test can prove the wipe actually touched every byte.
    private var lastZeroedHistory = Data()

    // MARK: - Init

    /// - Parameters:
    ///   - sampleRate: PCM sample rate in Hz. Production: 16 000.
    ///   - capacitySeconds: ring-buffer span in seconds. Production:
    ///     `MeetingsConfig.prerecordBufferCapacitySeconds` (60).
    init(sampleRate: Int, capacitySeconds: TimeInterval) {
        self.sampleRate = sampleRate
        // 2 bytes per PCM16 sample. Integer-truncate then multiply so
        // a fractional `capacitySeconds` (e.g. tests passing 0.5) still
        // produces a deterministic byte count.
        let frames = Int(capacitySeconds * Double(sampleRate))
        self.capacityBytes = frames * 2
        // Reserve capacity up front to avoid mid-append reallocations
        // (which would defeat the in-place zero guarantee on `gc`).
        self.storage.reserveCapacity(capacityBytes)
    }

    // MARK: - Lifecycle

    /// Idempotent. After `start()` the buffer accepts `append` calls;
    /// subsequent `start()`s are no-ops. Stage 4's MeetingRecorder will
    /// subscribe to mic + system streams after this. Stage 3 keeps the
    /// method intentionally minimal so the wiring test can assert
    /// "buffer started" without any audio source actually plumbed in.
    func start() async {
        guard !isStartedFlag else { return }
        isStartedFlag = true
        os_log(
            "buffer started (cap_seconds: %{public}.0f)",
            log: Self.log, type: .info,
            Double(capacityBytes / 2) / Double(sampleRate)
        )
    }

    // MARK: - Append

    /// Append a chunk of CMSampleBuffer audio. Extracts 16 kHz mono
    /// Float32 samples through the existing
    /// `SystemAudioVADProbe.extractMono16kFloat32` helper (re-used so
    /// the buffer does not duplicate the CMSampleBuffer decoding
    /// surface) and converts to Int16 little-endian for storage.
    ///
    /// No-op if the buffer is not currently started — the caller is
    /// expected to gate on the pill state, but the guard here means
    /// late-arriving CMSampleBuffers after `gc()` cannot resurrect the
    /// storage.
    func append(_ buffer: CMSampleBuffer) async {
        guard isStartedFlag else { return }
        guard let floats = SystemAudioVADProbe.extractMono16kFloat32(from: buffer) else {
            return
        }
        var ints = [Int16](repeating: 0, count: floats.count)
        for i in 0..<floats.count {
            let clamped = max(-1.0, min(1.0, floats[i]))
            ints[i] = Int16(clamped * Float(Int16.max))
        }
        await append(samples: ints)
    }

    /// Primary append surface used by both the CMSampleBuffer overload
    /// and tests. FIFO-evicts the oldest bytes when the new payload
    /// would push `storage.count` past `capacityBytes`.
    func append(samples: [Int16]) async {
        guard isStartedFlag else { return }
        guard !samples.isEmpty else { return }

        // Convert Int16 samples to little-endian byte payload. The
        // host (arm64 / x86_64) is little-endian, so a `withUnsafeBytes`
        // on `[Int16]` already gives us the correct byte order.
        let payload = samples.withUnsafeBufferPointer { ptr -> Data in
            Data(buffer: ptr)
        }
        appendBytes(payload)
    }

    /// Internal byte-level append + FIFO eviction. Kept private so the
    /// public `append(samples:)` is the only entry point — keeps the
    /// "Int16 LE" storage invariant in one place.
    private func appendBytes(_ payload: Data) {
        storage.append(payload)
        if storage.count > capacityBytes {
            let overflow = storage.count - capacityBytes
            storage.removeFirst(overflow)
        }
    }

    // MARK: - Snapshot

    /// Builds a self-contained 16 kHz mono PCM16 WAV blob from whatever
    /// is currently in the ring. Caller owns the returned `Data` — any
    /// later `gc()` / `append()` on the buffer leaves it untouched.
    func snapshot() async -> Data {
        let body = storage
        let bodySize = UInt32(body.count)
        let totalSize = UInt32(36 + body.count) // RIFF chunk size = 4+24+8+dataSize
        let byteRate = UInt32(sampleRate * 1 * 16 / 8)
        let blockAlign: UInt16 = 1 * 16 / 8

        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(uint32LE: totalSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(uint32LE: 16)                          // PCM fmt chunk size
        header.append(uint16LE: 1)                           // PCM
        header.append(uint16LE: 1)                           // mono
        header.append(uint32LE: UInt32(sampleRate))
        header.append(uint32LE: byteRate)
        header.append(uint16LE: blockAlign)
        header.append(uint16LE: 16)                          // bits per sample
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(uint32LE: bodySize)

        var wav = header
        wav.append(body)
        return wav
    }

    // MARK: - GC

    /// Privacy invariant: zero the live storage in place, snapshot the
    /// wiped bytes for the gc-zero test, then drop the storage entirely.
    /// `isStartedFlag` flips back to false so any in-flight `append`
    /// awaiting on the actor sees the buffer as closed and bails.
    func gc() async {
        let priorCount = storage.count
        if priorCount > 0 {
            storage.withUnsafeMutableBytes { rawPtr in
                guard let base = rawPtr.baseAddress, rawPtr.count > 0 else { return }
                memset(base, 0, rawPtr.count)
            }
            // Capture the zeroed bytes for the test before we drop the
            // allocation. Production never reads `lastZeroedHistory` —
            // it exists solely so the gc test can prove the wipe ran.
            lastZeroedHistory = storage
        } else {
            lastZeroedHistory = Data()
        }
        storage = Data()
        storage.reserveCapacity(capacityBytes)
        isStartedFlag = false
        os_log(
            "buffer gc (prior_bytes: %{public}d)",
            log: Self.log, type: .info,
            priorCount
        )
    }

    // MARK: - Test-only accessors
    // These are surfaced through the actor's public API so the unit
    // tests can verify private state without sprinkling `@testable
    // private` workarounds. The leading `_test` prefix marks them as
    // not part of the production surface — Stage 4+ wiring should never
    // call them.

    /// Returns the live storage decoded back to Int16 samples. Used by
    /// FIFO-contract tests to inspect what survived eviction.
    func _testRetainedSamples() -> [Int16] {
        return storage.withUnsafeBytes { raw -> [Int16] in
            let count = raw.count / 2
            guard let base = raw.baseAddress, count > 0 else { return [] }
            let buf = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Int16.self),
                count: count
            )
            return Array(buf)
        }
    }

    /// Returns the live storage byte payload. Used by the gc test to
    /// confirm the post-gc storage is empty (length 0).
    func _testUnderlyingBytes() -> [UInt8] {
        return Array(storage)
    }

    /// Returns the most-recently-wiped allocation. After `gc()` this
    /// holds the previous storage with every byte set to 0. Used solely
    /// by `test_gc_zeroes_underlying_bytes` to prove the wipe touched
    /// every byte of the prior allocation.
    func _testZeroedHistorySnapshot() -> [UInt8] {
        return Array(lastZeroedHistory)
    }
}

// MARK: - Data little-endian append helpers

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32LE value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
