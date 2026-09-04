import Foundation
@testable import Sidekey

/// Stub `StreamingAudioSourcing` for the degraded-path tests. Unlike the
/// `StubAudioSource` in `SonioxStreamingSessionTests`, this double:
///
///   - returns real bytes from `capturedPCM16()` (the local-audio capture
///     the degraded path retains for batch recovery), and
///   - keeps its `chunks` stream OPEN across a transport error — modelling
///     the Task-2 contract that capture (and the tee filling
///     `TurnAudioBuffer`) keeps running after the WS dies. The stream only
///     finishes when `stop()` is called (the user releasing the hotkey).
final class CapturingStubAudioSource: StreamingAudioSourcing, @unchecked Sendable {
    let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    let failures: AsyncStream<StreamingAudioEngineError>
    private let failuresContinuation: AsyncStream<StreamingAudioEngineError>.Continuation

    /// Bytes the tee would have accumulated this turn; returned by
    /// `capturedPCM16()` so the degraded outcome can be batch-transcribed.
    private let captured: Data

    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var didFinish = false

    init(captured: Data) {
        self.captured = captured
        let (stream, cont) = AsyncStream<Data>.makeStream()
        self.chunks = stream
        self.continuation = cont
        let (failStream, failCont) = AsyncStream<StreamingAudioEngineError>.makeStream()
        self.failures = failStream
        self.failuresContinuation = failCont
    }

    func start() throws { didStart = true }

    /// Mirror the real engine: `finish()` keeps the stream open (the tail is
    /// still being captured); `stop()` closes it.
    func finish() { didFinish = true }

    func stop() {
        guard !didStop else { return }
        didStop = true
        continuation.finish()
        failuresContinuation.finish()
    }

    func emit(_ data: Data) { continuation.yield(data) }

    func emitFailure(_ failure: StreamingAudioEngineError) {
        failuresContinuation.yield(failure)
    }

    func capturedPCM16() -> Data { captured }
}
