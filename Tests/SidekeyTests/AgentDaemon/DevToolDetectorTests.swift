import XCTest
@testable import Sidekey

final class LoginShellWhichTests: XCTestCase {
    func testParseTrimsAndMapsEmptyToNil() {
        XCTAssertEqual(LoginShellWhich.parse("  /opt/homebrew/bin/brew\n"), "/opt/homebrew/bin/brew")
        XCTAssertNil(LoginShellWhich.parse(""))
        XCTAssertNil(LoginShellWhich.parse(" \n"))
        XCTAssertNil(LoginShellWhich.parse(nil))
    }

    /// Smoke: resolving a universally-present command through the real login
    /// shell yields a path. (Positive-only — a negative case would require the
    /// developer's shell rc to print nothing, which we cannot guarantee.)
    func testResolveFindsUbiquitousCommand() {
        XCTAssertNotNil(LoginShellWhich.resolve("ls"))
    }
}

final class DevToolDetectorTests: XCTestCase {
    func testBrewSatisfiedByAppleSiliconPathWithoutLoginShell() {
        var d = DevToolDetector()
        d.fileExists = { $0 == "/opt/homebrew/bin/brew" }
        d.loginShellWhich = { _ in
            XCTFail("login shell must not run when a known path hits")
            return nil
        }
        XCTAssertTrue(d.brewInstalled())
    }

    func testBrewSatisfiedByIntelPath() {
        var d = DevToolDetector()
        d.fileExists = { $0 == "/usr/local/bin/brew" }
        d.loginShellWhich = { _ in nil }
        XCTAssertTrue(d.brewInstalled())
    }

    func testBrewFallsBackToLoginShellResolution() {
        var captured: String?
        var d = DevToolDetector()
        d.fileExists = { _ in false }
        d.loginShellWhich = { cmd in
            captured = cmd
            return "/custom/prefix/bin/brew"
        }
        XCTAssertTrue(d.brewInstalled())
        XCTAssertEqual(captured, "brew")
    }

    func testBrewAbsentEverywhere() {
        var d = DevToolDetector()
        d.fileExists = { _ in false }
        d.loginShellWhich = { _ in nil }
        XCTAssertFalse(d.brewInstalled())
    }

    func testNodeSatisfiedByKnownPaths() {
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            var d = DevToolDetector()
            d.fileExists = { $0 == path }
            d.loginShellWhich = { _ in nil }
            XCTAssertTrue(d.nodeInstalled(), "expected node detected at \(path)")
        }
    }

    /// nvm-style installs live outside the fixed paths; the login-shell
    /// `command -v node` fallback must catch them.
    func testNodeFallsBackToLoginShellForNvmInstalls() {
        var captured: String?
        var d = DevToolDetector()
        d.fileExists = { _ in false }
        d.loginShellWhich = { cmd in
            captured = cmd
            return "/Users/x/.nvm/versions/node/v22.0.0/bin/node"
        }
        XCTAssertTrue(d.nodeInstalled())
        XCTAssertEqual(captured, "node")
    }

    func testNodeAbsentEverywhere() {
        var d = DevToolDetector()
        d.fileExists = { _ in false }
        d.loginShellWhich = { _ in nil }
        XCTAssertFalse(d.nodeInstalled())
    }
}
