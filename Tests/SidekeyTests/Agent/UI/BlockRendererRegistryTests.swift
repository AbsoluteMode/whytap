import XCTest
@testable import Sidekey

final class BlockRendererRegistryTests: XCTestCase {
    func testDispatchesEveryKindToExpectedRenderer() {
        let cases: [(block: UIBlock, renderer: String)] = [
            (.textAnswer(TextAnswerBlock(body: "Answer")), "TextAnswerView"),
            (.entityCard(EntityCardBlock(
                entityType: .calendarEvent,
                name: "Planning"
            )), "EntityCardView"),
            (.entityList(EntityListBlock(items: [
                EntityListBlock.Item(title: "Spec")
            ])), "EntityListView"),
            (.metricCard(MetricCardBlock(
                label: "Latency",
                value: "120",
                unit: "ms"
            )), "MetricCardView"),
            (.searchResults(SearchResultsBlock(results: [
                SearchResultsBlock.Result(title: "Sidekey")
            ])), "SearchResultsView"),
            (.stateEmpty(StateEmptyBlock(message: "No results")), "StateEmptyView"),
            (.stateError(StateErrorBlock(
                message: "Tool failed",
                code: "tool_failed",
                retryable: true
            )), "StateErrorView"),
            (.statePermission(StatePermissionBlock(
                provider: "slack",
                message: "Connect Slack"
            )), "StatePermissionView"),
            (.usefulLinks(UsefulLinksBlock(links: [
                UsefulLink(
                    url: URL(string: "https://example.com")!,
                    description: "Example"
                )
            ])), "UsefulLinksBlockView")
        ]

        for testCase in cases {
            XCTAssertEqual(
                BlockRendererRegistry.rendererTypeName(for: testCase.block),
                testCase.renderer
            )
            XCTAssertFalse(String(describing: type(of: BlockRendererRegistry.view(for: testCase.block))).isEmpty)
        }
    }
}

