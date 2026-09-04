import XCTest
@testable import Sidekey

@MainActor
final class PasteTargetValidatorTests: XCTestCase {
    /// `pid_t` of -1 cannot resolve to any real process. The validator
    /// guards against this before touching `AXUIElementCreateApplication`
    /// (which on some macOS revisions has crashed on negative pids in
    /// the past). The expected return is `false` — the `pid <= 0` gate
    /// is the only path that's strict regardless of the new permissive
    /// AX default.
    func testInvalidPidReturnsFalseWithoutCrashing() {
        XCTAssertFalse(PasteTargetValidator.appHasFocusedTextInput(pid: -1))
    }

    /// `pid_t` of 0 is a sentinel value (used by AutoPasteEngine's log
    /// line for "no target remembered"). Same contract as -1: short-
    /// circuit to `false` before any AX work.
    func testZeroPidReturnsFalseWithoutCrashing() {
        XCTAssertFalse(PasteTargetValidator.appHasFocusedTextInput(pid: 0))
    }

    /// A pid that's syntactically valid but extremely unlikely to map
    /// to a running process (32-bit max). Under the iter 21 permissive-
    /// default contract, every AX source errors out (the pid maps to
    /// nothing), no source returns a definitive non-text element, so
    /// the validator falls through to the permissive default and
    /// returns `true`. This is the Electron-shaped path: AX is
    /// unavailable but we want to show the hint anyway.
    func testNonexistentPidReturnsTrueViaPermissiveDefault() {
        let bogus: pid_t = .max
        XCTAssertTrue(PasteTargetValidator.appHasFocusedTextInput(pid: bogus))
    }

    /// Bundle-id blacklist takes priority over the permissive default.
    /// Even if AX would have fallen through to "true", a blacklisted
    /// bundle id (Finder) suppresses the hint. The pid here doesn't
    /// need to be valid — the blacklist check happens before any AX
    /// work, gated only by `pid > 0`.
    func testBlacklistedBundleIdReturnsFalse() {
        let bogus: pid_t = .max
        XCTAssertFalse(
            PasteTargetValidator.appHasFocusedTextInput(
                pid: bogus,
                bundleIdentifier: "com.apple.finder"
            )
        )
    }

    /// A non-blacklisted bundle id behaves the same as `nil` — the
    /// permissive default applies once AX fails on every source.
    func testNonBlacklistedBundleIdAllowsPermissiveDefault() {
        let bogus: pid_t = .max
        XCTAssertTrue(
            PasteTargetValidator.appHasFocusedTextInput(
                pid: bogus,
                bundleIdentifier: "com.example.someapp"
            )
        )
    }

    /// The validator queries the running test host's own pid. In CI the
    /// xctest runner has no focused UI element (it's a faceless
    /// process), but under the permissive default that means the
    /// validator may still return `true`. Either outcome is acceptable
    /// — the point is that the call doesn't crash or hang on a real
    /// live pid.
    func testTestHostPidDoesNotCrash() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        _ = PasteTargetValidator.appHasFocusedTextInput(pid: myPid)
        // No assert on return value: depends on environment.
    }
}
