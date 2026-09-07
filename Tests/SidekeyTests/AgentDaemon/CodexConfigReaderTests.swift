import XCTest
@testable import Sidekey

final class CodexConfigReaderTests: XCTestCase {
    func testParsesTopLevelKeys() {
        let toml = """
        model_reasoning_effort = "xhigh"
        model = "gpt-5.5"
        service_tier = "fast"
        """
        let s = CodexConfigReader.parse(toml)
        XCTAssertEqual(s.model, "gpt-5.5")
        XCTAssertEqual(s.serviceTier, "fast")
    }

    func testFirstOccurrenceWinsAndSectionsSkipped() {
        let toml = """
        model = "gpt-5.5"
        [profiles.other]
        model = "gpt-5.4"
        """
        XCTAssertEqual(CodexConfigReader.parse(toml).model, "gpt-5.5")
    }

    func testNestedProfileNeverBecomesGlobalModelOrSpeed() {
        let snapshot = CodexConfigReader.parse("""
        [profiles.other]
        model = "other-model"
        service_tier = "fast"
        """)
        XCTAssertNil(snapshot.model)
        XCTAssertNil(snapshot.serviceTier)
    }

    func testMissingKeysYieldNil() {
        let s = CodexConfigReader.parse("# just a comment\n")
        XCTAssertNil(s.model)
        XCTAssertNil(s.serviceTier)
    }
}
