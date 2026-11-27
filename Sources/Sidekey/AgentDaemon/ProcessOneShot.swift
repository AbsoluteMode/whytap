import Darwin
import Foundation

/// Runs a short CLI command (`auth status`, `login status`) to completion.
/// Both pipes drain while the child runs, so a large output cannot block it.
/// One deadline bounds the whole call: a child that has not exited by then is
/// terminated (then killed if it ignores TERM) and the call returns nil, and a
/// helper that inherited the pipes cannot hold the call open after the child
/// exits either.
enum ProcessOneShot {
    /// How long a timed-out child gets between TERM and KILL.
    static let terminateGrace: TimeInterval = 0.2

    static func run(binary: URL, args: [String], environment: [String: String],
                    timeout: TimeInterval = 20) -> ProcessResult? {
        let deadline = DispatchTime.now() + timeout
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let stdout = Drain(out.fileHandleForReading)
        let stderr = Drain(err.fileHandleForReading)
        do { try process.run() } catch {
            stdout.stop()
            stderr.stop()
            return nil
        }

        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + terminateGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminateGrace)
            }
            stdout.stop()
            stderr.stop()
            return nil
        }
        // The child exited; its output is complete at EOF unless a helper it
        // started still holds the pipes. The same deadline bounds that wait.
        _ = stdout.finished.wait(timeout: deadline)
        _ = stderr.finished.wait(timeout: deadline)
        return ProcessResult(stdout: String(decoding: stdout.stop(), as: UTF8.self),
                             stderr: String(decoding: stderr.stop(), as: UTF8.self),
                             exitCode: process.terminationStatus)
    }

    /// Collects one pipe without a blocking read, so stopping it never waits
    /// for the writer.
    private final class Drain: @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let handle: FileHandle
        private let lock = NSLock()
        private var data = Data()
        private var open = true

        init(_ handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    self.close()
                    self.finished.signal()
                } else {
                    self.lock.lock()
                    if self.open { self.data.append(chunk) }
                    self.lock.unlock()
                }
            }
        }

        /// Stops reading and returns what arrived.
        @discardableResult
        func stop() -> Data {
            close()
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        private func close() {
            lock.lock()
            let wasOpen = open
            open = false
            lock.unlock()
            guard wasOpen else { return }
            // Only the handler is removed: closing the descriptor here could
            // race a handler call already reading it. The pipe closes when its
            // handle is released.
            handle.readabilityHandler = nil
        }
    }
}
