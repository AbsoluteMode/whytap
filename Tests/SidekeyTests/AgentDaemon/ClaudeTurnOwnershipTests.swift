import Foundation
import XCTest
@testable import Sidekey

/// A newer turn owns the provider from its start: whatever the new child
/// does (fails to start, exits while registering, exits later), a permission
/// answer never reaches an earlier or exited writer.
final class ClaudeTurnOwnershipTests: XCTestCase {
    private final class Writer: ClaudeStdinWriting {
        var close: (() -> Void)?
        var observe: ((String) -> Void)?
        func writeLine(_ line: String) { observe?(line) }
        func closeStdin() { close?() }
        func terminate() {}
        var processIdentifier: Int32? { nil }
    }

    private enum Timing { case beforeRegistration, duringRegistration, afterPublication }

    private func checkReplacement(_ timing: Timing) {
        let earlier = Writer(), replacement = Writer()
        let earlierReady = expectation(description: "first writer is active")
        let replacementReady = expectation(description: "replacement is active")
        let stale = expectation(description: "post-exit response must reach neither writer")
        stale.isInverted = true
        earlier.observe = { line in
            if line.contains("earlier-ready") { earlierReady.fulfill() }
            if line.contains("after-replacement") { stale.fulfill() }
        }
        replacement.observe = { line in
            if line.contains("replacement-ready") { replacementReady.fulfill() }
            if line.contains("after-replacement") { stale.fulfill() }
        }
        var starts = 0
        var end: ((Int32) -> Void)?
        let provider = ClaudeCodeProvider(locate: { URL(fileURLWithPath: "/usr/bin/false") },
                                         runStreaming: { _, _, _, onLine, onExit in
            starts += 1
            if starts == 1 { return earlier }
            switch timing {
            case .beforeRegistration: onExit(1)
            case .duringRegistration:
                replacement.close = { onExit(0) }
                onLine(#"{"type":"result","subtype":"success","session_id":"fixture","is_error":false}"#)
            case .afterPublication: end = onExit
            }
            return replacement
        }, idleSoftTimeout: 20, idleHardTimeout: 30)
        let options = AgentRunOptions(workingDirectory: FileManager.default.temporaryDirectory)
        let a = provider.run(prompt: "one", resumeSessionID: nil, options: options)
        provider.respondToPermission(requestId: "earlier-ready", decision: .deny(message: "fixture"))
        wait(for: [earlierReady], timeout: 2)
        let b = provider.run(prompt: "two", resumeSessionID: nil, options: options)
        if timing == .afterPublication {
            provider.respondToPermission(requestId: "replacement-ready", decision: .deny(message: "fixture"))
            wait(for: [replacementReady], timeout: 2)
            end?(0)
        } else {
            replacementReady.fulfill()
            wait(for: [replacementReady], timeout: 1)
        }
        withExtendedLifetime((a,b)) {
            provider.respondToPermission(requestId: "after-replacement", decision: .deny(message: "fixture"))
            wait(for: [stale], timeout: 0.25)
        }
    }
    func testAReplacementThatExitsBeforeRegistrationLeavesNoWriterActive() { checkReplacement(.beforeRegistration) }
    func testAReplacementThatExitsWhileRegisteringLeavesNoWriterActive() { checkReplacement(.duringRegistration) }
    func testAReplacementThatExitsAfterPublicationLeavesNoWriterActive() { checkReplacement(.afterPublication) }
}
