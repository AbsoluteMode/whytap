import Foundation
import XCTest
@testable import Sidekey

/// Stage 5b activation: the coordinator routes a finalized event into the
/// fully-on-device `MeetingLocalProcessor` ONLY when (a) a local processor is
/// wired, (b) the finalized event carried retained separate tracks, and (c) the
/// local-meeting gate passes (both transcription & LLM = .local). When it does,
/// the BYOK direct processor is bypassed entirely. Any other combination falls
/// through to the BYOK path.
@MainActor
final class MeetingsCoordinatorLocalProcessTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-local-process-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        super.tearDown()
    }

    // MARK: - Seams

    private final class SpyLocalProcessor: MeetingLocalProcessing, @unchecked Sendable {
        private(set) var processCalls = 0
        let idToReturn: UUID
        init(idToReturn: UUID = UUID()) { self.idToReturn = idToReturn }
        func process(
            event: MeetingRecorder.FinalizedEvent,
            startedAt: Date,
            language: String?,
            meetingsStore: MeetingsStore?
        ) async throws -> UUID {
            processCalls += 1
            return idToReturn
        }
    }

    /// Always-active BYOK processor spy: records whether the coordinator fell
    /// through to the direct (BYOK) route.
    private final class SpyDirectProcessor: MeetingDirectProcessing, @unchecked Sendable {
        private(set) var processCalls = 0
        func shouldProcessDirectly() -> Bool { true }
        func process(
            event: MeetingRecorder.FinalizedEvent,
            startedAt: Date,
            language: String?,
            meetingsStore: MeetingsStore?
        ) async throws -> UUID {
            processCalls += 1
            return event.meetingId
        }
    }

    private final class StubDetector: MeetingDetectorProtocol, @unchecked Sendable {
        func subscribe() {}
    }

    private func makeTracks() throws -> MeetingRecorder.SeparateTrackURLs {
        let micURL = tempRoot.appendingPathComponent("mic.wav")
        let systemURL = tempRoot.appendingPathComponent("system.wav")
        try Data([0x01]).write(to: micURL)
        try Data([0x01]).write(to: systemURL)
        return MeetingRecorder.SeparateTrackURLs(micURL: micURL, systemURL: systemURL)
    }

    private func makeEvent(withTracks: Bool) throws -> MeetingRecorder.FinalizedEvent {
        MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [],
            totalDurationSeconds: 3,
            reason: .user,
            separateTrackURLs: withTracks ? try makeTracks() : nil
        )
    }

    // MARK: - Tests

    func test_localProcessorRunsAndBypassesBYOK_whenGatePassesAndTracksPresent() async throws {
        let config = MeetingsConfig(defaults: makeDefaults())
        config.isEnabled = true
        let processor = SpyLocalProcessor()
        let direct = SpyDirectProcessor()

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubDetector(),
            directProcessor: direct,
            localProcessor: processor,
            localMeetingGate: { true }
        )

        await coordinator.dispatchFinalizedForProcessing(
            event: try makeEvent(withTracks: true),
            startedAt: Date()
        )

        XCTAssertEqual(processor.processCalls, 1, "local processor must run")
        XCTAssertEqual(direct.processCalls, 0, "BYOK direct processor must be bypassed")
    }

    func test_localProcessorSkipped_whenGateFails_byokPathUsed() async throws {
        let config = MeetingsConfig(defaults: makeDefaults())
        config.isEnabled = true
        let processor = SpyLocalProcessor()
        let direct = SpyDirectProcessor()

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubDetector(),
            directProcessor: direct,
            localProcessor: processor,
            localMeetingGate: { false }  // not both-.local
        )

        // Event has retained tracks but the gate is closed: must NOT run the
        // local processor; it falls through to the BYOK path.
        await coordinator.dispatchFinalizedForProcessing(
            event: try makeEvent(withTracks: true),
            startedAt: Date()
        )

        XCTAssertEqual(processor.processCalls, 0, "gate closed: local processor must not run")
        XCTAssertEqual(direct.processCalls, 1, "gate closed: BYOK direct processor must handle the meeting")
    }

    func test_localProcessorSkipped_whenNoSeparateTracks() async throws {
        let config = MeetingsConfig(defaults: makeDefaults())
        config.isEnabled = true
        let processor = SpyLocalProcessor()
        let direct = SpyDirectProcessor()

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubDetector(),
            directProcessor: direct,
            localProcessor: processor,
            localMeetingGate: { true }  // gate open, but no tracks retained
        )

        await coordinator.dispatchFinalizedForProcessing(
            event: try makeEvent(withTracks: false),
            startedAt: Date()
        )

        XCTAssertEqual(processor.processCalls, 0, "no retained tracks: local processor must not run")
        XCTAssertEqual(direct.processCalls, 1, "no retained tracks: BYOK direct processor must handle the meeting")
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "coord-local-process-\(UUID().uuidString)")!
    }
}
