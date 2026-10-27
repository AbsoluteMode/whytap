import AppKit
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
///   - `.readyToInstall` — explicit Restart / Later after a deferred download.
///
/// Rendering correctness (icons, monospaced label, etc.) is verified in the
/// manual smoke checklist; tests target wiring and label/affordance contracts.
final class IslandUpdateAvailablePillTests: XCTestCase {
    @MainActor
    func test_pendingPressCannotTurnIntoRestartAfterStageChange() {
        let bridge = IslandHoverHitBridge()
        bridge.setEnabled(true); bridge.setContext("fixture")
        var downloads = 0, installs = 0
        func content(_ stage: IslandUpdateAvailablePillStage) -> some View {
            IslandUpdateAvailablePill(displayVersion: "1.0", stage: stage, hoverExpanded: true,
                onDownload: { downloads += 1 }, onSkip: {}, onInstall: { installs += 1 }, hitBridge: bridge)
                .frame(width: 70, height: 40)
        }
        let host = NSHostingView(rootView: content(.available))
        let window = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 70, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 70, height: 40)
        func settle() { for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
        settle()
        let point = host.convert(NSPoint(x: 20, y: 20), to: nil)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        host.rootView = content(.readyToInstall)
        settle()
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(downloads, 0); XCTAssertEqual(installs, 0)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(installs, 1)
        host.rootView = content(.downloading)
        settle()
        XCTAssertFalse(bridge.mouseDown(at: point, in: window, allowed: true))
    }

    @MainActor
    func test_render_update_click_states() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_UPDATE_RENDER_DIR"] else {
            throw XCTSkip("set EXODIA_UPDATE_RENDER_DIR for offscreen images")
        }
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for stage in [IslandUpdateAvailablePillStage.available, .readyToInstall, .downloading] {
            for disabled in [false, true] {
                let bridge = IslandHoverHitBridge()
                bridge.setEnabled(true); bridge.setContext("fixture")
                let host = NSHostingView(rootView: IslandUpdateAvailablePill(displayVersion: "1.0", stage: stage,
                    hoverExpanded: true, onDownload: {}, onSkip: {}, onInstall: {}, onLater: {}, hitBridge: bridge)
                    .disabled(disabled).frame(width: 70, height: 40).background(Color.black))
                let window = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 70, height: 40),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                host.frame = NSRect(x: 0, y: 0, width: 70, height: 40)
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                for pressed in [false, true] {
                    let point = host.convert(NSPoint(x: 20, y: 20), to: nil)
                    if pressed {
                        let captured = bridge.mouseDown(at: point, in: window, allowed: true)
                        XCTAssertEqual(captured, stage != .downloading && !disabled)
                        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                    }
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("update-\(stage)-\(disabled ? "disabled" : "enabled")-\(pressed ? "pressed" : "rest").png"))
                }
                XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    @MainActor
    func test_updateActionsReceiveFirstMouseWithoutActivatingTheApp() throws {
        for stage in [IslandUpdateAvailablePillStage.available, .readyToInstall] {
            for toolsEnabled in [false, true] {
                let bridge = IslandHoverHitBridge()
                bridge.setEnabled(toolsEnabled); bridge.setSurface(.result); bridge.setContext("fixture")
                var primary = 0, secondary = 0
                let pill = IslandUpdateAvailablePill(displayVersion: "1.0", stage: stage, hoverExpanded: true,
                    onDownload: { primary += 1 }, onSkip: { secondary += 1 },
                    onInstall: { primary += 1 }, onLater: { secondary += 1 }, hitBridge: bridge)
                let host = NSHostingView(rootView: pill.frame(width: 70, height: 40))
                let window = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 70, height: 40),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                defer { window.close() }
                host.frame = NSRect(x: 0, y: 0, width: 70, height: 40)
                for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                let first = host.convert(NSPoint(x: 20, y: 20), to: nil)
                let second = host.convert(NSPoint(x: 50, y: 20), to: nil)
                let gap = host.convert(NSPoint(x: 35, y: 20), to: nil)
                XCTAssertFalse(bridge.mouseDown(at: gap, in: window, allowed: true))
                XCTAssertTrue(bridge.mouseDown(at: first, in: window, allowed: true))
                bridge.mouseUp(at: first, in: window, allowed: true)
                bridge.mouseUp(at: first, in: window, allowed: true)
                XCTAssertEqual(primary, 1)
                XCTAssertTrue(bridge.mouseDown(at: second, in: window, allowed: true))
                bridge.mouseUp(at: second, in: window, allowed: true)
                XCTAssertEqual(secondary, 1)
                XCTAssertTrue(bridge.mouseDown(at: first, in: window, allowed: true))
                bridge.mouseDragged(at: second, in: window, allowed: true)
                bridge.mouseUp(at: second, in: window, allowed: true)
                XCTAssertEqual(primary, 1); XCTAssertEqual(secondary, 1)
                XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

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

    func test_readyToInstall_primaryLabel_is_Ready() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .readyToInstall,
            hoverExpanded: false,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertEqual(pill.primaryLabel, "Ready")
    }

    func test_readyToInstall_showsRestartAffordance_whenHoverExpanded() {
        let pill = IslandUpdateAvailablePill(
            displayVersion: "1.9.3",
            stage: .readyToInstall,
            hoverExpanded: true,
            onDownload: {},
            onSkip: {}
        )
        XCTAssertTrue(pill.showsRestartAffordance)
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

    func test_readyToInstall_restartAndLaterHaveDistinctCallbacks() {
        var installs = 0
        var laters = 0
        let pill = IslandUpdateAvailablePill(
            displayVersion: "2.2.0", stage: .readyToInstall, hoverExpanded: true,
            onDownload: { XCTFail("Do not download again") }, onSkip: { XCTFail("Later is not Skip") },
            onInstall: { installs += 1 }, onLater: { laters += 1 },
            restartDeferralReason: "Finish recording before restarting."
        )
        pill.onInstall()
        pill.onLater()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(laters, 1)
        XCTAssertEqual(pill.restartDeferralReason, "Finish recording before restarting.")
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
