import XCTest
@testable import Sidekey

/// Pure-function tests for the marquee overflow predicate used by the
/// integrated Now Playing body's title. The window-level hit-test math for
/// the body lives in `IslandMusicBodyTests`.
final class IslandMarqueeTextTests: XCTestCase {

    // MARK: - Marquee overflow predicate

    /// Content wider than its envelope must scroll (Reduce Motion off).
    func test_marquee_scrolls_whenContentWiderThanEnvelope() {
        XCTAssertTrue(
            IslandMarqueeText.shouldScroll(
                contentWidth: 200,
                envelopeWidth: 100,
                reduceMotion: false
            )
        )
    }

    /// Content that fits its envelope renders static, never scrolls.
    func test_marquee_static_whenFits() {
        XCTAssertFalse(
            IslandMarqueeText.shouldScroll(
                contentWidth: 80,
                envelopeWidth: 100,
                reduceMotion: false
            )
        )
    }

    /// Reduce Motion overrides overflow: even an overflowing title stays
    /// static (truncated), never scrolls.
    func test_marquee_static_whenReduceMotion() {
        XCTAssertFalse(
            IslandMarqueeText.shouldScroll(
                contentWidth: 200,
                envelopeWidth: 100,
                reduceMotion: true
            )
        )
    }

    /// Equal widths are NOT overflow — a title that exactly fills its
    /// envelope reads cleanly, so no scroll.
    func test_marquee_static_whenExactlyEqual() {
        XCTAssertFalse(
            IslandMarqueeText.shouldScroll(
                contentWidth: 100,
                envelopeWidth: 100,
                reduceMotion: false
            )
        )
    }
}
