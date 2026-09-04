import XCTest
@testable import Sidekey

/// Pure-route tests for `AgentController.agentVoiceTapRoute(state:)`.
///
/// `handleVoiceTap` dispatches through this static function so the toggle
/// logic is pinned here as a table-driven test rather than through the full
/// controller machinery.  Every `AgentControllerState` case is covered so
/// future additions force a conscious routing decision.
///
/// Route classification rationale:
///   - `.idle`           → startVoiceCapture   (normal first tap)
///   - `.voiceRecording` → stopVoiceCapture    (second tap = toggle stop)
///   - `.textInput`      → noop                (text panel open; tap text-toggles
///                                              via onTextTap path, not onVoiceTap)
///   - `.executing`      → noop                (turn in flight; voice tap during a
///                                              streaming response would collide with
///                                              the active turn — mirror hold-start's
///                                              guard which also no-ops when non-idle)
@MainActor
final class AgentVoiceTapToggleTests: XCTestCase {

    // MARK: - Routing table (exhaustive over AgentControllerState)

    func test_idle_routes_to_startVoiceCapture() {
        XCTAssertEqual(
            AgentController.agentVoiceTapRoute(state: .idle),
            .startVoiceCapture
        )
    }

    func test_voiceRecording_routes_to_stopVoiceCapture() {
        XCTAssertEqual(
            AgentController.agentVoiceTapRoute(state: .voiceRecording),
            .stopVoiceCapture
        )
    }

    func test_textInput_routes_to_noop() {
        // Text panel open: voice tap in tap-gesture mode must not start a
        // parallel voice capture on top of the active text session.
        XCTAssertEqual(
            AgentController.agentVoiceTapRoute(state: .textInput),
            .noop
        )
    }

    func test_executing_routes_to_noop() {
        // A turn is streaming. Starting a new voice capture here would race
        // with the live SSE/streaming session; noop mirrors hold-start's guard.
        XCTAssertEqual(
            AgentController.agentVoiceTapRoute(state: .executing),
            .noop
        )
    }
}
