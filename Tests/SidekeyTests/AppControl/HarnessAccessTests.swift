import CryptoKit
import Darwin
import WhytapCaseKit
import XCTest
@testable import Sidekey

private final class ProcessTable: CaseProcessInspecting {
    var table: [pid_t: CaseProcessInfo] = [:]

    func add(_ pid: pid_t, parent: pid_t, team: String? = nil, id: String? = nil) {
        table[pid] = CaseProcessInfo(
            pid: pid, parentPID: parent, executablePath: "/bin/p\(pid)", teamID: team, signingIdentifier: id)
    }

    func info(pid: pid_t) -> CaseProcessInfo? { table[pid] }
    func peer(of socket: Int32) -> (pid: pid_t, auditToken: audit_token_t)? { nil }
    func isTrustedHelper(auditToken: audit_token_t, helperURL: URL) -> Bool { false }
}

@MainActor
private final class Prompt: HarnessAccessPresenting {
    var answer: HarnessAccessOutcome = .allow
    private(set) var asked: [HarnessClient] = []
    private var waiting: [CheckedContinuation<HarnessAccessOutcome, Never>] = []
    var holds = false

    func requestAccess(for client: HarnessClient) async -> HarnessAccessOutcome {
        asked.append(client)
        guard holds else { return answer }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func release(_ outcome: HarnessAccessOutcome) {
        let held = waiting
        waiting = []
        for continuation in held { continuation.resume(returning: outcome) }
    }
}

/// A user installs the plugin, answers Whytap's question once and forgets it.
@MainActor
final class HarnessAccessTests: XCTestCase {
    private let helper: pid_t = 900
    private let claude = HarnessClient(
        identity: HarnessIdentity(teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code"),
        name: "Claude Code")
    private var processes: ProcessTable!
    private var prompt: Prompt!
    private var store: HarnessAccessStore!
    private var gate: HarnessAccessGate!
    private var file: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() async throws {
        processes = ProcessTable()
        // Claude Code starts the plugin's MCP server itself.
        processes.add(500, parent: 1, team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
        processes.add(helper, parent: 500)
        prompt = Prompt()
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-access-\(UUID().uuidString)/harness-access.json")
        store = HarnessAccessStore(fileURL: file, key: { [key] in key })
        gate = HarnessAccessGate(
            resolver: HarnessCallerResolver(inspector: processes), store: store, presenter: prompt)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func read(_ operation: String = "meetings_search", from pid: pid_t? = nil) async -> AppControlResponse? {
        await gate.intercept(AppControlRequest(operation), peerPID: pid ?? helper)
    }

    // MARK: The harness

    func test_only_the_process_that_started_the_helper_counts() {
        let resolver = HarnessCallerResolver(inspector: processes)
        XCTAssertEqual(resolver.client(peerPID: helper), claude)

        // A script in the harness's shell: claude -> zsh -> node -> helper.
        processes.add(600, parent: 500)
        processes.add(601, parent: 600)
        processes.add(901, parent: 601)
        XCTAssertNil(resolver.client(peerPID: 901))
    }

    func test_codex_is_its_own_harness_and_unknown_programs_are_none() {
        let resolver = HarnessCallerResolver(inspector: processes)
        processes.add(700, parent: 1, team: "2DC432GLL2", id: "codex")
        processes.add(902, parent: 700)
        XCTAssertEqual(resolver.client(peerPID: 902)?.name, "Codex")

        // A program that only claims Claude Code's identifier: no Apple-vouched team.
        processes.add(710, parent: 1, team: nil, id: "com.anthropic.claude-code")
        processes.add(903, parent: 710)
        XCTAssertNil(resolver.client(peerPID: 903))
        // The helper run by launchd, a missing parent, or a dead helper.
        processes.add(904, parent: 1)
        processes.add(905, parent: 4242)
        XCTAssertNil(resolver.client(peerPID: 904))
        XCTAssertNil(resolver.client(peerPID: 905))
        XCTAssertNil(resolver.client(peerPID: 4243))
    }

    // MARK: Yes / No

    func test_yes_is_asked_once_and_remembered() async {
        let first = await read()
        XCTAssertNil(first, "an allowed request goes through to the tools")
        let second = await read("meeting_get")
        XCTAssertNil(second)
        XCTAssertEqual(prompt.asked, [claude])
        XCTAssertEqual(store.decision(for: claude.identity), .allow)
    }

    func test_no_is_remembered_and_never_asked_again() async {
        prompt.answer = .deny
        let first = await read()
        let second = await read()
        XCTAssertEqual(first?.data.object?["code"], .string("access_denied"))
        XCTAssertEqual(second?.data.object?["code"], .string("access_denied"))
        XCTAssertEqual(prompt.asked.count, 1)
    }

    func test_an_unanswered_prompt_grants_nothing_and_the_next_request_asks_again() async {
        prompt.answer = .timedOut
        let first = await read()
        XCTAssertEqual(first?.data.object?["code"], .string("approval_timed_out"))
        XCTAssertNil(store.decision(for: claude.identity))
        prompt.answer = .allow
        let second = await read()
        XCTAssertNil(second)
        XCTAssertEqual(prompt.asked.count, 2)
    }

    func test_settings_and_todo_keep_their_earlier_boundary() async {
        prompt.answer = .deny
        for operation in ["get_state", "get_settings", "set_setting", "todo_list", "capture_screen"] {
            let answer = await read(operation)
            XCTAssertNil(answer, operation)
        }
        XCTAssertTrue(prompt.asked.isEmpty)
    }

    func test_every_meeting_tool_is_gated() {
        XCTAssertEqual(HarnessAccessGate.gatedOperations, AppControlMeetings.operations)
    }

    func test_a_script_in_the_harness_shell_gets_nothing_even_after_yes() async {
        _ = await read()
        processes.add(600, parent: 500)
        processes.add(901, parent: 600)
        let answer = await read(from: 901)
        XCTAssertEqual(answer?.data.object?["code"], .string("unsupported_client"))
    }

    // MARK: The prompt

    func test_sessions_starting_together_share_one_prompt() async {
        prompt.holds = true
        processes.add(906, parent: 500)
        async let first = read()
        async let second = read(from: 906)
        while prompt.asked.isEmpty { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(prompt.asked.count, 1)
        prompt.release(.allow)
        let answers = await [first, second]
        XCTAssertEqual(answers, [nil, nil])
    }

    func test_installing_the_plugin_shows_the_prompt_without_waiting_for_the_answer() async {
        prompt.holds = true
        let status = await read(HarnessAccessGate.requestOperation)
        XCTAssertEqual(status, .success(.object(["client": .string("Claude Code"), "access": .string("pending")])))
        while prompt.asked.isEmpty { await Task.yield() }

        // Another session of the same harness starts: still one prompt.
        _ = await read(HarnessAccessGate.requestOperation)
        XCTAssertEqual(prompt.asked.count, 1)

        prompt.release(.allow)
        while store.decision(for: claude.identity) == nil { await Task.yield() }
        let after = await read(HarnessAccessGate.requestOperation)
        XCTAssertEqual(after?.data.object?["access"], .string("allowed"))
    }

    func test_a_prompt_left_unanswered_is_not_repeated_by_new_sessions() async {
        prompt.answer = .timedOut
        _ = await read(HarnessAccessGate.requestOperation)
        while prompt.asked.isEmpty { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        _ = await read(HarnessAccessGate.requestOperation)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(prompt.asked.count, 1)
    }

    func test_a_client_that_left_during_the_prompt_gets_nothing() async {
        prompt.holds = true
        let request = Task { await self.read() }
        while prompt.asked.isEmpty { await Task.yield() }
        request.cancel()
        prompt.release(.allow)
        let answer = await request.value
        XCTAssertEqual(answer?.data.object?["code"], .string("cancelled"))
    }

    func test_access_revoked_in_settings_stops_the_next_request_and_asks_again() async {
        _ = await read()
        store.forget(claude.identity)
        prompt.answer = .deny
        let answer = await read()
        XCTAssertEqual(answer?.data.object?["code"], .string("access_denied"))
        XCTAssertEqual(prompt.asked.count, 2)
    }

    // MARK: Remembered answers

    func test_answers_survive_a_relaunch() {
        store.record(.allow, for: claude, at: Date(timeIntervalSince1970: 1_800_000_000))
        let relaunched = HarnessAccessStore(fileURL: file, key: { [key] in key })
        XCTAssertEqual(relaunched.decision(for: claude.identity), .allow)
        XCTAssertEqual(relaunched.grants.first?.name, "Claude Code")
    }

    func test_another_process_cannot_write_itself_a_yes() throws {
        store.record(.deny, for: claude, at: Date())
        // The attacker rewrites the file with its own key or flips the answer.
        let forged = HarnessAccessStore(fileURL: file, key: { SymmetricKey(size: .bits256) })
        forged.record(.allow, for: claude, at: Date())
        let relaunched = HarnessAccessStore(fileURL: file, key: { [key] in key })
        XCTAssertNil(relaunched.decision(for: claude.identity), "a file signed by another key is ignored")

        try Data("{\"payload\":\"e30=\",\"mac\":\"AAAA\"}".utf8).write(to: file)
        XCTAssertNil(HarnessAccessStore(fileURL: file, key: { [key] in key }).decision(for: claude.identity))
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(HarnessAccessStore(fileURL: file, key: { [key] in key }).decision(for: claude.identity))
    }

    // MARK: Settings -> Agents

    func test_settings_lists_answered_tools_by_name_and_the_switch_changes_the_answer() async {
        let codex = HarnessClient(identity: HarnessIdentity(teamID: "2DC432GLL2", signingIdentifier: "codex"), name: "Codex")
        store.record(.deny, for: codex, at: Date())
        store.record(.allow, for: claude, at: Date())
        XCTAssertEqual(HarnessAccessSettingsSection.rows(store.grants).map(\.name), ["Claude Code", "Codex"])
        XCTAssertTrue(HarnessAccessSettingsSection.subtitle(.deny).contains("Not allowed"))

        // The switch turned off: the session that is already open is refused.
        store.record(.deny, for: claude, at: Date())
        XCTAssertEqual(HarnessAccessSettingsSection.rows(store.grants).map(\.name), ["Claude Code", "Codex"])
        let refused = await read()
        XCTAssertEqual(refused?.data.object?["code"], .string("access_denied"))
        // Turned on again: no second prompt.
        store.record(.allow, for: claude, at: Date())
        let allowed = await read()
        XCTAssertNil(allowed)
        XCTAssertTrue(prompt.asked.isEmpty)
    }

    func test_without_the_keychain_nothing_is_trusted_or_overwritten() {
        store.record(.allow, for: claude, at: Date())
        var available = false
        let locked = HarnessAccessStore(fileURL: file, key: { [key] in available ? key : nil })
        XCTAssertNil(locked.decision(for: claude.identity))
        locked.record(.deny, for: HarnessClient(
            identity: HarnessIdentity(teamID: "2DC432GLL2", signingIdentifier: "codex"), name: "Codex"), at: Date())
        // The Keychain becomes readable: the saved Yes is back, this launch's No is kept.
        available = true
        XCTAssertEqual(locked.decision(for: claude.identity), .allow)
        XCTAssertEqual(locked.grants.count, 2)
    }
}
