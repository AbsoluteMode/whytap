import Foundation
@testable import Sidekey

/// Stub WS transport: records sent frames and lets the test enqueue
/// inbound frames the client will see on the next `.receive()` call.
final class StubWebSocketTransport: StreamingTransporting, @unchecked Sendable {
    enum Sent: Equatable {
        case text(String)
        case data(Data)
    }

    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var inbound: [Result<StreamingFrame, Error>] = []
    private var continuations: [CheckedContinuation<Result<StreamingFrame, Error>, Never>] = []

    private(set) var resumed = false
    private(set) var cancelled = false
    private(set) var cancelReason: String?

    /// When set, every subsequent `send` throws it — simulates a socket
    /// broken for OUTBOUND frames (e.g. the end-of-stream marker) while the
    /// receive side is still pending. Lets session tests pin the
    /// fail-fast-on-eof-send-error contract.
    var sendError: Error?

    var sent: [Sent] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    func resume() {
        resumed = true
    }

    func cancel(reason: String?) {
        cancelled = true
        cancelReason = reason
        // Drain pending receives with a cancellation error so the receive
        // loop on the client side can terminate cleanly.
        lock.lock()
        let conts = continuations
        continuations.removeAll()
        lock.unlock()
        for c in conts {
            c.resume(returning: .failure(StreamingSessionError.transportCancelled))
        }
    }

    func send(_ frame: StreamingFrame) async throws {
        lock.lock()
        if let sendError {
            lock.unlock()
            throw sendError
        }
        switch frame {
        case .text(let s): _sent.append(.text(s))
        case .data(let d): _sent.append(.data(d))
        }
        lock.unlock()
    }

    func receive() async -> Result<StreamingFrame, Error> {
        await withCheckedContinuation { (c: CheckedContinuation<Result<StreamingFrame, Error>, Never>) in
            lock.lock()
            if !inbound.isEmpty {
                let next = inbound.removeFirst()
                lock.unlock()
                c.resume(returning: next)
            } else {
                continuations.append(c)
                lock.unlock()
            }
        }
    }

    /// Test helper: deliver an inbound frame to the next pending receive,
    /// or queue it if no receive is in flight yet.
    func deliver(_ result: Result<StreamingFrame, Error>) {
        lock.lock()
        if !continuations.isEmpty {
            let c = continuations.removeFirst()
            lock.unlock()
            c.resume(returning: result)
        } else {
            inbound.append(result)
            lock.unlock()
        }
    }

    func deliverText(_ json: String) {
        deliver(.success(.text(json)))
    }
}
