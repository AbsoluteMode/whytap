import XCTest
@testable import Sidekey

/// Pure-geometry tests for `IslandAgentHitZones` — the agent-surface
/// hit regions inside the (already enlarged) host window bounds.
///
/// Coordinate system matches `ClickThroughHostingView`: an `NSHostingView`
/// is NOT flipped, so the origin is bottom-left and `boundsSize.height` is
/// the top edge (y-up). The island stack is top-anchored, so the wing
/// capsule's top edge (`maxY`) sits flush with the window top.
final class IslandAgentHitZonesTests: XCTestCase {
    func test_agentZones_wingRectCoversExtension_answerRectBelow() {
        // The agent phase content begins in the right band (inside the
        // capsule); only the part that overflows the band grows the island
        // form. The hit zone covers JUST that overflow (the extension), so the
        // max recording face (260) passes `wingWidth = 190` (= 260 - 70 band).
        let zones = IslandAgentHitZones(
            boundsSize: CGSize(width: 800, height: 600),
            compactSize: CGSize(width: 244, height: 32),
            rightAgentZoneWidth: 300,
            wingWidth: IslandFrameLayout.agentWingRecordingExtension,
            wingGap: 8,
            answerSize: CGSize(width: 336, height: 220)
        )
        let wing = zones.wingRect
        // Wing extension is FLUSH against the capsule's right edge — its
        // overflow begins exactly where the compact capsule ends.
        XCTAssertEqual(wing.minX, 800 - 300)
        XCTAssertEqual(wing.width, IslandFrameLayout.agentWingRecordingExtension)
        XCTAssertEqual(wing.maxY, 600)                   // window top edge
        XCTAssertEqual(wing.height, 32)
        let answer = zones.answerRect
        XCTAssertEqual(answer.width, 336)
        // Answer panel is centred under the pill (hover-panel geometry): its
        // right edge sits at the pill's right edge (`wingRect.minX` == window
        // right minus the wing zone), so a pill-width card is centred under the
        // notch. Must stay in lockstep with `IslandView.agentAnswerLayer`'s
        // trailing pad (`rightAgentZoneWidth`).
        XCTAssertEqual(answer.maxX, wing.minX)
        // `wingGap` is now the VERTICAL gap between the capsule row and the
        // answer panel (the horizontal seam is gone).
        XCTAssertEqual(answer.maxY, wing.minY - 8)
        XCTAssertEqual(answer.height, 220)
    }

    func test_answerCloseHotspot_coversWingCloseControls() {
        // Close controls ([Esc] [✕]) live in the WING while the answer is up
        // (the `.answerControls` face), not over the card. The hotspot covers
        // that controls face in the compact-row band: right edge at the face's
        // right (pill right `wingRect.minX` + its extension), width = the
        // controls width, height = the compact row — all with a few pts of slop.
        let zones = IslandAgentHitZones(
            boundsSize: CGSize(width: 925, height: 653),
            compactSize: CGSize(width: 325, height: 32),
            rightAgentZoneWidth: IslandFrameLayout.rightAgentZoneWidth,
            wingWidth: 0,
            wingGap: IslandFrameLayout.agentWingGap,
            answerSize: CGSize(
                width: IslandFrameLayout.agentAnswerPanelWidth,
                height: IslandFrameLayout.agentAnswerZoneHeight
            )
        )
        let hotspot = zones.answerCloseHotspot
        let controlsWidth = IslandFrameLayout.agentWingAnswerControlsWidth
        let ext = IslandFrameLayout.agentWingExtension(faceWidth: controlsWidth)
        // Controls face right edge = pill right (925 - 300) + its extension.
        let right = (925 - IslandFrameLayout.rightAgentZoneWidth) + ext
        XCTAssertEqual(hotspot.maxX, right + 4, accuracy: 0.001)
        XCTAssertEqual(hotspot.width, controlsWidth + 8, accuracy: 0.001)
        // Sits in the compact-row band (top of the window), not below the card.
        XCTAssertEqual(hotspot.maxY, 653 + 4, accuracy: 0.001)
        XCTAssertEqual(hotspot.height, 32 + 8, accuracy: 0.001)
        // A click in the middle of the [Esc] [✕] cluster lands inside.
        XCTAssertTrue(hotspot.contains(CGPoint(x: right - controlsWidth / 2, y: 653 - 16)))
        // The centred card area (well left of the wing) stays outside.
        XCTAssertFalse(hotspot.contains(CGPoint(x: right - controlsWidth - 40, y: 653 - 16)))
    }
}
