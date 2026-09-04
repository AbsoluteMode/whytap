import XCTest
@testable import Sidekey

final class UIBlockTests: XCTestCase {
    func testDecodesTextAnswerBlock() throws {
        let block = try decode("""
        {
          "kind": "text.answer",
          "schemaVersion": 1,
          "title": "Answer",
          "body": "Use the calendar link.",
          "actions": [{"type": "copy", "label": "Copy", "payload": {"text": "Use the calendar link."}}],
          "sourceIds": ["s1"]
        }
        """)

        guard case .textAnswer(let payload) = block else {
            XCTFail("Expected textAnswer, got \(block)")
            return
        }
        XCTAssertEqual(payload.title, "Answer")
        XCTAssertEqual(payload.body, "Use the calendar link.")
        XCTAssertEqual(payload.actions?.first?.type, .copy)
        XCTAssertEqual(payload.sourceIds, ["s1"])
    }

    func testDecodesEntityCardBlock() throws {
        let block = try decode("""
        {
          "kind": "entity.card",
          "schemaVersion": 1,
          "entityType": "calendar_event",
          "id": "evt_1",
          "name": "Planning",
          "description": "Weekly planning",
          "url": "https://calendar.google.com/event",
          "attributes": {"attendees": 3}
        }
        """)

        guard case .entityCard(let payload) = block else {
            XCTFail("Expected entityCard, got \(block)")
            return
        }
        XCTAssertEqual(payload.entityType, .calendarEvent)
        XCTAssertEqual(payload.name, "Planning")
        XCTAssertEqual(payload.attributes?["attendees"], .int(3))
    }

    func testDecodesEntityListBlock() throws {
        let block = try decode("""
        {
          "kind": "entity.list",
          "schemaVersion": 1,
          "entityType": "file",
          "items": [
            {"id": "f1", "title": "Spec", "subtitle": "docs", "entityType": "file", "url": "file:///tmp/spec.md"}
          ]
        }
        """)

        guard case .entityList(let payload) = block else {
            XCTFail("Expected entityList, got \(block)")
            return
        }
        XCTAssertEqual(payload.entityType, .file)
        XCTAssertEqual(payload.items.first?.title, "Spec")
        XCTAssertEqual(payload.items.first?.entityType, .file)
    }

    func testDecodesMetricCardBlock() throws {
        let block = try decode("""
        {
          "kind": "metric.card",
          "schemaVersion": 1,
          "label": "Latency",
          "value": "120",
          "unit": "ms",
          "trend": "down"
        }
        """)

        guard case .metricCard(let payload) = block else {
            XCTFail("Expected metricCard, got \(block)")
            return
        }
        XCTAssertEqual(payload.label, "Latency")
        XCTAssertEqual(payload.unit, "ms")
    }

    func testDecodesSearchResultsBlock() throws {
        let block = try decode("""
        {
          "kind": "search.results",
          "schemaVersion": 1,
          "results": [
            {"title": "Sidekey", "snippet": "Docs", "url": "https://sidekey.ai", "sourceId": "s1"}
          ]
        }
        """)

        guard case .searchResults(let payload) = block else {
            XCTFail("Expected searchResults, got \(block)")
            return
        }
        XCTAssertEqual(payload.results.first?.title, "Sidekey")
        XCTAssertEqual(payload.results.first?.sourceId, "s1")
    }

    func testDecodesStateEmptyBlock() throws {
        let block = try decode("""
        {"kind":"state.empty","schemaVersion":1,"message":"No results"}
        """)

        guard case .stateEmpty(let payload) = block else {
            XCTFail("Expected stateEmpty, got \(block)")
            return
        }
        XCTAssertEqual(payload.message, "No results")
    }

    func testDecodesStateErrorBlock() throws {
        let block = try decode("""
        {"kind":"state.error","schemaVersion":1,"message":"Tool failed","code":"tool_failed","retryable":true}
        """)

        guard case .stateError(let payload) = block else {
            XCTFail("Expected stateError, got \(block)")
            return
        }
        XCTAssertEqual(payload.code, "tool_failed")
        XCTAssertTrue(payload.retryable)
    }

