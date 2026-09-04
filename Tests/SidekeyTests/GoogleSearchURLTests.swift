import XCTest
@testable import Sidekey

final class GoogleSearchURLTests: XCTestCase {
    func testASCIIQuery() {
        let url = GoogleSearchURL.make(query: "swift concurrency")
        XCTAssertEqual(url?.absoluteString, "https://www.google.com/search?q=swift%20concurrency")
    }

    func testCyrillicQuery() {
        let url = GoogleSearchURL.make(query: "как дела")
        XCTAssertEqual(
            url?.absoluteString,
            "https://www.google.com/search?q=%D0%BA%D0%B0%D0%BA%20%D0%B4%D0%B5%D0%BB%D0%B0"
        )
    }

    func testSpecialCharactersEncoded() {
        // URLComponents encodes & but leaves ? unencoded in the query value.
        // Both are valid percent-encoding for a query parameter; this test
        // documents actual URLComponents behaviour rather than hand-rolling.
        let url = GoogleSearchURL.make(query: "a & b ? c")
        XCTAssertEqual(url?.absoluteString, "https://www.google.com/search?q=a%20%26%20b%20?%20c")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(GoogleSearchURL.make(query: ""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(GoogleSearchURL.make(query: "   \n\t"))
    }

    func testTrimsSurroundingWhitespace() {
        let url = GoogleSearchURL.make(query: "  hello  ")
        XCTAssertEqual(url?.absoluteString, "https://www.google.com/search?q=hello")
    }
}
