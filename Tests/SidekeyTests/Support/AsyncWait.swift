import XCTest

/// Wait for an asynchronous side effect instead of sleeping for a fixed
/// duration and hoping it landed.
///
/// `Task.sleep` only guarantees a *minimum*; it says nothing about the work
/// scheduled to happen during that window actually having run. On a fast
/// machine the effect always lands first, so a fixed sleep looks reliable —
/// until CI runs the same test on a loaded two-core runner and the assertion
/// fires before the effect. Polling turns that class of test from
/// "usually true" into "true as soon as it is true", and keeps the suite fast
/// because the common case returns on the first check.
///
/// Use for *positive* expectations ("this eventually happens"). A negative
/// expectation ("this must never happen") still needs a real sleep: there is
/// nothing to poll for.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(3),
    pollInterval: Duration = .milliseconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return condition()
}

/// `waitUntil` plus an `XCTAssert`, so a timeout reports the expectation that
/// never came true rather than a bare `false`.
@MainActor
func assertEventually(
    _ message: @autoclosure () -> String,
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let satisfied = await waitUntil(timeout: timeout, condition)
    XCTAssertTrue(satisfied, message(), file: file, line: line)
}