    func testDecodesStatePermissionBlock() throws {
        let block = try decode("""
        {
          "kind": "state.permission",
          "schemaVersion": 1,
          "provider": "slack",
          "message": "Connect Slack",
          "actions": [{"type": "connect", "label": "Connect", "url": "https://sidekey.ai/connect/slack", "variant": "primary"}]
        }
        """)

        guard case .statePermission(let payload) = block else {
            XCTFail("Expected statePermission, got \(block)")
            return
        }
        XCTAssertEqual(payload.provider, "slack")
        XCTAssertEqual(payload.actions?.first?.type, .connect)
    }

    func testUnknownEntityTypeDecodesAsUnknown() throws {
        let block = try decode("""
        {
          "kind": "entity.card",
          "schemaVersion": 1,
          "entityType": "linear_issue",
          "name": "Issue"
        }
        """)

        guard case .entityCard(let payload) = block else {
            XCTFail("Expected entityCard, got \(block)")
            return
        }
        XCTAssertEqual(payload.entityType, .unknown)
    }

    func testUnknownKindThrowsOutsideProd() {
        XCTAssertThrowsError(
            try decode("""
            {"kind":"future.block","schemaVersion":1}
            """, env: .beta)
        ) { error in
            XCTAssertEqual(error as? BlockDecodingError, .unknownKind(raw: "future.block"))
        }
    }

    func testUnknownKindFallsBackInProd() throws {
        let block = try decode("""
        {"kind":"future.block","schemaVersion":1}
        """, env: .prod)

        assertMalformedFallback(block)
    }

    func testSchemaVersionMismatchThrowsOutsideProd() {
        XCTAssertThrowsError(
            try decode("""
            {"kind":"text.answer","schemaVersion":2,"body":"future"}
            """, env: .beta)
        ) { error in
            XCTAssertEqual(
                error as? BlockDecodingError,
                .schemaVersionMismatch(expected: 1, actual: 2)
            )
        }
    }

    func testSchemaVersionMismatchFallsBackInProd() throws {
        let block = try decode("""
        {"kind":"text.answer","schemaVersion":2,"body":"future"}
        """, env: .prod)

        assertMalformedFallback(block)
    }

    // MARK: useful.actions block

    func testDecodesUsefulActionsBlockWithMixedItems() throws {
        let block = try decode("""
        {
          "kind": "useful.actions",
          "schemaVersion": 1,
          "items": [
            {"type": "link", "url": "https://brew.sh", "description": "Homebrew", "provider": "WEB"},
            {"type": "path", "path": "/Users/maxim/Downloads/Hammerspoon.app", "description": "Hammerspoon"},
            {"type": "copy", "text": "/bin/bash -c install"}
          ]
        }
        """)

        guard case .usefulActions(let payload) = block else {
            XCTFail("Expected usefulActions, got \(block)")
            return
        }
        XCTAssertEqual(payload.kind, .usefulActions)
        XCTAssertEqual(payload.items.count, 3)
        // Provider is normalised to lowercase, matching UsefulLink.
        XCTAssertEqual(
            payload.items[0],
            .link(url: URL(string: "https://brew.sh")!, description: "Homebrew", provider: "web")
        )
        XCTAssertEqual(
            payload.items[1],
            .path(path: "/Users/maxim/Downloads/Hammerspoon.app", description: "Hammerspoon")
        )
        XCTAssertEqual(payload.items[2], .copy(text: "/bin/bash -c install", description: nil))
    }

    func testUsefulActionsBlockCapsItemsAtMax() throws {
        let entries = (0..<(UsefulActionsBlock.maxItems + 5))
            .map { "{\"type\":\"copy\",\"text\":\"item-\($0)\"}" }
            .joined(separator: ",")
        let block = try decode("""
        {"kind":"useful.actions","schemaVersion":1,"items":[\(entries)]}
        """)

        guard case .usefulActions(let payload) = block else {
            XCTFail("Expected usefulActions, got \(block)")
            return
        }
        XCTAssertEqual(payload.items.count, UsefulActionsBlock.maxItems)
    }

    // MARK: ActionItem decoding + helpers

    func testActionItemDecodesLinkWithActionsAndInsertText() throws {
        let item = try decodeActionItem("""
        {"type":"link","url":"https://example.com/x","description":"Example"}
        """)

        XCTAssertEqual(item, .link(url: URL(string: "https://example.com/x")!, description: "Example", provider: nil))
        XCTAssertEqual(item.availableActions, [.insert, .open])
        XCTAssertEqual(item.insertText, "https://example.com/x")
        XCTAssertEqual(item.description, "Example")
    }

