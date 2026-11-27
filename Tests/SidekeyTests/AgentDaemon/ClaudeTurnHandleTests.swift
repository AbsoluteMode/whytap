import Foundation
import XCTest
@testable import Sidekey

/// A turn's result closes that turn's own stdin, whenever it arrives: during
/// the spawn (before the writer is registered), after it, or late from a turn
/// the user already replaced.
final class ClaudeTurnHandleTests: XCTestCase {
    private let result = #"{"type":"result","subtype":"success","session_id":"fixture","is_error":false}"#

    private final class RecordingWriter: ClaudeStdinWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var _closed = 0
        private var _lines: [String] = []
        var onLine: (() -> Void)?
        var closed: Int { lock.lock(); defer { lock.unlock() }; return _closed }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func writeLine(_ line: String) {
            lock.lock(); _lines.append(line); lock.unlock()
            onLine?()
        }
        var onClose: (() -> Void)?
        func closeStdin() {
            lock.lock(); _closed += 1; lock.unlock()
            onClose?()
        }
        func terminate() {}
        var processIdentifier: Int32? { nil }
    }

    private struct Turn {
        let writer = RecordingWriter()
        var onLine: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
    }

    private func options() -> AgentRunOptions {
        AgentRunOptions(workingDirectory: FileManager.default.temporaryDirectory)
    }

    func testAResultDuringSpawnStillClosesThatTurnsStdin() {
        let writer = RecordingWriter()
        let provider = ClaudeCodeProvider(locate: { URL(fileURLWithPath: "/usr/bin/false") },
                                          runStreaming: { _, _, _, onLine, onExit in
            onLine(self.result)
            onExit(0)
            return writer
        }, idleSoftTimeout: 10, idleHardTimeout: 20)
        let stream = provider.run(prompt: "synthetic", resumeSessionID: nil, options: options())
        withExtendedLifetime(stream) {
            XCTAssertEqual(writer.closed, 1)
        }
    }

    /// The deferred close at registration makes the child exit before the
    /// writer is published: that exited writer must never become active.
    func testAnExitDuringRegistrationNeverPublishesTheExitedWriter() {
        let writer = RecordingWriter()
        let wrote = expectation(description: "the exited child receives nothing")
        wrote.isInverted = true
        let provider = ClaudeCodeProvider(locate: { URL(fileURLWithPath: "/usr/bin/false") },
                                          runStreaming: { _, _, _, onLine, onExit in
            writer.onClose = { onExit(0) }
            onLine(self.result)
            return writer
        }, idleSoftTimeout: 10, idleHardTimeout: 20)
        let stream = provider.run(prompt: "synthetic", resumeSessionID: nil, options: options())
        writer.onLine = { wrote.fulfill() }   // after the prompt line run() writes itself
        provider.respondToPermission(requestId: "late", decision: .deny(message: "no"))
        withExtendedLifetime(stream) { wait(for: [wrote], timeout: 0.35) }
    }

    /// An exit while the child is still starting (before its writer exists).
    func testAnExitBeforeRegistrationNeverPublishesTheWriter() {
        let writer = RecordingWriter()
        let wrote = expectation(description: "the exited child receives nothing")
        wrote.isInverted = true
        let provider = ClaudeCodeProvider(locate: { URL(fileURLWithPath: "/usr/bin/false") },
                                          runStreaming: { _, _, _, _, onExit in
            onExit(1)
            return writer
        }, idleSoftTimeout: 10, idleHardTimeout: 20)
        let stream = provider.run(prompt: "synthetic", resumeSessionID: nil, options: options())
        writer.onLine = { wrote.fulfill() }
        provider.respondToPermission(requestId: "late", decision: .deny(message: "no"))
        withExtendedLifetime(stream) { wait(for: [wrote], timeout: 0.35) }
    }

    func testAResultAfterStartClosesStdinOnce() {
        var turn = Turn()
        let writer = turn.writer
        let provider = ClaudeCodeProvider(locate: { URL(fileURLWithPath: "/usr/bin/false") },
                                          runStreaming: { _, _, _, onLine, onExit in
            turn.onLine = onLine
            turn.onExit = onExit
            return writer
        }, idleSoftTimeout: 10, idleHardTimeout: 20)
        let stream = provider.run(prompt: "synthetic", resumeSessionID: nil, options: options())
        withExtendedLifetime(stream) {
            XCTAssertEqual(writer.closed, 0, "nothing closes before the result")
            turn.onLine?(result)
            turn.onExit?(0)
            XCTAssertEqual(writer.closed, 1)
        }
    }

    func testALateResultOfAReplacedTurnLeavesTheNewTurnAlone() {
        var turns: [Turn] = []
        let provider = ClaudeCodeProvider(locate: { URL(fileURLWithPath: "/usr/bin/false") },
                                          runStreaming: { _, _, _, onLine, onExit in
            var turn = Turn()
            turn.onLine = onLine
            turn.onExit = onExit
            turns.append(turn)
            return turn.writer
        }, idleSoftTimeout: 10, idleHardTimeout: 20)
        let first = provider.run(prompt: "first", resumeSessionID: nil, options: options())
        let second = provider.run(prompt: "second", resumeSessionID: nil, options: options())
        withExtendedLifetime((first, second)) {
            XCTAssertEqual(turns.count, 2)
            turns[0].onLine?(result)
            turns[0].onExit?(0)
            XCTAssertEqual(turns[0].writer.closed, 1)
            XCTAssertEqual(turns[1].writer.closed, 0, "the old turn's result never closes the new turn's stdin")

            let answered = expectation(description: "the live turn receives the permission answer")
            turns[1].writer.onLine = { answered.fulfill() }
            provider.respondToPermission(requestId: "r1", decision: .deny(message: "no"))
            wait(for: [answered], timeout: 2)
            XCTAssertTrue(turns[1].writer.lines.contains { $0.contains("r1") })
            XCTAssertFalse(turns[0].writer.lines.contains { $0.contains("r1") })
        }
    }
}
