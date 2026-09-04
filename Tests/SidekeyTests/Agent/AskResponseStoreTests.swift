import XCTest
@testable import Sidekey

@MainActor
final class AskResponseStoreTests: XCTestCase {
    func testConsumeAppendsSummaryBlocksAndSources() async throws {
        let store = AskResponseStore()
        let block = UIBlock.textAnswer(TextAnswerBlock(title: "Answer", body: "Body"))
        let source = Source(id: "s1", title: "Docs", url: URL(string: "https://sidekey.ai"), provider: "web")

        store.markLocalStatus(.uploading)
        await store.consume(stream([
            .toolExecuting(tool: "web_search", label: "Searching web"),
            .summaryDelta(text: "Hello "),
            .summaryDelta(text: "world"),
            .blockComplete(block),
            .done(sources: [source])
        ]))

        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.summary, "Hello world")
        XCTAssertEqual(store.blocks, [block])
        XCTAssertEqual(store.sources, [source])
        XCTAssertNil(store.currentToolLabel)
    }

    func testConsumeCallsFirstBlockHandlerOnlyOnce() async {
        let store = AskResponseStore()
        var firstBlockCalls = 0

        await store.consume(
            stream([
                .summaryDelta(text: "Before"),
                .blockComplete(.textAnswer(TextAnswerBlock(body: "First"))),
                .blockComplete(.textAnswer(TextAnswerBlock(body: "Second"))),
                .done(sources: [])
            ]),
            onFirstBlock: {
                firstBlockCalls += 1
            }
        )

        XCTAssertEqual(firstBlockCalls, 1)
        XCTAssertEqual(store.blocks.count, 2)
        XCTAssertTrue(store.streamCompleted)
    }

    func testConsumeAccumulatesStreamingTextAndExtendsToFullBodyOnBlockComplete() async {
        let store = AskResponseStore()
        // Realistic case: streaming deltas are a strict prefix of the
        // final block body. Streaming text now mutates directly from SSE
        // deltas (no typewriter smoothing for Sonnet), and the block
        // body acts as a terminator that backfills the canonical text
        // in case any deltas were dropped or arrived out of order.
        let block = UIBlock.textAnswer(TextAnswerBlock(body: "Hello world"))

        await store.consume(stream([
            .summaryDelta(text: "Hel"),
            .summaryDelta(text: "lo"),
            .blockComplete(block),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.summary, "Hello")
        // textAnswer block backfills `streamingText` to the canonical
        // body so the user sees the full answer even if deltas under-
        // delivered. The block ALSO stays in `blocks` for history
        // persistence; the response panel filters textAnswer out of
        // the on-screen block list and renders Pill 2 from
        // `streamingText` instead.
        XCTAssertEqual(store.streamingText, "Hello world")
        XCTAssertEqual(store.blocks, [block])
    }

    func testStreamingTextReflectsSummaryDeltasImmediatelyWithoutFlush() async {
        // Sonnet streaming is no longer typewriter-smoothed. SSE
        // summary.delta events mutate `streamingText` directly at backend
        // pace, so a consumer reading `streamingText` after `consume(_:)`
        // returns sees the concatenation of all deltas without needing
        // to flush a typewriter. This is what makes Pill 2's MarkdownBody
        // re-parse rate fall from 80-160/sec (typewriter ticks) down to
        // whatever the backend SSE emits (~30-50/sec).
        let store = AskResponseStore()

        await store.consume(stream([
            .summaryDelta(text: "First "),
            .summaryDelta(text: "second "),
            .summaryDelta(text: "third"),
            .done(sources: [])
        ]))
        // NOTE: no flushTypewritersForTesting() — the assertion must hold
        // on the immediate value.

        XCTAssertEqual(store.streamingText, "First second third")
        XCTAssertEqual(store.summary, "First second third")
    }

    func testBlockCompleteDoesNotShortenStreamingTextWhenDeltasAlreadyAhead() async {
        // Defensive: if for some reason `summary.delta` deltas accumulate
        // MORE text than the canonical block body (e.g. backend re-emits
        // with an older body, or two textAnswer blocks ship), the visible
        // stream must not visibly shrink. The backfill is one-way — extend
        // toward the canonical, never truncate.
        let store = AskResponseStore()

        await store.consume(stream([
            .summaryDelta(text: "Long streamed answer that exceeds the block body"),
            .blockComplete(.textAnswer(TextAnswerBlock(body: "Short"))),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.streamingText, "Long streamed answer that exceeds the block body")
    }

    func testNonTextAnswerBlockPreservesStreamingText() async {
        // Earlier semantics were "any non-textAnswer block.complete clears
        // streamingText". That deleted Sonnet's accumulated prose every
        // time a sibling block (useful_links, entityCard, ...) landed
        // first — visible to users as an empty Pill 2 above the chip row
        // when Sonnet declined to emit a follow-up textAnswer. The fix:
        // only textAnswer owns streamingText; other blocks leave it alone.
        let store = AskResponseStore()

        await store.consume(stream([
            .summaryDelta(text: "Half-typed answer"),
            .blockComplete(.entityCard(EntityCardBlock(
                entityType: .calendarEvent,
                name: "Planning"
            ))),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.streamingText, "Half-typed answer")
    }

    func testUsefulLinksBlockDoesNotClearStreamingText() async {
        // Repro for the visible bug: Sonnet streams a prose answer,
        // backend emits block.complete(useful_links) for the chips,
        // and Sonnet does NOT follow with a textAnswer block. Pre-fix
        // streamingText was wiped here and Pill 2 rendered empty.
        let store = AskResponseStore()

        await store.consume(stream([
            .summaryDelta(text: "Hello world"),
            .blockComplete(.usefulLinks(UsefulLinksBlock(links: [
                UsefulLink(
                    url: URL(string: "https://example.com")!,
                    description: "Example"
                )
            ]))),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.streamingText, "Hello world")
    }

    func testUsefulLinksBlockStripsTrailingJSONFence() async {
        // Sonnet emits useful_links as a trailing ```json fenced block
        // at the end of its prose. By the time block.complete arrives
        // the backend has already extracted the JSON payload, but our
        // locally accumulated streamingText still carries the fence —
        // visible briefly as raw JSON in Pill 2. Strip it on
        // block.complete(useful_links) so the prose stays clean.
        let store = AskResponseStore()
        let prose = "Here are the links you asked for."
        let fenced = "\(prose)\n\n```json\n{\"links\": [...]}\n```"

        await store.consume(stream([
            .summaryDelta(text: fenced),
            .blockComplete(.usefulLinks(UsefulLinksBlock(links: [
                UsefulLink(
                    url: URL(string: "https://example.com")!,
                    description: "Example"
                )
            ]))),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.streamingText, prose)
    }

    func testTextAnswerBlockStillBackfillsStreamingText() async {
        // Sanity: existing textAnswer backfill behaviour is preserved.
        // If deltas under-deliver and the canonical body is longer, the
        // block.complete(textAnswer) replaces streamingText with the
        // canonical body.
        let store = AskResponseStore()

        await store.consume(stream([
            .summaryDelta(text: "Hel"),
            .blockComplete(.textAnswer(TextAnswerBlock(body: "Hello world"))),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.streamingText, "Hello world")
    }

    func testStrippingTrailingJSONFenceJsonPattern() {
        // ```json fence — primary pattern. Trim whitespace + newlines
        // around the prose so a fence immediately preceded by blank
        // lines doesn't leave a dangling \n.
        let text = "Some prose.\n\n```json\n{\"x\": 1}\n```"
        XCTAssertEqual(
            AskResponseStore.strippingTrailingJSONFence(from: text),
            "Some prose."
        )
    }

    func testStrippingTrailingJSONFenceNewlineBracePattern() {
        // ```\n{ — Sonnet sometimes omits the language tag but still
        // opens a JSON object on the next line. Must strip identically.
        let text = "Prose body\n```\n{\"x\": 1}\n```"
        XCTAssertEqual(
            AskResponseStore.strippingTrailingJSONFence(from: text),
            "Prose body"
        )
    }

    func testStrippingTrailingJSONFenceInlineBracePattern() {
        // ```{ — Sonnet sometimes emits the opening fence and the JSON
        // brace on a single line, no language tag, no newline between.
        let text = "Prose\n```{\"x\": 1}\n```"
        XCTAssertEqual(
            AskResponseStore.strippingTrailingJSONFence(from: text),
            "Prose"
        )
    }

    func testStrippingTrailingJSONFenceNoFenceReturnsUnchanged() {
        // No fence in the text — return verbatim, do not trim user
        // content. (We trim ONLY when we matched a fence; otherwise
        // the input may legitimately have leading / trailing
        // whitespace the model intended.)
        let text = "Plain prose with no fence at all."
        XCTAssertEqual(
            AskResponseStore.strippingTrailingJSONFence(from: text),
            text
        )
    }

    func testStrippingTrailingJSONFenceEmptyStringIsNoop() {
        XCTAssertEqual(
            AskResponseStore.strippingTrailingJSONFence(from: ""),
            ""
        )
    }

    func testResetClearsStreamCompleted() async {
        let store = AskResponseStore()

        await store.consume(stream([.done(sources: [])]))
        XCTAssertTrue(store.streamCompleted)

        store.reset()

        XCTAssertFalse(store.streamCompleted)
    }

    func testToolExecutingSetsThinkingAndToolLabelBeforeDone() async {
        let store = AskResponseStore()
        var continuation: AsyncStream<AgentSSEEvent>.Continuation!
        let stream = AsyncStream<AgentSSEEvent> { streamContinuation in
            continuation = streamContinuation
        }

        let task = Task { @MainActor in
            await store.consume(stream)
        }
        continuation.yield(.toolExecuting(tool: "linear", label: "Checking Linear"))
        // Cooperative scheduling on the same actor: multiple yields let the
        // consume() task pick up the yielded event before we assert.
        for _ in 0..<10 {
            await Task.yield()
            if store.status == .thinking { break }
        }
        // Typewriter drains the label one char per 40 ms — flush so the
        // assertion sees the final value without sleeping.
        store.flushTypewritersForTesting()

        XCTAssertEqual(store.status, .thinking)
        XCTAssertEqual(store.currentToolLabel, "Checking Linear")
        continuation.finish()
        await task.value
    }

    func testErrorEventMarksFailed() async {
        let store = AskResponseStore()

        await store.consume(stream([
            .error(code: "tool_failed", message: "Tool failed", retryable: true)
        ]))

        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.errorCode, "tool_failed")
        XCTAssertEqual(store.errorMessage, "Tool failed")
        XCTAssertTrue(store.isErrorRetryable)
        XCTAssertNil(store.currentToolLabel)
    }

    func testResetClearsResponseState() async {
        let store = AskResponseStore()
        await store.consume(stream([
            .summaryDelta(text: "hello"),
            .blockComplete(.textAnswer(TextAnswerBlock(body: "Body"))),
            .done(sources: [Source(id: "s1", title: "Docs")])
        ]))

        store.reset()

        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.summary, "")
        XCTAssertEqual(store.streamingText, "")
        XCTAssertTrue(store.blocks.isEmpty)
        XCTAssertTrue(store.sources.isEmpty)
        XCTAssertNil(store.errorCode)
        XCTAssertNil(store.errorMessage)
    }

    func testMarkErrorSetsFailedState() {
        let store = AskResponseStore()

        store.markError(.rateLimited, code: "custom_rate_limit")

        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.errorCode, "custom_rate_limit")
        XCTAssertEqual(store.errorMessage, AgentClientError.rateLimited.description)
        XCTAssertTrue(store.isErrorRetryable)
    }

    // MARK: - Terminal error semantics

    func testDoneArrivingAfterErrorDoesNotClearErrorState() async {
        // Backend emits error then done as terminators. The error must remain
        // visible to the user — done must not silently wipe it.
        let store = AskResponseStore()

        await store.consume(stream([
            .error(code: "provider_error", message: "Provider failed", retryable: true),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.errorCode, "provider_error")
        XCTAssertEqual(store.errorMessage, "Provider failed")
        XCTAssertTrue(store.isErrorRetryable)
        XCTAssertTrue(store.streamCompleted)
    }

    func testDoneArrivingAfterErrorPreservesNonRetryableError() async {
        let store = AskResponseStore()

        await store.consume(stream([
            .error(code: "unauthorized", message: "Authentication required.", retryable: false),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.errorCode, "unauthorized")
        XCTAssertEqual(store.errorMessage, "Authentication required.")
        XCTAssertFalse(store.isErrorRetryable)
    }

    func testDoneWithoutErrorStillClearsErrorState() async {
        // Sanity check: when no error fired during the stream, done's normal
        // bookkeeping still applies (sources land, error stays nil).
        let store = AskResponseStore()
        let source = Source(id: "s1", title: "Docs")

        await store.consume(stream([
            .blockComplete(.textAnswer(TextAnswerBlock(body: "ok"))),
            .done(sources: [source])
        ]))

        XCTAssertEqual(store.status, .ready)
        XCTAssertNil(store.errorCode)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.sources, [source])
    }

    func testErrorEventInvokesErrorHandler() async {
        // Controller relies on this hook to open the response panel even when
        // no blocks arrived — otherwise the user sees the streaming preview
        // die and nothing replaces it.
        let store = AskResponseStore()
        var errorEvents = 0

        await store.consume(
            stream([
                .error(code: "provider_error", message: "boom", retryable: true)
            ]),
            onErrorEvent: {
                errorEvents += 1
            }
        )

        XCTAssertEqual(errorEvents, 1)
    }

    func testErrorAfterBlockKeepsTerminalErrorState() async {
        // Even if a block landed first, a subsequent error must terminate
        // the stream as failed.
        let store = AskResponseStore()

        await store.consume(stream([
            .blockComplete(.textAnswer(TextAnswerBlock(body: "partial"))),
            .error(code: "provider_error", message: "boom", retryable: false),
            .done(sources: [])
        ]))

        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.errorCode, "provider_error")
        XCTAssertEqual(store.errorMessage, "boom")
    }

    // MARK: - chatTitle seam (dormant)

    func testInitialChatTitleIsNil() {
        let store = AskResponseStore()

        XCTAssertNil(store.chatTitle)
    }

    // MARK: - Repeated tool.executing (Stage 2)

    func testConsumeRepeatedToolExecutingUpdatesLabel() async {
        // Backend re-emits `tool.executing` for the same tool with the
        // Nano-enriched label once it is available. Store must overwrite
        // currentToolLabel each time, not duplicate or ignore.
        let store = AskResponseStore()

        await store.consume(stream([
            .toolExecuting(tool: "slack.search", label: "Searching"),
            .toolExecuting(tool: "slack.search", label: "Searching Slack for PR-345")
        ]))
        store.flushTypewritersForTesting()

        XCTAssertEqual(store.currentToolLabel, "Searching Slack for PR-345")
        XCTAssertEqual(store.status, .thinking)
    }

    func testRepeatedToolExecutingInvokesToolEventCallbackEachTime() async {
        // onToolEvent is the controller's hook to record tool names. Backend
        // re-emit must invoke it consistently (idempotent on the controller
        // side — that's Stage 4a's responsibility). Here we just verify the
        // store does not swallow repeats.
        let store = AskResponseStore()
        var recorded: [String] = []

        await store.consume(
            stream([
                .toolExecuting(tool: "linear", label: "default"),
                .toolExecuting(tool: "linear", label: "Nano-enriched"),
                .done(sources: [])
            ]),
            onToolEvent: { tool in
                recorded.append(tool)
            }
        )

        XCTAssertEqual(recorded, ["linear", "linear"])
    }

    // MARK: - Local-CLI final answer (steps during turn, clean final at done)

    func testFinalAnswerHiddenUntilDone() async {
        let store = AskResponseStore()
        var continuation: AsyncStream<AgentSSEEvent>.Continuation!
        let s = AsyncStream<AgentSSEEvent> { continuation = $0 }
        let task = Task { @MainActor in await store.consume(s) }

        continuation.yield(.finalAnswer(text: "The answer"))
        for _ in 0..<10 {
            await Task.yield()
            if store.status == .thinking { break }
        }
        // Buffered, not shown live -> the pill stays on tool-step labels.
        XCTAssertEqual(store.streamingText, "")

        continuation.yield(.done(sources: []))
        continuation.finish()
        await task.value

        XCTAssertEqual(store.streamingText, "The answer")
        XCTAssertEqual(store.summary, "The answer")
    }

    func testNarrationDeltaIsHiddenFallbackRevealedAtDone() async {
        let store = AskResponseStore()
        await store.consume(stream([
            .narrationDelta(text: "thinking "),
            .narrationDelta(text: "out loud"),
            .done(sources: [])
        ]))
        // No finalAnswer -> the accumulated narration is the fallback answer.
        XCTAssertEqual(store.streamingText, "thinking out loud")
    }

    func testFinalAnswerWinsOverNarration() async {
        let store = AskResponseStore()
        await store.consume(stream([
            .narrationDelta(text: "intermediate narration"),
            .finalAnswer(text: "clean final"),
            .done(sources: [])
        ]))
        XCTAssertEqual(store.streamingText, "clean final")
    }

    // MARK: - statusNarration (local-CLI live progress line)

    func testStatusNarrationUpdatesLabelWithoutToolEvent() async {
        let store = AskResponseStore()
        var toolEvents: [String] = []
        let s = AsyncStream<AgentSSEEvent> { c in
            c.yield(.statusNarration(text: "Сначала запущу тесты."))
            c.finish()
        }
        await store.consume(s, onToolEvent: { toolEvents.append($0) })
        // Typewriter drains the label lazily — flush so assertions see the
        // final value immediately (same pattern as toolExecuting tests above).
        store.flushTypewritersForTesting()
        XCTAssertEqual(store.currentToolLabel, "Сначала запущу тесты.")
        XCTAssertEqual(store.status, .thinking)
        XCTAssertTrue(toolEvents.isEmpty)
    }

    private func stream(_ events: [AgentSSEEvent]) -> AsyncStream<AgentSSEEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
