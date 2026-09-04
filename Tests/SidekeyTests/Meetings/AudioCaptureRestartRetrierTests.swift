import XCTest
@testable import Sidekey

final class AudioCaptureRestartRetrierTests: XCTestCase {
    func test_retriesAfterFailedAttemptAndThenSucceeds() async throws {
        let recorder = RetryRecorder(failuresBeforeSuccess: 1)
        let retrier = AudioCaptureRestartRetrier(
            delaysNanoseconds: [0, 25],
            sleep: { delay in
                await recorder.recordSleep(delay)
            }
        )

        try await retrier.run(
            operation: { attempt in
                try await recorder.runAttempt(attempt)
            },
            onFailure: { attempt, _ in
                await recorder.recordFailure(attempt)
            }
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.attempts, [1, 2])
        XCTAssertEqual(snapshot.failures, [1])
        XCTAssertEqual(snapshot.sleeps, [25])
    }

    func test_throwsLastErrorAfterAttemptsAreExhausted() async {
        let recorder = RetryRecorder(failuresBeforeSuccess: .max)
        let retrier = AudioCaptureRestartRetrier(
            delaysNanoseconds: [0, 10, 20],
            sleep: { delay in
                await recorder.recordSleep(delay)
            }
        )

        do {
            try await retrier.run(
                operation: { attempt in
                    try await recorder.runAttempt(attempt)
                },
                onFailure: { attempt, _ in
                    await recorder.recordFailure(attempt)
                }
            )
            XCTFail("Expected retrier to throw")
        } catch {
            XCTAssertEqual(error as? RetryTestError, .failedAttempt(3))
        }

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.attempts, [1, 2, 3])
        XCTAssertEqual(snapshot.failures, [1, 2, 3])
        XCTAssertEqual(snapshot.sleeps, [10, 20])
    }
}

private actor RetryRecorder {
    private let failuresBeforeSuccess: Int
    private var attempts: [Int] = []
    private var failures: [Int] = []
    private var sleeps: [UInt64] = []

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func runAttempt(_ attempt: Int) throws {
        attempts.append(attempt)
        if attempt <= failuresBeforeSuccess {
            throw RetryTestError.failedAttempt(attempt)
        }
    }

    func recordFailure(_ attempt: Int) {
        failures.append(attempt)
    }

    func recordSleep(_ delay: UInt64) {
        sleeps.append(delay)
    }

    func snapshot() -> (attempts: [Int], failures: [Int], sleeps: [UInt64]) {
        (attempts, failures, sleeps)
    }
}

private enum RetryTestError: Error, Equatable {
    case failedAttempt(Int)
}
