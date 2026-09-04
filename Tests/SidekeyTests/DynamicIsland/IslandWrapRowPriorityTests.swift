import XCTest
@testable import Sidekey

/// Pure-function tests for `IslandRightBandPriority` — the helper
/// extracted from `IslandWrapRow` so its right-band priority logic
/// (P0 meeting layers > P1 update pill > P2 trigger orbs) is unit
/// testable without instantiating SwiftUI views.
///
/// `IslandWrapRow.hasPriorityRightState` / `showsUpdateAvailable`
/// delegate to these static functions; the view layer becomes a thin
/// pass-through.
final class IslandWrapRowPriorityTests: XCTestCase {

    // MARK: - hasPriorityRightState

    /// Truth table — `hasPriorityRightState` is `true` iff at least
    /// one of the three booleans is `true`. Exhaustive 2^3 = 8 cases
    /// so any future signal added without updating the OR chain
    /// surfaces immediately.
    func test_hasPriorityRightState_includesUpdateAvailable() {
        let cases: [(Bool, Bool, Bool, Bool, Bool)] = [
            // (countdown, recording, updateAvailable, dropModeStatus, expected)
            (false, false, false, false, false),
            (true,  false, false, false, true),
            (false, true,  false, false, true),
            (false, false, true,  false, true),
            (false, false, false, true,  true),
            (true,  true,  false, false, true),
            (true,  false, true,  false, true),
            (false, true,  true,  false, true),
            (false, true,  false, true,  true),
            (true,  true,  true,  true,  true),
        ]
        for (countdown, recording, updateAvailable, dropModeStatus, expected) in cases {
            XCTAssertEqual(
                IslandRightBandPriority.hasPriorityRightState(
                    showsMeetingCountdown: countdown,
                    showsMeetingRecording: recording,
                    showsUpdateAvailable: updateAvailable,
                    showsDropModeStatus: dropModeStatus
                ),
                expected,
                "countdown=\(countdown) recording=\(recording) update=\(updateAvailable) dropMode=\(dropModeStatus)"
            )
        }
    }

    /// Music joins the OR chain: the passive hints must yield to an active
    /// music wing exactly as they yield to every other priority slot.
    /// `showsMusic` defaults to `false`, so the existing call sites above
    /// (which omit it) keep their meaning; this case proves music alone is
    /// enough to make the hints fade.
    func test_hasPriorityRightState_includesMusic() {
        XCTAssertTrue(
            IslandRightBandPriority.hasPriorityRightState(
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                showsMusic: true
            ),
            "An active music wing is a priority right-band state — passive hints must yield to it."
        )
        XCTAssertFalse(
            IslandRightBandPriority.hasPriorityRightState(
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                showsMusic: false
            ),
            "No slot and no music → hints stay visible."
        )
    }

    // MARK: - showsMusic

    /// Music renders only when a track is active and NO higher-priority
    /// slot (agent / meeting countdown / meeting recording / update /
    /// drop-mode status) occupies the right band. It sits just above the
    /// passive hints.
    func test_showsMusic_trueOnlyAboveHints_whenNoHigherSlot() {
        XCTAssertTrue(
            IslandRightBandPriority.showsMusic(
                musicActive: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                agentFlowActive: false
            )
        )
        // No track → no wing even with every slot clear.
        XCTAssertFalse(
            IslandRightBandPriority.showsMusic(
                musicActive: false,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                agentFlowActive: false
            )
        )
    }

    func test_showsMusic_yieldsToAgentFlow() {
        XCTAssertFalse(
            IslandRightBandPriority.showsMusic(
                musicActive: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                agentFlowActive: true
            )
        )
    }

    func test_showsMusic_yieldsToMeetingCountdown() {
        XCTAssertFalse(
            IslandRightBandPriority.showsMusic(
                musicActive: true,
                showsMeetingCountdown: true,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                agentFlowActive: false
            )
        )
    }

    func test_showsMusic_yieldsToMeetingRecording() {
        XCTAssertFalse(
            IslandRightBandPriority.showsMusic(
                musicActive: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: true,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                agentFlowActive: false
            )
        )
    }

    func test_showsMusic_yieldsToUpdateAvailable() {
        XCTAssertFalse(
            IslandRightBandPriority.showsMusic(
                musicActive: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: true,
                showsDropModeStatus: false,
                agentFlowActive: false
            )
        )
    }

    func test_showsMusic_yieldsToDropModeStatus() {
        XCTAssertFalse(
            IslandRightBandPriority.showsMusic(
                musicActive: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: true,
                agentFlowActive: false
            )
        )
    }

    /// The inverse of the priority relation: the drop-mode status slot
    /// must NOT yield to music — music sits strictly below it. So an active
    /// track never suppresses the drop-mode status (its visibility is
    /// independent of `musicActive`, as `showsDropModeStatus` has no music
    /// parameter at all).
    func test_dropModeStatus_doesNotYieldToMusic() {
        // Drop-mode status stays visible regardless of an active track.
        XCTAssertTrue(
            IslandRightBandPriority.showsDropModeStatus(
                dropModeStatusNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false
            )
        )
        // And in that exact situation, music is the one that yields.
        XCTAssertFalse(
            IslandRightBandPriority.showsMusic(
                musicActive: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: true,
                agentFlowActive: false
            )
        )
    }

