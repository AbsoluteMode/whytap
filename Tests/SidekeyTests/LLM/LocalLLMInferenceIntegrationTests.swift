import XCTest
@testable import Sidekey

/// End-to-end guard against the real on-device MLX inference path. Opt-in:
/// requires `SIDEKEY_RUN_LOCAL_LLM_IT=1`, so routine `swift test` skips it (the
/// ~2.3GB Qwen3-4B download is not for CI). Run explicitly on Apple Silicon:
///   SIDEKEY_RUN_LOCAL_LLM_IT=1 swift test --filter LocalLLMInferenceIntegrationTests
///
/// First run downloads the model into a temp dir; it then performs one chat turn
/// and asserts the reply is non-empty (a human verifies coherence from the
/// printed snippet).
final class LocalLLMInferenceIntegrationTests: XCTestCase {
    func testRealLocalInferenceReturnsNonEmptyText() async throws {
        guard ProcessInfo.processInfo.environment["SIDEKEY_RUN_LOCAL_LLM_IT"] == "1" else {
            throw XCTSkip("set SIDEKEY_RUN_LOCAL_LLM_IT=1 to run on-device LLM inference (Apple Silicon)")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-local-llm-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LocalLLMModelStore(rootDirectory: root)

        try await store.downloadModel { fraction in
            // Coarse progress to stderr so a human running this can see it move.
            FileHandle.standardError.write(Data("download \(Int(fraction * 100))%\n".utf8))
        }

        let ready = await store.isModelReady()
        XCTAssertTrue(ready, "model should be downloaded and ready")

        let session = LocalLLMSession(modelStore: store)

        // Realistic RU dictation with voice artifacts the cleaner should fix —
        // exercises the SLIM local prompt + the non-greedy decoding profile
        // (ROO-257). With the old near-greedy params this came back empty.
        let rawDictation = "ну смотри значит эээ надо короче добавить кнопку " +
            "которая открывает настройки ну и чтобы там был список моделей"
        let user = PostProcessor.wrapTranscript(rawDictation)
        let reply = try await session.complete(
            system: PostProcessor.localCleanupSystemPrompt,
            user: user
        )

        // Assert on the SHAPE of the reply, not its content. Dumping the full
        // model output to stdout is noise and, on the local paths, brushes up
        // against invariant #3 (never surface generated text). A non-empty,
        // bounded-length, non-echo reply is the real contract this IT guards.
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "local inference returned empty text")
        XCTAssertLessThan(
            trimmed.count, 8_000,
            "reply length \(trimmed.count) is implausibly large for a single short turn"
        )
        // Not a verbatim echo of the input envelope: cleanup must actually
        // rewrite, and must never leak the `<transcript>` wrapper.
        XCTAssertFalse(trimmed.contains("<transcript>"),
                       "cleanup leaked the transcript wrapper")
        XCTAssertNotEqual(trimmed, rawDictation,
                          "cleanup echoed the raw dictation unchanged")
    }
}
