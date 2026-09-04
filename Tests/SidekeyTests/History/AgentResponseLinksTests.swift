import XCTest
@testable import Sidekey

final class AgentResponseLinksTests: XCTestCase {
    func testExtractsBareHttpURL() {
        let md = "Check out https://example.com for details."
        let links = AgentResponseLinks.extract(from: md)
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testExtractsBareHttpsURLWithPath() {
        let md = "Docs at https://example.com/path/to/page?q=1#anchor."
        let links = AgentResponseLinks.extract(from: md)
        XCTAssertEqual(
            links,
            [URL(string: "https://example.com/path/to/page?q=1#anchor")!]
        )
    }

    func testExtractsMarkdownStyleLink() {
        let md = "See [the docs](https://example.com/docs) for more."
        let links = AgentResponseLinks.extract(from: md)
        XCTAssertEqual(links, [URL(string: "https://example.com/docs")!])
    }

    func testDeduplicatesEqualURLs() {
        let md = """
            First: https://example.com
            Second: https://example.com
            Third: [click](https://example.com)
            """
        let links = AgentResponseLinks.extract(from: md)
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testReturnsEmptyArrayWhenNoLinks() {
        let md = "Nothing here, just text."
        let links = AgentResponseLinks.extract(from: md)
        XCTAssertEqual(links, [])
    }

    func testIgnoresInvalidURLs() {
        let md = "Bad: htp://broken not://valid"
        let links = AgentResponseLinks.extract(from: md)
        XCTAssertEqual(links, [])
    }

    func testPreservesOrderOfFirstAppearance() {
        let md = """
            Visit https://b.example.com first.
            Then https://a.example.com second.
            Then again https://b.example.com.
            """
        let links = AgentResponseLinks.extract(from: md)
        XCTAssertEqual(
            links,
            [
                URL(string: "https://b.example.com")!,
                URL(string: "https://a.example.com")!,
            ]
        )
    }
}