    // MARK: - Now Playing progress math

    /// The player's linear progress fraction is sourced from
    /// `NowPlayingSnapshot.progressFraction` (Stage 1). Confirm the
    /// contract the body relies on: clamped to `0...1`, `0` when duration
    /// is unknown.
    func test_progressFraction_clampsAndGuardsZeroDuration() {
        XCTAssertEqual(makeSnapshot(elapsed: 30, duration: 120).progressFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(makeSnapshot(elapsed: 0, duration: 120).progressFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(makeSnapshot(elapsed: 120, duration: 120).progressFraction, 1, accuracy: 0.0001)
        // Elapsed beyond duration clamps to 1, never overshoots the bar.
        XCTAssertEqual(makeSnapshot(elapsed: 200, duration: 120).progressFraction, 1, accuracy: 0.0001)
        // Unknown duration → 0, avoids divide-by-zero in the Capsule width.
        XCTAssertEqual(makeSnapshot(elapsed: 30, duration: 0).progressFraction, 0, accuracy: 0.0001)
    }

    /// Regular track (duration > 0): the fraction must ADVANCE as `elapsed`
    /// grows across successive snapshots — this is what makes the wing's
    /// progress bar fill/advance as the controller re-polls (~1 s). Radio /
    /// live (duration 0) stays empty regardless of elapsed.
    func test_progressFraction_advancesOnRegularTrack_emptyOnRadio() {
        let early = makeSnapshot(elapsed: 10, duration: 200).progressFraction
        let later = makeSnapshot(elapsed: 90, duration: 200).progressFraction
        XCTAssertGreaterThan(
            later, early,
            "On a regular track the progress fraction must grow as elapsed advances."
        )
        XCTAssertEqual(early, 0.05, accuracy: 0.0001)
        XCTAssertEqual(later, 0.45, accuracy: 0.0001)

        // Radio / live: no duration → the bar stays empty even as elapsed runs.
        XCTAssertEqual(makeSnapshot(elapsed: 10, duration: 0).progressFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(makeSnapshot(elapsed: 90, duration: 0).progressFraction, 0, accuracy: 0.0001)
    }

    private func makeSnapshot(elapsed: TimeInterval, duration: TimeInterval) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            app: .music,
            title: "Track",
            artist: "Artist",
            album: "Album",
            artwork: nil,
            elapsed: elapsed,
            duration: duration,
            isPlaying: true,
            capturedAt: Date()
        )
    }

    // MARK: - showsDropModeStatus

    func test_showsDropModeStatus_trueWhenNoHigherPriorityState() {
        XCTAssertTrue(
            IslandRightBandPriority.showsDropModeStatus(
                dropModeStatusNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false
            )
        )
    }

    func test_showsDropModeStatus_falseWhenMeetingOrUpdateTakesPriority() {
        XCTAssertFalse(
            IslandRightBandPriority.showsDropModeStatus(
                dropModeStatusNonNil: true,
                showsMeetingCountdown: true,
                showsMeetingRecording: false,
                showsUpdateAvailable: false
            )
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsDropModeStatus(
                dropModeStatusNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: true,
                showsUpdateAvailable: false
            )
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsDropModeStatus(
                dropModeStatusNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: true
            )
        )
    }

    // MARK: - showsHoverTriggerOrbs

    func test_showsHoverTriggerOrbs_trueOnlyDuringHoverWithoutPriorityRightState() {
        XCTAssertTrue(
            IslandRightBandPriority.showsHoverTriggerOrbs(
                hoverExpanded: true,
                showsUpdateAvailable: false,
                showsDropModeStatus: false
            )
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsHoverTriggerOrbs(
                hoverExpanded: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false
            )
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsHoverTriggerOrbs(
                hoverExpanded: true,
                showsUpdateAvailable: true,
                showsDropModeStatus: false
            )
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsHoverTriggerOrbs(
                hoverExpanded: true,
                showsUpdateAvailable: false,
                showsDropModeStatus: true
            )
        )
    }

    /// During an active meeting recording the right band is owned by the
    /// meeting slot. Hover expansion is still allowed (user can reach
    /// the lower drop-mode panel) but the trigger orbs themselves must
    /// stay hidden so they do not visually collide with the recording
    /// slot in the right band.
    func test_showsHoverTriggerOrbs_falseDuringMeetingRecording() {
        XCTAssertFalse(
            IslandRightBandPriority.showsHoverTriggerOrbs(
                hoverExpanded: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: true,
                showsUpdateAvailable: false,
                showsDropModeStatus: false
            )
        )
    }

    /// The pre-accept meeting suggestion countdown owns the right band
    /// too — orbs yield exactly like they do during recording.
    func test_showsHoverTriggerOrbs_falseDuringMeetingSuggestion() {
        XCTAssertFalse(
            IslandRightBandPriority.showsHoverTriggerOrbs(
                hoverExpanded: true,
                showsMeetingCountdown: true,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false
            )
        )
    }

    // MARK: - showsUpdateActions

    func test_showsUpdateActions_visibleOnHover_forReadyToInstall_orAvailableToDownload() {
        // MARK: readyToInstall branch
        XCTAssertTrue(
            IslandRightBandPriority.showsUpdateActions(
                hoverExpanded: true,
                showsUpdateAvailable: true,
                isReadyToInstall: true
            ),
            "Restart/Later icons should appear on island hover once the update is downloaded."
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateActions(
                hoverExpanded: false,
                showsUpdateAvailable: true,
                isReadyToInstall: true
            ),
            "Compact ready state must not expose actions until the user hovers the island."
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateActions(
                hoverExpanded: true,
                showsUpdateAvailable: false,
                isReadyToInstall: true
            ),
            "No pending update means no actions, even while hover is open."
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateActions(
                hoverExpanded: true,
                showsUpdateAvailable: true,
                isReadyToInstall: false
            ),
            "Downloading stage (neither flag set) must never expose actions — there is nothing to act on yet."
        )

        // MARK: isAvailableToDownload branch
        XCTAssertTrue(
            IslandRightBandPriority.showsUpdateActions(
                hoverExpanded: true,
                showsUpdateAvailable: true,
                isReadyToInstall: false,
                isAvailableToDownload: true
            ),
            "The download ↓ button must be reachable when the pill is in .available stage and hover is open."
        )
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateActions(
                hoverExpanded: false,
                showsUpdateAvailable: true,
                isReadyToInstall: false,
                isAvailableToDownload: true
            ),
            "Compact .available state must not expose the download action until the user hovers the island."
        )
    }

