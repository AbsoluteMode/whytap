import XCTest
@testable import Sidekey

@MainActor
final class NativeAgentFinalAnswerTests: XCTestCase {
    private func arguments(_ answer: String = "The event happened on Monday.") -> [String: Any] {
        ["status": "answered", "answer": answer, "sources": [], "actions": []]
    }

    func testRequiredClosedShapeRejectsMissingUnknownAndWronglyTypedFields() {
        for field in ["answer", "status", "sources", "actions"] {
            var value = arguments(); value.removeValue(forKey: field)
            XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value), field)
            value = arguments(); value[field] = NSNull()
            XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value), field)
        }
        var value = arguments(); value["extra"] = "SYNTHETIC_PRIVATE_CONTENT"
        XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value)) { error in
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE_CONTENT"))
        }
        value = arguments(); value["status"] = "success"
        XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value))
        value = arguments(); value["sources"] = ["https://example.com"]
        XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value))
    }

    func testSourceDumpAndEmptyAnswerCannotMasqueradeAsACompletedAnswer() {
        for answer in ["", "  \n", "\u{200B}", "https://example.com", "HTTPS://example.com", "Sources:\n- https://example.com/a\n- https://example.com/b",
                       "Ссылки для проверки:\n- https://example.com/a\n- https://example.com/b",
                       "See links below", "Смотри ссылки", "[Article](https://example.com/a)",
                       "Sources:\n1. https://example.com/a\n2. https://example.com/b"] {
            var value = arguments(answer)
            value["sources"] = [["url": "https://example.com/a", "title": "Source"]]
            XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value), answer)
        }
        for answer in ["42", "4.2", "Да.", "No.", "👍", "Sources", "Ссылки", "The sources do not confirm the statement.",
                       "Yes, it happened on Monday. [Source](https://example.com/a)"] {
            XCTAssertNoThrow(try NativeAgentFinalAnswer(arguments: arguments(answer)), answer)
        }
    }

    func testUnverifiedAndClarificationStatusStayVisibleEvenWithOptimisticProse() throws {
        var value = arguments("The available evidence is inconclusive.")
        value["status"] = "unverified"
        let unverified = try NativeAgentFinalAnswer(arguments: value)
        XCTAssertEqual(unverified.visibleText, "Couldn’t verify\n\nThe available evidence is inconclusive.")
        value["status"] = "needs_clarification"; value["answer"] = "Which year do you mean?"
        XCTAssertEqual(try NativeAgentFinalAnswer(arguments: value).visibleText, "Clarification needed\n\nWhich year do you mean?")
    }

    func testTypedCardsPreserveOrderAndDeduplicateWithoutOpeningAnything() throws {
        var value = arguments()
        value["sources"] = [["title": " Source ", "url": "https://example.com"], ["title": "Duplicate", "url": "https://example.com/"]]
        value["actions"] = [["type": "path", "path": "/tmp/My Project", "description": "Folder"],
                            ["type": "copy", "text": "let x = 42", "description": "Code"]]
        let final = try NativeAgentFinalAnswer(arguments: value)
        XCTAssertEqual(final.actions.items.map(\.insertText), ["https://example.com", "/tmp/My Project", "let x = 42"])
        XCTAssertEqual(final.actions.items.first?.description, "Source")
        XCTAssertNil(final.actions.items.last?.openTarget)
    }

    func testInvalidCardsRejectTheWholeAnswerRatherThanSilentlyDroppingItems() {
        for source in [["title": "Source", "url": "javascript:alert(1)"], ["title": " ", "url": "https://example.com"],
                       ["title": "Source", "url": "https://user:secret@example.com"], ["title": "Source", "url": "https://"],
                       ["title": "Source", "url": "https://example.com", "extra": "value"]] {
            var value = arguments(); value["sources"] = [source]
            XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value))
        }
        for action in [["type": "path", "path": "relative/file", "description": "Folder"],
                       ["type": "path", "path": "/tmp/line\nbreak", "description": "Folder"],
                       ["type": "path", "path": "//remote/share", "description": "Folder"],
                       ["type": "copy", "text": " ", "description": "Copy"],
                       ["type": "copy", "text": "example"],
                       ["type": "command", "text": "echo fail", "description": "Run"]] {
            var value = arguments(); value["actions"] = [action]
            XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value))
        }
    }

    func testLimitsRejectOversizedObjectsBeforeUIBlockTruncation() {
        XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: arguments(String(repeating: "a", count: 32_001))))
        var value = arguments()
        value["sources"] = (0..<21).map { ["url": "https://example.com/\($0)", "title": "Source"] }
        XCTAssertThrowsError(try NativeAgentFinalAnswer(arguments: value))
    }

    func testStrictCatalogKeepsOptionalArgumentsNullableAndActionPolicyIntact() throws {
        let tools = NativeAgentTools.structuredDefinitions(allowActions: false)
        XCTAssertFalse(tools.contains { ["write_file", "run_command", "show_actions"].contains($0["name"] as? String ?? "") })
        XCTAssertTrue(tools.allSatisfy { $0["strict"] as? Bool == true })
        for tool in tools {
            let schema = try XCTUnwrap(tool["parameters"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys))
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }
        let read = try XCTUnwrap(tools.first { $0["name"] as? String == "read_file" }?["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(read["properties"] as? [String: [String: Any]])
        let offset = try XCTUnwrap(properties["offset"]?["anyOf"] as? [[String: Any]])
        XCTAssertEqual(offset.last?["type"] as? String, "null")
        XCTAssertNil(offset.first?["minimum"])
        XCTAssertEqual(properties["path"]?["type"] as? String, "string")
        XCTAssertTrue(NativeAgentTools.structuredDefinitions(allowActions: true).contains { $0["name"] as? String == "write_file" })
    }
}
