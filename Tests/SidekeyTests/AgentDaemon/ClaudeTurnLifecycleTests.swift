import Foundation
import XCTest
@testable import Sidekey

final class ClaudeTurnLifecycleTests: XCTestCase {
    private final class Writer: ClaudeStdinWriting {
        let observe: (String) -> Void
        init(_ observe: @escaping (String) -> Void = { _ in }) { self.observe = observe }
        func writeLine(_ line: String) { observe(line) }
        func closeStdin() {}
        func terminate() {}
        var processIdentifier: Int32? { nil }
    }

    // Adapted from build-queue probe 721. A replacement turn that cannot
    // start still retires the previous writer.
    func testMissingBinaryOnReplacement() { checkEarlyReturn(missingBinary: true) }
    func testUnavailableWorkspaceOnReplacement() { checkEarlyReturn(missingBinary: false) }

    /// The real Agent folder blocked by a regular file. Runs only in the
    /// builder's isolated home (CFFIXED_USER_HOME + BUILDER_TEST_AGENT_PATH).
    func testUnavailableRealWorkspaceOnReplacement() throws {
        guard let expected = ProcessInfo.processInfo.environment["BUILDER_TEST_AGENT_PATH"] else {
            throw XCTSkip("needs an isolated home with a file at the Agent folder path")
        }
        let fm = FileManager.default
        guard AgentDaemonWorkingDirectory.url().standardizedFileURL.path == expected,
              (try fm.attributesOfItem(atPath: expected))[.type] as? FileAttributeType == .typeRegular else {
            return XCTFail("requires a regular-file obstacle in the isolated test home")
        }
        checkEarlyReturn(missingBinary: false, realWorkspace: true)
    }

    private func checkEarlyReturn(missingBinary: Bool, realWorkspace: Bool = false) {
        let ready = expectation(description: "old writer is published")
        let stale = expectation(description: "old writer must not receive the later marker")
        stale.isInverted = true
        let old = Writer { line in
            if line.contains("fixture-ready") { ready.fulfill() }
            if line.contains("fixture-stale") { stale.fulfill() }
        }
        var lookup = 0, launches = 0
        let provider = ClaudeCodeProvider(locate: {
            lookup += 1
            return missingBinary && lookup == 2 ? nil : URL(fileURLWithPath: "/usr/bin/false")
        }, runStreaming: { _, _, _, _, _ in launches += 1; return old },
           agentWorkspace: realWorkspace ? { try? AgentDaemonWorkingDirectory.ensure() } : { nil })
        let opts = AgentRunOptions(workingDirectory: FileManager.default.temporaryDirectory)
        let a = provider.run(prompt: "first", resumeSessionID: nil, options: opts)
        provider.respondToPermission(requestId: "fixture-ready", decision: .deny(message: "fixture"))
        wait(for: [ready], timeout: 1)
        let b = provider.run(prompt: "next", resumeSessionID: nil, options: missingBinary ? opts : AgentRunOptions())
        XCTAssertEqual(lookup, 2)
        XCTAssertEqual(launches, 1)
        withExtendedLifetime((a,b)) {
            provider.respondToPermission(requestId: "fixture-stale", decision: .deny(message: "fixture"))
            wait(for: [stale], timeout: 0.2)
        }
    }

    func testCompletedTurnReleasesItsWriterWhileProviderIsIdle() {
        weak var idleWriter: Writer?
        var finish: ((Int32) -> Void)?
        let provider = ClaudeCodeProvider(locate: { URL(fileURLWithPath: "/usr/bin/false") },
            runStreaming: { _, _, _, _, exit in
                let writer = Writer()
                idleWriter = writer
                finish = exit
                return writer
            })
        var stream: AsyncStream<AgentSSEEvent>? = provider.run(prompt: "fixture", resumeSessionID: nil,
            options: AgentRunOptions(workingDirectory: FileManager.default.temporaryDirectory))
        XCTAssertNotNil(stream)
        finish?(0)
        finish = nil
        stream = nil
        withExtendedLifetime(provider) {
            let deadline = Date().addingTimeInterval(0.5)
            while idleWriter != nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertNil(idleWriter, "The latest finished turn still retains its writer")
        }
    }
}
