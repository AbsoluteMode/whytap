import XCTest
@testable import Sidekey

/// Contract for the structured-protocol parser. Tasks must come out as typed
/// objects with split assignee/deadline + stable ids — the foundation for the
/// future "push task to tracker" action.
final class MeetingProtocolParserTests: XCTestCase {

    private let sample = """
    <!-- protocol:v1 -->
    # Weekly sync

    Quick alignment on the Q3 launch and open risks.

    ## Tasks
    - Ship the onboarding PR — Maxim — Fri Jun 13
      - needs design review first
    - Draft the pricing doc — Anna
    - Book the venue

    ## Decisions
    - Go with Paddle for billing
      - revisit fees in Q4

    ## Other
    - Do we need SOC2 this year?
    """

    func test_returns_nil_without_marker() {
        let md = "# Weekly sync\n\n## Tasks\n- something"
        XCTAssertNil(MeetingProtocolParser.parse(md))
    }

    /// Backend emits the H1 first and the marker after it (so old clients still
    /// extract the title). The parser must detect the marker anywhere + parse.
    func test_marker_after_h1_still_parses() {
        let md = """
        # Synced sync

        <!-- protocol:v1 -->

        Quick desc.

        ## Tasks
        - Do it — Max — Fri

        ## Decisions

        ## Other
        """
        guard let p = MeetingProtocolParser.parse(md) else { return XCTFail("parse") }
        XCTAssertEqual(p.name, "Synced sync")
        XCTAssertEqual(p.description, "Quick desc.")
        XCTAssertEqual(p.tasks.first?.assignee, "Max")
        XCTAssertEqual(p.tasks.first?.deadline, "Fri")
    }

    func test_parses_name_and_description() {
        let p = MeetingProtocolParser.parse(sample)
        XCTAssertEqual(p?.name, "Weekly sync")
        XCTAssertEqual(p?.description, "Quick alignment on the Q3 launch and open risks.")
    }

    func test_parses_tasks_with_split_fields_and_comment() {
        guard let p = MeetingProtocolParser.parse(sample) else { return XCTFail("parse") }
        XCTAssertEqual(p.tasks.count, 3)

        XCTAssertEqual(p.tasks[0].task, "Ship the onboarding PR")
        XCTAssertEqual(p.tasks[0].assignee, "Maxim")
        XCTAssertEqual(p.tasks[0].deadline, "Fri Jun 13")
        XCTAssertEqual(p.tasks[0].comment, "needs design review first")

        // Assignee only, no deadline.
        XCTAssertEqual(p.tasks[1].task, "Draft the pricing doc")
        XCTAssertEqual(p.tasks[1].assignee, "Anna")
        XCTAssertNil(p.tasks[1].deadline)
        XCTAssertNil(p.tasks[1].comment)

        // Task text only.
        XCTAssertEqual(p.tasks[2].task, "Book the venue")
        XCTAssertNil(p.tasks[2].assignee)
        XCTAssertNil(p.tasks[2].deadline)
    }

    func test_task_ids_are_stable_and_unique() {
        let a = MeetingProtocolParser.parse(sample)
        let b = MeetingProtocolParser.parse(sample)
        XCTAssertEqual(a?.tasks.map(\.id), b?.tasks.map(\.id), "ids deterministic across parses")
        let ids = Set(a?.tasks.map(\.id) ?? [])
        XCTAssertEqual(ids.count, a?.tasks.count, "ids unique within a note")
    }

    func test_parses_decisions_and_other() {
        guard let p = MeetingProtocolParser.parse(sample) else { return XCTFail("parse") }
        XCTAssertEqual(p.decisions.count, 1)
        XCTAssertEqual(p.decisions[0].text, "Go with Paddle for billing")
        XCTAssertEqual(p.decisions[0].comment, "revisit fees in Q4")

        XCTAssertEqual(p.other.count, 1)
        XCTAssertEqual(p.other[0].text, "Do we need SOC2 this year?")
        XCTAssertNil(p.other[0].comment)
    }

    /// Sections are keyed by order, so localized headers parse identically.
    func test_localized_headers_parse_by_order() {
        let ru = """
        <!-- protocol:v1 -->
        # Синк

        Краткая сверка.

        ## Задачи
        - Сделать PR — Максим — пятница

        ## Принятые решения
        - Берём Paddle

        ## Прочее
        - Нужен ли SOC2?
        """
        guard let p = MeetingProtocolParser.parse(ru) else { return XCTFail("parse") }
        XCTAssertEqual(p.tasks.first?.assignee, "Максим")
        XCTAssertEqual(p.tasks.first?.deadline, "пятница")
        XCTAssertEqual(p.decisions.first?.text, "Берём Paddle")
        XCTAssertEqual(p.other.first?.text, "Нужен ли SOC2?")
    }
}
