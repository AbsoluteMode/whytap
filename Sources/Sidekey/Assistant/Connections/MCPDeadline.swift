import Foundation

/// One deadline for a whole operation. At the deadline, or when the caller is
/// cancelled, `run` returns at once and cancels the operation without waiting
/// for it to wind down; every operation passed here stops its own I/O when
/// cancelled (stdin polls, URLSession tasks, the folder reader's checks).
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md (Bounds)
enum MCPDeadline {
    static func run<T: Sendable>(until deadline: Date, timeout: MCPError,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                box.start(continuation,
                          work: Task { do { box.finish(.success(try await operation())) } catch { box.finish(.failure(error)) } },
                          timer: Task {
                              let seconds = max(0, deadline.timeIntervalSinceNow)
                              try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                              guard !Task.isCancelled else { return }
                              box.finish(.failure(timeout))
                          })
            }
        } onCancel: {
            box.finish(.failure(MCPError.cancelled))
        }
    }

    static func seconds(until deadline: Date) -> Int { max(1, Int(deadline.timeIntervalSinceNow.rounded())) }

    /// Resumes the caller once, with whichever of the operation, the timer
    /// or cancellation comes first, and cancels the other two.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        func start(_ continuation: CheckedContinuation<T, Error>, work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            if let early {
                lock.unlock()
                work.cancel(); timer.cancel()
                continuation.resume(with: early)
                return
            }
            self.continuation = continuation; self.work = work; self.timer = timer
            lock.unlock()
        }

        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard let continuation else {
                if early == nil { early = result }
                lock.unlock()
                return
            }
            self.continuation = nil
            let (work, timer) = (self.work, self.timer)
            lock.unlock()
            work?.cancel(); timer?.cancel()
            continuation.resume(with: result)
        }
    }
}

/// A flag set from a cancellation handler and read by blocking I/O loops.
final class MCPCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

/// A revocable permission checked by `MCPClient` in the same actor step that
/// dispatches a tool call: once the controller revokes it (stop, disable,
/// removal, reclassification), no further call goes out under it.
final class SourceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    var isValid: Bool { lock.withLock { !revoked } }
    func revoke() { lock.withLock { revoked = true } }
}
