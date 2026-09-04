import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class HistoryHoverViewTests: XCTestCase {
    func testConstantsMatchHoverHistoryContract() {
        XCTAssertEqual(HistoryHoverView.visibleRowCount, 5)
        XCTAssertEqual(HistoryHoverView.modeOrder, [.agent, .drop, .clipboard])
    }

    func testRowsStayReadableOverBusyWallpapers() {
        XCTAssertGreaterThanOrEqual(HistoryHoverVisualStyle.rowIdleOpacity, 0.8)
        XCTAssertGreaterThan(HistoryHoverVisualStyle.rowHoverOpacity, HistoryHoverVisualStyle.rowIdleOpacity)
        XCTAssertGreaterThanOrEqual(HistoryHoverVisualStyle.hintOpacity, 0.8)
    }

    func testViewportHeightHugsTheActualCardCount() {
        // A near-empty feed must not render a full fixed-height window —
        // the results viewport hugs the rows it actually has, capped at 5.
        XCTAssertEqual(HistoryHoverView.viewportHeight(forCardCount: 0), 34)   // empty-state slot
        XCTAssertEqual(HistoryHoverView.viewportHeight(forCardCount: 1), 34)
        XCTAssertEqual(HistoryHoverView.viewportHeight(forCardCount: 3), 34 * 3 + 6 * 2)
        XCTAssertEqual(
            HistoryHoverView.viewportHeight(forCardCount: 10),
            HistoryHoverView.resultViewportHeight
        )
    }

    func testHistoryHoverBandFitsFullContent() {
        // The island hover band is a fixed-height clipped region. The History
        // inline panel must declare a band tall enough for its full content
        // (mode row + visible rows + hint); rendering it into the default
        // 145pt band clips the view down to a floating sliver of row #1 —
        // the original "click History and nothing happens" bug.
        XCTAssertGreaterThanOrEqual(
            IslandDropModeControl.historyHoverPanelHeight,
            IslandDropModeControl.detachedPanelGap
                + HistoryHoverView.requiredContentHeight
        )
    }

    func testHintNamesCapturedTarget() {
        XCTAssertEqual(
            HistoryHoverView.hintText(targetAppName: "Telegram"),
            "Click for copy   Enter to paste to Telegram"
        )
        XCTAssertEqual(
            HistoryHoverView.hintText(targetAppName: nil),
            "Click for copy"
        )
    }

    func testDisplayTextUsesOnlyResultContent() {
        let agent = HistoryStripCard.agent(.init(
            id: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            title: "Ignored title",
            responseMarkdown: "Agent answer only",
            links: []
        ))
        let drop = HistoryStripCard.drop(.init(
            id: 2,
            createdAt: Date(timeIntervalSince1970: 2),
            formattedText: "Drop result only",
            targetApp: "Ignored target"
        ))
        let clipboard = HistoryStripCard.clipboard(.init(
            id: 3,
            createdAt: Date(timeIntervalSince1970: 3),
            payload: .text("Clipboard contents only")
        ))

        XCTAssertEqual(HistoryHoverContent.displayText(for: agent), "Agent answer only")
        XCTAssertEqual(HistoryHoverContent.displayText(for: drop), "Drop result only")
        XCTAssertEqual(HistoryHoverContent.displayText(for: clipboard), "Clipboard contents only")
    }

    // MARK: - Preview policy

    func testNeedsPreviewForOverflowingAndMultilineTextOnly() {
        let short = HistoryStripCard.clipboard(.init(
            id: 1, createdAt: Date(timeIntervalSince1970: 1), payload: .text("hi")
        ))
        let long = HistoryStripCard.clipboard(.init(
            id: 2, createdAt: Date(timeIntervalSince1970: 2),
            payload: .text(String(repeating: "wide text ", count: 40))
        ))
        let multiline = HistoryStripCard.clipboard(.init(
            id: 3, createdAt: Date(timeIntervalSince1970: 3), payload: .text("a\nb")
        ))

        XCTAssertFalse(HistoryHoverPreviewPolicy.needsPreview(for: short, availableTextWidth: 200))
        XCTAssertTrue(HistoryHoverPreviewPolicy.needsPreview(for: long, availableTextWidth: 200))
        XCTAssertTrue(HistoryHoverPreviewPolicy.needsPreview(for: multiline, availableTextWidth: 200))
    }

    func testPreviewTextTrimsSurroundingWhitespaceSoTheBubbleHugsContent() {
        let trailingNewlines = HistoryStripCard.clipboard(.init(
            id: 1, createdAt: Date(timeIntervalSince1970: 1), payload: .text("hi\n\n\n")
        ))
        XCTAssertEqual(HistoryHoverPreviewPolicy.previewText(for: trailingNewlines), "hi")
        XCTAssertFalse(
            HistoryHoverPreviewPolicy.needsPreview(for: trailingNewlines, availableTextWidth: 200),
            "Trailing newlines alone must not summon a preview for a short row."
        )
    }

    func testNeedsPreviewAlwaysTrueForImagesAndFiles() {
        let image = HistoryStripCard.clipboard(.init(
            id: 1, createdAt: Date(timeIntervalSince1970: 1),
            payload: .image(ClipboardImagePayload(
                uuid: UUID(), fileExtension: "png", thumbnailData: Data()
            ))
        ))
        let files = HistoryStripCard.clipboard(.init(
            id: 2, createdAt: Date(timeIntervalSince1970: 2),
            payload: .fileURLs([URL(fileURLWithPath: "/tmp/a.txt")])
        ))

        XCTAssertTrue(HistoryHoverPreviewPolicy.needsPreview(for: image, availableTextWidth: 10_000))
        XCTAssertTrue(HistoryHoverPreviewPolicy.needsPreview(for: files, availableTextWidth: 10_000))
    }

    func testImageDisplaySizeNeverUpscalesAndFitsCap() {
        let cap = CGSize(width: 264, height: 344)
        XCTAssertEqual(
            HistoryHoverPreviewPolicy.imageDisplaySize(natural: CGSize(width: 100, height: 50), cap: cap),
            CGSize(width: 100, height: 50)
        )
        let fitted = HistoryHoverPreviewPolicy.imageDisplaySize(natural: CGSize(width: 1000, height: 500), cap: cap)
        XCTAssertEqual(fitted.width, 264, accuracy: 0.5)
        XCTAssertEqual(fitted.height, 132, accuracy: 0.5)
        XCTAssertEqual(HistoryHoverPreviewPolicy.imageDisplaySize(natural: .zero, cap: cap), .zero)
    }

    func testEnterPasteUsesLocalKeyMonitorLikeTheBottomStrip() throws {
        // The bottom strip's proven Enter path: a local NSEvent keyDown
        // monitor matching Return(36)/NumpadEnter(76), swallowing the event
        // when a row is hovered. SwiftUI `.onKeyPress` + focus never worked
        // reliably on the non-activating island panel (system beep).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/History/HistoryHoverView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("addLocalMonitorForEvents(matching: .keyDown)"))
        XCTAssertTrue(source.contains("event.keyCode == 36 || event.keyCode == 76"))
        XCTAssertFalse(
            source.contains("onKeyPress"),
            "Replaced by the local key monitor — keep one Enter path only."
        )
    }

    func testRowsHaveNoExpandAffordance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/History/HistoryHoverView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("ExpandIconButton"),
            "Hover rows must not carry the ↗ expand button — the hover preview replaced it."
        )
        XCTAssertFalse(
            source.contains("onExpand"),
            "The expand chain is removed end-to-end."
        )
    }

    func testViewRendersWithoutCrashing() {
        let view = HistoryHoverView(
            mode: .constant(.drop),
            cards: [
                .drop(.init(
                    id: 1,
                    createdAt: Date(timeIntervalSince1970: 1),
                    formattedText: "Meeting intro paragraph.",
                    targetApp: "Telegram"
                ))
            ],
            targetAppName: "Telegram",
            onSelectMode: { _ in },
            onCopy: { _ in },
            onPreviewAnchorChange: { _, _ in },
            onPaste: { _ in }
        )
        let hosting = NSHostingController(rootView: view)
        XCTAssertNotNil(hosting.view)
    }
}
