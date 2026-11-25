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
        private var _resumes = true
        init(hasNewBuild: Bool, resumes: Bool = true) { _hasNewBuild = hasNewBuild; _resumes = resumes }
        var hasNewBuild: Bool { get { lock.withLock { _hasNewBuild } } set { lock.withLock { _hasNewBuild = newValue } } }
        var resumes: Bool { get { lock.withLock { _resumes } } set { lock.withLock { _resumes = newValue } } }
        var stagingFails = false
        private(set) var discarded = 0
        func verifiedReplacement() -> HelperReplacement? {
            hasNewBuild ? HelperReplacement(codeHashes: [Data(repeating: 7, count: 20)], resumesSession: resumes) : nil
        }
        func stageReplacement() -> StagedHelper? {
            guard !stagingFails, let replacement = verifiedReplacement() else { return nil }
            return StagedHelper(executable: "/private/staged/A.app/Contents/Helpers/whytap", directory: "/private/staged",
                                replacement: replacement)
        }
        func discard(_ staged: StagedHelper) { lock.withLock { discarded += 1 } }
    }

    /// Everything one helper image's relauncher was asked to hand over.
    private final class Relaunches: @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [MCPResumeState] = []
        private var _fresh = 0
        private var _executed: [String] = []
        let succeed: Bool
        init(succeed: Bool = true) { self.succeed = succeed }
        var states: [MCPResumeState] { lock.withLock { _states } }
        /// Execs into a build that cannot resume (no state).
        var fresh: Int { lock.withLock { _fresh } }
        /// The paths exec was given: always a staged, verified copy.
        var executed: [String] { lock.withLock { _executed } }
        func record(_ staged: StagedHelper, _ state: MCPResumeState?) -> Bool {
            lock.withLock { _executed.append(staged.executable); if let state { _states.append(state) } else { _fresh += 1 } }
            return succeed
        }
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
             relaunches: Relaunches = Relaunches(), now: @escaping () -> Date = Date.init, caseMCP: Bool = false,
             beforeProbeSends: @escaping () -> Void = {}) {
            self.app = app; self.stdin = stdin; self.relaunches = relaunches
            handover = MCPBuildHandover(identity: disk, resumed: resumed, helperPath: "/Applications/A.app/Contents/Helpers/whytap",
                                        now: now, relaunch: relaunches.record)
            let client = BuildFollowingBrokerClient(inner: app, handover: handover)
            let source = FileDescriptorLineSource(fd: stdin.read, prefill: resumed?.input ?? Data())
            let output = output, handover = handover
            Thread.detachNewThread { [self] in
                if caseMCP {
                    CaseMCPServer(client: client, executablePath: "/A.app/Contents/Helpers/whytap")
                        .run(source: source, write: output.write, handover: handover)
                } else {
                    AppControlMCPServer(confirmedAccessProbe: { [self] in
                        probes += 1
                        beforeProbeSends()
                        if case .appControl? = try? client.send(.appControl(AppControlRequest("request_access"))) { return true }
                        return false
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
        waitFor({ old.output.ids() == [1, 2] && app.operations.contains("request_access") }, "the first build answers normally")
        Thread.sleep(forTimeInterval: 0.05) // the probe's completion is recorded after its answer

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
        XCTAssertEqual(old.relaunches.executed, ["/private/staged/A.app/Contents/Helpers/whytap"], "exec runs the verified copy")
        XCTAssertEqual(state.helperPath, "/Applications/A.app/Contents/Helpers/whytap")
        XCTAssertEqual(state.stagingDirectory, "/private/staged")

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

    // MARK: Builder review 565

    func test_a_cancellation_already_buffered_before_exec_is_never_dispatched() throws {
        let session = Stdin()
        let image = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: true),
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []))
        let handover = image.handover
        // Hold the gate's handover until both lines are buffered: the call is
        // denied, then its cancellation sits unread when the handover drains.
        session.send(Self.call(2), #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#,
                     Self.call(3))
        XCTAssertTrue(image.waitUntilStopped())
        _ = handover
        let state = try XCTUnwrap(image.relaunches.states.first)
        let carried = String(decoding: state.input, as: UTF8.self)
        XCTAssertFalse(carried.contains(#""id":2"#), "the cancelled call is not replayed")
        XCTAssertFalse(carried.contains("notifications/cancelled"))
        XCTAssertTrue(carried.contains(#""id":3"#))
    }

    func test_carried_input_drops_a_call_cancelled_later_in_the_same_bytes() {
        let cancel2 = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#
        let cancel9 = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#
        XCTAssertEqual(MCPCarriedInput.droppingCancelled([Self.call(2), Self.call(3), cancel2, cancel9]),
                       [Self.call(3), cancel9], "an unmatched cancellation is harmless and kept")
        // A cancellation before its request (id reuse) does not cancel it.
        XCTAssertEqual(MCPCarriedInput.droppingCancelled([cancel2, Self.call(2)]), [cancel2, Self.call(2)])
    }

    func test_an_access_probe_still_in_flight_is_repeated_by_the_new_image() throws {
        let session = Stdin()
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        let app = App(.deniesStaleHelper)
        let stale = Image(app: app, stdin: session, disk: Disk(hasNewBuild: true), beforeProbeSends: {
            probeStarted.signal()
            _ = releaseProbe.wait(timeout: .now() + 5)
        })
        session.send(Self.initialize, Self.initialized)
        XCTAssertEqual(probeStarted.wait(timeout: .now() + 5), .success)
        session.send(Self.call(2))
        XCTAssertTrue(stale.waitUntilStopped())
        releaseProbe.signal()
        let state = try XCTUnwrap(stale.relaunches.states.first)
        XCTAssertTrue(state.initialized)
        XCTAssertFalse(state.probed, "scheduled is not done: the probe had sent nothing")
    }

    func test_a_replacement_that_cannot_resume_answers_every_carried_request_then_takes_over() {
        let session = Stdin()
        let image = Image(app: App(.deniesStaleHelper), stdin: session, disk: Disk(hasNewBuild: true, resumes: false),
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []))
        session.send(Self.call(2), Self.call(3))
        XCTAssertTrue(image.waitUntilStopped())
        XCTAssertEqual(image.relaunches.fresh, 1, "exec into the rollback build without a state")
        XCTAssertEqual(image.relaunches.states.count, 0)
        XCTAssertEqual(image.output.ids().sorted(), [2, 3], "the triggering call gets an explicit answer")
        XCTAssertTrue(image.output.lines.allSatisfy { $0.contains("Retry the request") })
    }

    func test_a_rollback_answers_at_once_and_execs_only_after_a_half_written_frame_completes() {
        let session = Stdin()
        let disk = Disk(hasNewBuild: true, resumes: false)
        let image = Image(app: App(.deniesStaleHelper), stdin: session, disk: disk,
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []))
        let next = Self.call(3)
        let split = next.index(next.startIndex, offsetBy: 12)
        session.sendPartial(Self.call(2) + "\n" + String(next[..<split]))
        waitFor({ image.output.ids() == [2] }, "the triggering call is answered while the next frame is unfinished")
        XCTAssertEqual(image.relaunches.fresh, 0, "no exec while a request is half written")
        XCTAssertEqual(disk.discarded, 1, "the staged copy of that attempt is removed")
        session.sendPartial(String(next[split...]) + "\n")
        XCTAssertTrue(image.waitUntilStopped())
        XCTAssertEqual(image.relaunches.fresh, 1)
        XCTAssertEqual(image.output.ids().sorted(), [2, 3])
    }

    func test_an_access_probe_the_app_never_answered_is_not_carried_as_done() throws {
        let session = Stdin()
        let app = App(.notRunning)
        let image = Image(app: app, stdin: session, disk: Disk(hasNewBuild: true))
        session.send(Self.initialize, Self.initialized)
        waitFor({ image.probes == 1 }, "the probe ran and got no answer")
        Thread.sleep(forTimeInterval: 0.05)
        app.mode = .deniesStaleHelper
        session.send(Self.call(2))
        XCTAssertTrue(image.waitUntilStopped())
        let state = try XCTUnwrap(image.relaunches.states.first)
        XCTAssertFalse(state.probed, "unavailable is not a confirmed answer")
    }

    func test_without_a_verified_private_copy_the_old_image_stays_and_answers() {
        let session = Stdin()
        let disk = Disk(hasNewBuild: true)
        disk.stagingFails = true
        let image = Image(app: App(.deniesStaleHelper), stdin: session, disk: disk,
                          resumed: MCPResumeState(initialized: true, probed: true, input: Data(), relaunches: []))
        session.send(Self.call(2), Self.call(3))
        finish(image, session, answering: [2, 3])
        XCTAssertEqual(image.relaunches.executed, [], "nothing unverified is executed")
    }

    func test_staging_folders_are_removed_only_under_their_root_and_after_their_process() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("whytap-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = HelperStaging.root(bundleID: "ai.whytap.test", home: home)
        XCTAssertEqual(root.path, home.path + "/Library/Application Support/ai.whytap.test/helper-handover")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outside = home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        HelperStaging.remove(outside.path, root: root)
        HelperStaging.remove(root.appendingPathComponent("../../outside").path, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "never outside the staging root")

        let current = root.appendingPathComponent("\(getpid())-current")
        let older = root.appendingPathComponent("\(getpid())-older")
        let otherLive = root.appendingPathComponent("1-live") // launchd: always running
        let dead = root.appendingPathComponent("999999-dead")
        for url in [current, older, otherLive, dead] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        HelperStaging.sweep(root: root, keeping: current.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path), "the copy this process runs from stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path), "this process's older copy goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherLive.path), "another running process keeps its copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path), "an ended process's copy goes")

        // A real staged copy only after a baseline; without one nothing is staged.
        let identity = SystemHelperBuildIdentity(executable: URL(fileURLWithPath: CommandLine.arguments[0]), stagingRoot: root)
        XCTAssertNil(identity.stageReplacement())
    }

    func test_the_copy_is_verified_again_right_before_exec() {
        final class FlipDisk: HelperBuildIdentifying, @unchecked Sendable {
            func verifiedReplacement() -> HelperReplacement? { HelperReplacement(codeHashes: [Data([1])], resumesSession: true) }
            /// The file changed after the trigger: the private copy does not verify.
            func stageReplacement() -> StagedHelper? { nil }
            func discard(_ staged: StagedHelper) {}
        }
        let relaunches = Relaunches()
        let handover = MCPBuildHandover(identity: FlipDisk(), resumed: nil, relaunch: relaunches.record)
        handover.observe(.denied(reason: .untrustedHelper))
        XCTAssertTrue(handover.isRequested)
        let outcome = handover.handOver(initialized: true, probed: true, held: [Self.call(2)], waiting: [],
                                        unread: Data(), write: { _ in })
        XCTAssertEqual(outcome, .answerHere, "the file no longer verifies: nothing is executed")
        XCTAssertEqual(relaunches.states.count + relaunches.fresh, 0)
        XCTAssertFalse(handover.isRequested)
    }

    func test_an_envelope_over_the_shared_bound_is_answered_here() {
        let relaunches = Relaunches()
        let handover = MCPBuildHandover(identity: Disk(hasNewBuild: true), resumed: nil, relaunch: relaunches.record)
        handover.observe(.denied(reason: .untrustedHelper))
        let big = Data(repeating: 0x61, count: MCPResumeState.maxEncodedBytes)
        XCTAssertEqual(handover.handOver(initialized: true, probed: true, held: [Self.call(2)], waiting: [],
                                         unread: big, write: { _ in }), .answerHere)
        XCTAssertEqual(relaunches.states.count, 0, "the writer never execs with an envelope the reader rejects")
        XCTAssertNil(MCPResumeState(initialized: true, probed: true, input: big, relaunches: []).encoded())
        let fits = MCPResumeState(initialized: true, probed: true, input: Data(repeating: 0x61, count: 1024), relaunches: [])
        XCTAssertEqual(fits.encoded().flatMap(MCPResumeState.decode), fits)
    }

    func test_too_many_waiting_lines_abandon_the_handover_and_everything_is_answered_here() {
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
        session.send(Self.call(3))
        waitFor({ image.handover.isRequested }, "the update is noticed")
        let pings = (0...MCPBuildHandover.maxWaitingLines).map { #"{"jsonrpc":"2.0","id":\#(1000 + $0),"method":"ping"}"# }
        for ping in pings { session.send(ping) }
        waitFor({ image.output.ids().count >= pings.count + 1 }, "pings and the denied call are answered here")
        app.mode = .trusts
        release.signal()
        finish(image, session, answering: [2, 3])
        XCTAssertEqual(image.relaunches.states.count, 0)
    }

    func test_an_image_that_is_not_the_verified_replacement_refuses_carried_requests() {
        let carried = MCPCarriedInput.join([Self.call(2), #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#])
            + Data(#"{"jsonrpc":"2.0","id":3"#.utf8)
        let state = MCPResumeState(initialized: true, probed: true, input: carried, relaunches: [Date()],
                                   expectedCodeHashes: [Data(repeating: 1, count: 20)])
        XCTAssertEqual(state.admitted(runningHash: Data(repeating: 1, count: 20), write: { _ in XCTFail("no refusal") }), state)
        var written: [String] = []
        let admitted = state.admitted(runningHash: Data(repeating: 2, count: 20)) { written.append($0) }
        XCTAssertEqual(written.count, 1, "one explicit error for the one carried request")
        XCTAssertTrue(written[0].contains(#""id":2"#) && written[0].contains("-32000"))
        XCTAssertEqual(admitted.input, Data(#"{"jsonrpc":"2.0","id":3"#.utf8), "the unfinished frame stays for stdin to complete")
        XCTAssertFalse(admitted.probed)
        XCTAssertEqual(admitted.relaunches.count, 1)
    }

    func test_an_unterminated_frame_is_bounded() {
        let stdin = Stdin()
        let source = FileDescriptorLineSource(fd: stdin.read, maxFrameBytes: 64)
        stdin.sendPartial(String(repeating: "x", count: 200))
        stdin.sendPartial(String(repeating: "y", count: 200) + "\nnext\n")
        stdin.close()
        XCTAssertTrue(source.waitForLine())
        XCTAssertEqual(source.takeLine(), String(repeating: "x", count: 64), "kept only up to the bound")
        XCTAssertTrue(source.waitForLine())
        XCTAssertEqual(source.takeLine(), "next")
        XCTAssertEqual(FileDescriptorLineSource.defaultMaxFrameBytes, AppControlMCPServer.maxLineBytes + 1,
                       "a truncated frame is always answered as too large")
    }

    func test_identity_without_a_baseline_accepts_no_replacement() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)")
        let identity = SystemHelperBuildIdentity(executable: URL(fileURLWithPath: CommandLine.arguments[0]), stagingRoot: root)
        XCTAssertNil(identity.verifiedReplacement(), "fail closed before the signer is known")
        XCTAssertNil(SystemHelperBuildIdentity(executable: URL(fileURLWithPath: "/nonexistent/whytap"), stagingRoot: root)
            .verifiedReplacement())
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
    }

    func test_a_process_whose_file_is_in_place_counts_as_intact() {
        // The test runner's executable exists and validates; an image that lost
        // its file (an identical build swapped in) is covered by the live check.
        XCTAssertTrue(SystemHelperBuildIdentity.runningCodeIntact())
    }
}
