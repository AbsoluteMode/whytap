import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Smoke tests for the strip / card / expanded SwiftUI views. They
/// only check that `NSHostingController` can resolve and lay out each
/// view without crashing — visual correctness is verified manually.
@MainActor
final class HistoryStripViewSmokeTests: XCTestCase {
    private func makeStore() throws -> SQLiteHistoryStore {
        try SQLiteHistoryStore(path: ":memory:")
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-strip-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - DarkGlassCard

    func testDarkGlassCardHostsWithoutCrashing() {
        let view = DarkGlassCard(width: 200, height: 100, cornerRadius: 18) {
            Text("hi")
                .foregroundStyle(.white)
        }
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - HistoryCardView

    func testHistoryCardAgentRendersWithoutCrashing() {
        let card = HistoryStripCard.agent(.init(
            id: 1,
            createdAt: Date(),
            title: "Hello",
            responseMarkdown: "Body text",
            links: [URL(string: "https://example.com")!]
        ))
        let view = HistoryCardView(
            card: card,
            assetsDirectory: makeTempDir(),
            onCopy: {},
            onExpand: {}
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testHistoryCardDropRendersWithoutCrashing() {
        let card = HistoryStripCard.drop(.init(
            id: 1,
            createdAt: Date(),
            formattedText: "Dictated text.",
            targetApp: "Notes"
        ))
        let view = HistoryCardView(
            card: card,
            assetsDirectory: makeTempDir(),
            onCopy: {},
            onExpand: {}
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testHistoryCardClipboardTextRendersWithoutCrashing() {
        let card = HistoryStripCard.clipboard(.init(
            id: 1,
            createdAt: Date(),
            payload: .text("clipboard contents")
        ))
        let view = HistoryCardView(
            card: card,
            assetsDirectory: makeTempDir(),
            onCopy: {},
            onExpand: {}
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testHistoryCardClipboardFileURLsRendersWithoutCrashing() {
        let card = HistoryStripCard.clipboard(.init(
            id: 1,
            createdAt: Date(),
            payload: .fileURLs([
                URL(fileURLWithPath: "/tmp/a.txt"),
                URL(fileURLWithPath: "/tmp/b.txt"),
            ])
        ))
        let view = HistoryCardView(
            card: card,
            assetsDirectory: makeTempDir(),
            onCopy: {},
            onExpand: {}
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - HistoryStripView

    func testStripViewWithAgentModeRendersWithoutCrashing() throws {
        let store = try makeStore()
        let feed = HistoryStripFeed(store: store)
        let controller = HistoryStripController()
        controller.toggle(.agent)

        let view = HistoryStripView(
            controller: controller,
            feed: feed,
            assetsDirectory: makeTempDir()
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testStripViewEmptyClipboardRendersEmptyState() throws {
        let store = try makeStore()
        let feed = HistoryStripFeed(store: store)
        let controller = HistoryStripController()
        controller.toggle(.clipboard)

        let view = HistoryStripView(
            controller: controller,
            feed: feed,
            assetsDirectory: makeTempDir()
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - HistoryExpandedView

    func testExpandedAgentTextRendersWithoutCrashing() {
        let controller = HistoryStripController()
        controller.toggle(.agent)
        controller.expand(.agent(.text("expanded body")))

        let view = HistoryExpandedView(
            controller: controller,
            assetsDirectory: makeTempDir()
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testExpandedDropFullRendersWithoutCrashing() {
        let controller = HistoryStripController()
        controller.toggle(.drop)
        controller.expand(.drop(.full(
            raw: "raw transcript",
            formatted: "Formatted transcript.",
            targetApp: "Notes"
        )))

        let view = HistoryExpandedView(
            controller: controller,
            assetsDirectory: makeTempDir()
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testExpandedClipboardFileURLsRendersWithoutCrashing() {
        let controller = HistoryStripController()
        controller.toggle(.clipboard)
        controller.expand(.clipboard(.fileURLs([
            URL(fileURLWithPath: "/tmp/file.pdf")
        ])))

        let view = HistoryExpandedView(
            controller: controller,
            assetsDirectory: makeTempDir()
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - CopiedToastView smoke

    func testCopiedToastViewHiddenStateRendersWithoutCrashing() {
        let toast = CopiedToastController()
        let view = CopiedToastView(controller: toast)
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    func testCopiedToastViewVisibleStateRendersWithoutCrashing() {
        let toast = CopiedToastController(schedule: { _, _ in })
        toast.show()
        let view = CopiedToastView(controller: toast)
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    // MARK: - ExpandIconButton

    func testExpandIconButtonRendersWithoutCrashing() {
        let view = ExpandIconButton(action: {})
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }

    /// Wires the action callback through the button hierarchy. We
    /// don't simulate a real click — instead we pin the contract that
    /// the `action` closure is held and reachable, which is what the
    /// strip view uses to plumb `controller.toggleExpand` in.
    func testExpandIconButtonHoldsActionClosure() {
        var fired = false
        let button = ExpandIconButton(action: { fired = true })
        button.action()
        XCTAssertTrue(fired)
    }
}
