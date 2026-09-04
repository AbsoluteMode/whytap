import Foundation

/// Inbound / outbound WebSocket frame in the shape the BYOK adapters need.
/// Mirrors `URLSessionWebSocketTask.Message` without coupling tests to
/// Foundation's task type.
enum StreamingFrame {
    case text(String)
    case data(Data)
}

/// Abstract transport over a single WebSocket connection to a transcription
/// provider. The production implementation wraps `URLSessionWebSocketTask`;
/// tests inject a stub.
///
/// Concurrency: `send` / `receive` are async; the transport is expected
/// to serialize one outstanding receive at a time.
protocol StreamingTransporting: AnyObject, Sendable {
    func resume()
    func cancel(reason: String?)
    func send(_ frame: StreamingFrame) async throws
    func receive() async -> Result<StreamingFrame, Error>
}

/// Concrete `StreamingTransporting` backed by `URLSessionWebSocketTask`.
final class URLSessionWebSocketTransport: StreamingTransporting, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() {
        task.resume()
    }

    func cancel(reason: String?) {
        task.cancel(with: .normalClosure, reason: reason?.data(using: .utf8))
    }

    func send(_ frame: StreamingFrame) async throws {
        switch frame {
        case .text(let s):
            try await task.send(.string(s))
        case .data(let d):
            try await task.send(.data(d))
        }
    }

    func receive() async -> Result<StreamingFrame, Error> {
        do {
            let msg = try await task.receive()
            switch msg {
            case .string(let s): return .success(.text(s))
            case .data(let d): return .success(.data(d))
            @unknown default:
                return .failure(StreamingSessionError.unsupported)
            }
        } catch {
            return .failure(error)
        }
    }
}
