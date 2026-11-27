import AppKit
import XCTest
@testable import Sidekey

/// The island's black plate must meet the top screen edge even when the
/// camera band (`safeAreaInsets.top`) is fractional.
///
/// Reported 2026-11-26 on a Mac17,8 (macOS 27.2.1): a one-pixel wallpaper line
/// above the island. Its probe showed the window flush with the top
/// (CG y = 0, height 661) while the island requested 27.5 + 145 + 8 + 480 =
/// 660.5 pt. AppKit snapped the window outward to 661 pt; the hosting view
/// was then resized to the requested 660.5 pt from the window's bottom-left,
/// so the top-pinned plate started 0.5 pt below the screen edge.
/// WHY: .project-docs/decisions/2026-11-26-island-host-fills-window-height.md
@MainActor
final class IslandHostFillsWindowTests: XCTestCase {

    /// Mac17,8 built-in display, numbers verbatim from the user's probe.
    private static let fractionalBand = IslandScreenDescriptor(
        uuid: nil,
        frame: NSRect(x: 0, y: 0, width: 1496, height: 967),
        visibleFrame: NSRect(x: 0, y: 85, width: 1496, height: 854),
        safeAreaTopInset: 27.5,
        auxiliaryTopLeftArea: NSRect(x: 0, y: 939.5, width: 668, height: 27.5),
        auxiliaryTopRightArea: NSRect(x: 828, y: 939.5, width: 668, height: 27.5)
    )

    /// Mac16,7 16" (default scaling): whole-point band, already flush.
    private static let wholeBand = IslandScreenDescriptor(
        uuid: nil,
        frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: NSRect(x: 0, y: 0, width: 1728, height: 1084),
        safeAreaTopInset: 32,
        auxiliaryTopLeftArea: NSRect(x: 0, y: 1085, width: 771.5, height: 32),
        auxiliaryTopRightArea: NSRect(x: 956.5, y: 1085, width: 771.5, height: 32)
    )

    /// A scaled mode with a 37.5 pt band.
    private static let scaledHalfBand = IslandScreenDescriptor(
        uuid: nil,
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: NSRect(x: 0, y: 76, width: 1512, height: 868),
        safeAreaTopInset: 37.5,
        auxiliaryTopLeftArea: NSRect(x: 0, y: 944.5, width: 670, height: 37.5),
        auxiliaryTopRightArea: NSRect(x: 842, y: 944.5, width: 670, height: 37.5)
    )

    /// Same composition as `IslandPanel.Layout.windowFrame`: the permanently
    /// agent-sized host, the left notification reservation and the hover
    /// preview reservation.
    private func requestedWindowFrame(on screen: IslandScreenDescriptor) -> NSRect {
        let compact = IslandFrameLayout.islandFrame(on: screen)
        let base = IslandPanelFramePolicy.windowFrame(
            compactFrame: compact,
            expandedFrame: IslandFrameLayout.hostPanelFrame(on: screen, expanded: true, agentActive: true),
            acceptsExpandedHitTesting: false
        )
        return IslandPanelFramePolicy.reservingHoverPreview(
            in: base.union(IslandFrameLayout.leftNotificationFrame(on: screen, expanded: true)),
            compactFrame: compact
        )
    }

