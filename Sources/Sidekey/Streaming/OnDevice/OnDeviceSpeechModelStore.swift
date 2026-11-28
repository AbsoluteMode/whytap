import FluidAudio
import Foundation
import os.log

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
    /// The Hugging Face repository FluidAudio downloads `version` from.
    var repo: Repo { .parakeetV3 }
}

enum OnDeviceSpeechModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    /// The files are in place and Core ML is loading the model. The first
    /// load after a download compiles it for the Neural Engine, which can
    /// take minutes on an older Mac; later loads take about a second.
    case preparing
    /// Loaded in this launch: a take decodes at once.
    case ready
    case failed
    /// The files are in place but the model did not load.
    case loadFailed
}

enum OnDeviceSpeechError: Error, Equatable {
    case modelNotDownloaded
    case noAudio
    /// The model is still loading after the caller's wait. The load goes on.
    case modelPreparing
    /// The model's files are in place but it did not load.
    case modelLoadFailed
    /// A model that loaded during the take returned no text for audio at
    /// speech level.
    case modelNoText
}

/// Whether the on-device model can run right now. The route resolver, the
/// model picker and the batch path ask this instead of looking for a key: for
/// "On this Mac" the downloaded model is the credential.
struct OnDeviceSpeechReadiness: Sendable {
    let isReady: @Sendable () -> Bool

    /// Apple Silicon with the model's files in place and no download running
    /// (FluidAudio moves files in one by one, so a running download can
    /// already show every folder). The model need not be loaded: a take
    /// waits for its preparation. Never ready inside a test run, so a model
    /// the developer downloaded cannot change what the tests see; tests that
    /// need it pass `.ready`.
    static let live = OnDeviceSpeechReadiness {
        !isTestRun && OnDeviceSpeechModelStore.isSupportedHost
            && !OnDeviceSpeechModelStore.shared.snapshot.isDownloading
            && OnDeviceSpeechModelStore.modelFilesExist()
    }
    private static let isTestRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    static let ready = OnDeviceSpeechReadiness { true }
    static let unavailable = OnDeviceSpeechReadiness { false }
}

/// What the transcription session and the batch path need from the store.
/// Tests inject a fake so no Core ML model is loaded.
protocol OnDeviceSpeechModelManaging: Sendable {
    func status() async -> OnDeviceSpeechModelStatus
    /// Downloads the files. Preparation starts on its own when they are in place.
    func download(progress: (@Sendable (Double) -> Void)?) async throws
    func delete() async throws
    /// The loaded model for one decode. Every `acquire` is paired with a
    /// `release`: the model is never unloaded while a decode holds it, and is
    /// released once nothing has used it for `idleEviction`.
    func acquire() async throws -> AsrManager
    /// `acquire` that waits at most `limit` for a preparation in progress
    /// (`nil`: no limit) and then throws `OnDeviceSpeechError.modelPreparing`;
    /// the preparation itself goes on.
    func acquire(within limit: Duration?) async throws -> AsrManager
    func release() async
    /// Starts the model's preparation, or joins the one in progress, and
    /// returns whether the model is loaded afterwards.
    @discardableResult
    func prepare() async -> Bool
    /// Whether a decode can start without loading the model first.
    func isLoaded() async -> Bool
    /// Time left for the running preparation; nil when none runs.
    func preparationTimeLeft() async -> OnDeviceSpeechTimeLeft?
}

extension OnDeviceSpeechModelManaging {
    func preparationTimeLeft() async -> OnDeviceSpeechTimeLeft? { nil }
    func acquire(within limit: Duration?) async throws -> AsrManager { try await acquire() }
    @discardableResult
    func prepare() async -> Bool { await status() == .ready }
    func isLoaded() async -> Bool { await status() == .ready }
}

/// The store's state for synchronous readers (`OnDeviceSpeechReadiness`).
final class OnDeviceSpeechStoreSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var downloading = false
    private var preparation: (startedAt: TimeInterval, kind: OnDeviceSpeechPreparationKind)?

    /// When the running preparation started (`uptime` clock) and its kind.
    var runningPreparation: (startedAt: TimeInterval, kind: OnDeviceSpeechPreparationKind)? {
        lock.lock(); defer { lock.unlock() }
        return preparation
    }

    func setPreparation(_ value: (startedAt: TimeInterval, kind: OnDeviceSpeechPreparationKind)?) {
        lock.lock(); defer { lock.unlock() }
        preparation = value
    }

    var isDownloading: Bool {
        lock.lock(); defer { lock.unlock() }
        return downloading
    }

    func setDownloading(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        downloading = value
    }
}

