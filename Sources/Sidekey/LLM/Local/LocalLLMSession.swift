import Foundation
import MLXLMCommon
import os.log

/// Abstracts a single on-device system+user chat turn so call sites (drop
/// cleanup, meeting summary) can be unit-tested against a spy without loading
/// the 2.3GB MLX weights.
protocol LocalLLMCompleting: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// On-device LLM inference over the MLX runtime. Lazily resolves the cached
/// `ModelContainer` from the model store (mirroring how `LocalTranscriptionSession`
/// caches its Parakeet manager) and runs a single system+user chat turn.
///
/// Prompt and response text are NEVER logged — only timing (invariant #3).
actor LocalLLMSession: LocalLLMCompleting {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "local-llm")

    /// Generation parameters for a dictation-cleanup turn.
    ///
    /// `ChatSession` defaults to `GenerateParameters()`, whose `maxTokens` is
    /// `nil` (UNBOUNDED) and whose `temperature` is `0.6` (non-deterministic).
    /// For a cleanup turn neither default is right:
    ///  - `maxTokens` nil lets a misbehaving turn generate indefinitely (runaway
    ///    decode pinning the machine). A cleaned dictation is roughly the size of
    ///    its input, so 1024 tokens is a generous ceiling that bounds the cost.
    ///  - the decode MUST NOT be greedy. The previous profile
    ///    (`temperature 0.1`, `topP 1.0`, `topK 0`, `repetitionPenalty nil`) is
    ///    effectively greedy: `GenerateParameters.sampler()` only engages the
    ///    truncated `TopPSampler` when `topP ∈ (0,1)` OR `topK > 0` OR
    ///    `minP > 0`; otherwise it falls through to `CategoricalSampler`. Qwen3's
    ///    model card explicitly warns against greedy decoding — on the 4-bit
    ///    weights it collapses to immediate-EOS (empty output) or a degenerate
    ///    repetition loop (then stripped to empty by the band-aids), which is the
    ///    "empty / terrible RU cleanup" of ROO-257.
    ///
    /// Profile = Qwen3-recommended sampling tuned slightly deterministic for a
    /// faithful cleanup rewrite: nucleus (topP 0.8) + top-k (20) truncation, a
    /// light repetition penalty (1.05) over a short context, low-but-nonzero
    /// temperature (0.3 — temperature 0 would force the pure-greedy
    /// `ArgMaxSampler`). The summary (meetings) path, if it ever shares this
    /// session, is fine on the same profile.
    static let cleanupParameters = GenerateParameters(
        maxTokens: 1024,
        temperature: 0.3,
        topP: 0.8,
        topK: 20,
        repetitionPenalty: 1.05,
        repetitionContextSize: 20
    )

    private let modelStore: any LocalLLMModelManaging

    init(modelStore: any LocalLLMModelManaging = LocalLLMModelStore.shared) {
        self.modelStore = modelStore
    }

    /// Runs one system+user turn through the local model and returns the decoded
    /// reply. Throws `LocalLLMModelError.modelNotDownloaded` if the weights are
    /// not present.
    func complete(system: String, user: String) async throws -> String {
        let container = try await modelStore.loadContainer()

        let start = DispatchTime.now()
        os_log("local LLM inference: start", log: Self.log, type: .info)

        let instructions = system.isEmpty ? nil : system
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: Self.cleanupParameters
        )
        let reply = try await session.respond(to: user)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        os_log("local LLM inference: done in %{public}.0f ms", log: Self.log, type: .info, elapsedMs)

        let stripped = Self.stripThinkBlock(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        // Observability (ROO-257): the pinned model is the non-thinking variant
        // and must never emit `<think>`. If the strip actually removed content,
        // that is a model/template regression worth surfacing — flag only, never
        // the reply text (invariant #3). `stripThinkBlock` always trims, so guard
        // on the presence of the tag to avoid firing on a pure whitespace trim.
        if reply.contains("<think>") {
            os_log("local LLM: stripped <think> block from reply", log: Self.log, type: .error)
        }
        return stripped
    }

    /// Strips a leading `<think>…</think>` reasoning block from a model reply,
    /// returning only the (whitespace-trimmed) post-think answer.
    ///
    /// The pinned model (`Qwen3-4B-Instruct-2507-4bit`) is the non-thinking
    /// variant and should never emit `<think>`, but this is defense-in-depth: a
    /// template change or model swap that re-enabled thinking would otherwise
    /// leak reasoning into the pasted text — or, if the block were the whole
    /// reply, make cleanup come back empty. Handles an UNCLOSED `<think>`
    /// (generation cut off mid-reasoning by the token cap) by dropping
    /// everything from the open tag onward.
    static func stripThinkBlock(_ reply: String) -> String {
        let openTag = "<think>"
        let closeTag = "</think>"
        guard let openRange = reply.range(of: openTag) else {
            return reply.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let before = reply[reply.startIndex..<openRange.lowerBound]
        guard let closeRange = reply.range(
            of: closeTag,
            range: openRange.upperBound..<reply.endIndex
        ) else {
            // Unclosed think block — drop from the open tag to the end so no
            // reasoning leaks into the paste.
            return String(before).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let after = reply[closeRange.upperBound..<reply.endIndex]
        return (String(before) + String(after))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
