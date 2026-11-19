import FluidAudio
import Foundation

/// The speech model the "On this Mac" provider runs. One model for now; the
/// raw value is the model ID stored in a feature's route, so it must not change.
// WHY: .project-docs/decisions/2026-11-19-on-device-dictation.md
enum OnDeviceSpeechModel: String, CaseIterable, Sendable {
    case parakeetTdtV3 = "parakeet-tdt-v3"

    var displayName: String { "Parakeet v3" }

    /// Shown before the download; the Core ML bundle measured on disk.
    var approximateSize: String { "about 470 MB" }

    var directoryName: String { "parakeet-tdt-0.6b-v3" }
    var version: AsrModelVersion { .v3 }
    var encoderPrecision: ParakeetEncoderPrecision { .int8 }
}

enum OnDeviceSpeechModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case ready
    case failed
}

enum OnDeviceSpeechError: Error, Equatable {
    case modelNotDownloaded
    case noAudio
}

/// Whether the on-device model can run right now. The route resolver, the
/// model picker and the batch path ask this instead of looking for a key: for
/// "On this Mac" the downloaded model is the credential.
struct OnDeviceSpeechReadiness: Sendable {
    let isReady: @Sendable () -> Bool

    /// Apple Silicon with the model's files in place. A file check only: the
    /// model is not loaded. Never ready inside a test run, so a model the
    /// developer downloaded cannot change what the tests see; tests that need
    /// it pass `.ready`.
    static let live = OnDeviceSpeechReadiness {
        !isTestRun && OnDeviceSpeechModelStore.isSupportedHost && OnDeviceSpeechModelStore.modelFilesExist()
    }
    private static let isTestRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let ready = OnDeviceSpeechReadiness { true }
    static let unavailable = OnDeviceSpeechReadiness { false }
}

/// What the transcription session and the batch path need from the store.
/// Tests inject a fake so no Core ML model is loaded.
protocol OnDeviceSpeechModelManaging: Sendable {
    func status() async -> OnDeviceSpeechModelStatus
    func download(progress: (@Sendable (Double) -> Void)?) async throws
    func delete() async throws
    func loadManager() async throws -> AsrManager
    /// Called after every decode: the loaded model is released once nothing
    /// has used it for `idleEviction`.
    func noteUse() async
}

