import CryptoKit
import XCTest
@testable import Sidekey

@MainActor
final class CaseRegistrationTests: XCTestCase {
    private let claude = CaseKnownClient.claudeCode.identity
    private let serversID = UUID()

    // MARK: Registration

    func test_register_requires_touch_id_and_defaults_to_approve() async throws {
        let fx = try await Fixture(payload: payload())
        fx.auth.reasons.removeAll()

        let report = try await fx.vm.registerApp(claude, name: "Claude Code")

        XCTAssertEqual(fx.auth.reasons, ["connect Claude Code to Case"])
        XCTAssertTrue(report.problems.isEmpty)
        let app = try XCTUnwrap(fx.service.payload?.apps.first)
        XCTAssertEqual(app.displayName, "Claude Code")
        XCTAssertEqual(app.identity, claude)
        XCTAssertEqual(app.defaultMode, .approve)
        XCTAssertTrue(app.projectModes.isEmpty)
        XCTAssertEqual(fx.clients.connected, [claude], "the client gets its Case MCP entry")
        XCTAssertEqual(fx.vm.registeredAppNames, ["Claude Code"])
        XCTAssertEqual(fx.store.saved?.apps.count, 1, "saved in the encrypted vault")
    }

    func test_failed_touch_id_registers_nothing() async throws {
        let fx = try await Fixture(payload: payload())
        fx.auth.fail = true

        do {
            _ = try await fx.vm.registerApp(claude, name: "Claude Code")
            XCTFail("expected Touch ID failure")
        } catch {
            XCTAssertEqual(error as? CaseViewModelError, .authenticationFailed)
        }
        XCTAssertEqual(fx.service.payload?.apps, [])
        XCTAssertTrue(fx.clients.connected.isEmpty)
    }

    func test_client_config_failure_does_not_block_registration() async throws {
        let fx = try await Fixture(payload: payload())
        fx.clients.connectProblems = ["Claude Code: app not found"]

        let report = try await fx.vm.registerApp(claude, name: "Claude Code")

        XCTAssertEqual(report.problems, ["Claude Code: app not found"])
        XCTAssertEqual(fx.service.payload?.apps.count, 1, "registered in Case anyway")
        XCTAssertEqual(fx.vm.clientSetupProblems, ["Claude Code: app not found"], "shown in the UI")
    }

    func test_partial_connector_setup_can_retry_without_changing_rights_or_registering_again() async throws {
        let fx = try await Fixture(payload: payload())
        fx.clients.connectProblems = ["Codex: setup failed"]
        let id = try await fx.vm.registerApp(claude, name: "Claude Code", projects: [serversID]).appID
        fx.clients.connectProblems = []
        fx.auth.reasons.removeAll()
        let result = try await fx.vm.retryClientSetup(for: id)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(fx.vm.clientSetupProblems.isEmpty)
        XCTAssertEqual(fx.clients.connected, [claude, claude])
        XCTAssertEqual(fx.vm.registrations.count, 1)
        XCTAssertEqual(fx.app(id)?.allowedProjectIDs, [serversID])
        XCTAssertTrue(fx.auth.reasons.isEmpty)
    }

    func test_duplicate_and_invalid_registrations_are_refused() async throws {
        let fx = try await Fixture(payload: payload())
        _ = try await fx.vm.registerApp(claude, name: "Claude Code")
        fx.auth.reasons.removeAll()

        await assertThrows(.alreadyRegistered) { _ = try await fx.vm.registerApp(self.claude, name: "Claude again") }
        await assertThrows(.invalidAppName) { _ = try await fx.vm.registerApp(.executablePath("/Applications/X.app"), name: "  ") }
        await assertThrows(.invalidAppName) { _ = try await fx.vm.registerApp(.executablePath("relative/x"), name: "X") }
        XCTAssertTrue(fx.auth.reasons.isEmpty, "refused before Touch ID")
        XCTAssertEqual(fx.service.payload?.apps.count, 1)
    }

    func test_locked_case_cannot_register() async throws {
        let fx = try await Fixture(payload: payload())
        fx.vm.lock()
        await assertThrows(.locked) { _ = try await fx.vm.registerApp(self.claude, name: "Claude Code") }
    }

