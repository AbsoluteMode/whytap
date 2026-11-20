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

private final class MemoryAnswers: HarnessAccessPersisting {
    var stored: Data?
    var available = true
    var acceptsWrites = true

    func load() -> HarnessAccessStored {
        guard available else { return .unavailable }
        return stored.map(HarnessAccessStored.data) ?? .empty
    }

    func save(_ data: Data) -> Bool {
        guard available, acceptsWrites else { return false }
        stored = data
        return true
    }
}

private final class MemoryJournal: HarnessRevocationJournaling {
    var pending: [HarnessGrant] = []
    func load() -> [HarnessGrant] { pending }
    func save(_ pending: [HarnessGrant]) { self.pending = pending }
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
    private var answers: MemoryAnswers!
    private var journal: MemoryJournal!

    override func setUp() async throws {
        processes = ProcessTable()
        // Claude Code starts the plugin's MCP server itself.
        processes.add(500, parent: 1, team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
        processes.add(helper, parent: 500)
        prompt = Prompt()
        answers = MemoryAnswers()
        journal = MemoryJournal()
        store = HarnessAccessStore(persistence: answers, revocations: journal)
        gate = HarnessAccessGate(
            resolver: HarnessCallerResolver(inspector: processes), store: store, presenter: prompt)
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

    // MARK: Remembered answers

    func test_answers_survive_a_relaunch() {
        store.record(.allow, for: claude, at: Date(timeIntervalSince1970: 1_800_000_000))
        let relaunched = HarnessAccessStore(persistence: answers)
        XCTAssertEqual(relaunched.decision(for: claude.identity), .allow)
        XCTAssertEqual(relaunched.grants.first?.name, "Claude Code")
    }

    func test_unreadable_stored_answers_allow_nobody() {
        answers.stored = Data("not json".utf8)
        XCTAssertNil(HarnessAccessStore(persistence: answers).decision(for: claude.identity))
        answers.stored = Data("{\"allow\":true}".utf8)
        XCTAssertNil(HarnessAccessStore(persistence: answers).decision(for: claude.identity))
    }

    /// The switch is turned off while the Keychain refuses the write, and
    /// Whytap is quit at once. The stored Yes must not come back.
    func test_a_no_the_keychain_refused_still_holds_after_an_immediate_relaunch() async {
        _ = await read()
        answers.acceptsWrites = false
        XCTAssertFalse(store.record(.deny, for: claude, at: Date()))
        XCTAssertTrue(store.hasUnsavedAnswers, "Settings shows that it is not saved yet")
        let refused = await read()
        XCTAssertEqual(refused?.data.object?["code"], .string("access_denied"))

        // Relaunch with the Keychain still refusing writes: its item says Yes.
        let relaunched = HarnessAccessStore(persistence: answers, revocations: journal)
        XCTAssertEqual(relaunched.decision(for: claude.identity), .deny)
        XCTAssertEqual(HarnessAccessSettingsSection.rows(relaunched.grants).map(\.decision), [.deny])
        XCTAssertTrue(relaunched.hasUnsavedAnswers)
        let gate = HarnessAccessGate(
            resolver: HarnessCallerResolver(inspector: processes), store: relaunched, presenter: prompt)
        let answer = await gate.intercept(AppControlRequest("meetings_search"), peerPID: helper)
        XCTAssertEqual(answer?.data.object?["code"], .string("access_denied"))
        XCTAssertEqual(prompt.asked.count, 1, "no new question either")

        // Relaunch with the Keychain locked: the No applies before it can be read.
        answers.available = false
        XCTAssertEqual(HarnessAccessStore(persistence: answers, revocations: journal).decision(for: claude.identity), .deny)

        // The Keychain takes writes again: the No is stored and the journal emptied.
        answers.available = true
        answers.acceptsWrites = true
        let later = HarnessAccessStore(persistence: answers, revocations: journal)
        XCTAssertEqual(later.decision(for: claude.identity), .deny)
        XCTAssertFalse(later.hasUnsavedAnswers)
        XCTAssertTrue(journal.pending.isEmpty)
        XCTAssertEqual(HarnessAccessStore(persistence: answers).decision(for: claude.identity), .deny,
                       "the Keychain alone now says No")
    }

    func test_turning_access_back_on_removes_the_journaled_no() {
        answers.acceptsWrites = false
        store.record(.deny, for: claude, at: Date())
        XCTAssertEqual(journal.pending.map(\.identity), [claude.identity])
        // The user changes their mind before the Keychain is writable.
        XCTAssertFalse(store.record(.allow, for: claude, at: Date()))
        XCTAssertTrue(journal.pending.isEmpty)
        XCTAssertEqual(store.decision(for: claude.identity), .allow)
        // That Yes was never stored: after a relaunch the harness is asked again.
        XCTAssertNil(HarnessAccessStore(persistence: answers, revocations: journal).decision(for: claude.identity))
    }

    func test_a_damaged_journal_takes_no_access_away_and_a_yes_in_it_gives_none() {
        store.record(.allow, for: claude, at: Date())
        let defaults = UserDefaults(suiteName: "harness-access-tests-\(UUID().uuidString)")!
        defaults.set(Data("garbage".utf8), forKey: HarnessRevocationDefaults.key)
        let damaged = HarnessAccessStore(persistence: answers, revocations: HarnessRevocationDefaults(defaults: defaults))
        XCTAssertEqual(damaged.decision(for: claude.identity), .allow)

        // Another process writes a Yes for Codex into the journal: it is not an answer.
        let codex = HarnessClient(identity: HarnessIdentity(teamID: "2DC432GLL2", signingIdentifier: "codex"), name: "Codex")
        let forged = HarnessRevocationDefaults(defaults: defaults)
        forged.save([HarnessGrant(identity: codex.identity, name: "Codex", decision: .allow, decidedAt: Date())])
        XCTAssertNil(HarnessAccessStore(persistence: answers, revocations: forged).decision(for: codex.identity))

        // The real journal round-trips a No through UserDefaults.
        forged.save([HarnessGrant(identity: codex.identity, name: "Codex", decision: .deny, decidedAt: Date())])
        XCTAssertEqual(HarnessRevocationDefaults(defaults: defaults).load().map(\.decision), [.deny])
        forged.save([])
        XCTAssertNil(defaults.data(forKey: HarnessRevocationDefaults.key))
    }

    func test_while_the_keychain_is_locked_nothing_is_trusted_or_overwritten() {
        store.record(.allow, for: claude, at: Date())
        answers.available = false
        let locked = HarnessAccessStore(persistence: answers)
        XCTAssertNil(locked.decision(for: claude.identity))
        let codex = HarnessClient(identity: HarnessIdentity(teamID: "2DC432GLL2", signingIdentifier: "codex"), name: "Codex")
        XCTAssertFalse(locked.record(.deny, for: codex, at: Date()))
        // It unlocks: the stored Yes is back and this launch's No is stored with it.
        answers.available = true
        XCTAssertEqual(locked.decision(for: claude.identity), .allow)
        XCTAssertEqual(locked.decision(for: codex.identity), .deny)
        let relaunched = HarnessAccessStore(persistence: answers)
        XCTAssertEqual(relaunched.decision(for: codex.identity), .deny)
        XCTAssertEqual(relaunched.grants.count, 2)
    }

    // MARK: The whole request

    func test_access_turned_off_while_the_meeting_was_being_read_returns_nothing() async {
        _ = await read()
        var performed = 0
        let answer = await gate.handle(AppControlRequest("meeting_get"), peerPID: helper) { _ in
            performed += 1
            // The user flips the switch in Settings while the store is read.
            self.store.record(.deny, for: self.claude, at: Date())
            return .success(.string("the note"))
        }
        XCTAssertEqual(performed, 1)
        XCTAssertEqual(answer.data.object?["code"], .string("access_denied"))
    }

    func test_an_allowed_request_returns_what_the_tool_read_and_a_refused_one_reads_nothing() async {
        let allowed = await gate.handle(AppControlRequest("meeting_get"), peerPID: helper) { _ in .success(.string("the note")) }
        XCTAssertEqual(allowed, .success(.string("the note")))
        store.record(.deny, for: claude, at: Date())
        let refused = await gate.handle(AppControlRequest("meeting_get"), peerPID: helper) { _ in
            XCTFail("a refused request must not read"); return .success(.null)
        }
        XCTAssertEqual(refused.data.object?["code"], .string("access_denied"))
        // Settings tools are not affected by the answer.
        let state = await gate.handle(AppControlRequest("get_state"), peerPID: helper) { _ in .success(.string("state")) }
        XCTAssertEqual(state, .success(.string("state")))
    }

    func test_a_cancelled_request_stops_waiting_while_the_prompt_stays_for_the_user() async {
        prompt.holds = true
        let request = Task { await self.read() }
        while prompt.asked.isEmpty { await Task.yield() }
        request.cancel()
        let answer = await request.value
        XCTAssertEqual(answer?.data.object?["code"], .string("cancelled"), "returned without the user's answer")
        // The user answers later: the next request needs no second prompt.
        prompt.release(.allow)
        while store.decision(for: claude.identity) == nil { await Task.yield() }
        let next = await read()
        XCTAssertNil(next)
        XCTAssertEqual(prompt.asked.count, 1)
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

}
