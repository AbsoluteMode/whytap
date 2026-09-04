import XCTest
@testable import Sidekey

/// Unit tests for the pure post-processing applied to a local LLM reply.
///
/// The pinned model is `mlx-community/Qwen3-4B-Instruct-2507-4bit` — the
/// NON-thinking instruct/2507 variant, whose chat template does not enable
/// `<think>` reasoning. The strip is defense-in-depth: if any `<think>…</think>`
/// block ever appears (a future model swap, a template change), cleanup must
/// return only the post-think content so the pasted text is never empty or
/// polluted with reasoning.
final class LocalLLMSessionTests: XCTestCase {
    func testStripThinkRemovesThinkBlockAndReturnsAnswer() {
        let raw = "<think>The user dictated some text. I should clean it.</think>Готовый чистый текст."
        XCTAssertEqual(LocalLLMSession.stripThinkBlock(raw), "Готовый чистый текст.")
    }

    func testStripThinkHandlesLeadingWhitespaceAndNewlines() {
        let raw = "<think>\nreasoning across\nmultiple lines\n</think>\n\nFinal answer here"
        XCTAssertEqual(LocalLLMSession.stripThinkBlock(raw), "Final answer here")
    }

    func testStripThinkLeavesPlainTextUntouched() {
        let raw = "No reasoning, just a clean reply."
        XCTAssertEqual(LocalLLMSession.stripThinkBlock(raw), "No reasoning, just a clean reply.")
    }

    func testStripThinkWhenOnlyThinkBlockReturnsEmpty() {
        // A reply that is ONLY a think block (no answer) collapses to empty —
        // the caller treats an empty cleanup as "fall back to raw transcript".
        let raw = "<think>only reasoning, model never emitted an answer</think>"
        XCTAssertEqual(LocalLLMSession.stripThinkBlock(raw), "")
    }

    func testStripThinkRemovesUnclosedThinkBlock() {
        // Defensive: if generation is cut off mid-think (e.g. token cap), the
        // open `<think>` with no close must not leak reasoning into the paste.
        let raw = "<think>reasoning that never closed because generation stopped"
        XCTAssertEqual(LocalLLMSession.stripThinkBlock(raw), "")
    }
}