    /// The frame AppKit really gives a borderless panel for `requested`. The
    /// panel is never ordered in, so nothing appears on screen.
    private func actualWindowFrame(for requested: NSRect) -> NSRect {
        let panel = NSPanel(
            contentRect: requested,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.setFrame(requested, display: false)
        defer { panel.close() }
        return panel.frame
    }

    /// Screen y of the plate's top edge: the host's top inside the window
    /// (the island content is pinned to the host's top-leading corner).
    private func plateTop(host: NSRect, window: NSRect) -> CGFloat {
        window.minY + host.maxY
    }

    func test_fractionalBand_plateMeetsScreenTop() {
        let screen = Self.fractionalBand
        let compact = IslandFrameLayout.islandFrame(on: screen)
        // The plate keeps the real camera band: 27.5 pt, top at the screen edge.
        XCTAssertEqual(compact.height, 27.5, accuracy: 0.001)
        XCTAssertEqual(compact.maxY, 967, accuracy: 0.001)
        XCTAssertEqual(compact.minY, 939.5, accuracy: 0.001)

        let requested = requestedWindowFrame(on: screen)
        XCTAssertEqual(requested.height, 660.5, accuracy: 0.001)
        XCTAssertEqual(requested.maxY, 967, accuracy: 0.001)

        // AppKit contract this fix relies on: outward snap to whole points,
        // top kept. Matches the probe (CG y = 0, h = 661).
        let actual = actualWindowFrame(for: requested)
        XCTAssertEqual(actual.height, 661, accuracy: 0.001)
        XCTAssertEqual(actual.maxY, 967, accuracy: 0.001)

        // Before the fix: host sized to the requested height -> 966.5.
        let preFixHost = NSRect(origin: .zero, size: requested.size)
        XCTAssertEqual(plateTop(host: preFixHost, window: actual), 966.5, accuracy: 0.001)

        let host = IslandPanelFramePolicy.hostFrame(
            requestedWindowFrame: requested,
            actualWindowFrame: actual
        )
        XCTAssertEqual(plateTop(host: host, window: actual), 967, accuracy: 0.001)
        XCTAssertEqual(host.height, actual.height, accuracy: 0.001)
        XCTAssertEqual(host.width, requested.width, accuracy: 0.001)

        // The compact hit rect (`bounds.height - compactHeight`) lands on the
        // camera band too, not half a point lower.
        XCTAssertEqual(actual.minY + host.height - compact.height, 939.5, accuracy: 0.001)
    }

    func test_wholeBand_geometryUnchanged() {
        let screen = Self.wholeBand
        let requested = requestedWindowFrame(on: screen)
        XCTAssertEqual(requested.height, 665, accuracy: 0.001)
        let actual = actualWindowFrame(for: requested)
        let host = IslandPanelFramePolicy.hostFrame(
            requestedWindowFrame: requested,
            actualWindowFrame: actual
        )
        // Identical to the pre-fix host: same origin, width and height.
        XCTAssertEqual(host, NSRect(origin: .zero, size: requested.size))
        XCTAssertEqual(plateTop(host: host, window: actual), 1117, accuracy: 0.001)
        XCTAssertEqual(IslandFrameLayout.islandFrame(on: screen).height, 32, accuracy: 0.001)
    }

    func test_scaledHalfBand_plateMeetsScreenTopAndKeepsItsHeight() {
        let screen = Self.scaledHalfBand
        let compact = IslandFrameLayout.islandFrame(on: screen)
        XCTAssertEqual(compact.height, 37.5, accuracy: 0.001)

        let requested = requestedWindowFrame(on: screen)
        XCTAssertEqual(requested.height, 670.5, accuracy: 0.001)
        let actual = actualWindowFrame(for: requested)
        let host = IslandPanelFramePolicy.hostFrame(
            requestedWindowFrame: requested,
            actualWindowFrame: actual
        )
        XCTAssertEqual(plateTop(host: host, window: actual), 982, accuracy: 0.001)
        XCTAssertEqual(host.width, requested.width, accuracy: 0.001)
    }

    func test_hostNeverShrinksBelowTheRequestedHeight() {
        let requested = NSRect(x: 10, y: 20.5, width: 300.5, height: 660.5)
        let host = IslandPanelFramePolicy.hostFrame(
            requestedWindowFrame: requested,
            actualWindowFrame: NSRect(x: 10, y: 20, width: 300, height: 660)
        )
        XCTAssertEqual(host, NSRect(x: 0, y: 0, width: 300.5, height: 660.5))
    }
}
