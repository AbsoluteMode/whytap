import Foundation
import XCTest
@testable import Sidekey

/// Stage 5a tests for the OPT-IN separate-track retention on
/// `MeetingRecorder`. When `retainSeparateTracks` is on (the local
/// transcription path), the recorder writes the raw mic-only and
/// system-only tracks to `mic.wav` / `system.wav` IN ADDITION TO the
/// existing mixed chunks; the mixed chunks (the BYOK path) are unchanged.
/// When off (default), no separate files exist and the `FinalizedEvent`
/// exposes no separate-track URLs, proving the BYOK pre-mix path is
/// untouched.
@MainActor
final class MeetingRecorderSeparateTracksTests: XCTestCase {

    private var stagingRoot: URL!

    override func setUp() {
        super.setUp()
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-meeting-separate-tracks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stagingRoot)
        stagingRoot = nil
        super.tearDown()
    }

    // MARK: - Seams (mirror MeetingRecorderTests)

    private final class StubMicSource: MicSourcing, @unchecked Sendable {
        let samples: AsyncStream<[Float]>
        private let continuation: AsyncStream<[Float]>.Continuation
        init() {
            let (s, c) = AsyncStream<[Float]>.makeStream()
            samples = s; continuation = c
        }
        func start() async throws {}
        func stop() async {}
        nonisolated func feed(_ chunk: [Float]) { continuation.yield(chunk) }
        nonisolated func finish() { continuation.finish() }
    }

    private final class StubSystemSource: SystemAudioBufferStreaming, @unchecked Sendable {
        private let stream: AsyncStream<[Float]>
        private let continuation: AsyncStream<[Float]>.Continuation
        init() {
            let (s, c) = AsyncStream<[Float]>.makeStream()
            stream = s; continuation = c
        }
        func audioBufferStream() -> AsyncStream<[Float]> { stream }
        nonisolated func feed(_ chunk: [Float]) { continuation.yield(chunk) }
        nonisolated func finish() { continuation.finish() }
    }

    private final class StubMicInUse: MicInUseProbing, @unchecked Sendable {
        private let stream: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation
        init() {
            let (s, c) = AsyncStream<Bool>.makeStream()
            stream = s; continuation = c
        }
        func subscribe() -> AsyncStream<Bool> { stream }
        func stop() {}
        nonisolated func feed(_ inUse: Bool) { continuation.yield(inUse) }
    }

    // MARK: - Tests

    func test_retainSeparateTracks_writes_mic_and_system_wavs_in_addition_to_mixed() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: StubMicInUse(),
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000,
            retainSeparateTracks: true
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // Distinct mic and system signals so the separate WAVs are
        // verifiably the RAW per-source tracks (not the mix).
        let micChunk: [Float] = [0.5, 0.5, 0.5]
        let sysChunk: [Float] = [-0.25, -0.25, -0.25]
        mic.feed(micChunk)
        sys.feed(sysChunk)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let event = await recorder.stop(reason: .user)

        // The mixed chunk path is still present.
        let dir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let mixed = try chunkURLs(in: dir).filter { $0.lastPathComponent.hasPrefix("chunk-") }
        XCTAssertFalse(mixed.isEmpty, "mixed chunk(s) must still be written (BYOK path)")

        // FinalizedEvent exposes the separate track URLs.
        let tracks = try XCTUnwrap(event.separateTrackURLs, "retainSeparateTracks must surface track URLs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracks.micURL.path), "mic.wav must exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracks.systemURL.path), "system.wav must exist")

        // The mic track WAV is the RAW mic samples (0.5 → ~16383), NOT
        // the mix (which would be (0.5 + -0.25)/2 = 0.125).
        let micPCM = try pcmSamples(from: tracks.micURL)
        XCTAssertEqual(micPCM.count, 3)
        XCTAssertEqual(micPCM[0], Int16((0.5 as Float) * Float(Int16.max)),
                       "mic.wav must hold the raw mic samples, not the mix")

        // The system track WAV is the RAW system samples (-0.25).
        let sysPCM = try pcmSamples(from: tracks.systemURL)
        XCTAssertEqual(sysPCM.count, 3)
        XCTAssertEqual(sysPCM[0], Int16((-0.25 as Float) * Float(Int16.max)),
                       "system.wav must hold the raw system samples, not the mix")

        // And the mixed chunk is still the AVERAGE (proves pre-mix intact).
        let mixedPCM = try pcmSamples(from: mixed[0])
        XCTAssertEqual(mixedPCM[0], Int16((0.125 as Float) * Float(Int16.max)),
                       "mixed chunk must remain the (mic + system)/2 average")
    }

    func test_default_does_not_retain_separate_tracks_premix_path_untouched() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        // No retainSeparateTracks argument: default off (BYOK path).
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: StubMicInUse(),
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        mic.feed([0.5, 0.5])
        sys.feed([0.5, 0.5])
        try? await Task.sleep(nanoseconds: 200_000_000)

        let event = await recorder.stop(reason: .user)

        XCTAssertNil(event.separateTrackURLs,
                     "default path must NOT retain separate tracks")
        let dir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertFalse(entries.contains { $0.lastPathComponent == "mic.wav" },
                       "no mic.wav when retention is off")
        XCTAssertFalse(entries.contains { $0.lastPathComponent == "system.wav" },
                       "no system.wav when retention is off")
    }

    // MARK: - Helpers

    private func chunkURLs(in dir: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return entries
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pcmSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else { return [] }
        let body = data.subdata(in: 44..<data.count)
        return body.withUnsafeBytes { raw -> [Int16] in
            let count = raw.count / 2
            guard let base = raw.baseAddress, count > 0 else { return [] }
            return Array(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Int16.self),
                count: count
            ))
        }
    }
}
