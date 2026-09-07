import XCTest
@testable import Sidekey

final class CodexModelCatalogReaderTests: XCTestCase {
    private func fixture(_ script: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + script).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return file
    }

    func testHandshakePaginationHiddenFilteringAndCapabilities() async throws {
        let binary = try fixture(#"""
        read -r init
        case "$init" in *initialize*) ;; *) exit 1;; esac
        printf '%s\n' '{"id":0,"result":{}}'
        read -r initialized
        read -r request
        case "$request" in *model*list*) ;; *) exit 1;; esac
        printf '%s\n' '{"method":"notification","params":{}}'
        printf '%s\n' '{"id":1,"result":{"data":[{"model":"future-model","displayName":"Future","supportedReasoningEfforts":[{"reasoningEffort":"ultra"}],"defaultReasoningEffort":"ultra","serviceTiers":[{"id":"priority","name":"Fast"}],"isDefault":true},{"model":"hidden","hidden":true}],"nextCursor":"page2"}}'
        read -r next
        case "$next" in *page2*) ;; *) exit 1;; esac
        printf '%s\n' '{"id":2,"result":{"data":[{"model":"future-model"},{"model":"small","serviceTiers":[]}],"nextCursor":null}}'
        """#)
        let models = try await CodexModelCatalogReader(locate: { binary }).read()
        XCTAssertEqual(models.map(\.model), ["future-model", "small"])
        XCTAssertEqual(models[0].efforts, ["ultra"])
        XCTAssertEqual(models[0].tiers.map(\.id), ["priority"])
        XCTAssertTrue(models[1].tiers.isEmpty)
    }

    func testTimeoutAndCancellationStopWaitingForChild() async throws {
        let binary = try fixture("exec sleep 10\n")
        let start = Date()
        do {
            _ = try await CodexModelCatalogReader(locate: { binary }, timeout: 0.15).read()
            XCTFail("Expected timeout")
        } catch CodexModelCatalogReader.Failure.timedOut {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        let task = Task { try await CodexModelCatalogReader(locate: { binary }, timeout: 10).read() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelledAt = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
    }

    func testProtocolErrorsDoNotProduceInventedModels() async throws {
        let binary = try fixture(#"""
        read -r init
        printf '%s\n' '{"id":0,"error":{"code":-1,"message":"failure"}}'
        """#)
        do { _ = try await CodexModelCatalogReader(locate: { binary }).read(); XCTFail("Expected error") }
        catch CodexModelCatalogReader.Failure.unavailable {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testOlderRegistrySpeedFieldsAndExplicitEmptyTiers() throws {
        let legacy = try JSONDecoder().decode(CodexModelOption.self, from: Data(#"{"model":"older","additionalSpeedTiers":["fast"]}"#.utf8))
        XCTAssertEqual(legacy.tiers.map(\.id), ["priority"])
        let current = try JSONDecoder().decode(CodexModelOption.self, from: Data(#"{"model":"current","additionalSpeedTiers":["fast"],"serviceTiers":[]}"#.utf8))
        XCTAssertTrue(current.tiers.isEmpty)
    }

    func testLiveInstalledCodexRegistryWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["WHYTAP_LIVE_CODEX_CATALOG"] == "1" else {
            throw XCTSkip("Set WHYTAP_LIVE_CODEX_CATALOG=1 for a read-only installed CLI check")
        }
        let models = try await CodexModelCatalogReader().read()
        XCTAssertFalse(models.isEmpty)
        XCTAssertEqual(Set(models.map(\.model)).count, models.count)
        XCTAssertTrue(models.allSatisfy { $0.hidden != true })
        print("Live Codex models:", models.map(\.model).joined(separator: ", "))
    }

    func testLocatorPrefersCurrentDesktopCLIOverOldNpmInstall() {
        let path = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let locator = CodexBinaryLocator(fileExists: { $0 == path || $0.contains(".npm-global") }, loginShellWhich: { nil })
        XCTAssertEqual(locator.locate()?.path, path)
    }
}
