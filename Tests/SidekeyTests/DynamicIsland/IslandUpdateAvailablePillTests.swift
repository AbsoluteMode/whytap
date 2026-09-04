import SwiftUI
import XCTest
@testable import Sidekey

/// Behavioural tests for `IslandUpdateAvailablePill` covering three stages:
///
///   - `.available` — compact pill showing «Update» + hover-expanded
///     [Update ↓] [✕ Skip this version]. No restart affordance — install is
///     automatic after a user-initiated download (one-button update).
///   - `.downloading` — compact-only, ICON-ONLY (no "Updating" text — it breaks
///     ugly in the ~70pt right band). No hover-expanded actions because the
///     user has nothing to act on while Sparkle is fetching the bits. The same
///     visual covers the brief auto-install phase.
///   - `.readyToInstall` — present only as a transient internal tag; the host
///     auto-installs and never surfaces a user-actionable restart step.
///
/// Rendering correctness (icons, monospaced label, etc.) is verified in the
/// manual smoke checklist; tests target wiring and label/affordance contracts.
final class IslandUpdateAvailablePillTests: XCTestCase {

    // MARK: - .available stage label and affordances

    func test_available_stage_primaryLabel_is_Update_not_version() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .available,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertEqual(pill.primaryLabel, "Update")
    }

    func test_available_stage_showsDownloadAffordance_when_hoverExpanded() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .available,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertTrue(pill.showsDownloadAffordance)
    }

    func test_available_stage_doesNotShowDownloadAffordance_when_collapsed() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .available,
            hoverExpanded: false,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertFalse(pill.showsDownloadAffordance)
    }

    func test_available_stage_doesNotShowRestartAffordance() {
        // One-button update: there is no user-actionable restart step anymore.
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .available,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertFalse(pill.showsRestartAffordance)
    }

    func test_available_stage_onDownload_fires() {
        var fired = false
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .available,
            hoverExpanded: true,
            onDownload: { fired = true },
            onSkip: { XCTFail("onSkip must not fire") }
        )
        pill.onDownload()
        XCTAssertTrue(fired)
    }

    func test_available_stage_onSkip_fires() {
        var fired = false
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .available,
            hoverExpanded: true,
            onDownload: { XCTFail("onDownload must not fire") },
            onSkip: { fired = true }
        )
        pill.onSkip()
        XCTAssertTrue(fired)
    }

    // MARK: - .downloading stage label and affordances

    func test_downloading_stage_primaryLabel_is_empty() {
        // The narrow ~70pt right band can't fit "Updating" — it breaks as
        // "U"/"pdating". Downloading is icon-only.
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .downloading,
            hoverExpanded: false,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertEqual(pill.primaryLabel, "", "downloading must render no text label, just the icon")
    }

    func test_downloading_stage_doesNotShowDownloadAffordance() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .downloading,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertFalse(pill.showsDownloadAffordance)
    }

    func test_downloading_stage_doesNotShowRestartAffordance() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .downloading,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertFalse(pill.showsRestartAffordance)
    }

    // MARK: - .readyToInstall stage label and affordances

    func test_readyToInstall_primaryLabel_contains_version() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .readyToInstall,
            hoverExpanded: false,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertTrue(pill.primaryLabel.contains("1.9.3"))
    }

    func test_readyToInstall_doesNotShowRestartAffordance_evenWhenHoverExpanded() {
        // Install is automatic — the pill never offers a user-actionable
        // restart, even if the host ever forwarded a readyToInstall tag.
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .readyToInstall,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertFalse(pill.showsRestartAffordance)
    }

    func test_readyToInstall_doesNotShowDownloadAffordance() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .readyToInstall,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertFalse(pill.showsDownloadAffordance)
    }

    // MARK: - Init sanity

    func test_init_downloadingStageDefault() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "0.0.1",
            stage: .downloading,
            hoverExpanded: false,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertEqual(pill.displayVersion, "0.0.1")
        XCTAssertEqual(pill.stage, .downloading)
        XCTAssertFalse(pill.hoverExpanded)
    }

    // MARK: - Visual contract

    func test_downloadingIconUsesProgressGlyph() {
        XCTAssertEqual(
            IslandUpdateAvailablePillStyle.downloadingSystemImage,
            "arrow.down.circle"
        )
    }

    func test_readyToInstallIconUsesCheckmarkGlyph() {
        XCTAssertEqual(
            IslandUpdateAvailablePillStyle.readyToInstallSystemImage,
            "checkmark.circle.fill"
        )
    }

    func test_downloadAndSkipActionsUseMatchedCircularIconFrames() {
        XCTAssertEqual(
            IslandUpdateAvailablePillStyle.downloadActionSystemImage,
            "arrow.down.circle.fill"
        )
        XCTAssertEqual(
            IslandUpdateAvailablePillStyle.skipActionSystemImage,
            "xmark"
        )
        XCTAssertEqual(
            IslandUpdateAvailablePillStyle.actionButtonSize,
            24,
            accuracy: 0.001
        )
        XCTAssertEqual(
            IslandUpdateAvailablePillStyle.actionIconFrameSize,
            12,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            IslandUpdateAvailablePillStyle.secondaryActionIconFontSize,
            IslandUpdateAvailablePillStyle.primaryActionIconFontSize,
            "The xmark needs a small optical compensation so Skip does not look smaller than Update."
        )
    }
}
