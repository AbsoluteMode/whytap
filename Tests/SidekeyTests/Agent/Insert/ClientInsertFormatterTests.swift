import XCTest
@testable import Sidekey

final class ClientInsertFormatterTests: XCTestCase {
    private let formatter = ClientInsertFormatter()

    func testDetectsAppCategoryFromBundleID() {
        let cases: [(bundleID: String?, expected: AppCategory)] = [
            ("com.tinyspeck.slackmacgap", .slackFlavored),
            ("notion.id", .markdown),
            ("com.linear", .markdown),
            ("com.todesktop.230313mzl4w4u92", .markdown),
            ("com.microsoft.VSCode", .markdown),
            ("com.apple.mail", .plain),
            (nil, .plain)
        ]

        for testCase in cases {
            XCTAssertEqual(
                formatter.detect(from: testCase.bundleID),
                testCase.expected,
                testCase.bundleID ?? "nil"
            )
        }
    }

    func testEntityCardVariantsAreAppAwareAndAppendReplaceWhenEditableSelectionExists() {
        let cases: [VariantCase] = [
            VariantCase(
                name: "calendar event slack editable selection",
                block: calendarEventBlock,
                targetApp: .slackFlavored,
                isEditable: true,
                hasSelection: true,
                expectedIDs: [
                    "slack_link",
                    "url_only",
                    "title_only",
                    "markdown_link",
                    "full_plain_text",
                    "replace_selection"
                ],
                expectedPrimaryText: "<https://calendar.google.com/event|Planning>"
            ),
            VariantCase(
                name: "file markdown no selection",
                block: fileBlock,
                targetApp: .markdown,
                isEditable: true,
                hasSelection: false,
                expectedIDs: [
                    "markdown_link",
                    "url_only",
                    "title_only",
                    "full_plain_text"
                ],
                expectedPrimaryText: "[Spec](file:///tmp/spec.md)"
            ),
            VariantCase(
                name: "calendar event plain",
                block: calendarEventBlock,
                targetApp: .plain,
                isEditable: false,
                hasSelection: false,
                expectedIDs: [
                    "title_and_url",
                    "url_only",
                    "title_only",
                    "markdown_link",
                    "full_plain_text"
                ],
                expectedPrimaryText: "Planning - https://calendar.google.com/event"
            )
        ]

        assertVariantCases(cases)
    }

    func testTextAndListVariants() {
        let cases: [VariantCase] = [
            VariantCase(
                name: "text answer with replace",
                block: .textAnswer(TextAnswerBlock(title: "Answer", body: "Use the calendar link.")),
                targetApp: .plain,
                isEditable: true,
                hasSelection: true,
                expectedIDs: ["full_text", "title_only", "replace_selection"],
                expectedPrimaryText: "Use the calendar link."
            ),
            VariantCase(
                name: "entity list markdown",
                block: .entityList(EntityListBlock(
                    entityType: .file,
                    items: [
                        EntityListBlock.Item(
                            title: "Spec",
                            subtitle: "docs",
                            entityType: .file,
                            url: URL(string: "file:///tmp/spec.md")
                        )
                    ]
                )),
                targetApp: .markdown,
                isEditable: false,
                hasSelection: false,
                expectedIDs: [
                    "formatted_list",
                    "titles_only",
                    "urls_only",
                    "markdown_list",
                    "full_plain_text"
                ],
                expectedPrimaryText: "- [Spec](file:///tmp/spec.md) docs"
            ),
            VariantCase(
                name: "search results slack",
                block: .searchResults(SearchResultsBlock(results: [
                    SearchResultsBlock.Result(
                        title: "Sidekey",
                        snippet: "Docs",
                        url: URL(string: "https://sidekey.ai"),
                        sourceId: "s1"
                    )
                ])),
                targetApp: .slackFlavored,
                isEditable: false,
                hasSelection: false,
                expectedIDs: [
                    "formatted_results",
                    "titles_only",
                    "urls_only",
                    "markdown_list",
                    "full_plain_text"
                ],
                expectedPrimaryText: "- <https://sidekey.ai|Sidekey> Docs"
            )
        ]

        assertVariantCases(cases)
    }

