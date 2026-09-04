import XCTest
@testable import Sidekey

final class AgentSSEEventTests: XCTestCase {
    func testParsesToolExecutingEvent() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: tool.executing
        data: {"tool":"google_calendar","label":"Checking calendar"}

        """)

        XCTAssertEqual(
            event,
            .toolExecuting(tool: "google_calendar", label: "Checking calendar")
        )
    }

    func testParsesSummaryDeltaEvent() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: summary.delta
        data: {"text":"hello"}

        """)

        XCTAssertEqual(event, .summaryDelta(text: "hello"))
    }

    func testParsesBlockCompleteEvent() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: block.complete
        data: {"kind":"text.answer","schemaVersion":1,"body":"Answer"}

        """)

        guard case .blockComplete(.textAnswer(let block)) = event else {
            XCTFail("Expected text.answer block, got \(event)")
            return
        }
        XCTAssertEqual(block.body, "Answer")
    }

    func testParsesBlockCompleteUsefulLinksEvent() throws {
        // Frozen SSE contract uses `kind: "useful.links"` plus
        // `schemaVersion: 1` — same shape as every other UIBlock so
        // there's nothing special about the dispatcher. The decoder
        // emits the correct UIBlock variant; the agent flow then
        // forwards it to `UsefulLinksBlockView` in the renderer registry.
        let event = try AgentSSEEvent(rawSSE: """
        event: block.complete
        data: {"kind":"useful.links","schemaVersion":1,"links":[{"url":"https://www.notion.so/p","description":"Spec","provider":"notion"}]}

        """)

        guard case .blockComplete(.usefulLinks(let block)) = event else {
            XCTFail("Expected useful.links block, got \(event)")
            return
        }
        XCTAssertEqual(block.links.count, 1)
        XCTAssertEqual(block.links.first?.description, "Spec")
        XCTAssertEqual(block.links.first?.provider, "notion")
        XCTAssertEqual(block.schemaVersion, 1)
    }

    func testParsesDoneEvent() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: done
        data: {"sources":[{"id":"s1","title":"Docs","url":"https://sidekey.ai","provider":"web"}]}

        """)

        guard case .done(let sources) = event else {
            XCTFail("Expected done, got \(event)")
            return
        }
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.id, "s1")
        XCTAssertEqual(sources.first?.url?.absoluteString, "https://sidekey.ai")
    }

    /// Real backend emits `event: done\ndata: {}` when the turn produced no
    /// sources (see `app/agent/sse_adapter.py` — only attaches `sources` when
    /// it is a non-empty list). Pre-fix the client rejected this as
    /// "key 'sources' not found" and the `done` event was silently dropped —
    /// `AgentController.finalizeHistoryEntry` never fired and no history row
    /// was written. Treat missing/null `sources` as an empty list so the
    /// terminal event always reaches the controller.
    func testParsesDoneEventWithoutSources() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: done
        data: {}

        """)

        guard case .done(let sources) = event else {
            XCTFail("Expected done with empty sources, got \(event)")
            return
        }
        XCTAssertEqual(sources, [])
    }

    func testParsesDoneEventWithNullSources() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: done
        data: {"sources":null}

        """)

        guard case .done(let sources) = event else {
            XCTFail("Expected done with empty sources, got \(event)")
            return
        }
        XCTAssertEqual(sources, [])
    }

    func testParsesErrorEvent() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: error
        data: {"code":"tool_failed","message":"Tool failed","retryable":true}

        """)

        XCTAssertEqual(
            event,
            .error(code: "tool_failed", message: "Tool failed", retryable: true)
        )
    }

    func testThrowsOnUnknownEvent() {
        XCTAssertThrowsError(
            try AgentSSEEvent(rawSSE: """
            event: future.event
            data: {}

            """)
        ) { error in
            XCTAssertEqual(error as? AgentSSEEventDecodingError, .unknownEvent("future.event"))
        }
    }

    func testThrowsOnMalformedData() {
        XCTAssertThrowsError(
            try AgentSSEEvent(rawSSE: """
            event: summary.delta
            data: {

            """)
        )
    }

    // MARK: - voice.transcript

    func testDecodesVoiceTranscriptEventToVoiceTranscriptCase() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: voice.transcript
        data: {"text":"Можешь скинуть ссылку на Anthropic?"}

        """)

        XCTAssertEqual(
            event,
            .voiceTranscript(text: "Можешь скинуть ссылку на Anthropic?")
        )
    }

    // MARK: - started (Stage 0b)

    /// Backend emits `started` as the first SSE event in every `/api/agent`
    /// stream, carrying the `turn_id` that joins client telemetry rows with
    /// `usage_logs.turn_id`. Required fields: `turn_id`, `request_id`,
    /// `session_id`.
    func testParsesStartedEventAndExtractsTurnId() throws {
        let event = try AgentSSEEvent(rawSSE: """
        event: started
        data: {"turn_id":"abc123","request_id":"req-1","session_id":"sess-x"}

        """)

        guard case .started(let turnId, let requestId, let sessionId) = event else {
            XCTFail("Expected .started, got \(event)")
            return
        }
        XCTAssertEqual(turnId, "abc123")
        XCTAssertEqual(requestId, "req-1")
        XCTAssertEqual(sessionId, "sess-x")
    }

    func testStartedEventWithMissingTurnIdThrows() {
        XCTAssertThrowsError(
            try AgentSSEEvent(rawSSE: """
            event: started
            data: {"request_id":"req-1","session_id":"sess-x"}

            """)
        )
    }

    /// Regression: all core event types decode independently without interfering with each other.
    func testCoreEventTypesDecodeIndependently() throws {
        let toolExecuting = try AgentSSEEvent(rawSSE: """
        event: tool.executing
        data: {"tool":"slack","label":"Searching Slack"}

        """)
        XCTAssertEqual(toolExecuting, .toolExecuting(tool: "slack", label: "Searching Slack"))

        let summaryDelta = try AgentSSEEvent(rawSSE: """
        event: summary.delta
        data: {"text":"chunk"}

        """)
        XCTAssertEqual(summaryDelta, .summaryDelta(text: "chunk"))

        let blockComplete = try AgentSSEEvent(rawSSE: """
        event: block.complete
        data: {"kind":"text.answer","schemaVersion":1,"body":"hi"}

        """)
        guard case .blockComplete(.textAnswer(let block)) = blockComplete else {
            XCTFail("Expected text.answer block, got \(blockComplete)")
            return
        }
        XCTAssertEqual(block.body, "hi")

        let done = try AgentSSEEvent(rawSSE: """
        event: done
        data: {}

        """)
        guard case .done(let sources) = done else {
            XCTFail("Expected done, got \(done)")
            return
        }
        XCTAssertEqual(sources, [])

        let errorEvent = try AgentSSEEvent(rawSSE: """
        event: error
        data: {"code":"x","message":"y","retryable":false}

        """)
        XCTAssertEqual(errorEvent, .error(code: "x", message: "y", retryable: false))
    }
}
