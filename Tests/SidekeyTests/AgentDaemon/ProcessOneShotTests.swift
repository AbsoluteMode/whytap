import Foundation
import XCTest
@testable import Sidekey

/// The sign-in checks (`claude auth status`, `codex login status`) run through
/// ProcessOneShot; one deadline bounds the whole call.
final class ProcessOneShotTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    private func timed(_ body: () -> ProcessResult?) -> (ProcessResult?, TimeInterval) {
        let start = ProcessInfo.processInfo.systemUptime
        let result = body()
        return (result, ProcessInfo.processInfo.systemUptime - start)
    }

    func testOutputAndExitCodeOfANormalCommand() {
        let result = ProcessOneShot.run(binary: sh, args: ["-c", "printf out; printf err >&2; exit 3"],
                                        environment: [:], timeout: 5)
        XCTAssertEqual(result?.stdout, "out")
        XCTAssertEqual(result?.stderr, "err")
        XCTAssertEqual(result?.exitCode, 3)
    }

    func testLargeOutputDoesNotBlockTheChild() {
        let result = ProcessOneShot.run(binary: sh, args: ["-c", "head -c 300000 /dev/zero | tr '\\0' a"],
                                        environment: [:], timeout: 5)
        XCTAssertEqual(result?.stdout.count, 300_000)
    }

    func testTimeoutIsAFailureEvenWhenTheChildIgnoresTerminate() {
        let (result, elapsed) = timed {
            ProcessOneShot.run(binary: sh, args: ["-c", "trap '' TERM; /bin/sleep 1.0; printf 'late\\n'"],
                               environment: [:], timeout: 0.10)
        }
        XCTAssertNil(result, "a timed-out check is not a normal answer")
        XCTAssertLessThan(elapsed, 0.65)
    }

    func testAHelperHoldingThePipesCannotOutlastTheDeadline() {
        let (result, elapsed) = timed {
            ProcessOneShot.run(binary: sh, args: ["-c", "printf ready; (/bin/sleep 1.0) & exit 0"],
                               environment: [:], timeout: 0.10)
        }
        XCTAssertLessThan(elapsed, 0.65)
        XCTAssertNil(result, "output without EOF by the deadline is not a whole answer")
    }

    /// A signed-in-looking prefix on either pipe, with the rest held open by
    /// a helper past the deadline, must fail the check.
    func testAValidLookingPrefixWithoutEOFFailsOnEitherPipe() {
        for (label, status, held) in [("Claude stdout", #"{"loggedIn":true}"#, ""),
                                       ("Codex stderr", "Logged in using ChatGPT", "1>&2")] {
            let program = "printf '%s' \"$1\" \(held); (/bin/sleep 0.9; printf 'unfinished' \(held)) "
                + (held.isEmpty ? "2>/dev/null" : "1>/dev/null") + " & exit 0"
            let (result, elapsed) = timed {
                ProcessOneShot.run(binary: sh, args: ["-c", program, "fixture", status], environment: [:], timeout: 0.15)
            }
            XCTAssertLessThan(elapsed, 0.65, label)
            XCTAssertNil(result, label)
        }
    }

    func testAHelperThatFinishesInTimeKeepsTheWholeAnswer() {
        let result = ProcessOneShot.run(binary: sh, args: ["-c", "(/bin/sleep 0.1; printf done) & printf 'start '; wait"],
                                        environment: [:], timeout: 5)
        XCTAssertEqual(result?.stdout, "start done")
        XCTAssertEqual(result?.exitCode, 0)
    }

    func testMissingBinaryIsNil() {
        XCTAssertNil(ProcessOneShot.run(binary: URL(fileURLWithPath: "/nonexistent/claude"), args: [],
                                        environment: [:], timeout: 1))
    }
}
