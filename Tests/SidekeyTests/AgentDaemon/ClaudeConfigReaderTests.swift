import XCTest
@testable import Sidekey

final class ClaudeConfigReaderTests: XCTestCase {
    func testParsesCurrentModelAndHighestPerFamily() {
        let json = """
        {"model":"claude-opus-4-7","a":"claude-sonnet-4-5","b":"claude-sonnet-4-6","c":"claude-haiku-4-5","d":"claude-opus-4-6"}
        """
        let s = ClaudeConfigReader.parse(json)
        XCTAssertEqual(s.currentModel, "claude-opus-4-7")
        XCTAssertEqual(s.models.map { $0.token }, ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5"])
        XCTAssertEqual(s.models.first?.label, "Opus 4.7")
        XCTAssertEqual(s.models.first(where: { $0.token == "claude-sonnet-4-6" })?.label, "Sonnet 4.6")
    }

    func testCurrentIncludedEvenIfNotFamilyMax() {
        let json = #"{"model":"claude-opus-4-6","a":"claude-opus-4-7"}"#
        let s = ClaudeConfigReader.parse(json)
        XCTAssertEqual(s.currentModel, "claude-opus-4-6")
        XCTAssertTrue(s.models.contains { $0.token == "claude-opus-4-6" })
        XCTAssertTrue(s.models.contains { $0.token == "claude-opus-4-7" })
    }

    func testEmptyWhenNoModels() {
        let s = ClaudeConfigReader.parse("{}")
        XCTAssertNil(s.currentModel)
        XCTAssertTrue(s.models.isEmpty)
    }
}
