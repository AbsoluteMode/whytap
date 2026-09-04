import AppKit
import XCTest
@testable import Sidekey

/// The product is dark-only (no light theme anywhere). The island's shared
/// material must therefore be pinned to `.darkAqua`: without the pin a
/// light-mode user gets a near-white hover panel / pill while dark-mode
/// users get a dark one — the "looks completely different on my Mac" bug.
@MainActor
final class IslandVisualEffectBackgroundTests: XCTestCase {
    func test_backingViewIsDarkPinnedBehindWindowBlur() {
        let view = IslandVisualEffectBackground.makeBackingView(material: .popover)

        XCTAssertEqual(view.material, .popover)
        XCTAssertEqual(view.blendingMode, .behindWindow)
        XCTAssertEqual(view.state, .active)
        XCTAssertEqual(
            view.appearance?.name, .darkAqua,
            "island glass must not follow the user's system appearance"
        )
    }
}
