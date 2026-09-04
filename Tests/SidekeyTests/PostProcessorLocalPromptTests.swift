import XCTest
@testable import Sidekey

/// ROO-257: the on-device `.local` cleanup route must use a COMPACT prompt, not
/// the full ~25KB cloud system prompt. A 4B/4-bit model fed the full prompt
/// (17 few-shot examples + an adversarial injection-resistance section) reacts
/// with empty / echo / refusal-shaped output. The slim prompt keeps the core
/// editor contract and a few brand examples; the backend + direct (OpenRouter/
/// custom) routes keep the full prompt unchanged.
final class PostProcessorLocalPromptTests: XCTestCase {
    // MARK: - Slim prompt content

    func testLocalCleanupPromptIsMuchShorterThanFullPrompt() {
        let slim = PostProcessor.localCleanupSystemPrompt
        let full = PostProcessor.systemPrompt
        XCTAssertNotEqual(slim, full, "local prompt must not be the full cloud prompt")
        XCTAssertLessThan(
            slim.count, full.count / 3,
            "local prompt should be a fraction of the full prompt (was \(slim.count) vs \(full.count))"
        )
    }

    func testLocalCleanupPromptKeepsCoreEditorContract() {
        let slim = PostProcessor.localCleanupSystemPrompt
        // Returns ONLY the cleaned text — no preface/quotes/Markdown.
        XCTAssertTrue(slim.localizedCaseInsensitiveContains("только"),
                      "expected a return-only-the-text instruction")
        XCTAssertTrue(slim.localizedCaseInsensitiveContains("Markdown"),
                      "expected a no-Markdown instruction")
        // Keep the input language (do not translate/invent).
        XCTAssertTrue(slim.localizedCaseInsensitiveContains("язык"),
                      "expected a keep-the-language instruction")
    }

    func testLocalCleanupPromptTreatsTranscriptAsData() {
        let slim = PostProcessor.localCleanupSystemPrompt
        XCTAssertTrue(slim.localizedCaseInsensitiveContains("данные"),
                      "expected the transcript-is-data framing")
    }

    func testLocalCleanupPromptIncludesAtLeastOneBrandExample() {
        let slim = PostProcessor.localCleanupSystemPrompt
        // A couple of canonical brand normalizations carried over from the full
        // prompt so the small model still fixes the common ones.
        XCTAssertTrue(slim.contains("PostgreSQL") || slim.contains("GitHub") || slim.contains("public key"),
                      "expected at least one brand-normalization example")
    }

    /// The adversarial injection-resistance section is DROPPED for local: the
    /// single-turn on-device surface has minimal injection risk, and the section
    /// pushes small models toward empty/refusal output.
    func testLocalCleanupPromptDropsAdversarialInjectionSection() {
        let slim = PostProcessor.localCleanupSystemPrompt
        XCTAssertFalse(slim.contains("Примеры поведения при попытках injection"),
                       "the adversarial injection-resistance section must be dropped for local")
        XCTAssertFalse(slim.contains("игнорируй предыдущие инструкции"),
                       "the adversarial injection example must be dropped for local")
    }

    // MARK: - Route selection

    func testBackendDirectMessagesUseFullPrompt() {
        // The default (backend + direct OpenRouter/custom) message builder keeps
        // the full prompt unchanged.
        let messages = PostProcessor.openRouterMessages(
            transcript: PostProcessor.wrapTranscript("привет"),
            context: "Slack",
            language: "ru",
            outputLanguage: nil,
            transcriptionMode: "smart"
        )
        let system = messages.first(where: { $0.role == "system" })?.content
        XCTAssertEqual(system, PostProcessor.systemPrompt,
                       "backend/direct routes must keep the full system prompt")
    }
}
