import Foundation
import XCTest
@testable import Sidekey

@MainActor
final class UsefulLinksSelectionStateTests: XCTestCase {
    private static let itemA = ActionItem.link(
        url: URL(string: "https://www.notion.so/page-a")!,
        description: "A",
        provider: "notion"
    )
    private static let itemB = ActionItem.link(
        url: URL(string: "https://linear.app/team/issue/B")!,
        description: "B",
        provider: "linear"
    )
    private static let itemC = ActionItem.link(
        url: URL(string: "https://github.com/x/c")!,
        description: "C",
        provider: "github"
    )
    private static let copyItem = ActionItem.copy(text: "echo hi", description: "Run")
    private static let pathItem = ActionItem.path(path: "/tmp/report.md", description: "Report")

    // MARK: - Initial state

    func testInitialStateIsEmpty() {
        let state = UsefulLinksSelectionState()

        XCTAssertEqual(state.items.count, 0)
        XCTAssertNil(state.selectedItem)
        // No selection while empty — the chip and hotkey controller use
        // `selectedItem == nil` as the "don't render / don't register"
        // signal.
        XCTAssertEqual(state.currentIndex, 0)
    }

    func testApplyItemsSetsIndexToZero() {
        let state = UsefulLinksSelectionState()

        state.apply(items: [Self.itemA, Self.itemB, Self.itemC])

        XCTAssertEqual(state.items.count, 3)
        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.selectedItem?.description, "A")
    }

    func testApplyEmptyItemsClearsSelection() {
        // When the response panel transitions away from a useful_actions
        // block (next turn, panel close), `apply(items: [])` resets so
        // the chip vanishes and the hotkey controller's "count" reads 0.
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA, Self.itemB])

        state.apply(items: [])

        XCTAssertEqual(state.items.count, 0)
        XCTAssertNil(state.selectedItem)
        XCTAssertEqual(state.currentIndex, 0)
    }

    // MARK: - Navigation

    func testSelectNextAdvancesIndex() {
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA, Self.itemB, Self.itemC])

        state.selectNext()

        XCTAssertEqual(state.currentIndex, 1)
        XCTAssertEqual(state.selectedItem?.description, "B")
    }

    func testSelectNextClampsAtLastIndex() {
        // Spec: stop at last, no wrap. The first ↓ past the bottom is
        // a no-op so the chip doesn't teleport back to the top.
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA, Self.itemB])

        state.selectNext()
        state.selectNext()
        state.selectNext()

        XCTAssertEqual(state.currentIndex, 1)
        XCTAssertEqual(state.selectedItem?.description, "B")
    }

    func testSelectPreviousReducesIndex() {
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA, Self.itemB, Self.itemC])
        state.selectNext()
        state.selectNext()
        XCTAssertEqual(state.currentIndex, 2)

        state.selectPrevious()

        XCTAssertEqual(state.currentIndex, 1)
        XCTAssertEqual(state.selectedItem?.description, "B")
    }

    func testSelectPreviousClampsAtZero() {
        // Spec: stop at first, no wrap. Repeated ↑ at the top is a no-op.
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA, Self.itemB])

        state.selectPrevious()
        state.selectPrevious()

        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.selectedItem?.description, "A")
    }

    func testSelectNextOnEmptyStateIsNoOp() {
        let state = UsefulLinksSelectionState()

        state.selectNext()

        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertNil(state.selectedItem)
    }

    func testSelectPreviousOnEmptyStateIsNoOp() {
        let state = UsefulLinksSelectionState()

        state.selectPrevious()

        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertNil(state.selectedItem)
    }

    func testSelectNextWithSingleItemIsNoOp() {
        // count == 1 — `selectNext()` is a no-op so the chip stays
        // anchored to the only item.
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA])

        state.selectNext()
        state.selectNext()

        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.selectedItem?.description, "A")
    }

    func testSelectNextCanReachLastIndexBeyondFirstThreeRows() {
        let state = UsefulLinksSelectionState()
        state.apply(items: Self.items(count: 10))

        for _ in 0..<12 {
            state.selectNext()
        }

        XCTAssertEqual(state.items.count, 10)
        XCTAssertEqual(state.currentIndex, 9)
        XCTAssertEqual(state.selectedItem?.description, "Link 10")
    }

    // MARK: - Re-apply behaviour

    func testApplyItemsAlwaysResetsIndexToZero() {
        // Each fresh useful_actions block restarts selection from the top.
        // The first item is the highest-priority one per the SSE contract.
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA, Self.itemB, Self.itemC])
        state.selectNext()
        state.selectNext()
        XCTAssertEqual(state.currentIndex, 2)

        state.apply(items: [Self.itemA, Self.itemB])

        XCTAssertEqual(state.currentIndex, 0)
        XCTAssertEqual(state.selectedItem?.description, "A")
    }

    // MARK: - Per-item action set (open availability)

    func testSelectedItemSupportsOpenForLinkAndPath() {
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.itemA, Self.pathItem])

        // Link item selected first — supports open.
        XCTAssertTrue(state.selectedItemSupportsOpen)

        state.selectNext()
        // Path item — also supports open.
        XCTAssertTrue(state.selectedItemSupportsOpen)
    }

    func testSelectedItemDoesNotSupportOpenForCopy() {
        let state = UsefulLinksSelectionState()
        state.apply(items: [Self.copyItem, Self.itemA])

        // Copy item selected first — insert only, no open.
        XCTAssertFalse(state.selectedItemSupportsOpen)

        state.selectNext()
        // Moving onto the link item re-enables open.
        XCTAssertTrue(state.selectedItemSupportsOpen)
    }

    func testSelectedItemSupportsOpenIsFalseWhenEmpty() {
        let state = UsefulLinksSelectionState()

        XCTAssertFalse(state.selectedItemSupportsOpen)
    }

    // MARK: - Legacy link bridge

    func testApplyLinksFoldsIntoLinkItems() {
        // The legacy sync path still calls apply(links:); it folds into
        // .link items so callers that read `items` / `links` agree.
        let state = UsefulLinksSelectionState()
        let link = UsefulLink(
            url: URL(string: "https://example.com")!,
            description: "Example",
            provider: nil
        )

        state.apply(links: [link])

        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.selectedItem, .link(url: link.url, description: "Example", provider: nil))
        // The derived `links` view exposes the same single link.
        XCTAssertEqual(state.links.map(\.url), [link.url])
        XCTAssertEqual(state.selectedLink?.description, "Example")
    }

    private static func items(count: Int) -> [ActionItem] {
        (1...count).map { index in
            .link(
                url: URL(string: "https://example\(index).com")!,
                description: "Link \(index)",
                provider: nil
            )
        }
    }
}
