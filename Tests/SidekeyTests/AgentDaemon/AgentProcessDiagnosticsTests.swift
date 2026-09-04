import XCTest
@testable import Sidekey

final class AgentProcessDiagnosticsTests: XCTestCase {
    // Snapshot must never throw/crash and must mention the pid it was asked about.
    func testSnapshotReturnsStringForLivePid() {
        let line = AgentProcessDiagnostics.snapshot(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(line.contains("pid=\(ProcessInfo.processInfo.processIdentifier)"))
        XCTAssertFalse(line.isEmpty)
    }
}
