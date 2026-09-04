import XCTest
@testable import Sidekey

/// Proves the disk-byte sampler emits REAL byte-proportional progress while a
/// download runs, and falls back cleanly when the total can't be resolved.
final class ModelDownloadProgressSamplerTests: XCTestCase {

    /// With a known total and a growing on-disk size, the sampler emits a
    /// strictly-advancing fraction proportional to bytes — no 2%→57% leap.
    func testEmitsByteProportionalProgressWhileDownloading() async throws {
        let total: Int64 = 1_000_000
        let disk = DiskCounter()
        let emissions = Emissions()

        let sampler = ModelDownloadProgressSampler(
            totalBytesProvider: { total },
            diskBytesProvider: { disk.value },
            pollInterval: .milliseconds(5),
            minimumStep: 0.001
        )

        _ = try await sampler.run(
            emit: { emissions.append($0) },
            operation: {
                // Simulate bytes landing on disk in real chunks.
                for written in stride(from: 100_000, through: 1_000_000, by: 100_000) {
                    disk.set(Int64(written))
                    try await Task.sleep(for: .milliseconds(15))
                }
                // The sampler polls concurrently and stops when this operation
                // returns, so returning immediately after the last write is a
                // race: on a slow machine the final bytes are never sampled and
                // the last emission stays at the previous chunk. Wait for the
                // sampler to observe the full size instead of assuming it did.
                let deadline = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < deadline {
                    if (emissions.values.last ?? 0) >= ModelDownloadByteProgress.ceiling - 0.0001 {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                return ()
            }
        )

        let values = emissions.values
        XCTAssertFalse(values.isEmpty, "sampler must emit while bytes flow")
        // Monotonic.
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "emissions must be non-decreasing")
        }
        // Reached the ceiling once all bytes were on disk. The operation above
        // waits for that emission, so this is an assertion about the sampler's
        // arithmetic, not about how fast the machine ran.
        XCTAssertEqual(values.last ?? 0, ModelDownloadByteProgress.ceiling, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(values.last ?? 1, ModelDownloadByteProgress.ceiling + 0.0001)
        // Never reported a premature 100%.
        XCTAssertTrue(values.allSatisfy { $0 <= ModelDownloadByteProgress.ceiling + 0.0001 })
    }

    /// When the total is unknown, the sampler must NOT emit (so the caller keeps
    /// the library fraction) and still run the operation to completion.
    func testUnknownTotalDoesNotEmit() async throws {
        let emissions = Emissions()
        let didRun = Emissions()

        let sampler = ModelDownloadProgressSampler(
            totalBytesProvider: { nil },
            diskBytesProvider: { 500 },
            pollInterval: .milliseconds(5)
        )

        _ = try await sampler.run(
            emit: { emissions.append($0) },
            operation: {
                didRun.append(1)
                try await Task.sleep(for: .milliseconds(20))
                return ()
            }
        )

        XCTAssertTrue(emissions.values.isEmpty, "no byte total → no fabricated progress")
        XCTAssertEqual(didRun.values.count, 1, "operation still runs")
    }

    /// `directoryByteSize` sums regular files recursively and returns 0 for a
    /// missing directory.
    func testDirectoryByteSizeSumsFilesRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 250).write(to: sub.appendingPathComponent("b.bin"))

        XCTAssertEqual(ModelDownloadProgressSampler.directoryByteSize(at: root), 350)

        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(ModelDownloadProgressSampler.directoryByteSize(at: missing), 0)
    }

    // MARK: - Helpers

    private final class DiskCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int64 = 0
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ v: Int64) { lock.lock(); defer { lock.unlock() }; _value = v }
    }

    private final class Emissions: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Double] = []
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
        func append(_ v: Double) { lock.lock(); defer { lock.unlock() }; _values.append(v) }
    }
}
