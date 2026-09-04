import XCTest
@testable import Sidekey

final class AgentDaemonWorkingDirectoryTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for url in tempRoots {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoots = []
        try super.tearDownWithError()
    }

    private func makeTempAppSupportRoot(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-agent-dir-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempRoots.append(url)
        return url
    }

    private func agentDir(in appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent("whytap", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    // These drive the temp-dir seam, never the real `ensure()` — a bare
    // `ensure()` would migrate the developer's actual agent memory directory as
    // a side effect of running the suite.
    func testCreatesStableDirectory() throws {
        let appSupport = try makeTempAppSupportRoot()
        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "agent")
    }

    func testIsIdempotent() throws {
        // Calling twice returns the same URL without error.
        let appSupport = try makeTempAppSupportRoot()
        let first = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        let second = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        XCTAssertEqual(first.path, second.path)
    }

    func testParentIsWhytap() throws {
        let appSupport = try makeTempAppSupportRoot()
        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "whytap")
    }

    // MARK: - Unified AGENTS.md memory

    func testFreshInstallCreatesEmptyAgentsFileWithClaudeAlias() throws {
        let appSupport = try makeTempAppSupportRoot()
        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)

        let agents = url.appendingPathComponent("AGENTS.md")
        let legacy = url.appendingPathComponent("WHYTAP_MEMORY.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: agents.path))
        XCTAssertFalse(isSymlink(agents), "AGENTS.md must be a real file, not a symlink")
        assertClaudeIsAgentsAlias(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        let text = try String(contentsOf: agents, encoding: .utf8)
        XCTAssertTrue(text.isEmpty, "Fresh AGENTS.md must be empty; got: \(text)")
    }

    func testMigratesLegacyWhytapMemoryContentIntoRealAgentsFile() throws {
        let appSupport = try makeTempAppSupportRoot()
        let dir = agentDir(in: appSupport)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Current installs: a real WHYTAP_MEMORY.md with user content, and
        // AGENTS.md / CLAUDE.md as symlinks pointing at it.
        let legacyContent = "- The user prefers terse replies.\n- Katya is the user's colleague.\n"
        let legacy = dir.appendingPathComponent("WHYTAP_MEMORY.md")
        try legacyContent.write(to: legacy, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("AGENTS.md").path,
            withDestinationPath: "WHYTAP_MEMORY.md"
        )
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("CLAUDE.md").path,
            withDestinationPath: "WHYTAP_MEMORY.md"
        )

        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)

        let agents = url.appendingPathComponent("AGENTS.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: agents.path))
        XCTAssertFalse(isSymlink(agents), "AGENTS.md must be a real file after migration")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.appendingPathComponent("WHYTAP_MEMORY.md").path),
            "WHYTAP_MEMORY.md must be gone after migration"
        )
        assertClaudeIsAgentsAlias(url)

        let text = try String(contentsOf: agents, encoding: .utf8)
        XCTAssertTrue(text.contains("The user prefers terse replies."), "Legacy content must survive; got: \(text)")
        XCTAssertTrue(text.contains("Katya is the user's colleague."), "Legacy content must survive; got: \(text)")
    }

    func testMigratesRealUserClaudeFileContentIntoAgentsFile() throws {
        let appSupport = try makeTempAppSupportRoot()
        let dir = agentDir(in: appSupport)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A user who wrote a REAL CLAUDE.md (not a symlink) must not lose it.
        let claudeContent = "Always answer in Spanish for this user."
        try claudeContent.write(
            to: dir.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)

        let agents = url.appendingPathComponent("AGENTS.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: agents.path))
        XCTAssertFalse(isSymlink(agents))
        assertClaudeIsAgentsAlias(url)

        let text = try String(contentsOf: agents, encoding: .utf8)
        XCTAssertTrue(text.contains("Always answer in Spanish for this user."), "CLAUDE.md content must survive; got: \(text)")
    }

    func testMigratesBothLegacyMemoryAndRealClaudeContent() throws {
        let appSupport = try makeTempAppSupportRoot()
        let dir = agentDir(in: appSupport)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Worst case: a legacy real WHYTAP_MEMORY.md AND a real CLAUDE.md both
        // carry distinct user content. Neither may be destroyed.
        let legacyContent = "Memory: the user's project is named Whytap."
        try legacyContent.write(
            to: dir.appendingPathComponent("WHYTAP_MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("AGENTS.md").path,
            withDestinationPath: "WHYTAP_MEMORY.md"
        )
        let claudeContent = "Claude note: prefer ripgrep over grep."
        try claudeContent.write(
            to: dir.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)

        let agents = url.appendingPathComponent("AGENTS.md")
        XCTAssertFalse(isSymlink(agents))
        let text = try String(contentsOf: agents, encoding: .utf8)
        XCTAssertTrue(text.contains("the user's project is named Whytap."), "Legacy memory must survive; got: \(text)")
        XCTAssertTrue(text.contains("prefer ripgrep over grep."), "CLAUDE.md content must survive; got: \(text)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("WHYTAP_MEMORY.md").path))
        assertClaudeIsAgentsAlias(url)
    }

    func testEnsureIsIdempotentAndDoesNotDuplicateContent() throws {
        let appSupport = try makeTempAppSupportRoot()
        let dir = agentDir(in: appSupport)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let legacyContent = "- Durable fact A.\n"
        try legacyContent.write(
            to: dir.appendingPathComponent("WHYTAP_MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("AGENTS.md").path,
            withDestinationPath: "WHYTAP_MEMORY.md"
        )

        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        let firstText = try String(contentsOf: url.appendingPathComponent("AGENTS.md"), encoding: .utf8)

        // Second call must be a no-op: same bytes, no duplicated content,
        // no re-created aliases.
        _ = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        let secondText = try String(contentsOf: url.appendingPathComponent("AGENTS.md"), encoding: .utf8)

        XCTAssertEqual(firstText, secondText, "Repeated ensure() must not change AGENTS.md")
        assertClaudeIsAgentsAlias(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("WHYTAP_MEMORY.md").path))
    }

    func testProductionLayoutTwoSymlinksMigratesWithoutDuplication() throws {
        let appSupport = try makeTempAppSupportRoot()
        let dir = agentDir(in: appSupport)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The exact shape on a real install: one real WHYTAP_MEMORY.md and BOTH
        // AGENTS.md and CLAUDE.md as symlinks to it. Migration must promote the
        // real file to AGENTS.md byte-for-byte — no "Imported from" duplication
        // from a symlink being mistaken for a real file — and be idempotent.
        let content = "- Durable fact.\n"
        try content.write(
            to: dir.appendingPathComponent("WHYTAP_MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
        for alias in ["AGENTS.md", "CLAUDE.md"] {
            try FileManager.default.createSymbolicLink(
                atPath: dir.appendingPathComponent(alias).path,
                withDestinationPath: "WHYTAP_MEMORY.md"
            )
        }

        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        let agents = url.appendingPathComponent("AGENTS.md")
        let firstText = try String(contentsOf: agents, encoding: .utf8)
        _ = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)
        let secondText = try String(contentsOf: agents, encoding: .utf8)

        XCTAssertEqual(firstText, content, "Promoted AGENTS.md must equal the original bytes, with no duplicated import block")
        XCTAssertEqual(secondText, firstText, "Second ensure() must be a no-op")
        XCTAssertFalse(isSymlink(agents))
        assertClaudeIsAgentsAlias(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("WHYTAP_MEMORY.md").path))
    }

    func testMergePreservesNonUTF8ClaudeContent() throws {
        let appSupport = try makeTempAppSupportRoot()
        let dir = agentDir(in: appSupport)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A real CLAUDE.md whose bytes are not valid UTF-8 must be folded in by
        // raw bytes, not silently dropped because it failed a UTF-8 decode.
        let rawBytes = Data([0xFF, 0xFE, 0x41, 0x42])
        try rawBytes.write(to: dir.appendingPathComponent("CLAUDE.md"))

        let url = try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: appSupport)

        let agentsData = try Data(contentsOf: url.appendingPathComponent("AGENTS.md"))
        XCTAssertNotNil(agentsData.range(of: rawBytes), "Non-UTF-8 CLAUDE.md bytes must survive the merge")
        assertClaudeIsAgentsAlias(url)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// CLAUDE.md must be a symlink ALIAS pointing at AGENTS.md (so Claude Code,
    /// which reads CLAUDE.md natively, picks up the unified memory). One real
    /// file under two names.
    private func assertClaudeIsAgentsAlias(
        _ agentDir: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let claude = agentDir.appendingPathComponent("CLAUDE.md")
        XCTAssertEqual(
            try? FileManager.default.destinationOfSymbolicLink(atPath: claude.path),
            "AGENTS.md",
            "CLAUDE.md must be a symlink to AGENTS.md",
            file: file,
            line: line
        )
    }
}