    func test_connect_saves_chosen_scope_and_mode_atomically_and_widening_needs_touch_id() async throws {
        let fx = try await Fixture(payload: payload())
        fx.auth.reasons.removeAll()
        let id = try await fx.vm.registerApp(claude, name: "Claude Code", mode: .bypass, projects: [serversID]).appID
        XCTAssertEqual(fx.auth.reasons.count, 1)
        XCTAssertEqual(fx.app(id)?.allowedProjectIDs, [serversID])
        XCTAssertEqual(fx.app(id)?.defaultMode, .bypass)
        fx.auth.reasons.removeAll()
        try await fx.vm.setAccess(for: id, mode: .approve, projects: [], projectModes: [:])
        XCTAssertTrue(fx.auth.reasons.isEmpty, "closing access needs no authentication")
        fx.auth.fail = true
        await assertThrows(.authenticationFailed) {
            try await fx.vm.setAccess(for: id, mode: .approve, projects: nil, projectModes: [:])
        }
        XCTAssertEqual(fx.app(id)?.allowedProjectIDs, [])
        fx.auth.fail = false
        try await fx.vm.setAccess(for: id, mode: .approve, projects: nil, projectModes: [:])
        XCTAssertNil(fx.app(id)?.allowedProjectIDs)
        await assertThrows(.missingProject) {
            try await fx.vm.setAccess(for: id, mode: .approve, projects: [UUID()], projectModes: [:])
        }
    }

    // MARK: Modes

    func test_bypass_requires_touch_id_approve_does_not() async throws {
        let fx = try await Fixture(payload: payload())
        let appID = try await fx.vm.registerApp(claude, name: "Claude Code").appID
        fx.auth.reasons.removeAll()

        try await fx.vm.setMode(.bypass, for: appID, project: nil)
        XCTAssertEqual(fx.auth.reasons, ["turn on Bypass for Claude Code"])
        XCTAssertEqual(fx.app(appID)?.defaultMode, .bypass)

        fx.auth.reasons.removeAll()
        try await fx.vm.setMode(.approve, for: appID, project: nil)
        XCTAssertTrue(fx.auth.reasons.isEmpty, "back to Approve closes access without Touch ID")
        XCTAssertEqual(fx.app(appID)?.defaultMode, .approve)

        // Bypass for one project only.
        try await fx.vm.setMode(.bypass, for: appID, project: serversID)
        XCTAssertEqual(fx.auth.reasons, ["turn on Bypass for Claude Code"])
        XCTAssertEqual(fx.app(appID)?.projectModes[serversID], .bypass)
        XCTAssertEqual(fx.app(appID)?.defaultMode, .approve)

        // A failed Touch ID changes nothing.
        fx.auth.reasons.removeAll()
        fx.auth.fail = true
        await assertThrows(.authenticationFailed) { try await fx.vm.setMode(.bypass, for: appID, project: nil) }
        XCTAssertEqual(fx.app(appID)?.defaultMode, .approve)
        fx.auth.fail = false

        // "Default" removes the override, no Touch ID while the app is in Approve.
        fx.auth.reasons.removeAll()
        try await fx.vm.setMode(nil, for: appID, project: serversID)
        XCTAssertNil(fx.app(appID)?.projectModes[serversID])
        XCTAssertTrue(fx.auth.reasons.isEmpty)
    }

    func test_inheriting_a_bypass_app_mode_needs_touch_id() async throws {
        let fx = try await Fixture(payload: payload())
        let appID = try await fx.vm.registerApp(claude, name: "Claude Code").appID
        try await fx.vm.setMode(.bypass, for: appID, project: nil)
        try await fx.vm.setMode(.approve, for: appID, project: serversID)
        fx.auth.reasons.removeAll()

        // servers: Approve → "Default" (= Bypass) opens access.
        try await fx.vm.setMode(nil, for: appID, project: serversID)
        XCTAssertEqual(fx.auth.reasons, ["turn on Bypass for Claude Code"])
        XCTAssertNil(fx.app(appID)?.projectModes[serversID])

        await assertThrows(.missingProject) { try await fx.vm.setMode(.bypass, for: appID, project: UUID()) }
        await assertThrows(.missingApp) { try await fx.vm.setMode(.approve, for: UUID(), project: nil) }
        await assertThrows(.invalidAppOperation) { try await fx.vm.setMode(nil, for: appID, project: nil) }
    }

    // MARK: Unregister

