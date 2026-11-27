import XCTest
@testable import Sidekey

/// Claude Code and Codex answers: links, paths and a single command in the
/// final answer's own text become cards, as the built-in agent's did.
/// WHY: .project-docs/decisions/2026-11-27-agent-plain-text-cards.md
@MainActor
final class AgentPlainTextCardsTests: XCTestCase {
    private func stream(_ events: [AgentSSEEvent]) -> AsyncStream<AgentSSEEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    private func actions(_ store: AskResponseStore) -> [ActionItem] {
        store.blocks.flatMap { block -> [ActionItem] in
            if case .usefulActions(let actions) = block { return actions.items }
            return []
        }
    }

    private func actionBlocks(_ store: AskResponseStore) -> Int {
        store.blocks.filter { if case .usefulActions = $0 { return true }; return false }.count
    }

    /// A Claude Code result with a link and a path, no fence.
    func testAClaudeAnswerWithALinkAndAPathGetsBothCards() async {
        let store = AskResponseStore()
        let text = "Done. The report is in /Users/fixture/Documents/report.md and the docs are at https://example.com/guide."
        var firstBlocks = 0
        await store.consume(stream(ClaudeEventMapper.map(.result(sessionID: "s", isError: false, costUSD: nil, text: text),
                                                         registry: ClaudeTaskRegistry())),
                            onFirstBlock: { firstBlocks += 1 })
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.streamingText, text)
        XCTAssertEqual(actions(store), [
            .path(path: "/Users/fixture/Documents/report.md", description: "report.md"),
            .link(url: URL(string: "https://example.com/guide")!, description: "example.com", provider: nil),
        ])
        XCTAssertEqual(firstBlocks, 1)
    }

    /// A fence and plain text together: one block, the fence's metadata wins,
    /// and the shell command comes first so Insert is preselected.
    func testAFenceAndTheTextMergeIntoOneBlockWithTheCommandFirst() async {
        let store = AskResponseStore()
        let text = """
        Run this:

        ```bash
        brew upgrade whytap
        ```

        Release notes: https://example.com/notes

        ```json
        {"kind":"useful.actions","schemaVersion":1,"items":[{"type":"link","url":"https://example.com/notes","description":"Release notes"}]}
        ```
        """
        await store.consume(stream(ClaudeEventMapper.map(.result(sessionID: "s", isError: false, costUSD: nil, text: text),
                                                         registry: ClaudeTaskRegistry())))
        XCTAssertEqual(actionBlocks(store), 1)
        XCTAssertEqual(actions(store), [
            .copy(text: "brew upgrade whytap", description: nil),
            .link(url: URL(string: "https://example.com/notes")!, description: "Release notes", provider: nil),
        ])
        XCTAssertFalse(store.streamingText.contains("useful.actions"))
    }

    /// Codex: only the final message is read; a path named in an earlier
    /// message does not become a card.
    func testACodexIntermediateMessageAddsNoCard() async {
        let store = AskResponseStore()
        let events = CodexEventMapper.map(.agentMessage(text: "Looking in /Users/fixture/scratch/old.txt first."))
            + CodexEventMapper.map(.agentMessage(text: "The answer is in https://example.com/answer"))
            + CodexEventMapper.map(.turnCompleted)
        await store.consume(stream(events))
        XCTAssertEqual(actions(store), [
            .link(url: URL(string: "https://example.com/answer")!, description: "example.com", provider: nil),
        ])
    }

    /// Plain prose, a failed turn and an answer without destinations: no cards.
    func testNoCardsWithoutDestinationsOrAfterAnError() async {
        let plain = AskResponseStore()
        await plain.consume(stream([.finalAnswer(text: "It is 4 pm in Lisbon."), .done(sources: [])]))
        XCTAssertTrue(plain.blocks.isEmpty)

        let failed = AskResponseStore()
        await failed.consume(stream([.finalAnswer(text: "See https://example.com"),
                                     .error(code: "codex_error", message: "fixture", retryable: false),
                                     .done(sources: [])]))
        XCTAssertTrue(actions(failed).isEmpty)
    }

    /// The listed fence alone stays as it was: nothing is added or reordered.
    func testAFenceWithEverythingAlreadyListedIsUnchanged() async {
        let store = AskResponseStore()
        let listed = UsefulActionsBlock(items: [.link(url: URL(string: "https://example.com/a")!, description: "A", provider: nil)])
        await store.consume(stream([.finalAnswer(text: "Open A."), .blockComplete(.usefulActions(listed)), .done(sources: [])]))
        XCTAssertEqual(store.blocks, [.usefulActions(listed)])
    }
}
