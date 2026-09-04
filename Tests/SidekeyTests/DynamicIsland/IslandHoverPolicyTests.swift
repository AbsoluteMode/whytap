import XCTest
@testable import Sidekey

/// Pure-function tests for `IslandHoverPolicy.allowsExpansion(...)` —
/// the gate that disables hover trigger orbs / lower drop-mode panel
/// when a meeting-related state is occupying the right band.
///
/// Update-available is intentionally NOT part of this gate: the Drop
/// Mode hover panel must remain reachable while the update pill is
/// shown. Trigger-orb suppression for right-band priority states
/// (update pill / transient Drop Mode status) is handled at the row
/// level and covered by `IslandWrapRowPriorityTests`.
///
/// Default-arg coverage matters: existing call sites call
/// `allowsExpansion(meetingSuggestionActive:)` with one positional
/// argument. `meetingRecordingActive` must keep its `false` default so
/// legacy callers stay source-compatible —
/// `test_allowsExpansion_defaultArgs_returnsTrue` pins that contract.
final class IslandHoverPolicyTests: XCTestCase {

    // MARK: - Defaults

    /// Source-compatibility regression: calling with only the
    /// pre-existing `meetingSuggestionActive:` argument must keep
    /// returning `true` when that single signal is `false`. Forces
    /// `meetingRecordingActive` to keep its default.
    func test_allowsExpansion_defaultArgs_returnsTrue() {
        XCTAssertTrue(
            IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: false)
        )
    }

    // MARK: - Each meeting signal independently blocks

    func test_allowsExpansion_blockedWhenMeetingSuggestion() {
        XCTAssertFalse(
            IslandHoverPolicy.allowsExpansion(
                meetingSuggestionActive: true,
                meetingRecordingActive: false
            )
        )
    }

    /// Recording an active meeting must NOT block hover expansion —
    /// the user explicitly wants drop / agent / hover to keep working
    /// during a meeting. The meeting recording slot defends its visible
    /// area via `.contentShape(Capsule())` on the slot view; the policy
    /// only suppresses hover for the short suggestion window (pre-accept)
    /// because the suggestion pill needs the right band clear of
    /// trigger orbs.
    func test_allowsExpansion_notBlockedWhenMeetingRecording() {
        XCTAssertTrue(
            IslandHoverPolicy.allowsExpansion(
                meetingSuggestionActive: false,
                meetingRecordingActive: true
            )
        )
    }

    // MARK: - All clear

    func test_allowsExpansion_allInactive_returnsTrue() {
        XCTAssertTrue(
            IslandHoverPolicy.allowsExpansion(
                meetingSuggestionActive: false,
                meetingRecordingActive: false
            )
        )
    }

    // MARK: - Agent flow blocks expansion

    /// While any agent surface (wing / answer panel) is on screen the
    /// island owns its enlarged window; the hover Drop Mode panel must NOT
    /// expand underneath it (the lower drawer would collide with the agent
    /// answer column). Mirrors the meeting-suggestion gate.
    func test_allowsExpansion_falseWhileAgentFlowActive() {
        XCTAssertFalse(IslandHoverPolicy.allowsExpansion(
            meetingSuggestionActive: false,
            meetingRecordingActive: false,
            agentFlowActive: true
        ))
        XCTAssertTrue(IslandHoverPolicy.allowsExpansion(
            meetingSuggestionActive: false,
            meetingRecordingActive: false,
            agentFlowActive: false
        ))
    }
}