    func testActionItemDecodesPathWithActionsAndInsertText() throws {
        let item = try decodeActionItem("""
        {"type":"path","path":"/tmp/report.md","description":"Report"}
        """)

        XCTAssertEqual(item, .path(path: "/tmp/report.md", description: "Report"))
        XCTAssertEqual(item.availableActions, [.insert, .open])
        XCTAssertEqual(item.insertText, "/tmp/report.md")
        XCTAssertEqual(item.description, "Report")
    }

    func testActionItemDecodesCopyWithInsertOnlyAndNilDescription() throws {
        let item = try decodeActionItem("""
        {"type":"copy","text":"echo hi"}
        """)

        XCTAssertEqual(item, .copy(text: "echo hi", description: nil))
        // Copy items expose insert only — no open action.
        XCTAssertEqual(item.availableActions, [.insert])
        XCTAssertEqual(item.insertText, "echo hi")
        XCTAssertNil(item.description)
    }

    func testActionItemLinkOpenTargetIsTheURL() throws {
        let item = try decodeActionItem("""
        {"type":"link","url":"https://example.com/x","description":"Example"}
        """)

        // Open hands a link straight to NSWorkspace — the http(s) URL itself.
        XCTAssertEqual(item.openTarget, URL(string: "https://example.com/x"))
    }

    func testActionItemPathOpenTargetIsAFileURL() throws {
        let item = try decodeActionItem("""
        {"type":"path","path":"/Users/maxim/Downloads/Hammerspoon.app","description":"Hammerspoon"}
        """)

        // Open builds a file:// URL via URL(fileURLWithPath:) so NSWorkspace
        // launches the file in its default app — a Finder-style open, never an
        // auto-run of anything.
        let target = try XCTUnwrap(item.openTarget)
        XCTAssertTrue(target.isFileURL)
        XCTAssertEqual(target.path, "/Users/maxim/Downloads/Hammerspoon.app")
        XCTAssertEqual(target, URL(fileURLWithPath: "/Users/maxim/Downloads/Hammerspoon.app"))
    }

    func testActionItemCopyHasNoOpenTarget() throws {
        let item = try decodeActionItem("""
        {"type":"copy","text":"echo hi"}
        """)

        // Copy items expose insert only; there is nothing to open.
        XCTAssertNil(item.openTarget)
        XCTAssertFalse(item.availableActions.contains(.open))
    }

    func testActionItemRejectsNonHTTPLinkURL() {
        XCTAssertThrowsError(try decodeActionItem("""
        {"type":"link","url":"file:///etc/passwd","description":"Bad"}
        """))
    }

    func testActionItemRejectsEmptyPath() {
        XCTAssertThrowsError(try decodeActionItem("""
        {"type":"path","path":""}
        """))
    }

    func testActionItemRejectsEmptyCopyText() {
        XCTAssertThrowsError(try decodeActionItem("""
        {"type":"copy","text":""}
        """))
    }

    func testUsefulActionsBlockFailsWhenAnyItemInvalid() {
        // Item decoding is all-or-nothing (same as UsefulLinksBlock): one bad
        // item fails the whole block decode, so the graceful fallback throws
        // outside prod.
        XCTAssertThrowsError(try decode("""
        {"kind":"useful.actions","schemaVersion":1,"items":[\
        {"type":"copy","text":"ok"},{"type":"path","path":""}]}
        """, env: .beta))
    }

    private func decodeActionItem(_ json: String) throws -> ActionItem {
        try JSONDecoder().decode(ActionItem.self, from: Data(json.utf8))
    }

    private func decode(_ json: String, env: BuildFlavor = .beta) throws -> UIBlock {
        try UIBlock.decodeWithGracefulFallback(json, env: env)
    }

    private func assertMalformedFallback(_ block: UIBlock) {
        guard case .stateError(let payload) = block else {
            XCTFail("Expected stateError fallback, got \(block)")
            return
        }
        XCTAssertEqual(payload.code, "block_malformed")
        XCTAssertEqual(payload.message, "Malformed server response.")
        XCTAssertEqual(payload.actions?.first?.type, .retry)
    }
}
