import Foundation
import OSLog

/// Everything a stored Smart / translation timing line carries: fixed words,
/// verified catalog names and numbers. No prompt, reply, key, URL, error body
/// or saved model name can reach the log except through these fields, and
/// tests read them through the client's `diagnostics` sink.
// WHY: .project-docs/decisions/2026-11-24-smart-minimal-reasoning.md
struct CleanupDiagnostics: Equatable {
    /// `openrouter`, `openai`, `anthropic` or `custom` (a user's own server).
    var provider: String
    /// A `CleanupDiagnosticModel` label, or `custom`.
    var model: String
    /// OpenRouter's `gen-` ID, or `unavailable`.
    var requestID: String = "unavailable"
    /// The reasoning setting the answered request carried, or `default`.
    var effort: String
    /// The HTTP status of the last response.
    var status: Int
    var catalogMs: Int = 0
    /// From sending the first request to the last response, a repeat included.
    var llmMs: Int
    /// `-1` when the provider reported none; never an inferred zero.
    var outputTokens: Int = -1
    var reasoningTokens: Int = -1
    /// The provider refused the request with the reasoning field and it was
    /// repeated without it.
    var effortRefused: Bool = false

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "cleanup-llm")

    /// The default level, so the unified system log stores the line.
    static func write(_ line: CleanupDiagnostics) {
        os_log("cleanup provider=%{public}@ model=%{public}@ request_id=%{public}@ effort=%{public}@ status=%{public}d catalog_ms=%{public}d llm_ms=%{public}d output_tokens=%{public}d reasoning_tokens=%{public}d effort_refused=%{public}d",
               log: log, type: .default,
               line.provider, line.model, line.requestID, line.effort, line.status,
               line.catalogMs, line.llmMs, line.outputTokens, line.reasoningTokens,
               line.effortRefused ? 1 : 0)
    }
}
