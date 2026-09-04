import XCTest

@MainActor
final class IslandVocabularyEditorPanelTests: XCTestCase {
    func testVocabularyEditorHasNoBackButtonAndHintsEnterSubmit() throws {
        let source = try vocabularyEditorSource()

        XCTAssertFalse(source.contains("IslandVocabularyBackButton"))
        XCTAssertFalse(source.contains("onBack"))
        XCTAssertTrue(source.contains("Search or add, press Enter"))
    }

    func testVocabularyInputCursorIsVerticallyCentered() throws {
        let source = try vocabularyEditorSource()

        XCTAssertTrue(source.contains("drawInsertionPoint"))
        XCTAssertTrue(source.contains("bounds.midY"))
        XCTAssertTrue(source.contains("inputTextVerticalInset"))
    }

    private func vocabularyEditorSource() throws -> String {
        let root = try projectRoot()
        let url = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("DynamicIsland")
            .appendingPathComponent("IslandVocabularyEditorPanel.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "IslandVocabularyEditorPanelTests", code: 1)
    }
}
