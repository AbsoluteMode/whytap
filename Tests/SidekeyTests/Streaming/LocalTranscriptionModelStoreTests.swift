import XCTest
@testable import Sidekey

final class LocalTranscriptionModelStoreTests: XCTestCase {
    func testDefaultRootDirectoryIsSidekeyOwned() {
        let path = LocalTranscriptionModelStore.defaultRootDirectory().path

        XCTAssertTrue(path.contains("Application Support"))
        XCTAssertTrue(path.contains("Sidekey/LocalTranscriptionModels"))
    }

    func testModelDirectoryMatchesFluidAudioRepoCacheFolder() async throws {
        let root = try makeTempRoot()
        let store = LocalTranscriptionModelStore(rootDirectory: root)

        let directory = await store.modelDirectory()

        XCTAssertEqual(directory.lastPathComponent, "parakeet-tdt-0.6b-v3")
    }

    func testIsModelReadyRecognizesStagedParakeetV3Files() async throws {
        let root = try makeTempRoot()
        let modelDir = root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        try Self.stageParakeetV3Model(at: modelDir)
        let store = LocalTranscriptionModelStore(rootDirectory: root)

        let ready = await store.isModelReady()
        XCTAssertTrue(ready)
    }

    func testDeleteModelRemovesStagedModelDirectory() async throws {
        let root = try makeTempRoot()
        let modelDir = root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        try Self.stageParakeetV3Model(at: modelDir)
        let store = LocalTranscriptionModelStore(rootDirectory: root)

        try await store.deleteModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        let ready = await store.isModelReady()
        XCTAssertFalse(ready)
    }

    func testDownloadStatusStaysInStoreForLongRunningDownload() async throws {
        let root = try makeTempRoot()
        let gate = LocalModelDownloadGate()
        let store = LocalTranscriptionModelStore(
            rootDirectory: root,
            downloadAndWarm: { directory, _, progress in
                progress(0.25)
                await gate.wait()
                try Self.stageParakeetV3Model(at: directory)
                progress(1.0)
                return nil
            }
        )

        let task = Task {
            try await store.downloadModel(progress: nil)
        }

        try await waitForStatus(.downloading(0.25), in: store)
        await gate.open()
        try await task.value

        let status = await store.localModelStatus()
        XCTAssertEqual(status, .ready)
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-local-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForStatus(
        _ expected: LocalTranscriptionModelStatus,
        in store: LocalTranscriptionModelStore,
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

    private static func stageParakeetV3Model(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
        ] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data(#"{"0":"<blank>"}"#.utf8).write(
            to: directory.appendingPathComponent("parakeet_vocab.json")
        )
    }
}

private actor LocalModelDownloadGate {
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
