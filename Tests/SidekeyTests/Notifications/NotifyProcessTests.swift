import Darwin
import XCTest
@testable import Sidekey

private final class NotifyOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

final class NotifyProcessTests: XCTestCase {
    func testOutputDrainsBeforeExitAndArgumentsAreLiteral() async throws {
        let output = NotifyOutputCapture()
        let done = expectation(description: "process completed")
        let process = try NotifyProcess(command: ["/bin/echo", "$(must-not-execute); literal"], environment: ["PATH": "/usr/bin:/bin"],
            onData: { output.append($0) }, onExit: { _ in done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(output.text, "$(must-not-execute); literal\n")
        withExtendedLifetime(process) {}
    }
    func testStopKillsProcessGroupIncludingHelpersThatIgnoreTerm() async throws {
        let output = NotifyOutputCapture()
        let done = expectation(description: "group stopped")
        let process = try NotifyProcess(command: ["/bin/sh", "-c", "trap '' TERM; sleep 30 & echo ready; wait"],
            environment: ["PATH": "/usr/bin:/bin"], onData: { output.append($0) }, onExit: { _ in done.fulfill() })
        for _ in 0..<100 where !output.text.contains("ready") { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(output.text.contains("ready"))
        process.stop()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(kill(-process.pid, 0), -1)
    }
    /// Parent death (SIGKILL/crash) closes the app's end of the guard's stdin.
    /// The guard must take the script and its helpers, even TERM-ignoring ones, down.
    func testLifelineEOFStopsScriptAndHelpers() async throws {
        let output = NotifyOutputCapture()
        let done = expectation(description: "group ended after lifeline EOF")
        let process = try NotifyProcess(command: ["/bin/sh", "-c", "trap '' TERM; sleep 30 & echo \"helper $!\"; echo \"script $$\"; wait"],
            environment: ["PATH": "/usr/bin:/bin"], onData: { output.append($0) }, onExit: { _ in done.fulfill() })
        for _ in 0..<200 where !(output.text.contains("helper") && output.text.contains("script")) { try await Task.sleep(nanoseconds: 10_000_000) }
        let pids = Dictionary(uniqueKeysWithValues: output.text.split(separator: "\n").compactMap { line -> (String, pid_t)? in
            let parts = line.split(separator: " "); guard parts.count == 2, let pid = pid_t(parts[1]) else { return nil }
            return (String(parts[0]), pid)
        })
        let script = try XCTUnwrap(pids["script"]), helper = try XCTUnwrap(pids["helper"])
        XCTAssertNotEqual(script, process.pid, "the script runs under the guard, not as the leader")
        XCTAssertEqual(getpgid(script), process.pid); XCTAssertEqual(getpgid(helper), process.pid)
        process.closeLifeline()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(kill(script, 0), -1); XCTAssertEqual(kill(helper, 0), -1)
        XCTAssertEqual(kill(-process.pid, 0), -1)
    }
    func testGuardReportsScriptExitStatusAndGivesScriptNullStdin() async throws {
        let output = NotifyOutputCapture()
        let failed = expectation(description: "failing script exited")
        let failedStatus = NotifyOutputCapture()
        let failing = try NotifyProcess(command: ["/bin/sh", "-c", "cat; echo stdin-closed; exit 3"], environment: ["PATH": "/usr/bin:/bin"],
            onData: { output.append($0) }, onExit: { failedStatus.append(Data("\($0)".utf8)); failed.fulfill() })
        let succeeded = expectation(description: "instant script exited")
        let successStatus = NotifyOutputCapture()
        let instant = try NotifyProcess(command: ["/usr/bin/true"], environment: [:],
            onData: { _ in }, onExit: { successStatus.append(Data("\($0)".utf8)); succeeded.fulfill() })
        await fulfillment(of: [failed, succeeded], timeout: 5)
        XCTAssertEqual(output.text, "stdin-closed\n")
        let status = try XCTUnwrap(Int32(failedStatus.text))
        XCTAssertTrue(status & 0x7f == 0 && (status >> 8) & 0xff == 3, "raw status \(status)")
        XCTAssertEqual(successStatus.text, "0")
        withExtendedLifetime((failing, instant)) {}
    }
    func testMissingExecutableFailsWithoutStartingAWorker() {
        XCTAssertThrowsError(try NotifyProcess(command: ["/no/such/exodia-test-executable"], environment: [:], onData: { _ in }, onExit: { _ in }))
        XCTAssertThrowsError(try NotifyProcess(command: ["/tmp"], environment: [:], onData: { _ in }, onExit: { _ in }))
    }
}

@MainActor
final class NotifyScriptSupervisorTests: XCTestCase {
    func testWorkersDoNotInheritProviderOrBuildCredentials() {
        let environment = NotifyScriptSupervisor.environment(inherited: [
            "PATH": "/usr/bin:/bin", "HOME": "/tmp/synthetic-home",
            "OPENROUTER_API_KEY": "synthetic-value", "DOPPLER_TOKEN": "synthetic-value",
            "EXODIA_COMMUNITY_SIGNING_KEY": "synthetic-value"
        ], source: "test", directory: URL(fileURLWithPath: "/tmp/notify-fixture"))
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["EXODIA_NOTIFY_SOURCE"], "test")
        XCTAssertEqual(environment["WHYTAP_NOTIFY_SOURCE"], "test")
        XCTAssertEqual(environment["WHYTAP_NOTIFY_DIRECTORY"], "/tmp/notify-fixture")
        XCTAssertEqual(environment["EXODIA_NOTIFY_DIRECTORY"], environment["WHYTAP_NOTIFY_DIRECTORY"])
        XCTAssertNil(environment["OPENROUTER_API_KEY"]); XCTAssertNil(environment["DOPPLER_TOKEN"])
        XCTAssertNil(environment["EXODIA_COMMUNITY_SIGNING_KEY"])
    }
    func testSourceRunsWithoutOpeningDrawerAndDisableStopsPolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let script = NotifyScript(id: "synthetic", name: "Synthetic", command: ["/bin/echo", "{\"id\":\"setup\",\"title\":\"Connected\",\"tint\":\"#299FD6\",\"logo\":\"star.fill\"}"], intervalSeconds: 30)
        try JSONEncoder().encode(script).write(to: registry.appendingPathComponent("synthetic.json"))
        let hub = LocalNotificationHub(directory: root)
        let supervisor = NotifyScriptSupervisor(directory: root, hub: hub)
        supervisor.start()
        defer { supervisor.stop() }
        for _ in 0..<200 where hub.history.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hub.history.first?.id, "synthetic:setup")
        XCTAssertEqual(hub.history.first?.customLogo, "star.fill")
        supervisor.setEnabled(false, id: "synthetic")
        XCTAssertFalse(try JSONDecoder().decode(NotifyScript.self, from: Data(contentsOf: registry.appendingPathComponent("synthetic.json"))).enabled)
        supervisor.remove(id: "synthetic")
        XCTAssertTrue(supervisor.sources.isEmpty)
        XCTAssertEqual(hub.history.count, 1)
    }
    func testFailingScriptRestartsWithBackoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let script = NotifyScript(id: "flaky", name: "Flaky", command: ["/bin/sh", "-c", "echo \"{\\\"id\\\":\\\"run-$$\\\",\\\"title\\\":\\\"Run\\\"}\"; exit 1"], intervalSeconds: 30)
        try JSONEncoder().encode(script).write(to: registry.appendingPathComponent("flaky.json"))
        let hub = LocalNotificationHub(directory: root)
        // A tenth of a second per backoff step: the first failure waits 0.2 s
        // (2^1 steps; 2 s in the app) before the relaunch.
        let supervisor = NotifyScriptSupervisor(directory: root, hub: hub, backoffUnit: 0.1)
        supervisor.start()
        defer { supervisor.stop() }
        for _ in 0..<800 where hub.history.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(hub.history.count, 2)
        XCTAssertEqual(Set(hub.history.map(\.id)).count, 2, "each run is a separate script process")
    }
}