    func test_unregister_removes_client_config_and_access() async throws {
        let fx = try await Fixture(payload: payload())
        let appID = try await fx.vm.registerApp(claude, name: "Claude Code").appID
        try await fx.vm.setMode(.bypass, for: appID, project: nil)
        fx.auth.reasons.removeAll()

        let report = try await fx.vm.unregisterApp(appID)

        XCTAssertTrue(fx.auth.reasons.isEmpty, "unregistering never asks for Touch ID")
        XCTAssertTrue(report.problems.isEmpty)
        XCTAssertEqual(fx.service.payload?.apps, [])
        XCTAssertEqual(fx.store.saved?.apps, [])
        XCTAssertEqual(fx.clients.disconnected, [claude])
        XCTAssertEqual(fx.vm.registeredAppNames, [])

        // Access is gone at once: the same caller now resolves as an unregistered AI.
        let caller = CaseCallerResolver(inspector: StubInspector(), registrations: fx.service.payload?.apps ?? [],
                                        builtInOpenCodePIDs: [])
        XCTAssertEqual(caller.resolve(peerPID: 100), .knownUnregisteredAI(name: "Claude Code"))
        await assertThrows(.missingApp) { _ = try await fx.vm.unregisterApp(appID) }
    }

    func test_unregister_reports_client_cleanup_failure_but_still_closes_access() async throws {
        let fx = try await Fixture(payload: payload())
        let appID = try await fx.vm.registerApp(claude, name: "Claude Code").appID
        fx.clients.disconnectProblems = ["Claude Code: command failed (1)"]

        let report = try await fx.vm.unregisterApp(appID)

        XCTAssertEqual(report.problems, ["Claude Code: command failed (1)"])
        XCTAssertEqual(fx.service.payload?.apps, [])
    }

    // MARK: Timed approval

    func test_timed_approval_minutes_range() async throws {
        let fx = try await Fixture(payload: payload())
        XCTAssertEqual(fx.vm.timedApprovalMinutes, 15)

        try fx.vm.setTimedApprovalMinutes(1)
        XCTAssertEqual(fx.service.payload?.timedApprovalMinutes, 1)
        try fx.vm.setTimedApprovalMinutes(240)
        XCTAssertEqual(fx.vm.timedApprovalMinutes, 240)
        for bad in [0, -5, 241, 10_000] {
            XCTAssertThrowsError(try fx.vm.setTimedApprovalMinutes(bad)) { error in
                XCTAssertEqual(error as? CaseViewModelError, .invalidMinutes)
            }
        }
        XCTAssertEqual(fx.service.payload?.timedApprovalMinutes, 240)
        XCTAssertEqual(CaseViewModel.parseTimedMinutes(" 30 "), 30)
        XCTAssertNil(CaseViewModel.parseTimedMinutes("abc"))
        XCTAssertNil(CaseViewModel.parseTimedMinutes("999"))
    }

    // MARK: Built-in OpenCode

    func test_opencode_config_contains_case_mcp_only_when_registered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let helperURL = directory.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let fx = try await Fixture(payload: payload())
        XCTAssertNil(CaseBuiltInAgentAccess.mcpCommand(payload: fx.service.payload, helperURL: helperURL))
        let unregistered = try OpenCodeEnvironment.make(workingDirectory: directory, model: "vendor/model", key: "k",
            allowActions: true, caseMCPCommand: nil, inherited: [:])
        XCTAssertNil(try config(unregistered)["mcp"])

        _ = try await fx.vm.registerApp(.builtInOpenCode, name: CaseKnownClient.builtInOpenCode.displayName)
        let command = try XCTUnwrap(CaseBuiltInAgentAccess.mcpCommand(payload: fx.service.payload, helperURL: helperURL))
        XCTAssertEqual(command, [helperURL.path, "case", "mcp"])
        XCTAssertNil(CaseBuiltInAgentAccess.mcpCommand(payload: fx.service.payload, helperURL: nil),
                     "no helper in the bundle: no entry")
        XCTAssertNil(CaseBuiltInAgentAccess.mcpCommand(payload: fx.service.payload,
                                                       helperURL: directory.appendingPathComponent("missing")))

        for allowActions in [true, false] {
            let env = try OpenCodeEnvironment.make(workingDirectory: directory, model: "vendor/model", key: "k",
                allowActions: allowActions, caseMCPCommand: command, inherited: [:])
            let json = try config(env)
            let mcp = try XCTUnwrap(json["mcp"] as? [String: Any])
            let entry = try XCTUnwrap(mcp["case"] as? [String: Any])
            XCTAssertEqual(entry["type"] as? String, "local")
            XCTAssertEqual(entry["command"] as? [String], [helperURL.path, "case", "mcp"])
            XCTAssertEqual(entry["enabled"] as? Bool, true)
            XCTAssertNil(entry["environment"], "no values or tokens in the agent config")
            let permission = try XCTUnwrap(json["permission"] as? [String: String])
            XCTAssertEqual(permission["case_*"], "allow", "listing tools allowed even with actions off")
            if !allowActions { XCTAssertEqual(permission["*"], "deny") }
        }

