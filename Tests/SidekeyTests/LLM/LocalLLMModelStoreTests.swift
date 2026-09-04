import XCTest
@testable import Sidekey

final class LocalLLMModelStoreTests: XCTestCase {
    func testDefaultRootDirectoryIsSidekeyOwned() {
        let path = LocalLLMModelStore.defaultRootDirectory().path

        XCTAssertTrue(path.contains("Application Support"))
        XCTAssertTrue(path.contains("Sidekey/LocalLLMModels"))
    }

    func testModelDirectoryNestsHuggingFaceRepoUnderModels() async throws {
        let root = try makeTempRoot()
        let store = LocalLLMModelStore(rootDirectory: root)

        let directory = await store.modelDirectory()

        // HubApi lays a snapshot out under `<downloadBase>/models/<repo-id>`.
        XCTAssertEqual(directory.lastPathComponent, "Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "mlx-community")
        XCTAssertTrue(directory.pathComponents.contains("models"))
    }

    func testInitialStatusIsNotDownloaded() async throws {
        let root = try makeTempRoot()
        let store = LocalLLMModelStore(rootDirectory: root)

        let status = await store.localModelStatus()

        XCTAssertEqual(status, .notDownloaded)
    }

    func testIsModelReadyRecognizesStagedModelFiles() async throws {
        let root = try makeTempRoot()
        let store = LocalLLMModelStore(rootDirectory: root)
        let modelDir = await store.modelDirectory()
        try Self.stageModel(at: modelDir)

        let ready = await store.isModelReady()
        XCTAssertTrue(ready)

        let status = await store.localModelStatus()
        XCTAssertEqual(status, .ready)
    }

    func testDownloadStatusTransitionsNotDownloadedToDownloadingToReady() async throws {
        let root = try makeTempRoot()
        // Mirror the real HubApi layout: the snapshot lands at
        // `<downloadBase>/models/<repo-id>`, which is what `isModelReady()` checks.
        let snapshotDir = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("mlx-community/Qwen3-4B-Instruct-2507-4bit", isDirectory: true)
        let gate = LocalLLMDownloadGate()
        let store = LocalLLMModelStore(
            rootDirectory: root,
            downloadAndLoad: { _, _, progress in
                progress(0.25)
                await gate.wait()
                try Self.stageModel(at: snapshotDir)
                progress(1.0)
                return nil
            }
        )

        let initial = await store.localModelStatus()
        XCTAssertEqual(initial, .notDownloaded)

        let task = Task {
            try await store.downloadModel(progress: nil)
        }

        try await waitForStatus(.downloading(0.25), in: store)
        await gate.open()
        try await task.value

        let status = await store.localModelStatus()
        XCTAssertEqual(status, .ready)
    }

    func testDownloadFailureSurfacesFailedStatus() async throws {
        let root = try makeTempRoot()
        let store = LocalLLMModelStore(
            rootDirectory: root,
            downloadAndLoad: { _, _, _ in
                throw LocalLLMModelError.modelNotDownloaded
            }
        )

        do {
            try await store.downloadModel(progress: nil)
            XCTFail("expected download to throw")
        } catch {
            // expected
        }

        let status = await store.localModelStatus()
        if case .failed = status {
            // expected
        } else {
            XCTFail("expected .failed status, got \(status)")
        }
    }

    func testDeleteModelClearsCacheAndReturnsNotDownloaded() async throws {
        let root = try makeTempRoot()
        let store = LocalLLMModelStore(rootDirectory: root)
        let modelDir = await store.modelDirectory()
        try Self.stageModel(at: modelDir)

        let readyBefore = await store.isModelReady()
        XCTAssertTrue(readyBefore)

        try await store.deleteModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        let status = await store.localModelStatus()
        XCTAssertEqual(status, .notDownloaded)
    }

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-local-llm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForStatus(
        _ expected: LocalLLMModelStatus,
        in store: LocalLLMModelStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<20 {
            if await store.localModelStatus() == expected {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for \(expected)", file: file, line: line)
    }

    /// Stages the sentinel file the store uses to recognise a complete MLX
    /// snapshot (HF model repos ship a `config.json` at the root).
    private static func stageModel(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3"}"#.utf8).write(
            to: directory.appendingPathComponent("config.json")
        )
    }
}

private actor LocalLLMDownloadGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
