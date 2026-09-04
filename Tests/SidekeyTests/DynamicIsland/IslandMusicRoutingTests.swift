import XCTest
@testable import Sidekey

/// The "Hide Hover and Music" eye must hide the hover player WIDGET (the card
/// between the island and the hover drawer) WITHOUT touching the compact
/// right-band wing — that wing is an always-on "music is playing" indicator and
/// stays put. These pin the routing of the playback snapshot to each surface.
final class IslandMusicRoutingTests: XCTestCase {

    // MARK: - Compact right-band wing: eye-independent

    func test_compactWing_showsPlaybackEvenWhenEyeHidesHoverWidgets() {
        XCTAssertEqual(
            IslandMusicRouting.compactWingNowPlaying(7, hoverWidgetsHidden: true), 7,
            "the compact wing must keep showing playback when the eye is on"
        )
        XCTAssertEqual(
            IslandMusicRouting.compactWingNowPlaying(7, hoverWidgetsHidden: false), 7
        )
    }

    func test_compactWing_nilWhenNothingIsPlaying() {
        XCTAssertNil(IslandMusicRouting.compactWingNowPlaying(Int?.none, hoverWidgetsHidden: false))
    }

    // MARK: - Hover player widget: eye-gated

    func test_hoverWidget_hiddenWhenEyeIsOn() {
        XCTAssertNil(
            IslandMusicRouting.hoverWidgetNowPlaying(7, hoverWidgetsHidden: true),
            "the hover player widget must disappear when the eye is on"
        )
    }

    func test_hoverWidget_visibleWhenEyeIsOff() {
        XCTAssertEqual(
            IslandMusicRouting.hoverWidgetNowPlaying(7, hoverWidgetsHidden: false), 7
        )
    }
}