    // MARK: - Agent flow is top priority

    /// The agent surfaces (wing capsule + answer column) own the right band
    /// and the rightward window extension entirely. While active they
    /// suppress the meeting recording slot, the update pill, and the
    /// transient Drop Mode status — and `hasPriorityRightState` is `true`
    /// so the passive rolling hints are hidden. The meeting RECORDING
    /// itself keeps running; only its right-band slot is hidden.
    func test_agentActive_suppressesMeetingRecordingUpdateAndHints() {
        // Meeting recording slot suppressed.
        XCTAssertFalse(
            IslandRightBandPriority.showsMeetingRecording(
                meetingRecordingNonNil: true,
                agentFlowActive: true
            )
        )
        XCTAssertTrue(
            IslandRightBandPriority.showsMeetingRecording(
                meetingRecordingNonNil: true,
                agentFlowActive: false
            )
        )

        // Update pill suppressed.
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateAvailable(
                updateAvailableNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                agentFlowActive: true
            )
        )

        // Drop-mode status suppressed.
        XCTAssertFalse(
            IslandRightBandPriority.showsDropModeStatus(
                dropModeStatusNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                agentFlowActive: true
            )
        )

        // Passive hints yield: hasPriorityRightState true even with every
        // other slot inactive.
        XCTAssertTrue(
            IslandRightBandPriority.hasPriorityRightState(
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                agentFlowActive: true
            )
        )

        // Trigger orbs yield to the agent flow too.
        XCTAssertFalse(
            IslandRightBandPriority.showsHoverTriggerOrbs(
                hoverExpanded: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false,
                showsUpdateAvailable: false,
                showsDropModeStatus: false,
                agentFlowActive: true
            )
        )
    }

    // MARK: - showsUpdateAvailable

    func test_showsUpdateAvailable_falseWhenMeetingCountdown() {
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateAvailable(
                updateAvailableNonNil: true,
                showsMeetingCountdown: true,
                showsMeetingRecording: false
            )
        )
    }

    func test_showsUpdateAvailable_falseWhenMeetingRecording() {
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateAvailable(
                updateAvailableNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: true
            )
        )
    }

    func test_showsUpdateAvailable_trueWhenOnlyUpdate() {
        XCTAssertTrue(
            IslandRightBandPriority.showsUpdateAvailable(
                updateAvailableNonNil: true,
                showsMeetingCountdown: false,
                showsMeetingRecording: false
            )
        )
    }

    func test_showsUpdateAvailable_falseWhenNoUpdate() {
        // Even with no meeting layers, lack of pending update means
        // the pill does not render — covers the common idle state.
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateAvailable(
                updateAvailableNonNil: false,
                showsMeetingCountdown: false,
                showsMeetingRecording: false
            )
        )
        // Also covers the both-meeting-layers + no-update case for
        // defense-in-depth on the "no update" early-exit branch.
        XCTAssertFalse(
            IslandRightBandPriority.showsUpdateAvailable(
                updateAvailableNonNil: false,
                showsMeetingCountdown: true,
                showsMeetingRecording: true
            )
        )
    }
}
