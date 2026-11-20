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

private final class MemorySeal: HarnessAccessSealing {
    var stored: HarnessAccessSeal?
    /// A seal that exists and cannot be read.
    var readable = true
    var acceptsWrites = true
    var removable = true

    func load() -> HarnessAccessSealState {
        guard let stored else { return .missing }
        return readable ? .seal(stored) : .unreadable
    }

    func save(_ seal: HarnessAccessSeal) -> Bool {
        guard acceptsWrites else { return false }
        stored = seal
        return readable
    }

    func remove() -> Bool {
        guard removable else { return false }
        stored = nil
        return true
    }
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
    private var seal: MemorySeal!

    override func setUp() async throws {
        processes = ProcessTable()
        // Claude Code starts the plugin's MCP server itself.
        processes.add(500, parent: 1, team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
        processes.add(helper, parent: 500)
        prompt = Prompt()
        answers = MemoryAnswers()
        seal = MemorySeal()
        store = HarnessAccessStore(persistence: answers, seal: seal)
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

    private let codex = HarnessClient(
        identity: HarnessIdentity(teamID: "2DC432GLL2", signingIdentifier: "codex"), name: "Codex")

    private func relaunch() -> HarnessAccessStore { HarnessAccessStore(persistence: answers, seal: seal) }

    private func gate(on store: HarnessAccessStore) -> HarnessAccessGate {
        HarnessAccessGate(resolver: HarnessCallerResolver(inspector: processes), store: store, presenter: prompt)
    }

    func test_answers_survive_a_relaunch() {
        store.record(.allow, for: claude, at: Date(timeIntervalSince1970: 1_800_000_000))
        store.record(.deny, for: codex, at: Date(timeIntervalSince1970: 1_800_000_001))
        let relaunched = relaunch()
        XCTAssertEqual(relaunched.decision(for: claude.identity), .allow)
        XCTAssertEqual(relaunched.decision(for: codex.identity), .deny)
        XCTAssertEqual(relaunched.grants.map(\.name), ["Claude Code", "Codex"])
        XCTAssertFalse(relaunched.hasUnsavedAnswers)
    }

    func test_unreadable_stored_answers_allow_nobody() {
        answers.stored = Data("not json".utf8)
        XCTAssertNil(relaunch().decision(for: claude.identity))
        answers.stored = Data("{\"allow\":true}".utf8)
        XCTAssertNil(relaunch().decision(for: claude.identity))
    }

    /// The switch is turned off while the Keychain refuses the write, and
    /// Whytap is quit at once. The stored Yes must not come back.
    func test_a_no_the_keychain_refused_still_holds_after_an_immediate_relaunch() async {
        _ = await read()
        answers.acceptsWrites = false
        XCTAssertFalse(store.record(.deny, for: claude, at: Date()))
        XCTAssertTrue(store.hasUnsavedAnswers)
        XCTAssertFalse(store.revocationUnverified)
        let refused = await read()
        XCTAssertEqual(refused?.data.object?["code"], .string("access_denied"))

        // Relaunch with the Keychain still refusing writes: its item says Yes.
        let relaunched = relaunch()
        XCTAssertEqual(relaunched.decision(for: claude.identity), .deny)
        XCTAssertEqual(relaunched.grants.map(\.decision), [.deny])
        let answer = await gate(on: relaunched).intercept(AppControlRequest("meetings_search"), peerPID: helper)
        XCTAssertEqual(answer?.data.object?["code"], .string("access_denied"))
        XCTAssertEqual(prompt.asked.count, 1, "no new question either")

        // Relaunch with the Keychain locked: the No applies without reading it.
        answers.available = false
        XCTAssertEqual(relaunch().decision(for: claude.identity), .deny)

        // The Keychain takes writes again: the next answer stores the No too.
        answers.available = true
        answers.acceptsWrites = true
        let later = relaunch()
        XCTAssertTrue(later.record(.deny, for: codex, at: Date()))
        XCTAssertEqual(seal.stored?.revoked, [])
        seal.stored = nil
        XCTAssertEqual(relaunch().decision(for: claude.identity), .deny, "the Keychain alone now says No")
    }

    /// The same failed No, and then the seal is gone, unreadable or another
    /// one at the next launch: nothing proves the Yes in the Keychain is wanted.
    func test_a_stored_yes_without_its_seal_is_not_honoured() async {
        for damage in ["missing", "unreadable", "another seal"] {
            answers = MemoryAnswers()
            seal = MemorySeal()
            store = relaunch()
            store.record(.allow, for: claude, at: Date())
            answers.acceptsWrites = false
            XCTAssertFalse(store.record(.deny, for: claude, at: Date()))

            switch damage {
            case "missing": seal.stored = nil
            case "unreadable": seal.readable = false
            default: seal.stored = HarnessAccessSeal(token: "not-the-token", revoked: [])
            }
            let relaunched = relaunch()
            XCTAssertNil(relaunched.decision(for: claude.identity), damage)

            // The harness is asked again instead of being let in.
            prompt = Prompt()
            prompt.answer = .deny
            let answer = await gate(on: relaunched).intercept(AppControlRequest("meetings_search"), peerPID: helper)
            XCTAssertEqual(answer?.data.object?["code"], .string("access_denied"), damage)
            XCTAssertEqual(prompt.asked.count, 1, damage)
        }
    }

    /// The token the refused No leaves behind is new: the Keychain's old Yes
    /// cannot be matched again by anything still on disk.
    func test_a_refused_no_replaces_the_seal_token() {
        store.record(.allow, for: claude, at: Date())
        let sealed = seal.stored?.token
        XCTAssertNotNil(sealed)
        answers.acceptsWrites = false
        store.record(.deny, for: claude, at: Date())
        XCTAssertNotEqual(seal.stored?.token, sealed)
        XCTAssertEqual(seal.stored?.revoked.map(\.identity), [claude.identity])
        // Even with the journaled No removed by hand, the Yes does not return.
        seal.stored?.revoked = []
        XCTAssertNil(relaunch().decision(for: claude.identity))
    }

    /// Neither the Keychain nor the seal takes the No, but the old seal can
    /// be removed: the old Yes is cancelled, the tool will be asked again.
    func test_a_no_saved_nowhere_removes_the_seal_so_the_old_yes_cannot_return() {
        store.record(.allow, for: claude, at: Date())
        answers.acceptsWrites = false
        seal.acceptsWrites = false
        XCTAssertFalse(store.record(.deny, for: claude, at: Date()))
        XCTAssertNil(seal.stored)
        XCTAssertFalse(store.revocationUnverified)
        XCTAssertEqual(store.decision(for: claude.identity), .deny)
        XCTAssertNil(relaunch().decision(for: claude.identity), "asked again, never let in")
    }

    func test_a_no_that_reached_neither_place_and_could_not_remove_the_seal_says_so() {
        store.record(.allow, for: claude, at: Date())
        answers.acceptsWrites = false
        seal.acceptsWrites = false
        seal.removable = false
        XCTAssertFalse(store.record(.deny, for: claude, at: Date()))
        XCTAssertTrue(store.revocationUnverified)
        XCTAssertEqual(store.decision(for: claude.identity), .deny, "it holds for this launch")
        XCTAssertEqual(HarnessAccessSettingsSection.notice(unsaved: true, unverified: true),
                       HarnessAccessSettingsSection.unverifiedNotice)
        XCTAssertEqual(HarnessAccessSettingsSection.notice(unsaved: true, unverified: false),
                       HarnessAccessSettingsSection.unsavedNotice)
        XCTAssertNil(HarnessAccessSettingsSection.notice(unsaved: false, unverified: false))
        XCTAssertEqual(relaunch().decision(for: claude.identity), .allow, "exactly what the notice warns about")
        // Both become writable: the next read stores it and the warning goes.
        answers.acceptsWrites = true
        seal.acceptsWrites = true
        XCTAssertEqual(store.decision(for: claude.identity), .deny)
        XCTAssertFalse(store.revocationUnverified)
        XCTAssertFalse(store.hasUnsavedAnswers)
        XCTAssertEqual(relaunch().decision(for: claude.identity), .deny)
    }

    /// Claude Code is turned off and neither place saved it. Answering about
    /// Codex must not make the warning about Claude Code disappear.
    func test_the_warning_stays_until_that_no_is_saved_or_reversed() {
        store.record(.allow, for: claude, at: Date())
        answers.acceptsWrites = false
        seal.acceptsWrites = false
        seal.removable = false
        store.record(.deny, for: claude, at: Date())
        XCTAssertTrue(store.revocationUnverified)

        XCTAssertFalse(store.record(.allow, for: codex, at: Date()))
        XCTAssertTrue(store.revocationUnverified, "Claude Code's Off is still saved nowhere")
        XCTAssertFalse(store.record(.deny, for: codex, at: Date()))
        XCTAssertFalse(store.record(.allow, for: codex, at: Date()))
        XCTAssertTrue(store.revocationUnverified, "reversing Codex does not reverse Claude Code")

        // The seal becomes writable: the next answer about any tool lists the No.
        seal.acceptsWrites = true
        XCTAssertFalse(store.record(.allow, for: codex, at: Date()))
        XCTAssertFalse(store.revocationUnverified)
        XCTAssertEqual(seal.stored?.revoked.map(\.identity), [claude.identity])
        XCTAssertEqual(relaunch().decision(for: claude.identity), .deny)
    }

    func test_reversing_the_unsaved_no_itself_removes_the_warning() {
        store.record(.allow, for: claude, at: Date())
        answers.acceptsWrites = false
        seal.acceptsWrites = false
        seal.removable = false
        store.record(.deny, for: claude, at: Date())
        XCTAssertTrue(store.revocationUnverified)
        store.record(.allow, for: claude, at: Date())
        XCTAssertFalse(store.revocationUnverified)
        XCTAssertEqual(store.decision(for: claude.identity), .allow)
    }

    /// The seal stops taking writes after it listed Claude Code's No. Turning
    /// Codex off and on again must leave the ordinary notice: Claude Code's
    /// No is still on disk.
    func test_the_warning_is_worked_out_from_what_is_on_disk() {
        store.record(.allow, for: claude, at: Date())
        store.record(.allow, for: codex, at: Date())
        answers.acceptsWrites = false
        store.record(.deny, for: claude, at: Date())
        seal.acceptsWrites = false
        seal.removable = false
        store.record(.deny, for: codex, at: Date())
        XCTAssertFalse(store.revocationUnverified, "the rotated seal already cancelled Codex's stored Yes")
        store.record(.allow, for: codex, at: Date())
        XCTAssertFalse(store.revocationUnverified)
        XCTAssertTrue(store.hasUnsavedAnswers)
        XCTAssertEqual(relaunch().decision(for: claude.identity), .deny)
        XCTAssertNil(relaunch().decision(for: codex.identity))
    }

    /// An unsaved Yes for one tool keeps the seal of the others' stored answers.
    func test_an_unsaved_yes_does_not_cancel_other_stored_answers() {
        store.record(.allow, for: claude, at: Date())
        let token = seal.stored?.token
        answers.acceptsWrites = false
        XCTAssertFalse(store.record(.allow, for: codex, at: Date()))
        XCTAssertEqual(seal.stored?.token, token)
        let relaunched = relaunch()
        XCTAssertEqual(relaunched.decision(for: claude.identity), .allow)
        XCTAssertNil(relaunched.decision(for: codex.identity), "Codex is asked again")
    }

    /// Two tools were allowed. Codex is turned off while the Keychain
    /// refuses: Claude Code's stored Yes lost its seal too and must not be
    /// honoured, or written back, without asking.
    func test_a_refused_no_for_one_tool_makes_the_other_stored_yes_ask_again() {
        store.record(.allow, for: claude, at: Date())
        store.record(.allow, for: codex, at: Date())
        let loaded = relaunch()
        XCTAssertEqual(loaded.decision(for: claude.identity), .allow)
        answers.acceptsWrites = false
        XCTAssertFalse(loaded.record(.deny, for: codex, at: Date()))
        XCTAssertNil(loaded.decision(for: claude.identity), "in this same launch")
        answers.acceptsWrites = true
        XCTAssertEqual(loaded.decision(for: codex.identity), .deny)
        XCTAssertNil(loaded.decision(for: claude.identity))
        XCTAssertNil(relaunch().decision(for: claude.identity), "the Yes was not written back")
        XCTAssertEqual(relaunch().decision(for: codex.identity), .deny)
    }

    /// The seal lists a No and cannot be read for a moment at launch.
    func test_a_seal_unreadable_at_launch_keeps_its_no_and_is_not_replaced() {
        store.record(.allow, for: claude, at: Date())
        answers.acceptsWrites = false
        store.record(.deny, for: claude, at: Date())
        answers.acceptsWrites = true
        let journaled = seal.stored

        seal.readable = false
        let relaunched = relaunch()
        XCTAssertNil(relaunched.decision(for: claude.identity), "nothing is known yet: ask, do not allow")
        // An answer about another tool meanwhile must not wipe the seal's No.
        XCTAssertFalse(relaunched.record(.allow, for: codex, at: Date()))
        XCTAssertEqual(seal.stored?.revoked.map(\.identity), journaled?.revoked.map(\.identity))

        seal.readable = true
        XCTAssertEqual(relaunched.decision(for: claude.identity), .deny)
        XCTAssertFalse(relaunched.hasUnsavedAnswers)
        seal.stored = nil
        XCTAssertEqual(relaunch().decision(for: claude.identity), .deny, "the No reached the Keychain")
    }

    func test_while_the_keychain_is_locked_nothing_is_trusted_or_overwritten() {
        store.record(.allow, for: claude, at: Date())
        let stored = answers.stored
        answers.available = false
        let locked = relaunch()
        XCTAssertNil(locked.decision(for: claude.identity))
        XCTAssertEqual(answers.stored, stored)
        // It unlocks with nothing changed meanwhile: the stored Yes is back.
        answers.available = true
        XCTAssertEqual(locked.decision(for: claude.identity), .allow)
    }

    /// A No given while the Keychain is locked cannot be stored there, so it
    /// cancels every stored Yes: other tools are asked again rather than
    /// trusted on an answer that can no longer be confirmed.
    func test_a_no_given_while_the_keychain_is_locked_cancels_stored_yeses() {
        store.record(.allow, for: claude, at: Date())
        answers.available = false
        let locked = relaunch()
        XCTAssertFalse(locked.record(.deny, for: codex, at: Date()))
        XCTAssertFalse(locked.revocationUnverified)
        answers.available = true
        XCTAssertEqual(locked.decision(for: codex.identity), .deny)
        XCTAssertNil(locked.decision(for: claude.identity))
        let relaunched = relaunch()
        XCTAssertEqual(relaunched.decision(for: codex.identity), .deny)
        XCTAssertNil(relaunched.decision(for: claude.identity))
        XCTAssertEqual(relaunched.grants.count, 1)
    }

    func test_a_yes_survives_a_relaunch_only_with_its_seal_and_a_no_always() {
        store.record(.allow, for: claude, at: Date())
        store.record(.deny, for: codex, at: Date())
        XCTAssertEqual(relaunch().decision(for: claude.identity), .allow)
        seal.stored = nil
        let unsealed = relaunch()
        XCTAssertNil(unsealed.decision(for: claude.identity))
        XCTAssertEqual(unsealed.decision(for: codex.identity), .deny)
    }

    func test_turning_access_back_on_removes_the_journaled_no() {
        answers.acceptsWrites = false
        store.record(.deny, for: claude, at: Date())
        XCTAssertEqual(seal.stored?.revoked.map(\.identity), [claude.identity])
        // The user changes their mind before the Keychain is writable.
        XCTAssertFalse(store.record(.allow, for: claude, at: Date()))
        XCTAssertEqual(seal.stored?.revoked, [])
        XCTAssertEqual(store.decision(for: claude.identity), .allow)
        // That Yes was never stored: after a relaunch the harness is asked again.
        XCTAssertNil(relaunch().decision(for: claude.identity))
    }

    func test_the_seal_file_is_trusted_only_as_read_back_from_disk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = HarnessAccessSealFile(url: directory.appendingPathComponent("nested/harness-access-seal.json"))
        XCTAssertEqual(file.load(), .missing)
        let written = HarnessAccessSeal(token: "t1", revoked: [
            HarnessGrant(identity: claude.identity, name: "Claude Code", decision: .deny, decidedAt: Date(timeIntervalSince1970: 1_800_000_000))])
        XCTAssertTrue(file.save(written))
        XCTAssertEqual(file.load(), .seal(written))
        // Contents that are not a seal count as no seal and may be replaced.
        try Data("garbage".utf8).write(to: file.url)
        XCTAssertEqual(file.load(), .missing)
        // A seal that exists and cannot be read is told apart from a missing one.
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: false)
        XCTAssertEqual(file.load(), .unreadable)
        XCTAssertFalse(file.save(written))
        XCTAssertTrue(file.remove())
        XCTAssertEqual(file.load(), .missing)
        // A place that cannot hold the file: the save is reported as failed.
        XCTAssertTrue(file.save(written))
        let blocked = HarnessAccessSealFile(url: file.url.appendingPathComponent("under-a-file.json"))
        XCTAssertFalse(blocked.save(written))
    }

    /// A Yes forged into the seal is not an answer: only Nos are read from it.
    func test_a_yes_written_into_the_seal_gives_no_access() {
        seal.stored = HarnessAccessSeal(token: "x", revoked: [
            HarnessGrant(identity: codex.identity, name: "Codex", decision: .allow, decidedAt: Date())])
        XCTAssertNil(relaunch().decision(for: codex.identity))
    }

    /// The card is up; the user turns the tool off in Settings and only then
    /// the card's Yes arrives. The later answer stands.
    func test_an_answer_given_in_settings_while_the_card_is_up_is_not_overwritten_by_the_card() async {
        prompt.holds = true
        let request = Task { await self.read() }
        while prompt.asked.isEmpty { await Task.yield() }
        store.record(.deny, for: claude, at: Date())
        prompt.release(.allow)
        let answer = await request.value
        XCTAssertEqual(answer?.data.object?["code"], .string("access_denied"))
        XCTAssertEqual(store.decision(for: claude.identity), .deny)
        XCTAssertEqual(relaunch().decision(for: claude.identity), .deny)
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
