import XCTest
@testable import Sidekey

final class LocalDiarizerTests: XCTestCase {

    // MARK: - Model store

    func testDefaultRootDirectoryIsSidekeyOwned() {
        let path = LocalDiarizerModelStore.defaultRootDirectory().path

        XCTAssertTrue(path.contains("Application Support"))
        XCTAssertTrue(path.contains("Sidekey/LocalDiarizationModels"))
    }

    func testModelDirectoryUsesFluidAudioRepoFolderName() async throws {
        let root = try makeTempRoot()
        let store = LocalDiarizerModelStore(rootDirectory: root)

        let directory = await store.modelDirectory()

        // FluidAudio's DownloadUtils caches the diarizer repo under its
        // `folderName` ("speaker-diarization-coreml").
        XCTAssertEqual(directory.lastPathComponent, "speaker-diarization-coreml")
        XCTAssertEqual(directory.deletingLastPathComponent(), root)
    }

    func testInitialStatusIsNotDownloaded() async throws {
        let root = try makeTempRoot()
        let store = LocalDiarizerModelStore(rootDirectory: root)

        let status = await store.localModelStatus()

        XCTAssertEqual(status, .notDownloaded)
    }

    func testIsModelReadyRecognizesStagedModelFiles() async throws {
        let root = try makeTempRoot()
        let store = LocalDiarizerModelStore(rootDirectory: root)
        let modelDir = await store.modelDirectory()
        try Self.stageModels(at: modelDir)

        let ready = await store.isModelReady()
        XCTAssertTrue(ready)

        let status = await store.localModelStatus()
        XCTAssertEqual(status, .ready)
    }

    func testIsModelReadyFalseWhenOnlyOneModelStaged() async throws {
        let root = try makeTempRoot()
        let store = LocalDiarizerModelStore(rootDirectory: root)
        let modelDir = await store.modelDirectory()
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        // Only the segmentation model present — embedding missing.
        try FileManager.default.createDirectory(
            at: modelDir.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            withIntermediateDirectories: true
        )

        let ready = await store.isModelReady()
        XCTAssertFalse(ready)
    }

    func testDownloadStatusTransitionsNotDownloadedToDownloadingToReady() async throws {
        let root = try makeTempRoot()
        // The injected download receives the same model directory the store
        // reports, so staging files there flips `isModelReady()`.
        let modelDir = root.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
        let gate = DiarizerDownloadGate()
        let store = LocalDiarizerModelStore(
            rootDirectory: root,
            download: { _, progress in
                progress(0.25)
                await gate.wait()
                try Self.stageModels(at: modelDir)
                progress(1.0)
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
        let store = LocalDiarizerModelStore(
            rootDirectory: root,
            download: { _, _ in
                throw LocalDiarizerError.modelNotDownloaded
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
        let store = LocalDiarizerModelStore(rootDirectory: root)
        let modelDir = await store.modelDirectory()
        try Self.stageModels(at: modelDir)

        let readyBefore = await store.isModelReady()
        XCTAssertTrue(readyBefore)

        try await store.deleteModel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        let status = await store.localModelStatus()
        XCTAssertEqual(status, .notDownloaded)
    }

    // MARK: - Diarization mapping (segment → SpeakerTurn)

    func testDiarizeMapsSegmentsToTurnsWithDistinctSpeakers() async throws {
        // Two distinct speakers, non-overlapping in time, returned out of order.
        let segments = [
            DiarizedSegment(speakerId: "speaker_2", start: 2.0, end: 3.5),
            DiarizedSegment(speakerId: "speaker_1", start: 0.0, end: 1.5),
        ]
        let diarizer = LocalDiarizer(diarize: { _ in segments })

        let turns = try await diarizer.diarize(samples: [Float](repeating: 0, count: 16_000))

        XCTAssertEqual(turns.count, 2)
        // Sorted by start time.
        XCTAssertEqual(turns.map(\.speaker), ["speaker_1", "speaker_2"])
        XCTAssertEqual(turns.map(\.start), [0.0, 2.0])
        XCTAssertEqual(turns.map(\.end), [1.5, 3.5])

        // ≥2 distinct speaker labels.
        XCTAssertGreaterThanOrEqual(Set(turns.map(\.speaker)).count, 2)
        // Non-overlapping turns.
        XCTAssertTrue(turnsAreNonOverlapping(turns))
    }

    func testDiarizeDropsEmptySpeakerSegments() async throws {
        // FluidAudio emits "" speaker ids for frames it could not assign; those
        // must not become turns.
        let segments = [
            DiarizedSegment(speakerId: "speaker_1", start: 0.0, end: 1.0),
            DiarizedSegment(speakerId: "", start: 1.0, end: 1.2),
            DiarizedSegment(speakerId: "speaker_2", start: 1.5, end: 2.5),
        ]
        let diarizer = LocalDiarizer(diarize: { _ in segments })

        let turns = try await diarizer.diarize(samples: [Float](repeating: 0, count: 16_000))

        XCTAssertEqual(turns.count, 2)
        XCTAssertFalse(turns.contains { $0.speaker.isEmpty })
    }

    func testDiarizeEmptyAudioReturnsNoTurns() async throws {
        let diarizer = LocalDiarizer(diarize: { _ in [] })

        let turns = try await diarizer.diarize(samples: [])

        XCTAssertTrue(turns.isEmpty)
    }

    func testSpeakerTurnHasNoText() {
        // Compile-time guard that SpeakerTurn stays distinct from TranscriptSegment:
        // it carries speaker + timing only, never text.
        let turn = SpeakerTurn(speaker: "speaker_1", start: 0, end: 1)
        XCTAssertEqual(turn.speaker, "speaker_1")
        XCTAssertEqual(turn.start, 0)
        XCTAssertEqual(turn.end, 1)
    }

    // MARK: - Helpers

    private func turnsAreNonOverlapping(_ turns: [SpeakerTurn]) -> Bool {
        let sorted = turns.sorted { $0.start < $1.start }
        for index in 1..<max(sorted.count, 1) where index < sorted.count {
            if sorted[index].start < sorted[index - 1].end {
                return false
            }
        }
        return true
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-local-diarizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForStatus(
        _ expected: LocalDiarizerModelStatus,
        in store: LocalDiarizerModelStore,
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

    /// Stages the sentinel model bundles the store uses to recognise a complete
    /// FluidAudio diarizer cache.
    private static func stageModels(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for bundle in ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(bundle),
                withIntermediateDirectories: true
            )
        }
    }
}

private actor DiarizerDownloadGate {
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
