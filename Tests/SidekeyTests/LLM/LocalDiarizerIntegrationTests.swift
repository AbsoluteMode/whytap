import XCTest
import FluidAudio
@testable import Sidekey

/// End-to-end guard against the real on-device FluidAudio diarization path.
/// Opt-in: requires `SIDEKEY_RUN_LOCAL_DIARIZER_IT=1`, so routine `swift test`
/// skips it (the diarizer Core ML models are downloaded on first run and are
/// not for CI). Real speaker clustering needs genuine multi-speaker speech, so
/// the fixture is supplied by the developer via `SIDEKEY_DIARIZER_WAV` rather
/// than committed as a large binary asset.
///
/// Run on Apple Silicon with a real 2-speaker recording (mono or stereo WAV/CAF):
///   SIDEKEY_RUN_LOCAL_DIARIZER_IT=1 \
///   SIDEKEY_DIARIZER_WAV=/path/to/two-speakers.wav \
///   swift test --skip LinearEventNormalizerTests --filter LocalDiarizerIntegrationTests
///
/// First run downloads the models into a temp dir; it then diarizes the sample
/// and asserts ≥2 distinct speaker labels with non-overlapping turns.
final class LocalDiarizerIntegrationTests: XCTestCase {
    func testRealDiarizationProducesDistinctSpeakers() async throws {
        guard ProcessInfo.processInfo.environment["SIDEKEY_RUN_LOCAL_DIARIZER_IT"] == "1" else {
            throw XCTSkip(
                "set SIDEKEY_RUN_LOCAL_DIARIZER_IT=1 (and SIDEKEY_DIARIZER_WAV) to run on-device diarization"
            )
        }
        guard let wavPath = ProcessInfo.processInfo.environment["SIDEKEY_DIARIZER_WAV"] else {
            throw XCTSkip("set SIDEKEY_DIARIZER_WAV to a 2-speaker WAV/CAF file path")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-local-diarizer-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LocalDiarizerModelStore(rootDirectory: root)
        try await store.downloadModel { fraction in
            FileHandle.standardError.write(Data("diarizer download \(Int(fraction * 100))%\n".utf8))
        }
        let ready = await store.isModelReady()
        XCTAssertTrue(ready, "diarizer models should be downloaded and ready")

        // Decode + resample the fixture to 16 kHz mono Float using FluidAudio's
        // own converter, matching the model's expected input.
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: wavPath))

        let diarizer = LocalDiarizer(modelStore: store)
        let turns = try await diarizer.diarize(samples: samples)

        let distinctSpeakers = Set(turns.map(\.speaker))

        // Assert on shape, not a stdout dump: a real 2-speaker recording must
        // yield at least one turn before the speaker-count check below is
        // meaningful.
        XCTAssertFalse(turns.isEmpty, "diarization produced no turns for a real recording")

        XCTAssertGreaterThanOrEqual(
            distinctSpeakers.count, 2,
            "expected ≥2 distinct speakers, got \(distinctSpeakers.sorted())"
        )

        let sorted = turns.sorted { $0.start < $1.start }
        for index in 1..<max(sorted.count, 1) where index < sorted.count {
            XCTAssertGreaterThanOrEqual(
                sorted[index].start, sorted[index - 1].end,
                "turns must not overlap: \(sorted[index - 1]) then \(sorted[index])"
            )
        }
    }
}
