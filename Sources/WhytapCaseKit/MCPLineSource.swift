import Darwin
import Foundation

/// Request lines of a stdio MCP server, read so that nothing is lost when the
/// helper replaces itself with a new build: every byte taken from stdin is
/// either handed to the server as a line or returned by `drainForHandover()`.
// WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md
public protocol MCPLineSource: AnyObject {
    /// Blocks until `takeLine()` has a line, or returns false at end of input.
    func waitForLine() -> Bool
    /// Never blocks. The server calls it while holding its handover lock, so a
    /// line is either dispatched or still here when the helper hands over.
    func takeLine() -> String?
    /// Stops reading and returns every unconsumed byte, in order.
    func drainForHandover() -> Data
    /// After a failed handover: puts `data` back in front and resumes reading.
    func restore(_ data: Data)
    /// After a successful handover (tests): `waitForLine()` returns false.
    func close()
}

extension MCPLineSource {
    /// Splits the next complete line off `buffer` like `Swift.readLine()`:
    /// strips `\n` or `\r\n`; at end of input a final unterminated line counts.
    static func splitLine(_ buffer: inout Data, atEOF: Bool) -> String? {
        if let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == 0x0D { line = line.dropLast() }
            return String(decoding: line, as: UTF8.self)
        }
        guard atEOF, !buffer.isEmpty else { return nil }
        defer { buffer = Data() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Reads a file descriptor (stdin) itself instead of through stdio, whose
/// read-ahead buffer would vanish on `execve`. `read()` runs only under the
/// lock and only while no handover is draining, so bytes the old image never
/// took stay in the pipe for the new one.
public final class FileDescriptorLineSource: MCPLineSource, @unchecked Sendable {
    private let fd: Int32
    private let condition = NSCondition()
    private var buffer: Data
    private var eof = false
    private var drained = false
    private var closed = false
    /// An unterminated frame is kept only up to this size; the rest of that
    /// line is dropped and the server answers the truncated frame as too large.
    private let maxFrameBytes: Int
    /// Bytes of the current unterminated frame kept in `buffer`.
    private var frameLength = 0

    public static let defaultMaxFrameBytes = 512 * 1024 + 1 // just above AppControlMCPServer.maxLineBytes

    public init(fd: Int32 = STDIN_FILENO, prefill: Data = Data(), maxFrameBytes: Int = defaultMaxFrameBytes) {
        self.fd = fd
        self.buffer = Data()
        self.maxFrameBytes = maxFrameBytes
        append(prefill)
    }

    /// Lock held (or in init). Keeps at most `maxFrameBytes` of every frame.
    private func append<Bytes: Collection>(_ chunk: Bytes) where Bytes.Element == UInt8 {
        var rest = chunk[...]
        while !rest.isEmpty {
            let newline = rest.firstIndex(of: 0x0A)
            let segment = rest[..<(newline ?? rest.endIndex)]
            let kept = segment.prefix(max(0, maxFrameBytes - frameLength))
            buffer.append(contentsOf: kept)
            frameLength += kept.count
            guard let newline else { break }
            buffer.append(0x0A)
            frameLength = 0
            rest = rest[rest.index(after: newline)...]
        }
    }

    public func waitForLine() -> Bool {
        while true {
            condition.lock()
            while drained && !closed { condition.wait() }
            if closed { condition.unlock(); return false }
            if buffer.contains(0x0A) || (eof && !buffer.isEmpty) { condition.unlock(); return true }
            if eof { condition.unlock(); return false }
            condition.unlock()

            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if ready < 0 && errno != EINTR { markEOF(); continue }
            guard ready > 0 else { continue }

            condition.lock()
            if !drained && !closed && !eof {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &chunk, chunk.count)
                if count > 0 { append(chunk[0..<count]) }
                else if count == 0 || errno != EINTR && errno != EAGAIN { eof = true }
            }
            condition.unlock()
        }
    }

    private func markEOF() {
        condition.lock(); eof = true; condition.unlock()
    }

    public func takeLine() -> String? {
        condition.lock(); defer { condition.unlock() }
        guard !drained, !closed else { return nil }
        let line = Self.splitLine(&buffer, atEOF: eof)
        if buffer.isEmpty { frameLength = 0 }
        return line
    }

    public func drainForHandover() -> Data {
        condition.lock(); defer { condition.unlock() }
        drained = true
        let data = buffer
        buffer = Data(); frameLength = 0
        return data
    }

    public func restore(_ data: Data) {
        condition.lock()
        let after = buffer
        buffer = Data(); frameLength = 0
        append(data); append(after)
        drained = false
        condition.broadcast()
        condition.unlock()
    }

    public func close() {
        condition.lock(); closed = true; condition.broadcast(); condition.unlock()
    }
}

/// Adapts a `readLine` closure (tests, callers without a handover). The
/// closure's own buffering is outside the handover, so production MCP modes
/// use `FileDescriptorLineSource`.
public final class ClosureLineSource: MCPLineSource, @unchecked Sendable {
    private let readLine: () -> String?
    private let lock = NSLock()
    private var buffer = Data()
    private var eof = false
    private var drained = false
    private var closed = false

    public init(_ readLine: @escaping () -> String?) { self.readLine = readLine }

    public func waitForLine() -> Bool {
        lock.lock()
        if closed || drained { lock.unlock(); return false }
        if buffer.contains(0x0A) { lock.unlock(); return true }
        if eof { lock.unlock(); return false }
        lock.unlock()
        let line = readLine()
        lock.lock(); defer { lock.unlock() }
        if let line { buffer.append(Data((line + "\n").utf8)) } else { eof = true }
        return !closed && buffer.contains(0x0A)
    }

    public func takeLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !drained, !closed else { return nil }
        return Self.splitLine(&buffer, atEOF: false)
    }

    public func drainForHandover() -> Data {
        lock.lock(); defer { lock.unlock() }
        drained = true
        let data = buffer
        buffer = Data()
        return data
    }

    public func restore(_ data: Data) {
        lock.lock(); buffer = data + buffer; drained = false; lock.unlock()
    }

    public func close() { lock.lock(); closed = true; lock.unlock() }
}
