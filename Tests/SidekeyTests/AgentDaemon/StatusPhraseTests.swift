import XCTest
@testable import Sidekey

final class StatusPhraseTests: XCTestCase {
    func testFirstSentenceCutsAtFirstTerminator() {
        XCTAssertEqual(
            StatusPhrase.firstSentence("I'll inspect the project layout first. Then I run tests."),
            "I'll inspect the project layout first."
        )
    }

    func testFirstSentenceTakesFirstLineWhenNoTerminator() {
        XCTAssertEqual(
            StatusPhrase.firstSentence("Читаю оба файла\nи параллельно запускаю тесты"),
            "Читаю оба файла"
        )
    }

    func testFirstSentenceStripsMarkdownMarkers() {
        XCTAssertEqual(
            StatusPhrase.firstSentence("**Фаза 1 — Root Cause.** Сначала запущу тесты."),
            "Фаза 1 — Root Cause."
        )
    }

    func testFirstSentenceClipsLongTextWithEllipsis() {
        let long = String(repeating: "a", count: 100)
        let result = StatusPhrase.firstSentence(long)
        XCTAssertEqual(result.count, 81) // 80 chars + "…"
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testFirstSentenceEmptyAndWhitespaceReturnsEmpty() {
        XCTAssertEqual(StatusPhrase.firstSentence(""), "")
        XCTAssertEqual(StatusPhrase.firstSentence("  \n  "), "")
    }

    func testClipShortStringUnchanged() {
        XCTAssertEqual(StatusPhrase.clip("pytest", limit: 30), "pytest")
    }
}
