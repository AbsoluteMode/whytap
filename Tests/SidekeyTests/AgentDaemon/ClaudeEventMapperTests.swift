import XCTest
@testable import Sidekey

final class ClaudeEventMapperTests: XCTestCase {
    func testTextDeltaMapsToNarrationDelta() {
        // Intermediate narration is hidden (fallback buffer), not the live pill.
        XCTAssertEqual(ClaudeEventMapper.map(.textDelta("Hi")), [.narrationDelta(text: "Hi")])
    }

    func testToolUseMapsToToolExecuting() {
        XCTAssertEqual(
            ClaudeEventMapper.map(.toolUse(id: "t1", name: "Bash", input: ClaudeToolInput())),
            [.toolExecuting(tool: "Bash", label: "Running a command")]
        )
    }

    func testResultWithTextMapsToFinalAnswerThenDone() {
        XCTAssertEqual(
            ClaudeEventMapper.map(.result(sessionID: "s", isError: false, costUSD: 0.01, text: "Final answer")),
            [.finalAnswer(text: "Final answer"), .done(sources: [])]
        )
    }

    func testResultWithLegacyUsefulLinksFenceMapsToActionsBlockThenDone() {
        // A legacy useful.links fence still parses and now folds into a
        // useful.actions block with all-link items (backward compatibility).
        let text = """
        Here are the links.

        ```json
        {"kind":"useful.links","schemaVersion":1,"links":[{"url":"https://linear.app/example/issue/EX-209","description":"Security audit","provider":"linear"}]}
        ```
        """

        let events = ClaudeEventMapper.map(.result(sessionID: "s", isError: false, costUSD: 0.01, text: text))

        XCTAssertEqual(events.first, .finalAnswer(text: "Here are the links."))
        guard case .blockComplete(.usefulActions(let block)) = events.dropFirst().first else {
            return XCTFail("Expected useful.actions block, got: \(events)")
        }
        XCTAssertEqual(
            block.items.first,
            .link(
                url: URL(string: "https://linear.app/example/issue/EX-209")!,
                description: "Security audit",
                provider: "linear"
            )
        )
        XCTAssertEqual(events.last, .done(sources: []))
    }

    func testResultWithoutTextMapsToDoneOnly() {
        XCTAssertEqual(
            ClaudeEventMapper.map(.result(sessionID: "s", isError: false, costUSD: 0.01, text: nil)),
            [.done(sources: [])]
        )
    }

    func testResultErrorMapsToError() {
        guard case .error(let code, _, let retryable) = ClaudeEventMapper.map(
            .result(sessionID: nil, isError: true, costUSD: nil, text: nil)
        ).first
        else { return XCTFail("Expected error event") }
        XCTAssertEqual(code, "agent_error")
        XCTAssertFalse(retryable)
    }

    func testErrorCategoryMapsToError() {
        guard case .error(let code, _, _) = ClaudeEventMapper.map(
            .errorCategory("authentication_failed")
        ).first
        else { return XCTFail("Expected error event") }
        XCTAssertEqual(code, "authentication_failed")
    }

    func testInitProducesNothingVisible() {
        XCTAssertEqual(ClaudeEventMapper.map(.initSession(sessionID: "s")), [])
    }

    func testRateLimitErrorIsRetryable() {
        guard case .error(_, _, let retryable) = ClaudeEventMapper.map(
            .errorCategory("rate_limit")
        ).first
        else { return XCTFail("Expected error event") }
        XCTAssertTrue(retryable)
    }

    func testServerErrorIsRetryable() {
        guard case .error(_, _, let retryable) = ClaudeEventMapper.map(
            .errorCategory("server_error")
        ).first
        else { return XCTFail("Expected error event") }
        XCTAssertTrue(retryable)
    }

    // MARK: - Task 6 tests

    func testAssistantTextDoesNotBecomeAppChrome() {
        XCTAssertEqual(
            ClaudeEventMapper.map(.assistantText("Сначала запущу тесты. Потом посмотрю на падение.")),
            []
        )
    }

    func testToolResultMapsToNothing() {
        XCTAssertEqual(ClaudeEventMapper.map(.toolResult(toolUseId: "t", text: "ok")), [])
    }

    func testTaskUpdateInProgressUsesRegistryLabel() {
        let registry = ClaudeTaskRegistry()
        registry.observe(.toolUse(id: "c1", name: "TaskCreate",
                                  input: ClaudeToolInput(activeForm: "Создаю index.html")))
        registry.observe(.toolResult(toolUseId: "c1", text: "Task #1 created successfully: x"))
        XCTAssertEqual(
            ClaudeEventMapper.map(
                .toolUse(id: "u1", name: "TaskUpdate",
                         input: ClaudeToolInput(taskId: "1", status: "in_progress")),
                registry: registry
            ),
            [.toolExecuting(tool: "TaskUpdate", label: "Planning (1/1)")]
        )
    }

    func testTaskUpdateCompletedEmitsNothing() {
        XCTAssertEqual(
            ClaudeEventMapper.map(.toolUse(id: "u2", name: "TaskUpdate",
                                           input: ClaudeToolInput(taskId: "1", status: "completed"))),
            []
        )
    }

    func testBashToolUsesCommandCategory() {
        XCTAssertEqual(
            ClaudeEventMapper.map(.toolUse(id: "b1", name: "Bash",
                                           input: ClaudeToolInput(
                                            description: "Ejecutando pruebas",
                                            command: "swift test"
                                           ))),
            [.toolExecuting(tool: "Bash", label: "Running tests")]
        )
    }

    func testResultEmissionEndsWithTerminalEvent() {
        // The result arm always ends with .done(sources:[]) for non-error paths.
        // Pin this so no late statusNarration/toolExecuting can follow .done and
        // revive the thinking state.
        let events = ClaudeEventMapper.map(.result(sessionID: "s", isError: false, costUSD: nil, text: "Готово."))
        XCTAssertEqual(events.last, .done(sources: []))
    }
}
