import XCTest
@testable import Sidekey

final class NativeAgentAnswerArtifactsTests: XCTestCase {
    func testPlainSourceURLFromReportedAnswerBecomesAnAction() throws {
        let source = "https://www.espn.com/soccer/player/_/id/45843/lionel-messi"
        let block = try XCTUnwrap(NativeAgentAnswerArtifacts.collect(from: "Короткий ответ.\nИсточник: \(source)"))
        XCTAssertEqual(block.items.map(\.insertText), [source])
        XCTAssertEqual(block.items.first?.availableActions, [.insert, .open])
    }

    func testMarkdownLabelsAndPathsWithSpacesKeepAnswerOrder() throws {
        let answer = """
        [Документ](https://example.com/spec) и `/Users/test/My Project`.
        Файл: [Отчёт](/Users/test/My%20Project/report.pdf).
        Ещё: «~/Downloads/My Report.pdf» и /tmp/result.txt.
        """
        let items = try XCTUnwrap(NativeAgentAnswerArtifacts.collect(from: answer, homeDirectory: "/Users/test")).items
        XCTAssertEqual(items.map(\.insertText), ["https://example.com/spec", "/Users/test/My Project", "/Users/test/My Project/report.pdf", "/Users/test/Downloads/My Report.pdf", "/tmp/result.txt"])
        XCTAssertEqual(items.first?.description, "Документ")
    }

    func testExplicitMetadataWinsAndRepeatedSourcesDoNotConsumeTheLimit() throws {
        let url = URL(string: "https://example.com/source")!
        let explicit = ActionItem.link(url: url, description: "Проверенный источник", provider: "web")
        let text = String(repeating: url.absoluteString + "\n", count: 30) + "https://example.com/second"
        let items = try XCTUnwrap(NativeAgentAnswerArtifacts.collect(from: text, existing: .init(items: [explicit]))).items
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first, explicit)
        let merged = NativeAgentAnswerArtifacts.merging(.init(items: [explicit]), .init(items: [.link(url: url, description: "Other title", provider: nil)]))
        XCTAssertEqual(merged.items, [explicit])
    }

    func testOrdinaryCodeAndUnsupportedURLsDoNotCreateCards() throws {
        let answer = """
        ```bash
        curl https://example.com/api -o /tmp/output
        ```
        ```json
        {"url":"https://example.com/config","path":"/Users/test/file"}
        ```
        mailto:user@example.com javascript:alert(1) https://user:password@example.com
        """
        // The one-line shell command is an Insert card; its URL and path stay code.
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: answer)?.items,
                       [.copy(text: "curl https://example.com/api -o /tmp/output", description: nil)])
        XCTAssertNil(NativeAgentAnswerArtifacts.collect(from: "Обычный ответ без ссылок."))
    }

    func testPathOnlyFenceRemainsActionableAndResultsAreBounded() throws {
        let path = try XCTUnwrap(NativeAgentAnswerArtifacts.collect(from: "Папка:\n```\n/Users/test/My Project\n```"))
        XCTAssertEqual(path.items.map(\.insertText), ["/Users/test/My Project"])
        let urls = (0..<50).map { "https://example.com/\($0)" }.joined(separator: "\n")
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: urls)?.items.count, UsefulActionsBlock.maxItems)
        XCTAssertNil(NativeAgentAnswerArtifacts.collect(from: String(repeating: "a", count: 32_001) + " https://example.com/after-limit"))
    }

    func testInlineCodeAndEmphasisDoNotAlterURLTargets() throws {
        let url = "https://www.espn.com/nba/scoreboard"
        for text in ["Источник: `\(url)`", "Источник: **\(url)**", "Источник: _\(url)_", "Источник: ~~\(url)~~"] {
            XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: text)?.items.map(\.insertText), [url], text)
        }
        XCTAssertNil(NativeAgentAnswerArtifacts.collect(from: "Run `curl https://api.example.com/v1/x`"))
    }

    func testMarkdownURLsWithBalancedParenthesesKeepLabelAndTarget() throws {
        let url = "https://en.wikipedia.org/wiki/Swift_(programming_language)"
        let items = try XCTUnwrap(NativeAgentAnswerArtifacts.collect(from: "See [Swift](\(url)).")).items
        XCTAssertEqual(items.map(\.insertText), [url])
        XCTAssertEqual(items.first?.description, "Swift")
    }

    func testInlineCommandArgumentsAndUnclosedOrTildeCodeStayCode() {
        for text in ["`/usr/bin/python3 -m venv`", "`/Applications/Xcode.app --args -X`",
                     "```bash\nrm -rf /Users/test/tmp/build"] {
            XCTAssertNil(NativeAgentAnswerArtifacts.collect(from: text, homeDirectory: "/Users/test"), text)
        }
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: "~~~sh\ncat ~/.ssh/config\n~~~", homeDirectory: "/Users/test")?.items,
                       [.copy(text: "cat ~/.ssh/config", description: nil)], "A closed shell fence is a command, not a path")
    }

    func testRootURLSlashAndHostCaseDeduplicateWithoutMergingDifferentResourcePaths() throws {
        let explicit = ActionItem.link(url: URL(string: "https://ESPN.com")!, description: "ESPN", provider: nil)
        let items = try XCTUnwrap(NativeAgentAnswerArtifacts.collect(from: "https://espn.com/", existing: .init(items: [explicit]))).items
        XCTAssertEqual(items, [explicit])
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: "https://example.com/guide https://example.com/guide/")?.items.count, 2)
    }

    func testQuotedFileURLKeepsSpacesAndLiteralPercentEncodingInTheFilename() throws {
        let items = try XCTUnwrap(NativeAgentAnswerArtifacts.collect(from: "Файл: \"file:///Users/test/My%20Project/report%2520final.pdf\".")).items
        XCTAssertEqual(items.map(\.insertText), ["/Users/test/My Project/report%20final.pdf"])
    }
}
