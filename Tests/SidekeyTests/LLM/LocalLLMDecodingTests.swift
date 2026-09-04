import XCTest
import MLXLMCommon
@testable import Sidekey

/// Guards the on-device cleanup decoding profile against regressing to greedy.
///
/// ROO-257: the original profile (`temperature 0.1`, `topP 1.0`, `topK 0`,
/// `repetitionPenalty nil`) is effectively greedy. `GenerateParameters.sampler()`
/// only engages truncated sampling (`TopPSampler`) when `topP ∈ (0,1)` OR
/// `topK > 0` OR `minP > 0`; otherwise it falls through to `CategoricalSampler`
/// (or `ArgMaxSampler` at temperature 0). Qwen3's model card explicitly warns
/// against greedy decoding on the quantized weights — it collapses to
/// immediate-EOS (empty) or a repetition loop. These assertions lock in a
/// non-greedy, truncated profile.
final class LocalLLMDecodingTests: XCTestCase {
    func testCleanupParametersAreNonGreedy() {
        let p = LocalLLMSession.cleanupParameters
        // Truncation MUST be on — topP in the open interval (0,1) and/or topK>0.
        XCTAssertTrue(p.topP > 0 && p.topP < 1,
                      "topP must enable nucleus truncation (0 < topP < 1), was \(p.topP)")
        XCTAssertGreaterThan(p.topK, 0,
                             "topK must enable top-k truncation (>0), was \(p.topK)")
        // Repetition penalty present — defends against the degenerate repeat loop.
        let penalty = try? XCTUnwrap(p.repetitionPenalty)
        XCTAssertNotNil(penalty, "repetitionPenalty must be set to break repeat loops")
        if let penalty = p.repetitionPenalty {
            XCTAssertGreaterThan(penalty, 1.0,
                                 "repetitionPenalty must be > 1.0 to penalize repeats, was \(penalty)")
        }
        // Temperature stays low (deterministic-leaning cleanup) but non-zero
        // (temperature 0 forces ArgMaxSampler = pure greedy).
        XCTAssertGreaterThan(p.temperature, 0,
                             "temperature 0 forces greedy ArgMaxSampler")
        XCTAssertLessThanOrEqual(p.temperature, 0.5,
                                 "cleanup should stay deterministic-leaning")
    }

    /// The chosen profile must resolve to the truncated `TopPSampler`, not the
    /// untruncated `CategoricalSampler`. This is the behavioral contract the raw
    /// field values (asserted above) exist to satisfy.
    ///
    /// Opt-in: `GenerateParameters.sampler()` allocates an `MLXArray`, which
    /// fails to load the default metallib under `swift test` (same constraint as
    /// the on-device inference IT). Run on Apple Silicon with
    ///   SIDEKEY_RUN_LOCAL_LLM_IT=1 swift test --filter LocalLLMDecodingTests
    func testCleanupParametersResolveToTruncatedSampler() throws {
        guard ProcessInfo.processInfo.environment["SIDEKEY_RUN_LOCAL_LLM_IT"] == "1" else {
            throw XCTSkip("set SIDEKEY_RUN_LOCAL_LLM_IT=1 — sampler() touches MLX (metallib-blocked under swift test)")
        }
        let sampler = LocalLLMSession.cleanupParameters.sampler()
        XCTAssertTrue(sampler is TopPSampler,
                      "non-greedy cleanup must use TopPSampler, got \(type(of: sampler))")
    }

    /// A bounded token cap is retained so a misbehaving turn cannot run away.
    func testCleanupParametersKeepBoundedTokenCap() {
        let max = LocalLLMSession.cleanupParameters.maxTokens
        XCTAssertEqual(max, 1024)
    }
}
