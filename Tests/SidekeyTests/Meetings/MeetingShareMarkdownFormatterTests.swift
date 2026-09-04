import XCTest
@testable import Sidekey

final class MeetingShareMarkdownFormatterTests: XCTestCase {

    func test_formatStructuredProtocolAsCleanShareMarkdown() {
        let markdown = """
        <!-- protocol:v1 -->
        # Weekly sync

        Quick alignment on the Q3 launch.

        ## Tasks
        - Ship the onboarding PR — Maxim — Fri Jun 13
          - needs design review first
        - Book the venue

        ## Decisions
        - Go with Paddle for billing

        ## Other
        - Do we need SOC2 this year?
        """

        XCTAssertEqual(MeetingShareMarkdownFormatter.format(noteMarkdown: markdown), """
        # Weekly sync

        Quick alignment on the Q3 launch.

        ## Tasks
        - [ ] Ship the onboarding PR
          - Assignee: Maxim
          - Deadline: Fri Jun 13
          - Notes: needs design review first
        - [ ] Book the venue

        ## Decisions
        - Go with Paddle for billing

        ## Other
        - Do we need SOC2 this year?
        """)
    }

    func test_formatLegacyNoteSharesTrimmedMarkdownAsIs() {
        XCTAssertEqual(
            MeetingShareMarkdownFormatter.format(noteMarkdown: "\n\n# Freeform note\n\n- point\n\n"),
            "# Freeform note\n\n- point"
        )
    }
}
