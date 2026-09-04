import Foundation
import Hub
import MLXLLM
import MLXLMCommon

enum LocalLLMModelStatus: Equatable {
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

enum LocalLLMModel: String, CaseIterable, Codable, Sendable {
    case qwen3_4BInstruct2507_4bit

    /// HuggingFace repo id the MLX runtime downloads the weights from.
    var repoID: String {
        switch self {
        case .qwen3_4BInstruct2507_4bit:
            return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .qwen3_4BInstruct2507_4bit:
            return "Qwen3 4B Instruct"
        }
    }

    var detail: String {
        switch self {
        case .qwen3_4BInstruct2507_4bit:
            return "On-device MLX 4-bit LLM"
        }
    }
}

enum LocalLLMModelError: LocalizedError, Equatable {
    case modelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "Download the local language model first."
        }
    }
}

protocol LocalLLMModelManaging: Sendable {
    func localModelStatus() async -> LocalLLMModelStatus
    func isModelReady() async -> Bool
    func downloadModel(progress: (@Sendable (Double) -> Void)?) async throws
    func deleteModel() async throws
    func loadContainer() async throws -> ModelContainer
    func modelDirectory() async -> URL
    /// Drop the cached in-memory model (the weights stay on disk) so the
    /// next `loadContainer()` re-loads from scratch. Used by the meetings-local
    /// pipeline to serialise the three on-device models (STT → diarizer → LLM)
    /// and keep peak memory bounded on 8 GB machines.
    func evict() async
}

/// On-device LLM weight cache. Mirrors `LocalTranscriptionModelStore`: downloads
/// the MLX model snapshot into an app-owned directory under Application Support,
/// tracks status/progress, exposes a lazily-cached `ModelContainer`, and clears
/// the cache on delete. The model never leaves the device and no prompt/response
/// text is logged here (invariant #3).
actor LocalLLMModelStore: LocalLLMModelManaging {
    typealias DownloadAndLoad = @Sendable (
        URL,
        LocalLLMModel,
        @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer?

    static let shared = LocalLLMModelStore()

    private let fileManager: FileManager
    private let rootDirectory: URL
    private let model: LocalLLMModel
    private let downloadAndLoad: DownloadAndLoad
    private var cachedContainer: ModelContainer?
    private var downloadTask: Task<ModelContainer?, Error>?
    private var downloadProgress: Double = 0
    private var lastFailure: String?

    init(
        model: LocalLLMModel = .qwen3_4BInstruct2507_4bit,
        rootDirectory: URL = LocalLLMModelStore.defaultRootDirectory(),
        fileManager: FileManager = .default,
        downloadAndLoad: @escaping DownloadAndLoad = LocalLLMModelStore.defaultDownloadAndLoad
    ) {
        self.model = model
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.downloadAndLoad = downloadAndLoad
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Sidekey", isDirectory: true)
            .appendingPathComponent("LocalLLMModels", isDirectory: true)
    }

    /// Where `HubApi(downloadBase:)` places the snapshot: `<root>/models/<repo-id>`.
    func modelDirectory() -> URL {
        rootDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.repoID, isDirectory: true)
    }

    func isModelReady() -> Bool {
        // A complete MLX/HF snapshot always ships `config.json` at its root; its
        // presence is the cheap, dependency-free readiness sentinel.
        fileManager.fileExists(
            atPath: modelDirectory().appendingPathComponent("config.json").path
        )
    }

    func localModelStatus() -> LocalLLMModelStatus {
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

        let task: Task<ModelContainer?, Error>
        if let existingTask = downloadTask {
            task = existingTask
            progress?(downloadProgress)
        } else {
            lastFailure = nil
            downloadProgress = 0
            progress?(0)

            let directory = rootDirectory
            let model = self.model
            let downloadAndLoad = self.downloadAndLoad
            task = Task(priority: .utility) { [weak self] in
                try await downloadAndLoad(directory, model) { fraction in
                    let clamped = min(1.0, max(0.0, fraction))
                    progress?(clamped)
                    Task { await self?.recordDownloadProgress(clamped) }
                }
            }
            downloadTask = task
        }

        do {
            cachedContainer = try await task.value
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
        cachedContainer = nil

        let directory = modelDirectory()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func loadContainer() async throws -> ModelContainer {
        if let cachedContainer {
            return cachedContainer
        }
        guard isModelReady() else {
            throw LocalLLMModelError.modelNotDownloaded
        }
        let container = try await downloadAndLoad(rootDirectory, model) { _ in }
        guard let container else {
            throw LocalLLMModelError.modelNotDownloaded
        }
        cachedContainer = container
        return container
    }

    /// Release the cached `ModelContainer` (weights remain on disk). The MLX
    /// runtime reclaims the GPU/wired memory once the last reference drops, so
    /// dropping our reference here is sufficient; a later `loadContainer()`
    /// re-loads from the on-disk snapshot.
    func evict() {
        cachedContainer = nil
    }

    private func recordDownloadProgress(_ progress: Double) {
        downloadProgress = progress
    }

    private nonisolated static func defaultDownloadAndLoad(
        root: URL,
        model: LocalLLMModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer? {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        // `downloadBase` anchors the snapshot under our app-owned root as
        // `<root>/models/<repo-id>`, so the weights never land in the shared
        // user caches directory.
        let hub = HubApi(downloadBase: root)
        let configuration = ModelConfiguration(id: model.repoID)

        // The snapshot lands directly under `<root>/models/<repo-id>` (HubApi's
        // `localRepoLocation`). MLX downloads exactly `*.safetensors`, `*.json`
        // and `*.jinja` (see MLXLMCommon `downloadModel`), so the real total is
        // the byte sum of those files in the repo tree.
        let snapshotDirectory = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.repoID, isDirectory: true)
        let repoID = model.repoID
        let sampler = ModelDownloadProgressSampler(
            totalBytesProvider: {
                await HuggingFaceRepoSize().totalBytes(repoID: repoID) { path in
                    path.hasSuffix(".safetensors") || path.hasSuffix(".json") || path.hasSuffix(".jinja")
                }
            },
            diskBytesProvider: { ModelDownloadProgressSampler.directoryByteSize(at: snapshotDirectory) }
        )

        // Real byte progress comes from the sampler; the library's coarse
        // file-count fraction is forwarded only when the byte total is unknown.
        let byteProgressActive = SuppressionFlag()
        return try await sampler.run(
            emit: { fraction in
                byteProgressActive.set()
                progress(fraction)
            },
            operation: {
                try await LLMModelFactory.shared.loadContainer(
                    hub: hub,
                    configuration: configuration
                ) { fraction in
                    guard !byteProgressActive.isSet else { return }
                    progress(fraction.fractionCompleted)
                }
            }
        )
    }
}
