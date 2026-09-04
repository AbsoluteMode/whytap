import Foundation
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class ActionsBlockTests: XCTestCase {
    // MARK: - Per-type chip presentation

    func testLinkChipPresentationOpensAndUsesProviderTitle() {
        let item = ActionItem.link(
            url: URL(string: "https://www.notion.so/page")!,
            description: "Notion page",
            provider: "notion"
        )
        let presentation = ActionChipPresentation(item: item)

        // A link's primary click opens it.
        XCTAssertEqual(presentation.primaryAction, .open)
        // Title is the link description.
        XCTAssertEqual(presentation.title, "Notion page")
        // Links route to the rich favicon/provider chip, so they don't carry an
        // SF Symbol of their own.
        XCTAssertNil(presentation.symbolName)
        XCTAssertTrue(presentation.isLink)
    }

    func testPathChipPresentationOpensAndShowsBasename() {
        let item = ActionItem.path(
            path: "/Users/maxim/Downloads/Hammerspoon.app",
            description: nil
        )
        let presentation = ActionChipPresentation(item: item)

        // A path's primary click opens the file (Finder-style).
        XCTAssertEqual(presentation.primaryAction, .open)
        // With no description the title falls back to the path's last component.
        XCTAssertEqual(presentation.title, "Hammerspoon.app")
        // Paths render a file icon.
        XCTAssertEqual(presentation.symbolName, "doc")
        XCTAssertFalse(presentation.isLink)
    }

    func testPathChipPrefersDescriptionOverBasename() {
        let item = ActionItem.path(
            path: "/tmp/report.md",
            description: "Quarterly report"
        )
        let presentation = ActionChipPresentation(item: item)

        XCTAssertEqual(presentation.title, "Quarterly report")
    }

    func testCopyChipPresentationInsertsAndPreviewsText() {
        let item = ActionItem.copy(
            text: "/bin/bash -c \"$(curl -fsSL https://example.com/install.sh)\"",
            description: nil
        )
        let presentation = ActionChipPresentation(item: item)

        // Copy's primary click inserts (there is no open).
        XCTAssertEqual(presentation.primaryAction, .insert)
        // With no description the title falls back to a single-line text
        // preview (the raw command).
        XCTAssertEqual(presentation.title, item.insertText)
        // Copy renders a text/snippet icon.
        XCTAssertEqual(presentation.symbolName, "text.alignleft")
        XCTAssertFalse(presentation.isLink)
    }

    func testCopyChipPrefersDescriptionOverTextPreview() {
        let item = ActionItem.copy(text: "echo hi", description: "Install command")
        let presentation = ActionChipPresentation(item: item)

        XCTAssertEqual(presentation.title, "Install command")
    }

    // MARK: - Routing

    func testLatestUsefulActionsPicksTheLastActionsBlock() {
        let first = UsefulActionsBlock(items: [.copy(text: "first", description: nil)])
        let second = UsefulActionsBlock(items: [.copy(text: "second", description: nil)])
        let blocks: [UIBlock] = [
            .usefulActions(first),
            .textAnswer(TextAnswerBlock(body: "hi")),
            .usefulActions(second)
        ]

        let resolved = IslandAgentAnswerPanelView.latestUsefulActions(in: blocks)

        XCTAssertEqual(resolved?.items, second.items)
    }

    func testLatestUsefulActionsReturnsNilWithoutAnActionsBlock() {
        let blocks: [UIBlock] = [.textAnswer(TextAnswerBlock(body: "hi"))]

        XCTAssertNil(IslandAgentAnswerPanelView.latestUsefulActions(in: blocks))
    }

    // MARK: - Block renderer registry routing

    func testRegistryRoutesUsefulActionsToActionsBlockView() {
        let block = UIBlock.usefulActions(
            UsefulActionsBlock(items: [.copy(text: "x", description: nil)])
        )

        XCTAssertEqual(
            BlockRendererRegistry.rendererTypeName(for: block),
            String(describing: ActionsBlockView.self)
        )
    }

    // MARK: - Smoke render

    func testActionsBlockViewRendersMixedItemsWithoutCrashing() {
        let block = UsefulActionsBlock(items: [
            .link(url: URL(string: "https://brew.sh")!, description: "Homebrew", provider: nil),
            .path(path: "/Users/maxim/Downloads/Hammerspoon.app", description: "Hammerspoon"),
            .copy(text: "brew install hammerspoon", description: "Install command")
        ])
        let view = ActionsBlockView(block: block)
        let hosting = NSHostingController(rootView: view)

        XCTAssertNotNil(hosting.view)
    }
}
