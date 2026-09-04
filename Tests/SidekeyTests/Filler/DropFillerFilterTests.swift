import XCTest
@testable import Sidekey

final class DropFillerFilterTests: XCTestCase {
    func testEmptyTermsReturnsTextUnchanged() {
        XCTAssertEqual(DropFillerFilter.apply("привет", removing: []), "привет")
    }
    func testTermNotPresentReturnsUnchanged() {
        XCTAssertEqual(DropFillerFilter.apply("это всё", removing: ["мм"]), "это всё")
    }
    func testSubstringInsideWordNotStripped() {
        XCTAssertEqual(DropFillerFilter.apply("Программа работает", removing: ["мм"]), "Программа работает")
    }
    func testCommaSpacedFillerInMiddle() {
        XCTAssertEqual(DropFillerFilter.apply("Привет, мм, как дела?", removing: ["мм"]), "Привет, как дела?")
    }
    func testFillerAtSentenceStartCapitalizes() {
        XCTAssertEqual(DropFillerFilter.apply("мм, ладно.", removing: ["мм"]), "Ладно.")
    }
    func testFillerBeforePeriodKeepsLowercase() {
        XCTAssertEqual(DropFillerFilter.apply("текст ааа.", removing: ["ааа"]), "текст.")
    }
    func testFillerBetweenWordsCollapsesSpace() {
        XCTAssertEqual(DropFillerFilter.apply("Ну мм давай", removing: ["мм"]), "Ну давай")
    }
    func testCaseInsensitiveMultipleOccurrences() {
        XCTAssertEqual(DropFillerFilter.apply("ЭЭ что ээ там", removing: ["ээ"]), "Что там")
    }
    func testHyphenatedTerm() {
        XCTAssertEqual(DropFillerFilter.apply("э-э понятно", removing: ["э-э"]), "Понятно")
    }
    func testWhitespaceOnlyTermsIgnored() {
        XCTAssertEqual(DropFillerFilter.apply("привет мир", removing: ["   "]), "привет мир")
    }
    func testTrailingCommaOrphanRemoved() {
        XCTAssertEqual(DropFillerFilter.apply("текст, мм", removing: ["мм"]), "текст")
    }
    func testTrailingPeriodKept() {
        XCTAssertEqual(DropFillerFilter.apply("вот так мм.", removing: ["мм"]), "вот так.")
    }
    func testMultipleFillersInARow() {
        XCTAssertEqual(DropFillerFilter.apply("мм мм привет", removing: ["мм"]), "Привет")
    }
    func testFillerSurroundedByCommas() {
        XCTAssertEqual(DropFillerFilter.apply("ну, мм, и всё", removing: ["мм"]), "ну, и всё")
    }
}
