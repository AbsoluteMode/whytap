import Foundation

/// Holds the last `maxBytes` of a child process's stderr so it can be logged
/// on exit / watchdog-hang instead of being discarded. NOT thread-safe on its
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

    init(maxBytes: Int = 16 * 1024) {
        precondition(maxBytes > 0, "maxBytes must be > 0")
        self.maxBytes = maxBytes
    }

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > maxBytes {
            data.removeSubrange(0..<(data.count - maxBytes))
        }
    }

    var tail: String { String(decoding: data, as: UTF8.self) }
}
