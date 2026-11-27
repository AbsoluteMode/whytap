import Foundation

/// Drains a child process's stderr and keeps its last `maxBytes`. Only the
/// byte count reaches the log: stderr can carry paths, prompts or account
/// details. NOT thread-safe on its
/// own — the provider funnels all appends through its single stderr
/// readability handler (one queue), matching the existing buffer pattern.
///
/// Trimming is byte-wise, so a multi-byte UTF-8 codepoint split across the trim
/// boundary may render as a single U+FFFD replacement char at the very start of
/// `tail` — harmless for a logging buffer.
///
/// WHY: docs/decisions/2026-06-16-agent-turn-watchdog.md
struct BoundedStderrBuffer {
    private let maxBytes: Int
    private(set) var data = Data()
    /// Every byte seen, for the exit log line (the content is never logged).
    private(set) var byteCount = 0

    init(maxBytes: Int = 16 * 1024) {
        precondition(maxBytes > 0, "maxBytes must be > 0")
        self.maxBytes = maxBytes
    }

    mutating func append(_ chunk: Data) {
        byteCount += chunk.count
        data.append(chunk)
        if data.count > maxBytes {
            data.removeSubrange(0..<(data.count - maxBytes))
        }
    }

    var tail: String { String(decoding: data, as: UTF8.self) }
}
