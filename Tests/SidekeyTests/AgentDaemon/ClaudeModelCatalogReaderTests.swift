import XCTest
@testable import Sidekey

/// Claude Code's model list comes from its own `initialize` answer.
/// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
final class ClaudeModelCatalogReaderTests: XCTestCase {
    /// Claude Code 2.1.325's real answer, models and version unchanged; the
    /// account object is replaced with placeholders.
    static let fixture = #"{"type":"control_response","response":{"subtype":"success","request_id":"whytap-models","response":{"models":[{"value":"default","displayName":"Default (recommended)","description":"Fable 5.2","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"opus","displayName":"Opus 5.5","description":"For complex work and everyday tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"fable","displayName":"Fable 5.2","description":"For your toughest challenges","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"sonnet","displayName":"Sonnet 5.5","description":"Most efficient for simpler tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"haiku","displayName":"Haiku 5.5","description":"Fastest for quick answers","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-fable-5-1","displayName":"Fable 5.1","description":"Most capable for your hardest and longest-running tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","description":"Fastest for quick answers"},{"value":"claude-sonnet-5","displayName":"Sonnet 5","description":"Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-opus-5","displayName":"Opus 5","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-fable-5","displayName":"Fable 5","description":"Most capable for your hardest and longest-running tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-opus-4-8","displayName":"Opus 4.8","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-opus-4-7","displayName":"Opus 4.7","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"claude-opus-4-6","displayName":"Opus 4.6","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"]},{"value":"claude-sonnet-4-6","displayName":"Sonnet 4.6","description":"Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"]}],"claude_code_version":"2.1.325","account":{"email":"person@example.com","organization":"Example","subscriptionType":"max"}}}}"#

    func testParsesEveryModelWithItsOwnReasoningLevels() throws {
        let catalog = try XCTUnwrap(ClaudeModelCatalogReader.parse(controlResponse: Self.fixture))
        XCTAssertEqual(catalog.cliVersion, "2.1.325")
        XCTAssertEqual(catalog.models.count, 14)
        XCTAssertEqual(catalog.models.first?.value, "default")
        XCTAssertTrue(catalog.models.contains { $0.value == "fable" && $0.displayName == "Fable 5.2" })
        let haiku45 = try XCTUnwrap(catalog.models.first { $0.value == "claude-haiku-4-5-20251001" })
        XCTAssertEqual(haiku45.efforts, [], "a model without reasoning levels")
        let opus46 = try XCTUnwrap(catalog.models.first { $0.value == "claude-opus-4-6" })
        XCTAssertEqual(opus46.efforts, ["low", "medium", "high", "max"])
    }

    func testRejectsOtherLinesAndAnswersWithoutModels() {
        for line in ["", "not json",
                     #"{"type":"system","subtype":"hook_started"}"#,
                     #"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{"models":[{"value":"x","displayName":"X"}]}}}"#,
                     #"{"type":"control_response","response":{"subtype":"error","request_id":"whytap-models","error":"no"}}"#,
                     #"{"type":"control_response","response":{"subtype":"success","request_id":"whytap-models","response":{"models":[]}}}"#,
                     #"{"type":"control_response","response":{"subtype":"success","request_id":"whytap-models","response":{"models":[{"value":"two words"}]}}}"#] {
            XCTAssertNil(ClaudeModelCatalogReader.parse(controlResponse: line), line)
        }
    }

    func testDuplicateValuesKeepTheFirst() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"whytap-models","response":{"models":[{"value":"a","displayName":"A1"},{"value":"a","displayName":"A2"}]}}}"#
        XCTAssertEqual(try XCTUnwrap(ClaudeModelCatalogReader.parse(controlResponse: line)).models.map(\.displayName), ["A1"])
    }

    // MARK: - The real handshake against a fake `claude`

    private func fakeClaude(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testHandshakeSkipsHookOutputAndNeverSendsAUserMessage() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("stdin-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: log) }
        let answer = Self.fixture.replacingOccurrences(of: "'", with: "")
        let script = try fakeClaude("""
        read -r request
        printf '%s\\n' "$request" > '\(log.path)'
        printf '{"type":"system","subtype":"hook_started"}\\n'
        printf '%s\\n' '\(answer)'
        cat >> '\(log.path)'
        """)
        let catalog = try await ClaudeModelCatalogReader(locate: { script }).read()
        XCTAssertEqual(catalog.models.count, 14)
        let written = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(written.contains(#""subtype":"initialize""#))
        XCTAssertFalse(written.contains(#""type":"user""#), "no prompt, no model request")
    }

    func testHandshakeFailsWhenTheCLIExitsWithoutAnAnswer() async throws {
        let script = try fakeClaude("echo 'Error: not supported'; exit 1\n")
        do {
            _ = try await ClaudeModelCatalogReader(locate: { script }).read()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeModelCatalogError, .unreadable)
        }
    }

    func testHandshakeTimesOutOnASilentCLI() async throws {
        let script = try fakeClaude("sleep 30\n")
        do {
            _ = try await ClaudeModelCatalogReader(locate: { script }, timeout: 0.5).read()
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ClaudeModelCatalogError, .timedOut)
        }
    }

    func testNoAgentFolderMeansClaudeCodeNeverStarts() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("started-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let script = try fakeClaude(": > '\(marker.path)'\nread -r ignored\n")
        struct NoFolder: Error {}
        XCTAssertThrowsError(try ClaudeModelCatalogReader.defaultHandshake(
            binary: script, timeout: 0.6, workspace: { throw NoFolder() })) { error in
            XCTAssertEqual(error as? ClaudeModelCatalogError, .workspaceUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "neither the CLI nor its SessionStart hooks run outside the Agent's folder")
    }

    func testHandshakeRunsInTheAgentFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let answer = Self.fixture.replacingOccurrences(of: "'", with: "")
        let script = try fakeClaude("read -r request\npwd -P > cwd.txt\nprintf '%s\\n' '\(answer)'\ncat > /dev/null\n")
        _ = try ClaudeModelCatalogReader.defaultHandshake(binary: script, timeout: 5, workspace: { folder })
        let cwd = try String(contentsOf: folder.appendingPathComponent("cwd.txt"), encoding: .utf8)
        XCTAssertTrue(cwd.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/" + folder.lastPathComponent))
    }

    func testMissingClaudeCodeIsNotInstalled() async {
        do {
            _ = try await ClaudeModelCatalogReader(locate: { nil }).read()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ClaudeModelCatalogError, .notInstalled)
        }
    }
}
