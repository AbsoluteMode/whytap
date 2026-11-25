import Darwin
import XCTest
@testable import WhytapCaseKit

/// A `whytap mcp` started before a Whytap update must keep serving its
/// harness: the app denies the old image, the helper execs the new file and
/// the new image answers what the old one could not. Here a test relauncher
/// stands in for `execve` and a second server stands in for the new image;
/// `scripts/check-helper-follows-build.py` checks the real exec.
// WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md
final class HelperBuildHandoverTests: XCTestCase {
    /// The app as one image of the helper sees it.
    private final class App: CancellableCaseBrokerCalling, @unchecked Sendable {
        enum Mode { case trusts, deniesStaleHelper, notRunning }
        private let lock = NSLock()
        private var _mode: Mode
        private(set) var received: [CaseBrokerRequest] = []
        var onSend: ((CaseBrokerRequest) -> Void)?
        init(_ mode: Mode) { _mode = mode }
        var mode: Mode { get { lock.withLock { _mode } } set { lock.withLock { _mode = newValue } } }
        func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse { try send(request, cancellation: nil) }
        func send(_ request: CaseBrokerRequest, cancellation: AppControlCancellation?) throws -> CaseBrokerResponse {
            onSend?(request)
            switch mode {
            case .notRunning: throw CaseBrokerClientError.unavailable
            case .deniesStaleHelper: return .denied(reason: .untrustedHelper)
            case .trusts:
                lock.withLock { received.append(request) }
                switch request {
                case .appControl(let call): return .appControl(.success(.object(["operation": .string(call.operation)])))
                case .listKeys: return .keys([CaseKeyInfo(name: "OPENAI_API_KEY", description: "", project: "p")])
                default: return .projects([])
                }
            }
        }
        var operations: [String] {
            lock.withLock { received.compactMap { if case .appControl(let call) = $0 { return call.operation }; return nil } }
        }
    }

    /// The helper file on disk, compared with the image's running code.
    private final class Disk: HelperBuildIdentifying, @unchecked Sendable {
        private let lock = NSLock()
        private var _hasNewBuild: Bool
        init(hasNewBuild: Bool) { _hasNewBuild = hasNewBuild }
        var hasNewBuild: Bool { get { lock.withLock { _hasNewBuild } } set { lock.withLock { _hasNewBuild = newValue } } }
        func newBuildAvailable() -> Bool { hasNewBuild }
    }

