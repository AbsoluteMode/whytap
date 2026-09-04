import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Pure-logic + smoke tests for the 5-up rubbery horizontal row that
/// replaced the deck-with-peek carousel (ROO-208 iter 3).
///
/// Maxim's iter-3 directive: «делаем просто по низу 5 видимых из общих
/// 10 (с возможностью полистать влево-вправо) так, чтобы они доходили
/// до правого края панели». The row spans from the sidebar (with a
/// small gap) to the strip's right edge. Cards are sized so exactly 5
/// fit in the visible viewport; the remaining 5 (cap is 10 from iter 2)
/// are reachable by horizontal scroll.
@MainActor
final class HistoryStripRowLayoutTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-row-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeClipboardCard(_ i: Int) -> HistoryStripCard {
        .clipboard(.init(
            id: Int64(i),
            createdAt: Date(timeIntervalSince1970: TimeInterval(i)),
            payload: .text("entry-\(i)")
        ))
    }

    // MARK: - cardWidth math

    /// Round-figure baseline: 1000pt available, 5 cards visible, 12pt
    /// spacing → (1000 - 4 * 12) / 5 = 190.4.
    func testCardWidthBaselineMath() {
        let w = HistoryStripRowLayout.cardWidth(
            availableWidth: 1000,
            visibleCount: 5,
            spacing: 12
        )
        XCTAssertEqual(w, (1000 - 48) / 5, accuracy: 0.001)
    }

    /// Realistic strip width on a 1440-wide screen. After sidebar (110)
    /// + outer h-padding (24) + inner gap (10) the cards-area is
    /// roughly 1296pt. The helper should produce a card width in the
    /// 240-260pt range — slimmer than the legacy fixed 260pt but still
    /// readable for a 5-up layout.
    func testCardWidthAtRealisticStripWidth() {
        let w = HistoryStripRowLayout.cardWidth(
            availableWidth: 1296,
            visibleCount: 5,
            spacing: 12
        )
        XCTAssertGreaterThan(w, 230)
        XCTAssertLessThan(w, 260)
    }

    /// The width math must never produce a value below the configured
    /// minimum — if the available width collapses (small screen, lots
    /// of chrome) the cards stay at `minCardWidth` and the row
    /// overflows horizontally (user scrolls the row sideways to see
    /// them). Below-min snap protects against zero/negative widths
    /// when the strip is unusually narrow.
    func testCardWidthClampsToMinimum() {
        // 200 available, 5 visible, 12 spacing → raw = (200-48)/5 = 30.4
        // That's well below the minimum — should snap to the floor.
        let w = HistoryStripRowLayout.cardWidth(
            availableWidth: 200,
            visibleCount: 5,
            spacing: 12,
            minCardWidth: 180
        )
        XCTAssertEqual(w, 180, accuracy: 0.001)
    }

    /// Defensive: invalid input (zero or negative `visibleCount`) must
    /// not crash — return the minimum so SwiftUI receives a positive
    /// frame.
    func testCardWidthInvalidInputReturnsMinimum() {
        XCTAssertEqual(
            HistoryStripRowLayout.cardWidth(
                availableWidth: 1000,
                visibleCount: 0,
                spacing: 12,
                minCardWidth: 180
            ),
            180,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HistoryStripRowLayout.cardWidth(
                availableWidth: 1000,
                visibleCount: -1,
                spacing: 12,
                minCardWidth: 180
            ),
            180,
            accuracy: 0.001
        )
    }

    /// At very wide strips the cards stay readable — capped at the
    /// legacy `HistoryCardView.cardWidth` so they don't balloon to
    /// 500pt each when the strip stretches across a 27" display.
    func testCardWidthClampsToMaximum() {
        let w = HistoryStripRowLayout.cardWidth(
            availableWidth: 3000,
            visibleCount: 5,
            spacing: 12,
            minCardWidth: 180,
            maxCardWidth: 260
        )
        XCTAssertEqual(w, 260, accuracy: 0.001)
    }

    // MARK: - visualOrder (chat-style ordering)

    /// ROO-208 iter 5: cards are stored newest-first by the feed but
    /// rendered chat-style — oldest on the left, newest on the right.
    /// The pure-logic helper reverses the storage order; the scroll
    /// view's trailing anchor lands the user on the newest card on
    /// open. Maxim's quote: «самая свежая запись должна быть справа и
    /// с левой стороны самая старая».
    func testVisualOrderReversesNewestFirstStorage() {
        // Feed contract: newest-first. id=10 newest, id=1 oldest.
        let storage = (1...10).reversed().map { makeClipboardCard($0) }
        XCTAssertEqual(storage.first?.id, "clipboard-10", "precondition: storage is newest-first")
        XCTAssertEqual(storage.last?.id, "clipboard-1", "precondition: oldest is at the tail")

        let visual = HistoryStripRowLayout.visualOrder(storage)

        XCTAssertEqual(visual.first?.id, "clipboard-1", "leftmost = oldest")
        XCTAssertEqual(visual.last?.id, "clipboard-10", "rightmost = newest")
        XCTAssertEqual(visual.count, storage.count, "no entries dropped")
    }

    func testVisualOrderEmptyArrayIsEmpty() {
        XCTAssertTrue(HistoryStripRowLayout.visualOrder([]).isEmpty)
    }

    func testVisualOrderSingleEntryIsUnchanged() {
        let card = makeClipboardCard(42)
        let visual = HistoryStripRowLayout.visualOrder([card])
        XCTAssertEqual(visual.map(\.id), [card.id])
    }

    // MARK: - Smoke render tests

    /// The new horizontal row view must host without crashing across
    /// the boundary card counts: empty, single, exactly 5, and the
    /// feed cap of 10.
    func testRowViewWithTenCardsRendersWithoutCrashing() {
        let cards = (1...10).map { makeClipboardCard($0) }
        let view = HistoryStripCardsRowView(
            cards: cards,
            assetsDirectory: makeTempDir(),
            onCopy: { _ in },
            onExpand: { _ in }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 160)
        XCTAssertNotNil(hosting.view)
    }

    func testRowViewWithSingleCardRendersWithoutCrashing() {
        let cards = [makeClipboardCard(1)]
        let view = HistoryStripCardsRowView(
            cards: cards,
            assetsDirectory: makeTempDir(),
            onCopy: { _ in },
            onExpand: { _ in }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 160)
        XCTAssertNotNil(hosting.view)
    }

    func testRowViewWithExactlyFiveCardsRendersWithoutCrashing() {
        let cards = (1...5).map { makeClipboardCard($0) }
        let view = HistoryStripCardsRowView(
            cards: cards,
            assetsDirectory: makeTempDir(),
            onCopy: { _ in },
            onExpand: { _ in }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 160)
        XCTAssertNotNil(hosting.view)
    }
}
