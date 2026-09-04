import XCTest
@testable import Sidekey

@MainActor
final class AgentVoiceSessionTests: XCTestCase {
    func testStartAndStopReturnsRecordedAudio() async {
        let recorder = MockAgentAudioRecorder(stopData: Data("WAV".utf8))
        let session = AgentVoiceSession(recorder: recorder, maxDurationSeconds: 1)

        session.start()
        let audio = await session.stop()

        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(recorder.cancelCalls, 0)
        XCTAssertEqual(audio, Data("WAV".utf8))
        XCTAssertGreaterThanOrEqual(session.elapsedSeconds, 0)
    }

    func testTimerAutoStopsAtMaxDurationAndEmitsCallback() async {
        let recorder = MockAgentAudioRecorder(stopData: Data("RIFF".utf8))
        let session = AgentVoiceSession(recorder: recorder, maxDurationSeconds: 0.05)
        var autoStopCalls = 0
        session.onAutoStop = {
            autoStopCalls += 1
        }

        session.start()

        await waitUntil {
            recorder.stopCalls == 1 && autoStopCalls == 1
        }

        let audio = await session.stop()
        XCTAssertEqual(audio, Data("RIFF".utf8))
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(session.elapsedSeconds, 0.05, accuracy: 0.01)
    }

    func testEmptyRecordingReturnsNil() async {
        let recorder = MockAgentAudioRecorder(stopData: Data())
        let session = AgentVoiceSession(recorder: recorder, maxDurationSeconds: 1)

        session.start()
        let audio = await session.stop()

        XCTAssertNil(audio)
        XCTAssertEqual(recorder.stopCalls, 1)
    }

    func testStopExposesRecorderPeakEnergyToCaller() async {
        // The silence guard in `AgentController` reads
        // `voiceSession.peakEnergy` after `stop()` returns. The session
        // must snapshot the recorder's final peak so the controller sees
        // the cumulative value across the full recording, not zero (the
        // initial state) or some intermediate sample.
        let recorder = MockAgentAudioRecorder(stopData: Data("WAV".utf8))
        recorder.peakEnergy = 0.73
        let session = AgentVoiceSession(recorder: recorder, maxDurationSeconds: 1)

        session.start()
        _ = await session.stop()

        XCTAssertEqual(session.peakEnergy, 0.73, accuracy: 0.0001)
    }

    func testPeakEnergyBeforeStopIsZero() async {
        // Mirror of `elapsedSeconds` — peak is only meaningful after the
        // recording has been finalised. Before `stop()` the field reads
        // zero so callers can rely on a single "have I been stopped"
        // check rather than tracking a separate "has the peak been
        // captured" flag.
        let recorder = MockAgentAudioRecorder(stopData: Data("WAV".utf8))
        recorder.peakEnergy = 0.9
        let session = AgentVoiceSession(recorder: recorder, maxDurationSeconds: 1)

        session.start()

        XCTAssertEqual(session.peakEnergy, 0, accuracy: 0.0001)
    }

    func testCancelDropsBlob() async {
        let recorder = MockAgentAudioRecorder(stopData: Data("WAV".utf8))
        let session = AgentVoiceSession(recorder: recorder, maxDurationSeconds: 1)

        session.start()
        session.cancel()
        let audio = await session.stop()

        XCTAssertNil(audio)
        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(recorder.stopCalls, 0)
        XCTAssertEqual(recorder.cancelCalls, 1)
        XCTAssertEqual(session.elapsedSeconds, 0)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not met.", file: file, line: line)
    }
}

private final class MockAgentAudioRecorder: AgentAudioRecording {
    private let stopData: Data
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0
    /// Per the new `AgentAudioRecording` contract — the silence detector
    /// reads this after `stop()` to decide whether to ship the recording
    /// to the backend. Defaults to a value above the noise gate so the
    /// existing voice-session tests stay focused on session mechanics
    /// rather than incidentally exercising the silence guard.
    var peakEnergy: Float = 0.5

    init(stopData: Data) {
        self.stopData = stopData
    }

    func start() throws {
        startCalls += 1
    }

    func stop() throws -> Data {
        stopCalls += 1
        return stopData
    }

    func cancel() {
        cancelCalls += 1
    }
}
