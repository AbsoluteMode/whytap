import Foundation

/// Splits a child process's stdout into JSON lines. Not thread-safe: the CLI
/// providers touch it only on their serial buffer queue.
struct ProcessLineBuffer {
    private var buffer = Data()

    /// Appends a chunk and returns every complete line in it.
    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    /// At exit: the remaining bytes, each line separately (a CLI can write its
    /// last events in one chunk), plus an unterminated last line.
    mutating func finish(with remaining: Data) -> [String] {
        var lines = append(remaining)
        if !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer = Data()
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
