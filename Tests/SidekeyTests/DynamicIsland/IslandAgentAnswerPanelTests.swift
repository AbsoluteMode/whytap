import XCTest
@testable import Sidekey

@MainActor
final class IslandAgentAnswerPanelTests: XCTestCase {
    func testLatestUsefulLinksBlockWins() {
        // Two useful_links blocks in one block list — the panel surfaces
        // the LAST one so a follow-up turn's links replace an earlier set
        // (mirrors the legacy panel's "first/last wins" resolution but
        // scoped to a single render pass).
        let a = UsefulLinksBlock(links: [
            UsefulLink(
                url: URL(string: "https://www.notion.so/page-a")!,
                description: "A",
                provider: "notion"
            )
        ])
        let b = UsefulLinksBlock(links: [
            UsefulLink(
                url: URL(string: "https://linear.app/team/issue/B")!,
                description: "B",
                provider: "linear"
            ),
            UsefulLink(
                url: URL(string: "https://github.com/x/c")!,
                description: "C",
                provider: "github"
            )
        ])
        let blocks: [UIBlock] = [
            .usefulLinks(a),
            .textAnswer(TextAnswerBlock(title: "t", body: "b")),
            .usefulLinks(b)
        ]
        XCTAssertEqual(IslandAgentAnswerPanelView.latestUsefulLinks(in: blocks), b)
    }

    func testLatestUsefulLinksReturnsNilWhenNoLinksBlock() {
        let blocks: [UIBlock] = [
            .textAnswer(TextAnswerBlock(title: "t", body: "b"))
        ]
        XCTAssertNil(IslandAgentAnswerPanelView.latestUsefulLinks(in: blocks))
    }
}