        // The built-in agent is told apart by the PIDs Whytap started.
        let processes = CaseBuiltInAgentProcesses()
        processes.insert(4242)
        let resolver = CaseCallerResolver(inspector: StubInspector(), registrations: fx.service.payload?.apps ?? [],
                                          builtInOpenCodePIDs: processes.pids)
        guard case .registered(let reg) = resolver.resolve(peerPID: 200) else {
            return XCTFail("built-in agent should resolve to its registration")
        }
        XCTAssertEqual(reg.identity, .builtInOpenCode)
        processes.remove(4242)
        XCTAssertTrue(processes.pids.isEmpty)
    }

    func test_opencode_process_pid_is_tracked_while_running() throws {
        let processes = CaseBuiltInAgentProcesses.shared
        let exited = expectation(description: "exit")
        var seenWhileRunning = false
        let handle = OpenCodeProvider.defaultRunStreaming(
            binary: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "read line; echo done"],
            workingDirectory: FileManager.default.temporaryDirectory, environment: [:], prompt: "go\n",
            onLine: { _ in }, onExit: { _ in exited.fulfill() })
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let pid = handle.processIdentifier, processes.pids.contains(pid) { seenWhileRunning = true; break }
            if !seenWhileRunning, handle.processIdentifier == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        wait(for: [exited], timeout: 5)
        XCTAssertTrue(seenWhileRunning || processes.pids.isEmpty)
        // After exit nothing of it remains, so a reused PID is never mistaken for the agent.
        let settle = Date().addingTimeInterval(1)
        while Date() < settle, !processes.pids.isEmpty { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(processes.pids.isEmpty)
    }

    // MARK: Known clients

    func test_known_clients_match_caller_resolver_identities() {
        XCTAssertEqual(CaseKnownClient.claudeCode.identity, .developerID(teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code"))
        XCTAssertEqual(CaseKnownClient.codex.identity, .developerID(teamID: "2DC432GLL2", signingIdentifier: "codex"))
        XCTAssertEqual(CaseKnownClient.cursor.identity, .executablePath("/Applications/Cursor.app"))
        XCTAssertEqual(CaseKnownClient.builtInOpenCode.identity, .builtInOpenCode)
        for known in CaseCallerResolver.knownAIApps {
            XCTAssertTrue(CaseKnownClient.allCases.contains {
                $0.identity == .developerID(teamID: known.teamID, signingIdentifier: known.identifier) && $0.displayName == known.name
            })
        }
        XCTAssertEqual(CaseKnownClient(identity: .executablePath("/Applications/Cursor.app")), .cursor)
        XCTAssertNil(CaseKnownClient(identity: .executablePath("/Applications/Other.app")))
        XCTAssertTrue(CaseKnownClient.cursor.hasSharedTerminal)
        XCTAssertFalse(CaseKnownClient.claudeCode.hasSharedTerminal)
    }

    func test_setup_installs_cli_then_connector_and_reports_each_problem() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("case-setup-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let helperURL = home.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let runner = FakeCommandRunner()
        let claudeConnector = ClaudeCodeCaseConnector(home: home, socketPath: "/tmp/x.sock", runner: runner,
                                                      locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        let setup = CaseClientSetup(helperURL: helperURL, binDir: bin, flavorName: "prod",
                                    connectors: [.claudeCode: claudeConnector, .cursor: CursorCaseConnector(home: home, appInstalled: { false })],
                                    builtInAgentAvailable: { true })

        let ok = await setup.connect(claude)
        XCTAssertEqual(ok.problems, [])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bin.appendingPathComponent("whytap").path), helperURL.path)
        XCTAssertEqual(runner.calls.last?.arguments.last(where: { $0.hasPrefix("/") }), helperURL.path)

        // The user's own file in the way and a failing client: both reported, nothing thrown.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("whytap"))
        try Data("mine".utf8).write(to: bin.appendingPathComponent("whytap"))
        runner.status = 2
        let bad = await setup.connect(claude)
        XCTAssertEqual(bad.problems.count, 2)
        XCTAssertTrue(bad.problems[0].contains("whytap"))
        XCTAssertTrue(bad.problems[1].hasPrefix("Claude Code:"))
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("whytap"), encoding: .utf8), "mine")

        // No helper in the bundle: nothing points at a missing file.
        let noHelper = CaseClientSetup(helperURL: nil, binDir: bin, flavorName: "prod",
                                       connectors: [.claudeCode: claudeConnector], builtInAgentAvailable: { true })
        runner.calls.removeAll()
        let missing = await noHelper.connect(claude)
        XCTAssertEqual(missing.problems.count, 1)
        XCTAssertTrue(runner.calls.isEmpty)

        // Built-in agent and arbitrary programs have no external config.
        runner.status = 0
        try FileManager.default.removeItem(at: bin.appendingPathComponent("whytap"))
        let builtIn = await setup.connect(.builtInOpenCode)
        XCTAssertEqual(builtIn.problems, [])
        let other = await setup.disconnect(.executablePath("/Applications/Other.app"))
        XCTAssertEqual(other.problems, [])
        // The located Claude Code CLI is offered; Codex and Cursor are absent here.
        let detected = await setup.detectInstalledClients()
        XCTAssertEqual(detected, [.builtInOpenCode, .claudeCode])
    }

    func test_connect_catalog_offers_installed_agent_claude_code_codex_and_cursor_only() async throws {
        XCTAssertEqual(CaseKnownClient.connectableClients, [.builtInOpenCode, .claudeCode, .codex, .cursor])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("case-detection-\(UUID().uuidString)")
        let runner = FakeCommandRunner()
        // Discovery must not install a CLI, write a config, run a client or request authentication.
        for openCodeInstalled in [false, true] {
            for claudeInstalled in [false, true] {
                for codexInstalled in [false, true] {
                    for cursorInstalled in [false, true] {
                        let claudeConnector = ClaudeCodeCaseConnector(
                            home: home, socketPath: "/tmp/x.sock", runner: runner,
                            locate: { claudeInstalled ? URL(fileURLWithPath: "/usr/local/bin/claude") : nil })
                        let codexConnector = CodexCaseConnector(
                            home: home, runner: runner,
                            locate: { codexInstalled ? URL(fileURLWithPath: "/usr/local/bin/codex") : nil })
                        let setup = CaseClientSetup(helperURL: nil, binDir: home, flavorName: "prod",
                                                    connectors: [.claudeCode: claudeConnector,
                                                                 .codex: codexConnector,
                                                                 .cursor: CursorCaseConnector(home: home, appInstalled: { cursorInstalled })],
                                                    builtInAgentAvailable: { openCodeInstalled })
                        let found = await setup.detectInstalledClients()
                        var expected: [CaseKnownClient] = []
                        if openCodeInstalled { expected.append(.builtInOpenCode) }
                        if claudeInstalled { expected.append(.claudeCode) }
                        if codexInstalled { expected.append(.codex) }
                        if cursorInstalled { expected.append(.cursor) }
                        XCTAssertEqual(found, expected,
                                       "Agent \(openCodeInstalled), Claude Code \(claudeInstalled), Codex \(codexInstalled), Cursor \(cursorInstalled)")
                    }
                }
            }
        }
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func test_picker_offers_claude_code_and_codex_until_registered() async throws {
        let fx = try await Fixture(payload: payload())
        fx.clients.detected = [.claudeCode, .cursor, .codex, .builtInOpenCode]
        let available = await fx.vm.availableClientsToRegister()
        XCTAssertEqual(available, [.builtInOpenCode, .claudeCode, .codex, .cursor])

        // Not installed: not offered.
        fx.clients.detected = [.cursor, .codex]
        let withoutClaude = await fx.vm.availableClientsToRegister()
        XCTAssertEqual(withoutClaude, [.codex, .cursor])
        fx.clients.detected = [.cursor]
        let withoutCodex = await fx.vm.availableClientsToRegister()
        XCTAssertEqual(withoutCodex, [.cursor])

        fx.clients.detected = [.claudeCode, .cursor, .codex, .builtInOpenCode]
        _ = try await fx.vm.registerApp(claude, name: "Claude Code")
        _ = try await fx.vm.registerApp(.builtInOpenCode, name: "OpenCode", projects: [serversID])
        fx.auth.reasons.removeAll()
        fx.clients.connected.removeAll()
        let savedApps = fx.vm.registrations
        // Already registered: edited from its icon, not offered again.
        let remaining = await fx.vm.availableClientsToRegister()
        XCTAssertEqual(remaining, [.codex, .cursor])
        XCTAssertEqual(fx.vm.registrations, savedApps)
        XCTAssertTrue(fx.auth.reasons.isEmpty)
        XCTAssertTrue(fx.clients.connected.isEmpty)
        // Codex leaves the picker once it is registered too.
        _ = try await fx.vm.registerApp(CaseKnownClient.codex.identity, name: "Codex")
        let afterCodex = await fx.vm.availableClientsToRegister()
        XCTAssertEqual(afterCodex, [.cursor])
    }

    // MARK: Helpers

    private func config(_ env: [String: String]) throws -> [String: Any] {
        let content = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    }

    private func payload() -> CaseVaultPayload {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let secretID = UUID()
        return CaseVaultPayload(
            projects: [CaseProject.general(now: date),
                       CaseProject(id: serversID, name: "servers", description: "", createdAt: date, updatedAt: date)],
            secrets: [CaseSecret(id: secretID, name: "NETCUP_IP", projectID: serversID, description: "",
                                 copyCount: 0, lastCopiedAt: nil, createdAt: date, updatedAt: date)],
            values: [CaseSecretValue(secretID: secretID, value: "fixture-secret")])
    }

    private func assertThrows(_ expected: CaseViewModelError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CaseViewModelError, expected, file: file, line: line)
        }
    }
}

