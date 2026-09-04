import XCTest
@testable import Sidekey

final class ClaudeModelCatalogReaderTests: XCTestCase {
    func testHighestVersionPerFamilyAsAliases() {
        let tokens = [
            "claude-opus-4-5", "claude-opus-4-8", "claude-opus-4-6",
            "claude-sonnet-4-5", "claude-sonnet-4-6",
            "claude-haiku-4-5",
        ]
        let cat = ClaudeModelCatalogReader.build(tokens: tokens, current: "claude-opus-4-7")
        // Values are ALIASES (always-latest pointers), labels carry the resolved version.
        XCTAssertEqual(cat.options.map { $0.token }, ["opus", "sonnet", "haiku"])
        XCTAssertEqual(cat.options.map { $0.label }, ["Opus 4.8", "Sonnet 4.6", "Haiku 4.5"])
        XCTAssertEqual(cat.defaultAlias, "opus")
    }

    /// A date-form token (claude-opus-4-20250514) must NOT outrank 4-8.
    func testIgnoresDateFormTokens() {
        let cat = ClaudeModelCatalogReader.build(
            tokens: ["claude-opus-4-8", "claude-opus-4-20250514"], current: nil)
        XCTAssertEqual(cat.options.first?.label, "Opus 4.8")
    }

    func testDefaultAliasFallsBackToFirstOptionWhenNoCurrent() {
        let cat = ClaudeModelCatalogReader.build(tokens: ["claude-sonnet-4-6"], current: nil)
        XCTAssertEqual(cat.defaultAlias, "sonnet")
    }

    func testEmptyWhenNoTokens() {
        let cat = ClaudeModelCatalogReader.build(tokens: [], current: nil)
        XCTAssertTrue(cat.options.isEmpty)
        XCTAssertNil(cat.defaultAlias)
    }

    func testReadNilBinaryYieldsEmpty() {
        let cat = ClaudeModelCatalogReader(scanTokens: { _ in ["claude-opus-4-8"] },
                                           currentModel: { nil }).read(binary: nil)
        XCTAssertTrue(cat.options.isEmpty)
    }

    func testReadScansProvidedBinary() {
        let reader = ClaudeModelCatalogReader(
            scanTokens: { _ in ["claude-opus-4-8", "claude-haiku-4-5"] },
            currentModel: { "claude-haiku-4-5" })
        let cat = reader.read(binary: URL(fileURLWithPath: "/x/claude"))
        XCTAssertEqual(cat.options.map { $0.token }, ["opus", "haiku"])
        XCTAssertEqual(cat.defaultAlias, "haiku")
    }
}
