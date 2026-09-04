import Foundation
import FluidAudio

enum LocalTranscriptionModelStatus: Equatable {
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

enum LocalTranscriptionModel: String, CaseIterable, Codable, Sendable {
    case parakeetTdtV3

    var displayName: String {
        switch self {
        case .parakeetTdtV3:
            return "Parakeet TDT v3"
        }
    }

    var detail: String {
        switch self {
        case .parakeetTdtV3:
            return "Multilingual Core ML ASR"
        }
    }

    var directoryName: String {
        switch self {
        case .parakeetTdtV3:
            return "parakeet-tdt-0.6b-v3"
        }
    }

    var version: AsrModelVersion {
        switch self {
        case .parakeetTdtV3:
            return .v3
        }
    }

    var encoderPrecision: ParakeetEncoderPrecision {
        switch self {
        case .parakeetTdtV3:
            return .int8
        }
    }
}

enum LocalTranscriptionModelError: LocalizedError, Equatable {
    case modelNotDownloaded
    case noAudio

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Download the local transcription model first."
        case .noAudio:
            return "No local audio was captured."
        }
    }
}

protocol LocalTranscriptionModelManaging: Sendable {
    func localModelStatus() async -> LocalTranscriptionModelStatus
    func isModelReady() async -> Bool
    func downloadModel(progress: (@Sendable (Double) -> Void)?) async throws
    func deleteModel() async throws
    func loadManager() async throws -> AsrManager
    func modelDirectory() async -> URL
    /// Drop the cached Parakeet `AsrManager` (the Core ML model stays on disk)
    /// so the next `loadManager()` re-warms from scratch. Used by the
    /// meetings-local pipeline to free the ASR model before the diarizer / LLM
    /// load, keeping peak memory bounded on 8 GB machines.
    func evict() async
}

actor LocalTranscriptionModelStore: LocalTranscriptionModelManaging {
    typealias DownloadAndWarm = @Sendable (
        URL,
        LocalTranscriptionModel,
        @escaping @Sendable (Double) -> Void
    ) async throws -> AsrManager?

    static let shared = LocalTranscriptionModelStore()

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let model: LocalTranscriptionModel
    private let downloadAndWarm: DownloadAndWarm
    private var cachedManager: AsrManager?
    private var downloadTask: Task<AsrManager?, Error>?
    private var downloadProgress: Double = 0
    private var lastFailure: String?

    init(
        model: LocalTranscriptionModel = .parakeetTdtV3,
        rootDirectory: URL = LocalTranscriptionModelStore.defaultRootDirectory(),
        fileManager: FileManager = .default,
        downloadAndWarm: @escaping DownloadAndWarm = LocalTranscriptionModelStore.defaultDownloadAndWarm
    ) {
        self.model = model
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.downloadAndWarm = downloadAndWarm
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Sidekey", isDirectory: true)
            .appendingPathComponent("LocalTranscriptionModels", isDirectory: true)
    }

    func modelDirectory() -> URL {
        rootDirectory.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    func isModelReady() -> Bool {
        AsrModels.modelsExist(
            at: modelDirectory(),
            version: model.version,
            encoderPrecision: model.encoderPrecision
        )
    }

    func localModelStatus() -> LocalTranscriptionModelStatus {
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

        let task: Task<AsrManager?, Error>
        if let existingTask = downloadTask {
            task = existingTask
            progress?(downloadProgress)
        } else {
            lastFailure = nil
            downloadProgress = 0
            progress?(0)

            let directory = modelDirectory()
            let model = self.model
            let downloadAndWarm = self.downloadAndWarm
            task = Task(priority: .utility) { [weak self] in
                try await downloadAndWarm(directory, model) { fraction in
                    let clamped = min(1.0, max(0.0, fraction))
                    progress?(clamped)
                    Task { await self?.recordDownloadProgress(clamped) }
                }
            }
            downloadTask = task
        }

        do {
            cachedManager = try await task.value
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
            await cachedManager.cleanup()
        }
        cachedManager = nil

        let directory = modelDirectory()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func loadManager() async throws -> AsrManager {
        if let cachedManager {
            return cachedManager
        }
        guard isModelReady() else {
            throw LocalTranscriptionModelError.modelNotDownloaded
        }
        let manager = try await makeManager()
        cachedManager = manager
        return manager
    }

    private func makeManager() async throws -> AsrManager {
        let models = try await AsrModels.load(
            from: modelDirectory(),
            version: model.version,
            encoderPrecision: model.encoderPrecision
        )
        return AsrManager(config: .default, models: models)
    }

    /// Release the cached `AsrManager` (the Parakeet model remains on disk).
    /// Mirrors the `deleteModel()` cleanup of the live manager without touching
    /// the on-disk files, so a later `loadManager()` re-warms it.
    func evict() async {
        if let cachedManager {
            await cachedManager.cleanup()
        }
        cachedManager = nil
    }

    private func recordDownloadProgress(_ progress: Double) {
        downloadProgress = progress
    }

    private nonisolated static func defaultDownloadAndWarm(
        directory: URL,
        model: LocalTranscriptionModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AsrManager? {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // FluidAudio's `AsrModels.download` runs its 0→1 progress reporter once
        // per Core ML model it fetches, so the raw fraction sawtooths and the bar
        // jumps backwards between models. Each pass IS byte-weighted internally
        // (real bytes), so we stitch the passes into one forward-only curve
        // rather than fake a smooth bar. Parakeet TDT v3 is non-fused → four
        // passes (preprocessor, encoder, decoder, joint); see
        // `AsrModels.download` (FluidAudio 0.14.6).
        let segments = MonotonicFractionMapperBox(segmentCount: 4)
        _ = try await AsrModels.download(
            to: directory,
            version: model.version,
            encoderPrecision: model.encoderPrecision,
            progressHandler: { snapshot in
                progress(segments.map(snapshot.fractionCompleted))
            }
        )

        let models = try await AsrModels.load(
            from: directory,
            version: model.version,
            encoderPrecision: model.encoderPrecision
        )
        return AsrManager(config: .default, models: models)
    }
}
