import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Pure-logic tests for the unified strip's left sidebar (ROO-208).
///
/// The sidebar exposes three filter buttons (Clipboard / Drop / Agent)
/// and drives `HistoryStripController.setFilter(_:)` on tap. Tests here
/// pin:
///  * Order of the filters top → bottom
///  * Title + SF Symbol icon per filter
///  * Default-on-open filter
///  * `NSHostingController` smoke render does not crash
@MainActor
final class HistoryStripSidebarViewTests: XCTestCase {
    // MARK: - Filter order

    func testFilterOrderIsClipboardDropAgent() {
        // Spec ASCII diagram lists Clipboard at the top, then Drop, then
        // Agent. Pinned so a future tuning round can't flip the order
        // without flipping a test.
        XCTAssertEqual(
            HistoryStripSidebarView.filterOrder,
            [.clipboard, .drop, .agent]
        )
    }

    // MARK: - Per-filter labels + icons

    func testClipboardFilterLabelAndIcon() {
        XCTAssertEqual(HistoryStripSidebarView.title(for: .clipboard), "Clipboard")
        XCTAssertEqual(HistoryStripSidebarView.iconName(for: .clipboard), "doc.on.clipboard")
    }

    func testDropFilterLabelAndIcon() {
        XCTAssertEqual(HistoryStripSidebarView.title(for: .drop), "Drop")
        XCTAssertEqual(HistoryStripSidebarView.iconName(for: .drop), "mic")
    }

    func testAgentFilterLabelAndIcon() {
        XCTAssertEqual(HistoryStripSidebarView.title(for: .agent), "Agent")
        XCTAssertEqual(HistoryStripSidebarView.iconName(for: .agent), "sparkles")
    }

    // MARK: - Default filter contract

    func testDefaultFilterIsClipboard() {
        // ROO-208: on first open the unified strip lands on Clipboard
        // (most frequent use case). Pinned as a sidebar-level constant
        // so view-level + controller-level defaults can't drift.
        XCTAssertEqual(HistoryStripSidebarView.defaultFilter, .clipboard)
    }

    // MARK: - Smoke render

    func testSidebarRendersWithoutCrashingWhenInactive() {
        let controller = HistoryStripController()
        let view = HistoryStripSidebarView(
            activeFilter: .clipboard,
            onSelect: { _ in }
        )
        _ = controller
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testSidebarRendersWithoutCrashingWhenActiveFilterPicked() {
        let view = HistoryStripSidebarView(
            activeFilter: .drop,
            onSelect: { _ in }
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - onSelect callback wiring

    func testOnSelectCallbackIsConfigurable() {
        var picked: HistoryStripMode?
        let view = HistoryStripSidebarView(
            activeFilter: .clipboard,
            onSelect: { picked = $0 }
        )
        view.onSelect(.agent)
        XCTAssertEqual(picked, .agent)
    }
}