// MARK: - Fakes

@MainActor
private final class Fixture {
    let store: RegStubStore
    let service: CaseVaultService
    let auth = RegStubAuthenticator()
    let clients = FakeClientSetup()
    let vm: CaseViewModel

    init(payload: CaseVaultPayload) async throws {
        store = RegStubStore(payload: payload)
        service = CaseVaultService(store: store, keyProvider: RegStubKeys())
        vm = CaseViewModel(service: service, authenticator: auth, pasteboard: RegStubPasteboard(),
                           scheduleIdleLock: { _, _ in RegStubCancellable() }, clients: clients)
        try await vm.unlock()
    }

    func app(_ id: UUID) -> CaseAppRegistration? {
        service.payload?.apps.first { $0.id == id }
    }
}

final class FakeClientSetup: CaseClientConfiguring {
    var connected: [CaseAppIdentity] = []
    var disconnected: [CaseAppIdentity] = []
    var connectProblems: [String] = []
    var disconnectProblems: [String] = []
    var detected: [CaseKnownClient] = [.claudeCode, .codex]

    func detectInstalledClients() async -> [CaseKnownClient] { detected }
    func connect(_ identity: CaseAppIdentity) async -> CaseClientSetupReport {
        connected.append(identity)
        return CaseClientSetupReport(problems: connectProblems)
    }
    func disconnect(_ identity: CaseAppIdentity) async -> CaseClientSetupReport {
        disconnected.append(identity)
        return CaseClientSetupReport(problems: disconnectProblems)
    }
}

