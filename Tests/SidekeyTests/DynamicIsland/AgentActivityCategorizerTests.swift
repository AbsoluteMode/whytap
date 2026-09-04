import XCTest
@testable import Sidekey

final class AgentActivityCategorizerTests: XCTestCase {
    func testToolLabelPassesThrough() {
        XCTAssertEqual(
            AgentActivityCategorizer.label(toolLabel: "searching the web", status: .thinking),
            "searching the web"
        )
    }

    func testEmptyOrNilLabelFallsBackByStatus() {
        XCTAssertEqual(AgentActivityCategorizer.label(toolLabel: nil, status: .transcribing), "transcribing…")
        XCTAssertEqual(AgentActivityCategorizer.label(toolLabel: "", status: .thinking), "thinking…")
        XCTAssertEqual(AgentActivityCategorizer.label(toolLabel: nil, status: .uploading), "sending…")
        XCTAssertEqual(AgentActivityCategorizer.label(toolLabel: nil, status: .ready), "working…")
    }
}
