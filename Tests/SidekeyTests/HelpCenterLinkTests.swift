import XCTest
@testable import Sidekey

/// The Help Center link: one constant, reachable from the Help window, the
/// Settings footer and the island's tool search, next to (never replacing) the
/// whytap.ai website link. WHY: .project-docs/decisions/2026-11-26-help-center-link.md
@MainActor
final class HelpCenterLinkTests: XCTestCase {
    func testHelpCenterIsTheAskPageOnTheWebsite() {
        XCTAssertEqual(BuildConfig.helpCenterURL.absoluteString, "https://whytap.ai/help/")
        XCTAssertEqual(BuildConfig.helpCenterURL.host, BuildConfig.websiteURL.host)
        XCTAssertEqual(BuildConfig.websiteURL.absoluteString, "https://whytap.ai")
        XCTAssertEqual(HelpWindowContent.helpCenterURL, BuildConfig.helpCenterURL)
    }

    func testHelpToolRoutesToTheHelpCenterAndNeedsNoDrawer() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .help), .openHelpCenter)
        XCTAssertFalse(HoverSlotRouter.effect(for: .help).requiresExpansion)
        var opened = 0
        var actions = IslandActions.noOp
        actions.openHelpCenter = { opened += 1 }
        HoverSlotRouter.effect(for: .help).invoke(on: actions)
        XCTAssertEqual(opened, 1)
    }

    func testToolSearchFindsHelpByTitleAndByAskingAQuestion() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "help").first, .help)
        XCTAssertTrue(IslandHoverToolSearch.results(for: "ask question").contains(.help))
        XCTAssertTrue(IslandHoverToolSearch.results(for: "помощь").contains(.help))
    }

    func testHelpToolHasAnSFSymbolAndIsAnAction() {
        let info = HoverToolRegistry.info(for: .help)
        XCTAssertEqual(info.title, "Help")
        XCTAssertEqual(info.sfSymbol, "questionmark.circle")
        XCTAssertEqual(info.kind, .action)
    }

    func testHelpIsNotPinnedForExistingUsers() {
        XCTAssertFalse(HoverLayoutStore.defaultSlots.contains(.help))
    }
}
