import XCTest
@testable import Sidekey

/// Regression guard: the Google gesture (`activeSourceIsGoogle = true`) must
/// resolve agent phases to Google orb modes, while the existing agent/drop
/// mapping must remain untouched when the flag is false.
final class IslandGoogleOrbModeTests: XCTestCase {

    // MARK: - Google branch (activeSourceIsGoogle = true)

    func testVoiceRecordingResolvesToGoogleVoiceWhenGoogleActive() {
        let state = IslandState.listening
        let mode = state.orbMode(
            phase: .idle,
            agentPhase: .voiceRecording,
            activeSourceIsGoogle: true
        )
        XCTAssertEqual(mode, .googleVoice,
            "Google flow voice recording must resolve to .googleVoice, not \(mode)")
    }

    func testTextInputActiveResolvesToGoogleTextInputWhenGoogleActive() {
        let state = IslandState.textInput
        let mode = state.orbMode(
            phase: .idle,
            agentPhase: .textInputActive,
            activeSourceIsGoogle: true
        )
        XCTAssertEqual(mode, .googleTextInputActive,
            "Google flow text input must resolve to .googleTextInputActive, not \(mode)")
    }

    // MARK: - Agent branch unchanged (activeSourceIsGoogle = false)

    func testVoiceRecordingResolvesToAgentVoiceWhenGoogleInactive() {
        let state = IslandState.listening
        let mode = state.orbMode(
            phase: .idle,
            agentPhase: .voiceRecording,
            activeSourceIsGoogle: false
        )
        XCTAssertEqual(mode, .agentVoice,
            "Standard agent voice recording must still resolve to .agentVoice when google flag is false")
    }

    func testTextInputActiveResolvesToAgentTextInputWhenGoogleInactive() {
        let state = IslandState.textInput
        let mode = state.orbMode(
            phase: .idle,
            agentPhase: .textInputActive,
            activeSourceIsGoogle: false
        )
        XCTAssertEqual(mode, .agentTextInputActive,
            "Standard agent text input must still resolve to .agentTextInputActive when google flag is false")
    }

    // MARK: - Drop flow unaffected regardless of google flag

    func testDropVoiceUnaffectedByGoogleFlag() {
        let state = IslandState.listening
        let modeWithFlag = state.orbMode(
            phase: .recording,
            agentPhase: .idle,
            activeSourceIsGoogle: true
        )
        let modeWithoutFlag = state.orbMode(
            phase: .recording,
            agentPhase: .idle,
            activeSourceIsGoogle: false
        )
        XCTAssertEqual(modeWithFlag, .dropVoice,
            "Drop voice must resolve to .dropVoice even when google flag is true (drop wins on contention)")
        XCTAssertEqual(modeWithoutFlag, .dropVoice,
            "Drop voice must resolve to .dropVoice when google flag is false")
    }

    func testDropProcessingUnaffectedByGoogleFlag() {
        let state = IslandState.thinking
        let modeWithFlag = state.orbMode(
            phase: .transcribing,
            agentPhase: .idle,
            activeSourceIsGoogle: true
        )
        XCTAssertEqual(modeWithFlag, .dropProcessing,
            "Drop processing must resolve to .dropProcessing even when google flag is true")
    }

    // MARK: - Idle and default are stable

    func testIdleResolvesToIdleRegardlessOfGoogleFlag() {
        let state = IslandState.idle
        let modeTrue = state.orbMode(
            phase: .idle,
            agentPhase: .idle,
            activeSourceIsGoogle: true
        )
        let modeFalse = state.orbMode(
            phase: .idle,
            agentPhase: .idle,
            activeSourceIsGoogle: false
        )
        XCTAssertEqual(modeTrue, .idle)
        XCTAssertEqual(modeFalse, .idle)
    }
}