/// Downloads, prepares and removes the Parakeet Core ML model. The files live
/// in their own folder under Application Support/Sidekey, apart from the
/// folders `LegacyLocalModelCleanup` removes, and are never part of a backup.
///
/// Preparation (Core ML load and Neural Engine specialisation) is one shared
/// task: it starts after a download, at launch when a feature runs on this
/// Mac, when a take begins and when Settings shows the model. A caller that
/// stops waiting leaves it running, and its result is kept.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
actor OnDeviceSpeechModelStore: OnDeviceSpeechModelManaging {
    typealias DownloadFiles = @Sendable (
        URL, OnDeviceSpeechModel, @escaping @Sendable (Double) -> Void
    ) async throws -> Void
    typealias LoadModel = @Sendable (URL, OnDeviceSpeechModel) async throws -> AsrManager
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let shared = OnDeviceSpeechModelStore()
    static let folderName = "OnDeviceSpeechModels"

    /// Parakeet's Core ML build targets the Neural Engine; Intel is not offered.
    static var isSupportedHost: Bool { HostArchitecture.isAppleSilicon }

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "on-device-speech")

    nonisolated let snapshot = OnDeviceSpeechStoreSnapshot()

    private let model: OnDeviceSpeechModel
    private let rootDirectory: URL
    private let downloadFiles: DownloadFiles
    private let loadModel: LoadModel
    private let sleep: Sleep
    private let filesPresent: (@Sendable () -> Bool)?
    private let uptime: @Sendable () -> TimeInterval
    nonisolated let estimator: OnDeviceSpeechPreparationEstimator
    private let idleEviction: Duration
    private var cachedManager: AsrManager?
    private var downloadTask: Task<Void, Error>?
    private var downloadProgress: Double = 0
    private var failed = false
    private var evictionTask: Task<Void, Never>?
    private var inUse = 0

    private var preparationTask: Task<Void, Never>?
    /// Bumped by `delete()`, so a preparation of removed files keeps nothing.
    private var preparationGeneration = 0
    private var preparationWaiters: [AsyncStream<Bool>.Continuation] = []
    /// A load finished in this launch. Reloading after idle eviction takes
    /// about a second, so the model stays Ready.
    private var preparedOnce = false
    private var lastLoadFailed = false

    init(
        model: OnDeviceSpeechModel = .parakeetTdtV3,
        rootDirectory: URL = OnDeviceSpeechModelStore.defaultRootDirectory(),
        idleEviction: Duration = .seconds(300),
        filesPresent: (@Sendable () -> Bool)? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        machine: OnDeviceSpeechMachine = .current,
        history: any OnDeviceSpeechPreparationHistory = UserDefaultsPreparationHistory(),
        downloadFiles: @escaping DownloadFiles = OnDeviceSpeechModelStore.defaultDownloadFiles,
        loadModel: @escaping LoadModel = OnDeviceSpeechModelStore.defaultLoad
    ) {
        self.model = model
        self.rootDirectory = rootDirectory
        self.idleEviction = idleEviction
        self.filesPresent = filesPresent
        self.sleep = sleep
        self.uptime = uptime
        self.estimator = OnDeviceSpeechPreparationEstimator(machine: machine, history: history)
        self.downloadFiles = downloadFiles
        self.loadModel = loadModel
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
    private var filesExist: Bool { filesPresent?() ?? Self.modelFilesExist(model, root: rootDirectory) }

    func status() -> OnDeviceSpeechModelStatus {
        if downloadTask != nil { return .downloading(downloadProgress) }
        guard filesExist else { return failed ? .failed : .notDownloaded }
        if cachedManager != nil || preparedOnce { return .ready }
        if lastLoadFailed, preparationTask == nil { return .loadFailed }
        return .preparing
    }

    func isLoaded() async -> Bool { cachedManager != nil }

    func preparationTimeLeft() async -> OnDeviceSpeechTimeLeft? { currentPreparationTimeLeft() }

    /// For synchronous readers (the island's message when a take stops
    /// waiting).
    nonisolated func currentPreparationTimeLeft() -> OnDeviceSpeechTimeLeft? {
        guard let running = snapshot.runningPreparation else { return nil }
        return estimator.timeLeft(elapsed: uptime() - running.startedAt, kind: running.kind)
    }

    /// A second call while a download runs joins it.
    func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if downloadTask == nil, filesExist {
            failed = false
            progress?(1)
            startPreparationIfNeeded(reason: "download")
            return
        }
        let task: Task<Void, Error>
        if let running = downloadTask {
            task = running
            progress?(downloadProgress)
        } else {
            failed = false
            downloadProgress = 0
            progress?(0)
            let directory = self.directory
            let model = self.model
            let downloadFiles = self.downloadFiles
            task = Task(priority: .utility) { [weak self] in
                try await downloadFiles(directory, model) { fraction in
                    let clamped = min(1, max(0, fraction))
                    progress?(clamped)
                    Task { await self?.record(progress: clamped) }
                }
            }
            downloadTask = task
            snapshot.setDownloading(true)
            // New files: their first load compiles again.
            estimator.history.setCompiled(false)
        }
        let started = ContinuousClock.now
        do {
            try await task.value
            // Removed while it downloaded: the files are gone, keep nothing.
            guard downloadTask == task else { throw CancellationError() }
            downloadTask = nil
            snapshot.setDownloading(false)
            downloadProgress = 1
            os_log("on-device model: files in place ms=%{public}d",
                   log: Self.log, type: .info, Self.milliseconds(since: started))
        } catch {
            if downloadTask == task {
                downloadTask = nil
                snapshot.setDownloading(false)
                downloadProgress = 0
                failed = !(error is CancellationError)
                os_log("on-device model: download ended cancelled=%{public}@ error=%{public}@",
                       log: Self.log, type: .error,
                       error is CancellationError ? "true" : "false", Self.describe(error))
                // A partial download is not a model: the next attempt starts clean.
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
        progress?(1)
        startPreparationIfNeeded(reason: "download")
    }

    func delete() async throws {
        downloadTask?.cancel()
        downloadTask = nil
        snapshot.setDownloading(false)
        downloadProgress = 0
        failed = false
        evictionTask?.cancel()
        evictionTask = nil
        // A preparation in progress keeps running to its end (Core ML cannot
        // stop it) but its model is discarded; its waiters learn it now.
        preparationGeneration += 1
        preparationTask = nil
        snapshot.setPreparation(nil)
        estimator.history.setCompiled(false)
        finishWaiters(loaded: false)
        preparedOnce = false
        lastLoadFailed = false
        // A decode in flight keeps its own reference and finishes on the
        // loaded model; only an idle one is cleaned up here.
        let manager = cachedManager
        cachedManager = nil
        if inUse == 0 { await manager?.cleanup() }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func acquire() async throws -> AsrManager {
        try await acquire(within: nil)
    }

    func acquire(within limit: Duration?) async throws -> AsrManager {
        inUse += 1
        evictionTask?.cancel()
        do {
            return try await loadedManager(within: limit)
        } catch {
            inUse -= 1
            if inUse == 0 { scheduleEviction() }
            throw error
        }
    }

    func release() {
        inUse = max(0, inUse - 1)
        if inUse == 0 { scheduleEviction() }
    }

    @discardableResult
    func prepare() async -> Bool {
        if cachedManager != nil { return true }
        guard downloadTask == nil, filesExist else { return false }
        startPreparationIfNeeded(reason: "request")
        do {
            try await waitForPreparation(within: nil)
        } catch {
            return false
        }
        if cachedManager != nil, inUse == 0 { scheduleEviction() }
        return cachedManager != nil
    }

    private func loadedManager(within limit: Duration?) async throws -> AsrManager {
        if let cachedManager { return cachedManager }
        guard downloadTask == nil, filesExist else { throw OnDeviceSpeechError.modelNotDownloaded }
        startPreparationIfNeeded(reason: "decode")
        try await waitForPreparation(within: limit)
        if let cachedManager { return cachedManager }
        throw filesExist ? OnDeviceSpeechError.modelLoadFailed : OnDeviceSpeechError.modelNotDownloaded
    }

    private func startPreparationIfNeeded(reason: String) {
        guard preparationTask == nil, cachedManager == nil, downloadTask == nil else { return }
        lastLoadFailed = false
        let generation = preparationGeneration
        let directory = self.directory
        let model = self.model
        let loadModel = self.loadModel
        let started = ContinuousClock.now
        let kind: OnDeviceSpeechPreparationKind = estimator.history.hasCompiled ? .reload : .firstCompile
        snapshot.setPreparation((uptime(), kind))
        os_log("on-device model: preparing reason=%{public}@ first_in_launch=%{public}@ kind=%{public}@ expected_s=%{public}d",
               log: Self.log, type: .info, reason, preparedOnce ? "false" : "true", kind.rawValue,
               Int(estimator.expectedSeconds(kind)))
        preparationTask = Task(priority: .userInitiated) { [weak self] in
            let result: Result<AsrManager, Error>
            do {
                result = .success(try await loadModel(directory, model))
            } catch {
                result = .failure(error)
            }
            await self?.finishPreparation(result, generation: generation, started: started, kind: kind)
        }
    }

    private func finishPreparation(
        _ result: Result<AsrManager, Error>, generation: Int, started: ContinuousClock.Instant,
        kind: OnDeviceSpeechPreparationKind
    ) async {
        let elapsed = Self.milliseconds(since: started)
        guard generation == preparationGeneration else {
            // The files were removed meanwhile.
            if case .success(let manager) = result { await manager.cleanup() }
            return
        }
        preparationTask = nil
        snapshot.setPreparation(nil)
        switch result {
        case .success(let manager):
            cachedManager = manager
            estimator.history.record(kind, seconds: Double(elapsed) / 1000)
            estimator.history.setCompiled(true)
            preparedOnce = true
            lastLoadFailed = false
            os_log("on-device model: ready ms=%{public}d", log: Self.log, type: .info, elapsed)
        case .failure(let error):
            preparedOnce = false
            lastLoadFailed = true
            os_log("on-device model: preparation failed ms=%{public}d files_present=%{public}@ error=%{public}@",
                   log: Self.log, type: .error, elapsed, filesExist ? "true" : "false", Self.describe(error))
        }
        finishWaiters(loaded: cachedManager != nil)
        if inUse == 0 { scheduleEviction() }
    }

    /// Waits for the preparation in progress, if any. Cancelling the caller
    /// or passing `limit` ends the wait at once, never the preparation.
    private func waitForPreparation(within limit: Duration?) async throws {
        guard preparationTask != nil else { return }
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        preparationWaiters.append(continuation)
        let sleep = self.sleep
        let started = ContinuousClock.now
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in stream { return }
                    try Task.checkCancellation()
                }
                if let limit {
                    group.addTask {
                        try await sleep(limit)
                        throw OnDeviceSpeechError.modelPreparing
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch OnDeviceSpeechError.modelPreparing {
            continuation.finish()
            os_log("on-device model: wait ended, still preparing ms=%{public}d",
                   log: Self.log, type: .error, Self.milliseconds(since: started))
            throw OnDeviceSpeechError.modelPreparing
        } catch {
            continuation.finish()
            throw error
        }
    }

    private func finishWaiters(loaded: Bool) {
        let waiters = preparationWaiters
        preparationWaiters = []
        for waiter in waiters {
            waiter.yield(loaded)
            waiter.finish()
        }
    }

    /// Reloading a compiled model takes about a second, so an idle app does
    /// not hold it in memory.
    private func scheduleEviction() {
        evictionTask?.cancel()
        let delay = idleEviction
        let sleep = self.sleep
        evictionTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.evictIfIdle()
        }
    }

    private func evictIfIdle() async {
        guard inUse == 0, let manager = cachedManager else { return }
        cachedManager = nil
        os_log("on-device model: unloaded after idle", log: Self.log, type: .info)
        await manager.cleanup()
    }

    private func record(progress: Double) {
        guard downloadTask != nil else { return }
        downloadProgress = max(downloadProgress, progress)
    }

    /// Error type and code only: a description can carry a local path.
    nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(type(of: error)) \(nsError.domain)#\(nsError.code)"
    }

    nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Files only: the Core ML load is the preparation that follows, so
    /// Settings can say which of the two is running.
    private nonisolated static func defaultDownloadFiles(
        directory: URL, model: OnDeviceSpeechModel, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // FluidAudio reports its file download as 0 to 0.5 of a pass that
        // would go on to compile; the mapper keeps the bar monotonic.
        let segments = MonotonicFractionMapperBox(segmentCount: 1)
        try await DownloadUtils.downloadRepo(
            model.repo, to: parent,
            variant: model.encoderPrecision.rawValue,
            progressHandler: { progress(segments.map(min(1, $0.fractionCompleted * 2))) }
        )
        try Task.checkCancellation()
        guard modelFilesExist(model, root: parent) else {
            throw OnDeviceSpeechError.modelNotDownloaded
        }
    }

    // FluidAudio answers a failed model load by deleting the files and
    // downloading them again (`DownloadUtils.loadModels`). The readiness check
    // keeps a take from loading while files are still arriving.
    private nonisolated static func defaultLoad(directory: URL, model: OnDeviceSpeechModel) async throws -> AsrManager {
        let models = try await AsrModels.load(
            from: directory, version: model.version, encoderPrecision: model.encoderPrecision
        )
        return AsrManager(config: .default, models: models)
    }
}
