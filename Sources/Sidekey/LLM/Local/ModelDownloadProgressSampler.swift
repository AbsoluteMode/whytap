import Foundation

/// Drives real, byte-level download progress for an on-device model by watching
/// the bytes that actually land on disk, independent of the coarse fraction the
/// underlying HuggingFace download library reports.
///
/// WHY: see `ModelDownloadByteProgress`. `swift-transformers`' `HubApi.snapshot`
/// weights its `Progress` by file *count*, and FluidAudio re-runs a 0→1 reporter
/// per Core ML model — neither reflects bytes for the one multi-GB shard that
/// dominates the wait. Rather than reach into each library's per-file plumbing,
/// the sampler measures the destination directory's on-disk size against the
/// known remote total (summed from the Hub tree API, restricted to the files the
/// store actually downloads) and emits `downloadedBytes / totalBytes`.
///
/// The sampler runs a background polling task for the duration of a download. It
/// is intentionally I/O-thin: the math lives in the pure `ModelDownloadByteProgress`.
struct ModelDownloadProgressSampler: Sendable {
    /// Fetches the total number of bytes the download will write, or `nil` when
    /// the size cannot be determined up-front (caller then falls back to the
    /// library fraction). Injectable for tests.
    typealias TotalBytesProvider = @Sendable () async -> Int64?
    /// Measures the current on-disk byte size of the destination. Injectable.
    typealias DiskBytesProvider = @Sendable () -> Int64

    private let totalBytesProvider: TotalBytesProvider
    private let diskBytesProvider: DiskBytesProvider
    private let pollInterval: Duration
    private let minimumStep: Double

    init(
        totalBytesProvider: @escaping TotalBytesProvider,
        diskBytesProvider: @escaping DiskBytesProvider,
        pollInterval: Duration = .milliseconds(300),
        minimumStep: Double = 0.005
    ) {
        self.totalBytesProvider = totalBytesProvider
        self.diskBytesProvider = diskBytesProvider
        self.pollInterval = pollInterval
        self.minimumStep = minimumStep
    }

    /// Runs `operation` (the real library download/load) while polling disk bytes
    /// and forwarding a real fraction to `emit`. If the total size can't be
    /// resolved, `emit` is never called from here and the caller keeps using the
    /// library-provided fraction.
    ///
    /// `emit` is only invoked with strictly-advancing, throttled fractions in
    /// `[0, ModelDownloadByteProgress.ceiling]`; the store is responsible for the
    /// final `1.0` once the model is verified ready.
    func run<T>(
        emit: @escaping @Sendable (Double) -> Void,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let total = await totalBytesProvider()
        guard let total, total > 0 else {
            // Unknown total — don't fabricate progress; the library fraction
            // (whatever its granularity) remains the only signal.
            return try await operation()
        }

        let disk = diskBytesProvider
        let interval = pollInterval
        let step = minimumStep
        let samplingTask = Task<Void, Never> {
            var aggregator = ModelDownloadByteProgress(totalBytes: total, minimumStep: step)
            while !Task.isCancelled {
                if let fraction = aggregator.updateIfChanged(downloadedBytes: disk()) {
                    emit(fraction)
                }
                try? await Task.sleep(for: interval)
            }
        }
        defer { samplingTask.cancel() }

        return try await operation()
    }

    /// Recursively sums the byte size of every regular file under `directory`.
    /// Counts in-flight `.incomplete` temp files too, so the figure tracks bytes
    /// as they are flushed. Returns 0 when the directory does not yet exist.
    static func directoryByteSize(
        at directory: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: []
            )
        else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

/// Thread-safe one-way latch. Once real byte progress starts flowing from the
/// sampler, stores flip this so the library's coarse file-count fraction stops
/// emitting (otherwise the bar fights between byte-real and file-count values).
/// Both the sampler `emit` and the library callback run off the main thread.
final class SuppressionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