    /// Everything one helper image's relauncher was asked to hand over.
    private final class Relaunches: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [MCPResumeState] = []
        let succeed: Bool
        init(succeed: Bool = true) { self.succeed = succeed }
        var states: [MCPResumeState] { lock.withLock { _states } }
        func record(_ state: MCPResumeState) -> Bool { lock.withLock { _states.append(state) }; return succeed }
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func write(_ line: String) { lock.withLock { _lines.append(line) } }
        func ids() -> [Int] {
            lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .compactMap { $0["id"] as? Int }
        }
        func reply(_ id: Int) -> [String: Any]? {
            lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .first { $0["id"] as? Int == id }
        }
    }

    /// A pipe standing for the harness's end of the helper's stdin.
    private final class Stdin {
        let read: Int32, write: Int32
        init() {
            var fds: [Int32] = [0, 0]
            precondition(pipe(&fds) == 0)
            read = fds[0]; write = fds[1]
        }
        func send(_ lines: String...) {
            for line in lines {
                let data = Array((line + "\n").utf8)
                _ = data.withUnsafeBytes { Darwin.write(write, $0.baseAddress, $0.count) }
            }
        }
        func sendPartial(_ text: String) {
            let data = Array(text.utf8)
            _ = data.withUnsafeBytes { Darwin.write(write, $0.baseAddress, $0.count) }
        }
        func close() { Darwin.close(write) }
        deinit { Darwin.close(read) }
    }

    private static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
    private static let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    private static func call(_ id: Int, _ tool: String = "whytap_get_state") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#
    }

    /// One helper image: the server with the real command wiring, running on
    /// its own thread until EOF or a handover.
    private final class Image {
        let app: App, stdin: Stdin, output = Output(), relaunches: Relaunches, handover: MCPBuildHandover
        private let done = DispatchSemaphore(value: 0)
        var probes = 0
        init(app: App, stdin: Stdin, disk: Disk, resumed: MCPResumeState? = nil,
             relaunches: Relaunches = Relaunches(), now: @escaping () -> Date = Date.init, caseMCP: Bool = false) {
            self.app = app; self.stdin = stdin; self.relaunches = relaunches
            handover = MCPBuildHandover(identity: disk, resumed: resumed, now: now, relaunch: relaunches.record)
            let client = BuildFollowingBrokerClient(inner: app, handover: handover)
            let source = FileDescriptorLineSource(fd: stdin.read, prefill: resumed?.input ?? Data())
            let output = output, handover = handover
            Thread.detachNewThread { [self] in
                if caseMCP {
                    CaseMCPServer(client: client, executablePath: "/A.app/Contents/Helpers/whytap")
                        .run(source: source, write: output.write, handover: handover)
                } else {
                    AppControlMCPServer(accessProbe: { [self] in
                        probes += 1
                        _ = try? client.send(.appControl(AppControlRequest("request_access")))
                    }, caseServer: CaseMCPServer(client: client, executablePath: "/A.app/Contents/Helpers/whytap"),
                    cancellableCall: { request, cancellation in
                        AppControlCommand(client: client).call(request, cancellation: cancellation)
                    }).run(source: source, write: output.write, handover: handover)
                }
                done.signal()
            }
        }
        @discardableResult func waitUntilStopped(_ seconds: TimeInterval = 10) -> Bool {
            done.wait(timeout: .now() + seconds) == .success
        }
    }

    /// A harness closes stdin only after its answers arrived; EOF cancels
    /// calls still in flight (unchanged MCP behaviour).
    private func finish(_ image: Image, _ session: Stdin, answering ids: [Int], file: StaticString = #filePath, line: UInt = #line) {
        waitFor({ Set(image.output.ids()).isSuperset(of: ids) }, "answers \(ids) arrive")
        session.close()
        XCTAssertTrue(image.waitUntilStopped(), file: file, line: line)
    }

    private func waitFor(_ condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(condition(), message)
    }

    // MARK: Scenarios

    func test_open_client_keeps_working_after_the_bundle_is_replaced() throws {
        let session = Stdin()
        let app = App(.trusts)
        let disk = Disk(hasNewBuild: false)
        let old = Image(app: app, stdin: session, disk: disk)
        session.send(Self.initialize, Self.initialized, Self.call(2))
        waitFor({ old.output.ids() == [1, 2] && old.probes == 1 }, "the first build answers normally")

        // The update: the bundle is replaced and the app trusts only the new file.
        disk.hasNewBuild = true
        app.mode = .deniesStaleHelper
        session.send(Self.call(3), Self.call(4, "whytap_list_models"))
        XCTAssertTrue(old.waitUntilStopped(), "the stale image hands over instead of answering")
        XCTAssertEqual(old.output.ids(), [1, 2], "nothing denied reaches the harness")
        XCTAssertEqual(old.relaunches.states.count, 1)
        let state = try XCTUnwrap(old.relaunches.states.first)
        XCTAssertTrue(state.initialized, "the handshake is not repeated")
        XCTAssertTrue(state.probed)
        XCTAssertEqual(state.relaunches.count, 1)

        // The new image: same pid and stdin, prefilled with what was unanswered.
        let newApp = App(.trusts)
        let fresh = Image(app: newApp, stdin: session, disk: Disk(hasNewBuild: false), resumed: state)
        session.send(Self.call(5))
        finish(fresh, session, answering: [3, 4, 5])
        XCTAssertEqual(fresh.output.ids().sorted(), [3, 4, 5], "every call is answered exactly once, by the new build")
        XCTAssertEqual(newApp.operations.sorted(), ["get_state", "get_state", "list_models"])
        XCTAssertEqual(fresh.probes, 0, "the old image already probed for access")
        XCTAssertNil(fresh.output.lines.first { $0.contains("\"isError\":true") })
    }

    func test_bytes_read_but_not_yet_a_line_survive_the_handover() throws {
        let session = Stdin()
        let stale = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: true),
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []))
        let next = Self.call(7)
        let split = next.index(next.startIndex, offsetBy: 20)
        session.send(Self.call(6))
        session.sendPartial(String(next[..<split]))
        XCTAssertTrue(stale.waitUntilStopped())
        let state = try XCTUnwrap(stale.relaunches.states.first)
        let fresh = Image(app: App(.trusts), stdin: session, disk: Disk(hasNewBuild: false), resumed: state)
        session.sendPartial(String(next[split...]) + "\n")
        finish(fresh, session, answering: [6, 7])
        XCTAssertEqual(fresh.output.ids().sorted(), [6, 7])
    }

    func test_whytap_not_running_answers_unavailable_without_a_relaunch() {
        let session = Stdin()
        let image = Image(app: App(.notRunning), stdin: session, disk: Disk(hasNewBuild: true))
        session.send(Self.initialize, Self.call(2))
        finish(image, session, answering: [1, 2])
        XCTAssertEqual(image.relaunches.states.count, 0)
        XCTAssertTrue(image.output.reply(2).map { "\($0)".contains("unavailable") } ?? false)
    }

    func test_a_new_build_that_fails_verification_is_not_executed() {
        let session = Stdin()
        // The app denies, but the file on disk is not a valid newer build.
        let image = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: false))
        session.send(Self.initialize, Self.call(2), Self.call(3))
        finish(image, session, answering: [1, 2, 3])
        XCTAssertEqual(image.relaunches.states.count, 0, "no exec, so no loop")
        XCTAssertEqual(image.output.ids().sorted(), [1, 2, 3], "each call still gets its answer")
        XCTAssertTrue("\(image.output.reply(2) ?? [:])".contains("unavailable"))
    }

    func test_repeated_replacements_relaunch_again_within_a_bounded_budget() throws {
        var state = MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: [])
        let session = Stdin()
        for attempt in 1...MCPBuildHandover.maxRelaunches {
            let image = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: true), resumed: state)
            session.send(Self.call(10 + attempt))
            XCTAssertTrue(image.waitUntilStopped(), "replacement \(attempt) is followed")
            state = try XCTUnwrap(image.relaunches.states.first)
            XCTAssertEqual(state.relaunches.count, attempt)
        }
        // A fourth relaunch within the window is refused: the call is answered.
        let image = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: true), resumed: state)
        finish(image, session, answering: [11, 12, 13])
        XCTAssertEqual(image.relaunches.states.count, 0)
        XCTAssertEqual(image.output.ids().sorted(), [11, 12, 13], "the carried calls are answered, not lost")

        // After the window the budget is back.
        let later = Stdin()
        let image2 = Image(app: App(.deniesStaleHelper), stdin: later, disk: Disk(hasNewBuild: true), resumed:
            MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: state.relaunches),
            now: { Date().addingTimeInterval(MCPBuildHandover.relaunchWindow + 1) })
        later.send(Self.call(20))
        XCTAssertTrue(image2.waitUntilStopped())
        XCTAssertEqual(image2.relaunches.states.first?.relaunches.count, 1)
    }

    func test_failed_exec_answers_held_and_waiting_calls_here_and_stops_trying() {
        let session = Stdin()
        let app = App(.deniesStaleHelper)
        let image = Image(app: app, stdin: session, disk: Disk(hasNewBuild: true),
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []),
                          relaunches: Relaunches(succeed: false))
        session.send(Self.call(2))
        waitFor({ image.output.ids() == [2] }, "the denied call is answered after the failed exec")
        session.send(Self.call(3))
        finish(image, session, answering: [2, 3])
        XCTAssertEqual(image.relaunches.states.count, 1, "one attempt per process")
        XCTAssertEqual(image.output.ids(), [2, 3])
    }

    func test_handover_waits_for_a_call_the_app_is_still_answering() throws {
        let session = Stdin()
        let app = App(.trusts)
        let release = DispatchSemaphore(value: 0)
        app.onSend = { request in
            if case .appControl(let call) = request, call.operation == "meetings_search" { release.wait() }
        }
        let image = Image(app: app, stdin: session, disk: Disk(hasNewBuild: true),
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []))
        session.send(Self.call(2, "whytap_meetings_search"))
        Thread.sleep(forTimeInterval: 0.1)
        app.mode = .deniesStaleHelper // the update lands while the search is pending
        app.onSend = nil
        session.send(Self.call(3))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(image.relaunches.states.count, 0, "no exec while a call is in flight")
        app.mode = .trusts
        release.signal()
        XCTAssertTrue(image.waitUntilStopped())
        XCTAssertEqual(image.output.ids(), [2], "the finished call is answered once, here")
        let state = try XCTUnwrap(image.relaunches.states.first)
        XCTAssertEqual(String(decoding: state.input, as: UTF8.self), Self.call(3) + "\n", "only the denied call is replayed")
    }

    func test_a_call_cancelled_during_the_handover_is_not_replayed() throws {
        let session = Stdin()
        let app = App(.trusts)
        let release = DispatchSemaphore(value: 0)
        app.onSend = { request in
            if case .appControl(let call) = request, call.operation == "meetings_search" { release.wait() }
        }
        let image = Image(app: app, stdin: session, disk: Disk(hasNewBuild: true),
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []))
        session.send(Self.call(2, "whytap_meetings_search"))
        Thread.sleep(forTimeInterval: 0.1)
        app.onSend = nil
        app.mode = .deniesStaleHelper
        session.send(Self.call(3), #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#)
        Thread.sleep(forTimeInterval: 0.2)
        release.signal()
        XCTAssertTrue(image.waitUntilStopped())
        let state = try XCTUnwrap(image.relaunches.states.first)
        XCTAssertFalse(String(decoding: state.input, as: UTF8.self).contains(#""id":3"#))
    }

    func test_access_probe_denied_as_stale_is_repeated_once_by_the_new_image() throws {
        let session = Stdin()
        let stale = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: true))
        session.send(Self.initialize, Self.initialized)
        waitFor({ stale.probes == 1 && stale.handover.isRequested }, "the probe finds the new build")
        session.send(Self.call(2))
        XCTAssertTrue(stale.waitUntilStopped())
        let state = try XCTUnwrap(stale.relaunches.states.first)
        XCTAssertTrue(state.initialized)
        XCTAssertFalse(state.probed)
        let app = App(.trusts)
        let fresh = Image(app: app, stdin: session, disk: Disk(hasNewBuild: false), resumed: state)
        finish(fresh, session, answering: [2])
        waitFor({ app.operations.count == 2 }, "the new image probes")
        XCTAssertEqual(fresh.probes, 1)
        XCTAssertEqual(app.operations.sorted(), ["get_state", "request_access"])
    }

    func test_case_mcp_follows_a_replacement() throws {
        let session = Stdin()
        let stale = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: true), caseMCP: true)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_keys","arguments":{}}}"#)
        XCTAssertTrue(stale.waitUntilStopped())
        XCTAssertEqual(stale.output.lines, [])
        let state = try XCTUnwrap(stale.relaunches.states.first)
        let fresh = Image(app: App(.trusts), stdin: session, disk: Disk(hasNewBuild: false), resumed: state, caseMCP: true)
        finish(fresh, session, answering: [1])
        XCTAssertTrue(fresh.output.lines.joined().contains("OPENAI_API_KEY"))
    }

    // MARK: Resume state transfer

    func test_resume_state_travels_through_an_inherited_unlinked_file_only() throws {
        let state = MCPResumeState(initialized: true, probed: false, input: Data("line\n".utf8), relaunches: [Date()])
        var template = Array((NSTemporaryDirectory() + "whytap-test.XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        let payload = try JSONEncoder().encode(state)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        setenv(MCPResumeState.environmentKey, String(fd), 1)
        XCTAssertEqual(MCPResumeState.takeFromEnvironment(), state)
        XCTAssertNil(getenv(MCPResumeState.environmentKey), "children never inherit it")
        XCTAssertEqual(fcntl(fd, F_GETFD), -1, "the descriptor is closed after reading")

        let stdin = Stdin()
        setenv(MCPResumeState.environmentKey, String(stdin.read), 1)
        XCTAssertNil(MCPResumeState.takeFromEnvironment(), "a pipe (stdin) is never read as state")
        setenv(MCPResumeState.environmentKey, "0", 1)
        XCTAssertNil(MCPResumeState.takeFromEnvironment())
        setenv(MCPResumeState.environmentKey, "junk", 1)
        XCTAssertNil(MCPResumeState.takeFromEnvironment())
    }

    func test_running_code_hash_comes_from_the_kernel() {
        XCTAssertEqual(SystemHelperBuildIdentity.runningHash()?.count, 20)
        // A file that is not a signed helper is never a "new build".
        XCTAssertFalse(SystemHelperBuildIdentity(executable: URL(fileURLWithPath: "/nonexistent/whytap")).newBuildAvailable())
    }
}
