import SwiftUI
import XCTest
@testable import Sidekey

/// Behavioural tests for `IslandJustUpdatedPill` — the transient post-relaunch
/// "Updated" indicator (variant A). Compact-only: a checkmark + "Updated"
/// label sized for the ~70 pt right band (the version does not fit alongside).
/// The whole pill taps to dismiss immediately; otherwise it auto-hides after
/// ~5 s (owned by `JustUpdatedIndicator`, not the view).
final class IslandJustUpdatedPillTests: XCTestCase {

    func test_label_is_Updated_word() {
        let pill = IslandJustUpdatedPill(displayVersion: "1.18.0", onDismiss: {})
        XCTAssertEqual(
            pill.label,
            "Updated",
            "The ~70 pt band cannot fit a version alongside the checkmark, so the pill shows just the word."
        )
    }

    func test_usesCheckmarkGlyph() {
        XCTAssertEqual(
            IslandJustUpdatedPillStyle.systemImage,
            "checkmark.circle.fill",
            "The Updated indicator reuses the readyToInstall checkmark family."
        )
    }

    func test_tap_invokesDismiss() {
        var dismissed = false
        let pill = IslandJustUpdatedPill(displayVersion: "1.18.0", onDismiss: { dismissed = true })
        pill.onDismiss()
        XCTAssertTrue(dismissed, "Tapping the pill must dismiss it immediately.")
    }

    func test_accessibilityLabel_mentionsUpdatedAndVersion() {
        let pill = IslandJustUpdatedPill(displayVersion: "1.18.0", onDismiss: {})
        XCTAssertTrue(pill.accessibilityLabelText.contains("Updated"))
        XCTAssertTrue(
            pill.accessibilityLabelText.contains("1.18.0"),
            "VoiceOver should still announce the version even though the visible label omits it."
        )
    }

    func test_init_holdsDisplayVersion() {
        let pill = IslandJustUpdatedPill(displayVersion: "2.0.1", onDismiss: {})
        XCTAssertEqual(pill.displayVersion, "2.0.1")
    }
}