    func testUsefulLinksVariantsMatchEntityListContract() {
        // Useful Links is a link-first block (description + URL pairs),
        // so its variant lineup mirrors entity list + search results:
        // formatted, urls-only, descriptions-only (analogue of titles-only),
        // markdown list, and a full plain-text fallback. The first
        // variant is the markdown-flavoured link list.
        let variants = formatter.variants(
            for: .usefulLinks(UsefulLinksBlock(links: [
                UsefulLink(
                    url: URL(string: "https://www.notion.so/page")!,
                    description: "Spec doc",
                    provider: "notion"
                ),
                UsefulLink(
                    url: URL(string: "https://linear.app/team/issue/T-1")!,
                    description: "Ticket T-1",
                    provider: "linear"
                )
            ])),
            targetApp: .markdown,
            isEditable: false,
            hasSelection: false
        )

        XCTAssertEqual(
            variants.map(\.id),
            [
                "formatted_links",
                "urls_only",
                "descriptions_only",
                "markdown_list",
                "full_plain_text"
            ]
        )
        XCTAssertEqual(
            variants.first?.text,
            "- [Spec doc](https://www.notion.so/page)\n- [Ticket T-1](https://linear.app/team/issue/T-1)"
        )
    }

    func testUsefulLinksEmptyBlockProducesNoVariants() {
        // Defensive: a degenerate block with zero links must not surface
        // an insert menu. Backend contract requires ≥1 link but the
        // formatter shouldn't crash if it ever sees zero.
        let variants = formatter.variants(
            for: .usefulLinks(UsefulLinksBlock(links: [])),
            targetApp: .plain,
            isEditable: false,
            hasSelection: false
        )

        XCTAssertTrue(variants.isEmpty)
    }

    func testMetricCardVariantsAndStateBlocks() {
        let metricVariants = formatter.variants(
            for: .metricCard(MetricCardBlock(
                title: "Latency",
                label: "p95",
                value: "120",
                unit: "ms",
                trend: "down"
            )),
            targetApp: .plain,
            isEditable: true,
            hasSelection: true
        )

        XCTAssertEqual(
            metricVariants.map(\.id),
            ["metric_summary", "value_only", "full_plain_text", "replace_selection"]
        )
        XCTAssertEqual(metricVariants.first?.text, "Latency: p95 120 ms")
        XCTAssertEqual(metricVariants.last?.actionType, .replace)

        XCTAssertTrue(formatter.variants(
            for: .stateError(StateErrorBlock(message: "Nope", retryable: false)),
            targetApp: .plain,
            isEditable: true,
            hasSelection: true
        ).isEmpty)
    }

    private func assertVariantCases(_ cases: [VariantCase]) {
        for testCase in cases {
            let variants = formatter.variants(
                for: testCase.block,
                targetApp: testCase.targetApp,
                isEditable: testCase.isEditable,
                hasSelection: testCase.hasSelection
            )

            XCTAssertEqual(variants.map(\.id), testCase.expectedIDs, testCase.name)
            XCTAssertEqual(variants.first?.text, testCase.expectedPrimaryText, testCase.name)
            XCTAssertEqual(variants.first?.actionType, .paste, testCase.name)
            if testCase.expectedIDs.contains("replace_selection") {
                XCTAssertEqual(variants.last?.label, "Replace selection", testCase.name)
                XCTAssertEqual(variants.last?.text, variants.first?.text, testCase.name)
                XCTAssertEqual(variants.last?.actionType, .replace, testCase.name)
            }
        }
    }

    private var calendarEventBlock: UIBlock {
        .entityCard(EntityCardBlock(
            entityType: .calendarEvent,
            id: "evt_1",
            name: "Planning",
            description: "Weekly planning",
            url: URL(string: "https://calendar.google.com/event")
        ))
    }

    private var fileBlock: UIBlock {
        .entityCard(EntityCardBlock(
            entityType: .file,
            id: "file_1",
            name: "Spec",
            description: "docs",
            url: URL(string: "file:///tmp/spec.md")
        ))
    }
}

private struct VariantCase {
    let name: String
    let block: UIBlock
    let targetApp: AppCategory
    let isEditable: Bool
    let hasSelection: Bool
    let expectedIDs: [String]
    let expectedPrimaryText: String
}
