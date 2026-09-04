import XCTest
@testable import Sidekey

final class ClaudeBinaryLocatorTests: XCTestCase {
    func testPicksFirstExistingKnownPath() {
        let existing = "/opt/homebrew/bin/claude"
        let locator = ClaudeBinaryLocator(fileExists: { $0 == existing }, loginShellWhich: { nil })
        XCTAssertEqual(locator.locate()?.path, existing)
    }

    func testFallsBackToLoginShellWhich() {
        let locator = ClaudeBinaryLocator(
            fileExists: { _ in false },
            loginShellWhich: { "/Users/x/.claude/local/claude" }
        )
        XCTAssertEqual(locator.locate()?.path, "/Users/x/.claude/local/claude")
    }

    func testReturnsNilWhenAbsent() {
        let locator = ClaudeBinaryLocator(fileExists: { _ in false }, loginShellWhich: { nil })
        XCTAssertNil(locator.locate())
    }

    // MARK: - Newest-version selection

    private typealias SemVer = ClaudeBinaryLocator.SemVer

    func testParseSemVer() {
        XCTAssertEqual(ClaudeBinaryLocator.parseSemVer("2.1.160 (Claude Code)"),
                       SemVer(major: 2, minor: 1, patch: 160))
        XCTAssertEqual(ClaudeBinaryLocator.parseSemVer("2.1.69"),
                       SemVer(major: 2, minor: 1, patch: 69))
        XCTAssertNil(ClaudeBinaryLocator.parseSemVer("notaversion"))
    }

    func testSemVerOrdering() {
        XCTAssertTrue(SemVer(major: 2, minor: 1, patch: 152) < SemVer(major: 2, minor: 1, patch: 160))
        XCTAssertTrue(SemVer(major: 2, minor: 1, patch: 69) < SemVer(major: 2, minor: 1, patch: 152))
        XCTAssertTrue(SemVer(major: 2, minor: 1, patch: 100) < SemVer(major: 2, minor: 5, patch: 0))
    }

    func testPicksNewestDesktopManagedVersion() {
        var loc = ClaudeBinaryLocator()
        loc.listDirectory = { dir in
            dir == ClaudeBinaryLocator.desktopManagedDir ? ["2.1.155", "2.1.160", "junk"] : []
        }
        loc.fileExists = { _ in true }
        loc.loginShellWhich = { nil }
        loc.versionOf = { _ in nil }
        XCTAssertEqual(
            loc.locate()?.path,
            "\(ClaudeBinaryLocator.desktopManagedDir)/2.1.160/claude.app/Contents/MacOS/claude")
    }

    func testLegacyWinsWhenStrictlyNewerThanDesktop() {
        var loc = ClaudeBinaryLocator()
        loc.listDirectory = { dir in
            dir == ClaudeBinaryLocator.desktopManagedDir ? ["2.1.100"] : []
        }
        loc.fileExists = { $0.contains("2.1.100") || $0 == "/opt/homebrew/bin/claude" }
        loc.loginShellWhich = { nil }
        loc.versionOf = { _ in "2.5.0 (Claude Code)" }
        XCTAssertEqual(loc.locate()?.path, "/opt/homebrew/bin/claude")
    }

    func testFallsBackToLegacyWhenNoDesktopManaged() {
        var loc = ClaudeBinaryLocator()
        loc.listDirectory = { _ in [] }
        loc.fileExists = { $0 == "/usr/local/bin/claude" }
        loc.loginShellWhich = { nil }
        loc.versionOf = { _ in nil }
        XCTAssertEqual(loc.locate()?.path, "/usr/local/bin/claude")
    }
}