/// Peer 100 ← Claude Code (Developer ID); peer 200 ← pid 4242 (built-in agent).
private struct StubInspector: CaseProcessInspecting {
    func info(pid: pid_t) -> CaseProcessInfo? {
        switch pid {
        case 100: return CaseProcessInfo(pid: 100, parentPID: 50, executablePath: "/Users/x/.local/bin/whytap", teamID: nil, signingIdentifier: nil)
        case 50: return CaseProcessInfo(pid: 50, parentPID: 1, executablePath: "/opt/claude", teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code")
        case 200: return CaseProcessInfo(pid: 200, parentPID: 4242, executablePath: "/x/whytap", teamID: nil, signingIdentifier: nil)
        case 4242: return CaseProcessInfo(pid: 4242, parentPID: 1, executablePath: "/x/opencode", teamID: nil, signingIdentifier: nil)
        default: return nil
        }
    }

    func peer(of socket: Int32) -> (pid: pid_t, auditToken: audit_token_t)? { nil }
    func isTrustedHelper(auditToken: audit_token_t, helperURL: URL) -> Bool { false }
}

private final class RegStubStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    var saved: CaseVaultPayload?
    init(payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload { payload }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws { self.payload = payload; saved = payload }
    func reset() throws {}
}

private final class RegStubKeys: CaseVaultKeyProviding {
    func readOrCreateKey() throws -> SymmetricKey { SymmetricKey(size: .bits256) }
}

private final class RegStubAuthenticator: CaseAuthenticating {
    var reasons: [String] = []
    var fail = false
    func authenticate(reason: String) async throws {
        reasons.append(reason)
        if fail { throw CaseAuthenticationError.denied }
    }
}

private final class RegStubPasteboard: CasePasteboardWriting {
    func writeString(_ value: String) {}
}

private final class RegStubCancellable: CaseIdleLockCancellable {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}