/// Downloads, loads and removes the Parakeet Core ML model. The files live in
/// their own folder under Application Support/Sidekey, apart from the folders
/// `LegacyLocalModelCleanup` removes, and are never part of a backup.
actor OnDeviceSpeechModelStore: OnDeviceSpeechModelManaging {
    typealias DownloadAndLoad = @Sendable (
        URL, OnDeviceSpeechModel, @escaping @Sendable (Double) -> Void
    ) async throws -> AsrManager?

    static let shared = OnDeviceSpeechModelStore()
    static let folderName = "OnDeviceSpeechModels"

    /// Parakeet's Core ML build targets the Neural Engine; Intel is not offered.
    static var isSupportedHost: Bool { HostArchitecture.isAppleSilicon }

    private let model: OnDeviceSpeechModel
    private let rootDirectory: URL
    private let downloadAndLoad: DownloadAndLoad
    private let idleEviction: Duration
    private var cachedManager: AsrManager?
    private var downloadTask: Task<AsrManager?, Error>?
    private var downloadProgress: Double = 0
    private var failed = false
    private var evictionTask: Task<Void, Never>?

    init(
        model: OnDeviceSpeechModel = .parakeetTdtV3,
        rootDirectory: URL = OnDeviceSpeechModelStore.defaultRootDirectory(),
        idleEviction: Duration = .seconds(300),
        downloadAndLoad: @escaping DownloadAndLoad = OnDeviceSpeechModelStore.defaultDownloadAndLoad
    ) {
        self.model = model
        self.rootDirectory = rootDirectory
        self.idleEviction = idleEviction
        self.downloadAndLoad = downloadAndLoad
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Sidekey", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    nonisolated static func modelDirectory(
        _ model: OnDeviceSpeechModel = .parakeetTdtV3, root: URL = defaultRootDirectory()
    ) -> URL {
        root.appendingPathComponent(model.directoryName, isDirectory: true)
    }

    nonisolated static func modelFilesExist(
        _ model: OnDeviceSpeechModel = .parakeetTdtV3, root: URL = defaultRootDirectory()
    ) -> Bool {
        AsrModels.modelsExist(
            at: modelDirectory(model, root: root), version: model.version, encoderPrecision: model.encoderPrecision
        )
    }

    private var directory: URL { Self.modelDirectory(model, root: rootDirectory) }
    private var filesExist: Bool { Self.modelFilesExist(model, root: rootDirectory) }

    func status() -> OnDeviceSpeechModelStatus {
        if downloadTask != nil { return .downloading(downloadProgress) }
        if filesExist { return .ready }
        return failed ? .failed : .notDownloaded
    }

    /// A second call while a download runs joins it.
    func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if downloadTask == nil, filesExist {
            failed = false
            progress?(1)
            return
        }
        let task: Task<AsrManager?, Error>
        if let running = downloadTask {
            task = running
            progress?(downloadProgress)
        } else {
            failed = false
            downloadProgress = 0
            progress?(0)
            let directory = self.directory
            let model = self.model
            let downloadAndLoad = self.downloadAndLoad
            task = Task(priority: .utility) { [weak self] in
                try await downloadAndLoad(directory, model) { fraction in
                    let clamped = min(1, max(0, fraction))
                    progress?(clamped)
                    Task { await self?.record(progress: clamped) }
                }
            }
            downloadTask = task
        }
        do {
            let manager = try await task.value
            // Removed while it downloaded: the files are gone, keep nothing.
            guard downloadTask == task else { throw CancellationError() }
            downloadTask = nil
            cachedManager = manager
            downloadProgress = 1
            scheduleEviction()
        } catch {
            if downloadTask == task {
                downloadTask = nil
                downloadProgress = 0
                failed = !(error is CancellationError)
                // A partial download is not a model: the next attempt starts clean.
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
        progress?(1)
    }

    func delete() async throws {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = 0
        failed = false
        evictionTask?.cancel()
        evictionTask = nil
        await cachedManager?.cleanup()
        cachedManager = nil
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func loadManager() async throws -> AsrManager {
        if let cachedManager { return cachedManager }
        guard filesExist else { throw OnDeviceSpeechError.modelNotDownloaded }
        let models = try await AsrModels.load(
            from: directory, version: model.version, encoderPrecision: model.encoderPrecision
        )
        let manager = AsrManager(config: .default, models: models)
        cachedManager = manager
        return manager
    }

    func noteUse() {
        scheduleEviction()
    }

    /// Reloading a compiled model takes about 0.1 s, so an idle app does not
    /// hold it in memory.
    private func scheduleEviction() {
        evictionTask?.cancel()
        let delay = idleEviction
        evictionTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.evict()
        }
    }

    private func evict() async {
        await cachedManager?.cleanup()
        cachedManager = nil
    }

    private func record(progress: Double) {
        downloadProgress = max(downloadProgress, progress)
    }

    private nonisolated static func defaultDownloadAndLoad(
        directory: URL, model: OnDeviceSpeechModel, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AsrManager? {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // FluidAudio reports 0→1 once per Core ML model it fetches (four for
        // Parakeet TDT v3); the mapper stitches the passes into one curve.
        let segments = MonotonicFractionMapperBox(segmentCount: 4)
        _ = try await AsrModels.download(
            to: directory, version: model.version, encoderPrecision: model.encoderPrecision,
            progressHandler: { progress(segments.map($0.fractionCompleted)) }
        )
        try Task.checkCancellation()
        let models = try await AsrModels.load(
            from: directory, version: model.version, encoderPrecision: model.encoderPrecision
        )
        return AsrManager(config: .default, models: models)
    }
}
