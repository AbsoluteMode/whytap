import Foundation
import FluidAudio

enum LocalDiarizerModelStatus: Equatable {
    case checking
    case notDownloaded
    case downloading(Double)
    case ready
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isReady: Bool {
        self == .ready
    }
}

enum LocalDiarizerError: LocalizedError, Equatable {
    case modelNotDownloaded
    case noAudio

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Download the local diarization model first."
        case .noAudio:
            return "No audio was provided to diarize."
        }
    }
}

protocol LocalDiarizerModelManaging: Sendable {
    func localModelStatus() async -> LocalDiarizerModelStatus
    func isModelReady() async -> Bool
    func downloadModel(progress: (@Sendable (Double) -> Void)?) async throws
    func deleteModel() async throws
    func loadManager() async throws -> DiarizerManager
    func modelDirectory() async -> URL
    /// Drop the cached `DiarizerManager` (the Core ML bundles stay on disk) so
    /// the next `loadManager()` re-initialises from scratch. Used by the
    /// meetings-local pipeline to serialise the three on-device models and keep
    /// peak memory bounded.
    func evict() async
}

/// On-device speaker-diarization model cache. Mirrors `LocalLLMModelStore` /
/// `LocalTranscriptionModelStore`: downloads the FluidAudio
/// `FluidInference/speaker-diarization-coreml` Core ML bundles into an app-owned
/// directory under Application Support, tracks status/progress, exposes a
/// lazily-cached `DiarizerManager`, and clears the cache on delete. Audio never
/// leaves the device and no transcript/audio content is logged here (inv. #3).
actor LocalDiarizerModelStore: LocalDiarizerModelManaging {
    /// Injection seam: download the diarizer Core ML models into `directory`,
    /// reporting a 0...1 fraction. Defaults to the real FluidAudio downloader.
    typealias Download = @Sendable (
        URL,
        @escaping @Sendable (Double) -> Void
    ) async throws -> Void

    static let shared = LocalDiarizerModelStore()

    /// FluidAudio caches the diarizer repo under this folder name (see
    /// `Repo.diarizer.folderName`); we pin it locally so `modelDirectory()` and
    /// the FluidAudio downloader agree on the on-disk layout.
    private static let repoFolderName = "speaker-diarization-coreml"
    /// The two CoreML bundles a complete diarizer cache must contain
    /// (`ModelNames.Diarizer.segmentationFile` / `.embeddingFile`).
    private static let requiredModelBundles = [
        "pyannote_segmentation.mlmodelc",
        "wespeaker_v2.mlmodelc",
    ]

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let download: Download
    private var cachedManager: DiarizerManager?
    private var downloadTask: Task<Void, Error>?
    private var downloadProgress: Double = 0
    private var lastFailure: String?

    init(
        rootDirectory: URL = LocalDiarizerModelStore.defaultRootDirectory(),
        fileManager: FileManager = .default,
        download: @escaping Download = LocalDiarizerModelStore.defaultDownload
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.download = download
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Sidekey", isDirectory: true)
            .appendingPathComponent("LocalDiarizationModels", isDirectory: true)
    }

    /// Where the FluidAudio downloader places the diarizer bundles:
    /// `<root>/speaker-diarization-coreml/`.
    func modelDirectory() -> URL {
        rootDirectory.appendingPathComponent(Self.repoFolderName, isDirectory: true)
    }

    func isModelReady() -> Bool {
        let directory = modelDirectory()
        return Self.requiredModelBundles.allSatisfy { bundle in
            fileManager.fileExists(atPath: directory.appendingPathComponent(bundle).path)
        }
    }

    func localModelStatus() -> LocalDiarizerModelStatus {
        if isModelReady() {
            return .ready
        }
        if downloadTask != nil {
            return .downloading(downloadProgress)
        }
        if let lastFailure {
            return .failed(lastFailure)
        }
        return .notDownloaded
    }

    func downloadModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if isModelReady() {
            lastFailure = nil
            downloadProgress = 1
            progress?(1)
            return
        }

        let task: Task<Void, Error>
        if let existingTask = downloadTask {
            task = existingTask
            progress?(downloadProgress)
        } else {
            lastFailure = nil
            downloadProgress = 0
            progress?(0)

            let directory = modelDirectory()
            let download = self.download
            task = Task(priority: .utility) { [weak self] in
                try await download(directory) { fraction in
                    let clamped = min(1.0, max(0.0, fraction))
                    progress?(clamped)
                    Task { await self?.recordDownloadProgress(clamped) }
                }
            }
            downloadTask = task
        }

        do {
            try await task.value
            downloadTask = nil
            downloadProgress = 1
            lastFailure = nil
        } catch {
            downloadTask = nil
            downloadProgress = 0
            lastFailure = "Download failed"
            throw error
        }
        progress?(1.0)
    }

    func deleteModel() async throws {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = 0
        lastFailure = nil

        if let cachedManager {
            cachedManager.cleanup()
        }
        cachedManager = nil

        let directory = modelDirectory()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func loadManager() async throws -> DiarizerManager {
        if let cachedManager {
            return cachedManager
        }
        guard isModelReady() else {
            throw LocalDiarizerError.modelNotDownloaded
        }
        let directory = modelDirectory()
        let models = try DiarizerModels.load(
            localSegmentationModel: directory.appendingPathComponent(Self.requiredModelBundles[0]),
            localEmbeddingModel: directory.appendingPathComponent(Self.requiredModelBundles[1])
        )
        let manager = DiarizerManager()
        manager.initialize(models: models)
        cachedManager = manager
        return manager
    }

    /// Release the cached `DiarizerManager` (the Core ML bundles remain on
    /// disk). Mirrors the `deleteModel()` cleanup of the live manager without
    /// touching the on-disk files, so a later `loadManager()` re-initialises.
    func evict() {
        if let cachedManager {
            cachedManager.cleanup()
        }
        cachedManager = nil
    }

    private func recordDownloadProgress(_ progress: Double) {
        downloadProgress = progress
    }

    /// Real downloader: pulls the diarizer Core ML bundles from HuggingFace into
    /// `directory` (`<root>/speaker-diarization-coreml/`). `DiarizerModels.download`
    /// appends the repo `folderName` to `directory.deletingLastPathComponent()`,
    /// so passing the fully-qualified model directory lands the files exactly there.
    private nonisolated static func defaultDownload(
        directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // `DiarizerModels.download` makes a single `loadModels` pass for both
        // Core ML bundles, so FluidAudio's `fractionCompleted` is already one
        // continuous, byte-weighted 0→1 (download 0→0.5, compile 0.5→1.0). The
        // mapper only adds a monotonic guard so a transient dip never walks the
        // bar backwards.
        let segments = MonotonicFractionMapperBox(segmentCount: 1)
        _ = try await DiarizerModels.download(
            to: directory,
            progressHandler: { snapshot in
                progress(segments.map(snapshot.fractionCompleted))
            }
        )
    }
}
