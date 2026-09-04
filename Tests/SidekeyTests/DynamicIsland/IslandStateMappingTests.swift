import XCTest
@testable import Sidekey

/// Pure-function tests for `IslandState.from(phase:agentPhase:)`. This is
/// the mapping that drives the Dynamic Island orb off the real
/// `AppState.phase` + `AppState.agentPhase` signals (replacing the demo
/// cycler from the PoC). Tests are exhaustive across every combination
/// of `AppPhase` / `AgentPhase` so regressions in the mapping surface
/// immediately instead of as "orb stuck on idle" bug reports.
final class IslandStateMappingTests: XCTestCase {

    // MARK: - Idle baseline

    func test_idle_both_idle_returnsIdle() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .idle),
            .idle
        )
    }

    // MARK: - Drop flow (Option+/)

    func test_phase_recording_returnsListening() {
        XCTAssertEqual(
            IslandState.from(phase: .recording, agentPhase: .idle),
            .listening
        )
    }

    func test_phase_transcribing_returnsThinking() {
        XCTAssertEqual(
            IslandState.from(phase: .transcribing, agentPhase: .idle),
            .thinking
        )
    }

    func test_phase_verifying_returnsThinking() {
        XCTAssertEqual(
            IslandState.from(phase: .verifying, agentPhase: .idle),
            .thinking
        )
    }

    func test_phase_inserting_returnsThinking() {
        XCTAssertEqual(
            IslandState.from(phase: .inserting, agentPhase: .idle),
            .thinking
        )
    }

    // MARK: - Agent flow (RightCmd)

    func test_agentPhase_voiceRecording_returnsListening() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .voiceRecording),
            .listening
        )
    }

    func test_agentPhase_transcribing_returnsThinking() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .transcribing),
            .thinking
        )
    }

    func test_agentPhase_executing_returnsThinking() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .executing),
            .thinking
        )
    }

    func test_agentPhase_textInputActive_returnsTextInput() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .textInputActive),
            .textInput
        )
    }

    // MARK: - Edge case: both flows active simultaneously
    //
    // Should never happen in practice (the drop hotkey is suppressed
    // while agent is live, and vice versa). Defensive check: drop flow
    // wins — it owns the primary user-facing surface, so if the
    // bookkeeping is ever wrong the user still sees the listening UI
    // for the input they're actually generating.

    func test_both_active_prefers_drop_listening() {
        XCTAssertEqual(
            IslandState.from(phase: .recording, agentPhase: .voiceRecording),
            .listening
        )
    }

    func test_both_active_drop_thinking_wins_over_agent_textInput() {
        XCTAssertEqual(
            IslandState.from(phase: .transcribing, agentPhase: .textInputActive),
            .thinking
        )
    }

    func test_drop_recording_wins_over_agent_executing() {
        XCTAssertEqual(
            IslandState.from(phase: .recording, agentPhase: .executing),
            .listening
        )
    }

    // MARK: - VoiceOrbMode derivation
    //
    // The orb mode is a function of (IslandState, originating flow). The
    // drop flow uses `.dropVoice` / `.dropProcessing`; the agent flow
    // uses `.agentVoice` / `.agentProcessing`. `.textInput` is
    // agent-only.

    func test_orbMode_idle_isIdle() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .idle).orbMode(
                phase: .idle, agentPhase: .idle
            ),
            .idle
        )
    }

    func test_orbMode_dropRecording_isDropVoice() {
        XCTAssertEqual(
            IslandState.from(phase: .recording, agentPhase: .idle).orbMode(
                phase: .recording, agentPhase: .idle
            ),
            .dropVoice
        )
    }

    func test_orbMode_agentVoiceRecording_isAgentVoice() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .voiceRecording).orbMode(
                phase: .idle, agentPhase: .voiceRecording
            ),
            .agentVoice
        )
    }

    func test_orbMode_dropTranscribing_isDropProcessing() {
        XCTAssertEqual(
            IslandState.from(phase: .transcribing, agentPhase: .idle).orbMode(
                phase: .transcribing, agentPhase: .idle
            ),
            .dropProcessing
        )
    }

    func test_orbMode_agentExecuting_isAgentProcessing() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .executing).orbMode(
                phase: .idle, agentPhase: .executing
            ),
            .agentProcessing
        )
    }

    func test_orbMode_textInput_isAgentTextInputActive() {
        XCTAssertEqual(
            IslandState.from(phase: .idle, agentPhase: .textInputActive).orbMode(
                phase: .idle, agentPhase: .textInputActive
            ),
            .agentTextInputActive
        )
    }
}
