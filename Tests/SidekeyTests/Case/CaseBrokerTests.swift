import CryptoKit
import Darwin
import WhytapCaseKit
import XCTest
@testable import Sidekey

// Test values are obviously fake; no real secrets.
private let alphaID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let betaID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let epoch = Date(timeIntervalSinceReferenceDate: 0)

private func project(_ id: UUID, _ name: String, _ description: String) -> CaseProject {
    CaseProject(id: id, name: name, description: description, createdAt: epoch, updatedAt: epoch)
}

private func secret(_ name: String, in projectID: UUID, _ description: String = "") -> CaseSecret {
    CaseSecret(id: UUID(), name: name, projectID: projectID, description: description,
               copyCount: 0, lastCopiedAt: nil, createdAt: epoch, updatedAt: epoch)
}

private func registration(_ mode: CaseAccessMode, name: String = "Claude Code") -> CaseAppRegistration {
    CaseAppRegistration(
        id: UUID(), displayName: name,
        identity: .developerID(teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code"),
        defaultMode: mode, projectModes: [:], createdAt: epoch)
}

/// alpha: OPENAI_API_KEY, DB_URL; beta: OPENAI_API_KEY, STRIPE_KEY; General: GH_TOKEN.
private func fixturePayload(apps: [CaseAppRegistration] = []) -> CaseVaultPayload {
    let secrets = [
        secret("OPENAI_API_KEY", in: alphaID, "alpha openai"),
        secret("DB_URL", in: alphaID),
        secret("OPENAI_API_KEY", in: betaID, "beta openai"),
        secret("STRIPE_KEY", in: betaID),
        secret("GH_TOKEN", in: CaseProject.generalID),
    ]
    let fakeValues = [
        "fake-alpha-openai-0001", "fake-alpha-db-0002", "fake-beta-openai-0003",
        "fake-beta-stripe-0004", "fake-general-gh-0005",
    ]
    return CaseVaultPayload(
        projects: [
            CaseProject.general(now: epoch),
            project(alphaID, "alpha", "Alpha web app"),
            project(betaID, "beta", "Beta billing"),
        ],
        secrets: secrets,
        values: zip(secrets, fakeValues).map { CaseSecretValue(secretID: $0.id, value: $1) },
        apps: apps,
        timedApprovalMinutes: 15)
}

private let allFakeValues = [
    "fake-alpha-openai-0001", "fake-alpha-db-0002", "fake-beta-openai-0003",
    "fake-beta-stripe-0004", "fake-general-gh-0005",
]

private final class BrokerMemoryStore: CaseVaultStoring {
    var payload: CaseVaultPayload
    var loadError: Error?
    private(set) var loadCount = 0
    init(_ payload: CaseVaultPayload) { self.payload = payload }
    func load(using key: SymmetricKey) throws -> CaseVaultPayload {
        loadCount += 1
        if let loadError { throw loadError }
        return payload
    }
    func save(_ payload: CaseVaultPayload, using key: SymmetricKey) throws { self.payload = payload }
    func reset() throws {}
}

private struct BrokerKeys: CaseVaultKeyProviding {
    static let key = SymmetricKey(size: .bits256)
    func readOrCreateKey() throws -> SymmetricKey { Self.key }
}

private final class ScriptedResolver: CaseCallerResolving {
    var caller: CaseCaller
    var origin: String?
    private(set) var calls = 0
    func terminalAppName(peerPID: pid_t) -> String? { origin }
    init(_ caller: CaseCaller) { self.caller = caller }
    func resolve(peerPID: pid_t, registrations: [CaseAppRegistration]) -> CaseCaller {
        calls += 1
        return caller
    }
}

@MainActor
private final class FakeApprovals: CaseApprovalPresenting {
    var outcome: CaseApprovalOutcome = .allow
    private(set) var requests: [CaseApprovalRequest] = []
    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome {
        requests.append(r)
        return outcome
    }
}

private final class FakeAuthenticator: CaseAuthenticating {
    var fails = false
    var onAuthenticate: (() throws -> Void)?
    private(set) var reasons: [String] = []
    func authenticate(reason: String) async throws {
        reasons.append(reason)
        try onAuthenticate?()
        if fails { throw CaseAuthenticationError.denied }
    }
}

/// Every peer is reported as the test process; trust is scripted.
private final class ServerInspector: CaseProcessInspecting, @unchecked Sendable {
    var trusted = true
    func info(pid: pid_t) -> CaseProcessInfo? { nil }
    func peer(of socket: Int32) -> (pid: pid_t, auditToken: audit_token_t)? { (getpid(), audit_token_t()) }
    func isTrustedHelper(auditToken: audit_token_t, helperURL: URL) -> Bool { trusted }
}

@MainActor
final class CaseBrokerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var store: BrokerMemoryStore!
    private var service: CaseVaultService!
    private var resolver: ScriptedResolver!
    private var approvals: FakeApprovals!
    private var auth: FakeAuthenticator!
    private var broker: CaseBroker!

    private func makeBroker(caller: CaseCaller, payload: CaseVaultPayload? = nil) {
        var apps: [CaseAppRegistration] = []
        if case .registered(let app) = caller { apps = [app] }
        var initial = payload ?? fixturePayload(apps: apps)
        // A scripted registered caller must actually be registered in the vault.
        for app in apps where !initial.apps.contains(where: { $0.id == app.id }) {
            initial.apps.append(app)
        }
        store = BrokerMemoryStore(initial)
        service = CaseVaultService(store: store, keyProvider: BrokerKeys())
        resolver = ScriptedResolver(caller)
        approvals = FakeApprovals()
        auth = FakeAuthenticator()
        broker = CaseBroker(
            service: service, resolver: resolver, approvals: approvals, authenticator: auth,
            now: { [unowned self] in self.clock })
    }

    private func run(project: String? = nil, only: [String]? = nil, command: String = "npm test") async -> CaseBrokerResponse {
        await broker.handle(.resolveRun(project: project, only: only, command: command, cwd: "/tmp"), peerPID: 900)
    }

    func test_app_controls_do_not_load_case_vault_resolve_case_caller_or_authorize_secrets() async {
        makeBroker(caller: .registered(registration(.approve)))
        let controls = CaseBroker(service: service, resolver: resolver, approvals: approvals, authenticator: auth,
                                  appControl: { request in .success(.string(request.operation)) })
        let response = await controls.handle(.appControl(AppControlRequest("get_state")), peerPID: 900)
        XCTAssertEqual(response, .appControl(.success(.string("get_state"))))
        XCTAssertEqual(store.loadCount, 0)
        XCTAssertNil(service.payload)
        XCTAssertEqual(resolver.calls, 0)
        XCTAssertTrue(auth.reasons.isEmpty)
        XCTAssertTrue(approvals.requests.isEmpty)
    }

    /// Content tools first pass the harness access gate, with the helper's
    /// pid; a refusal never reaches the controls and never touches the vault.
    func test_harness_access_decides_before_the_app_controls_and_without_the_vault() async {
        makeBroker(caller: .registered(registration(.bypass)))
        var reached: [String] = []
        var asked: [(String, pid_t)] = []
        let controls = CaseBroker(
            service: service, resolver: resolver, approvals: approvals, authenticator: auth,
            appControl: { request in reached.append(request.operation); return .success(.null) },
            harnessAccess: { request, pid in
                asked.append((request.operation, pid))
                return request.operation == "meetings_search" ? .failure("access_denied", "no") : nil
            })
        let refused = await controls.handle(.appControl(AppControlRequest("meetings_search")), peerPID: 900)
        XCTAssertEqual(refused, .appControl(.failure("access_denied", "no")))
        let passed = await controls.handle(.appControl(AppControlRequest("get_state")), peerPID: 900)
        XCTAssertEqual(passed, .appControl(.success(.null)))
        XCTAssertEqual(reached, ["get_state"])
        XCTAssertEqual(asked.map(\.0), ["meetings_search", "get_state"])
        XCTAssertEqual(asked.map(\.1), [900, 900])
        XCTAssertEqual(store.loadCount, 0, "a Case Bypass registration gives no access to meetings")
        XCTAssertEqual(resolver.calls, 0)
    }

    func test_app_control_client_exchanges_through_the_authenticated_socket() async throws {
        makeBroker(caller: .registered(registration(.approve)))
        broker = CaseBroker(service: service, resolver: resolver, approvals: approvals, authenticator: auth,
                            appControl: { request in .success(.string(request.operation)) })
        let dir = try tempSocketDir()
        let server = makeServer(dir: dir, inspector: ServerInspector())
        try server.start()
        defer { server.stop() }
        let reply = try await Self.call(dir.appendingPathComponent("b.sock"), .appControl(AppControlRequest("get_state")))
        XCTAssertEqual(reply, .appControl(.success(.string("get_state"))))
        XCTAssertEqual(store.loadCount, 0)
    }

    func test_cancelling_control_socket_cancels_the_pending_app_task() async throws {
        makeBroker(caller: .registered(registration(.approve)))
        let began = expectation(description: "control reached app")
        let cancelled = expectation(description: "app task cancelled")
        broker = CaseBroker(service: service, resolver: resolver, approvals: approvals, authenticator: auth,
                            appControl: { _ in
            began.fulfill()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                XCTFail("the pending task should have been cancelled")
            } catch { cancelled.fulfill() }
            return .failure("cancelled", "test")
        })
        let dir = try tempSocketDir()
        let server = makeServer(dir: dir, inspector: ServerInspector())
        try server.start()
        defer { server.stop() }
        let cancellation = AppControlCancellation()
        let client = UnixSocketBrokerClient(socketURL: dir.appendingPathComponent("b.sock"))
        let task = Task.detached { try client.send(.appControl(AppControlRequest("get_state")), cancellation: cancellation) }
        await fulfillment(of: [began], timeout: 2)
        cancellation.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        do { _ = try await task.value; XCTFail("cancelled connection should fail") } catch {}
        XCTAssertEqual(store.loadCount, 0)
    }

    func test_scope_limits_listing_lookup_and_bypass_even_with_a_timed_grant() async throws {
        var app = registration(.bypass)
        app.allowedProjectIDs = [alphaID]
        makeBroker(caller: .registered(app))
        let projects = await broker.handle(.listProjects, peerPID: 900)
        XCTAssertEqual(projects, .projects([CaseProjectInfo(name: "alpha", description: "Alpha web app", keyCount: 2)]))
        let outsideKeys = await broker.handle(.listKeys(project: "beta"), peerPID: 900)
        XCTAssertEqual(outsideKeys, .denied(reason: .unknownProject))
        let keys = await broker.handle(.listKeys(project: nil), peerPID: 900)
        guard case .keys(let visible) = keys else { return XCTFail("expected keys") }
        XCTAssertEqual(Set(visible.map(\.project)), ["alpha"])
        let outsideRun = await run(project: "beta")
        XCTAssertEqual(outsideRun, .denied(reason: .unknownProject))
        let unqualified = await run(only: ["OPENAI_API_KEY"])
        XCTAssertEqual(unqualified, .runEnvironment(["OPENAI_API_KEY": "fake-alpha-openai-0001"]),
                       "a duplicate in an inaccessible project is not disclosed")
        try service.mutate { $0.apps[0].allowedProjectIDs = [] }
        let none = await broker.handle(.listProjects, peerPID: 900)
        XCTAssertEqual(none, .projects([]))
        let denied = await run(project: "alpha")
        XCTAssertEqual(denied, .denied(reason: .unknownProject))
    }

    func test_scope_revocation_while_approval_is_open_releases_neither_keys_nor_grant() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) {
            try self.service.mutate { $0.apps[0].allowedProjectIDs = [] }
        }
        let response = await run(project: "alpha")
        XCTAssertEqual(response, .denied(reason: .unknownProject))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    func test_timed_bypass_uses_selected_duration_and_scope_changes_revoke_it() async throws {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        approvals.outcome = .allowTimed(minutes: 2)
        _ = await run(project: "alpha")
        XCTAssertTrue(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock + 119))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock + 120))
        try service.mutate { $0.apps[0].allowedProjectIDs = [betaID] }
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
        try service.mutate { $0.apps[0].allowedProjectIDs = nil }
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
        approvals.outcome = .allowTimed(minutes: 241)
        let invalid = await run(project: "alpha")
        XCTAssertEqual(invalid, .denied(reason: .userDeclined))
    }

    // MARK: Brief scenarios

    func test_bypass_returns_environment_without_prompt() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let response = await run(project: "alpha")

        XCTAssertEqual(response, .runEnvironment([
            "OPENAI_API_KEY": "fake-alpha-openai-0001",
            "DB_URL": "fake-alpha-db-0002",
        ]))
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertTrue(auth.reasons.isEmpty)
    }

    func test_approve_prompts_and_timed_grant_skips_next_prompt() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        approvals.outcome = .allowTimed(minutes: 15)

        let first = await run(project: "alpha", only: ["DB_URL"], command: "psql \"$DB_URL\"")

        XCTAssertEqual(first, .runEnvironment(["DB_URL": "fake-alpha-db-0002"]))
        XCTAssertEqual(approvals.requests, [CaseApprovalRequest(
            appName: "Claude Code", projectName: "alpha", keyNames: ["DB_URL"],
            command: "psql \"$DB_URL\"", timedMinutes: 15, appID: app.id, projectID: alphaID)])

        // Within the 15 minutes: no prompt for the same app and project.
        approvals.outcome = .deny
        clock = clock.addingTimeInterval(14 * 60)
        let second = await run(project: "alpha")
        XCTAssertEqual(second, .runEnvironment([
            "OPENAI_API_KEY": "fake-alpha-openai-0001", "DB_URL": "fake-alpha-db-0002",
        ]))
        XCTAssertEqual(approvals.requests.count, 1)

        // Another project is not covered by the grant.
        let other = await run(project: "beta")
        XCTAssertEqual(other, .denied(reason: .userDeclined))
        XCTAssertEqual(approvals.requests.count, 2)

        // After expiry the prompt comes back.
        clock = clock.addingTimeInterval(2 * 60)
        let expired = await run(project: "alpha")
        XCTAssertEqual(expired, .denied(reason: .userDeclined))
        XCTAssertEqual(approvals.requests.count, 3)
    }

    func test_ambiguous_name_without_project() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let response = await run(only: ["OPENAI_API_KEY"])

        XCTAssertEqual(response, .ambiguous(key: "OPENAI_API_KEY", projects: [
            CaseProjectInfo(name: "alpha", description: "Alpha web app", keyCount: 2),
            CaseProjectInfo(name: "beta", description: "Beta billing", keyCount: 2),
        ]))
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertTrue(auth.reasons.isEmpty)
    }

    func test_listing_contains_no_values() async throws {
        makeBroker(caller: .registered(registration(.approve)))

        let projects = await broker.handle(.listProjects, peerPID: 900)
        let allKeys = await broker.handle(.listKeys(project: nil), peerPID: 900)
        let alphaKeys = await broker.handle(.listKeys(project: "alpha"), peerPID: 900)

        XCTAssertEqual(alphaKeys, .keys([
            CaseKeyInfo(name: "DB_URL", description: "", project: "alpha"),
            CaseKeyInfo(name: "OPENAI_API_KEY", description: "alpha openai", project: "alpha"),
        ]))
        guard case .keys(let keys) = allKeys else { return XCTFail("expected keys") }
        XCTAssertEqual(keys.count, 5)
        guard case .projects(let list) = projects else { return XCTFail("expected projects") }
        XCTAssertEqual(list.map(\.name), ["General", "alpha", "beta"])

        for response in [projects, allKeys, alphaKeys] {
            let wire = String(decoding: try CaseBrokerCodec.encodeLine(response), as: UTF8.self)
            for value in allFakeValues {
                XCTAssertFalse(wire.contains(value))
                XCTAssertFalse(wire.contains(Data(value.utf8).base64EncodedString()))
            }
        }
        // Names are given to a registered app even in Approve mode, without a prompt.
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertTrue(auth.reasons.isEmpty)
    }

    // MARK: Key resolution

    func test_run_with_project_returns_only_that_projects_values() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let response = await run(project: "beta", only: ["OPENAI_API_KEY"])

        XCTAssertEqual(response, .runEnvironment(["OPENAI_API_KEY": "fake-beta-openai-0003"]))
    }

    func test_unique_name_without_project_resolves_to_its_project() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let response = await run(only: ["STRIPE_KEY"])

        XCTAssertEqual(response, .runEnvironment(["STRIPE_KEY": "fake-beta-stripe-0004"]))
    }

    func test_run_without_project_or_only_is_unknown_project() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let none = await run()
        let empty = await run(only: [])
        XCTAssertEqual(none, .denied(reason: .unknownProject))
        XCTAssertEqual(empty, .denied(reason: .unknownProject))
    }

    func test_unknown_project_and_unknown_key() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let missingProject = await run(project: "gamma")
        let missingKeyInProject = await run(project: "alpha", only: ["STRIPE_KEY"])
        let missingKeyAnywhere = await run(only: ["NOPE"])
        XCTAssertEqual(missingProject, .denied(reason: .unknownProject))
        XCTAssertEqual(missingKeyInProject, .denied(reason: .unknownKey))
        XCTAssertEqual(missingKeyAnywhere, .denied(reason: .unknownKey))
    }

    func test_keys_from_two_projects_without_project_are_refused() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let response = await run(only: ["DB_URL", "STRIPE_KEY"])

        XCTAssertEqual(response, .denied(reason: .unknownProject))
    }

    func test_project_name_matches_case_insensitively() async {
        makeBroker(caller: .registered(registration(.bypass)))

        let response = await run(project: "ALPHA", only: ["DB_URL"])

        XCTAssertEqual(response, .runEnvironment(["DB_URL": "fake-alpha-db-0002"]))
    }

    // MARK: Callers

    func test_human_run_asks_touch_id_with_project_reason() async {
        makeBroker(caller: .human)

        let allowed = await run(project: "alpha", only: ["DB_URL"])
        XCTAssertEqual(allowed, .runEnvironment(["DB_URL": "fake-alpha-db-0002"]))
        XCTAssertEqual(auth.reasons, ["let an unknown process run “npm test” with keys from project alpha"])

        auth.fails = true
        let refused = await run(project: "alpha")
        XCTAssertEqual(refused, .denied(reason: .touchIDFailed))
        XCTAssertTrue(approvals.requests.isEmpty)
    }

    func test_touch_id_reason_names_the_terminal_and_a_one_line_command() async {
        makeBroker(caller: .human)
        resolver.origin = "iTerm2"
        let long = "docker compose -f deploy/compose.prod.yml run --rm migrate\n  && ./scripts/seed.sh --env production --force"
        _ = await run(project: "alpha", only: ["DB_URL"], command: long)
        let reason = try? XCTUnwrap(auth.reasons.first)
        XCTAssertEqual(reason?.hasPrefix("let iTerm2 run “"), true)
        XCTAssertEqual(reason?.hasSuffix("” with keys from project alpha"), true)
        let shown = CaseBroker.commandSummary(long)
        XCTAssertEqual(shown.count, 80)
        XCTAssertFalse(shown.contains("\n"))
        XCTAssertTrue(shown.hasPrefix("docker compose"))
        XCTAssertTrue(shown.hasSuffix("--force"))
        XCTAssertTrue(shown.contains("…"))
        XCTAssertEqual(CaseBroker.commandSummary("  npm   test "), "npm test")
        // Values never get into the reason: only the command text the caller typed.
        XCTAssertFalse(auth.reasons.joined().contains("fake-alpha-db-0002"))
    }

    func test_human_listing_requires_touch_id() async {
        makeBroker(caller: .human)
        auth.fails = true

        let response = await broker.handle(.listProjects, peerPID: 900)

        XCTAssertEqual(response, .denied(reason: .touchIDFailed))
        XCTAssertEqual(auth.reasons.count, 1)
    }

    func test_human_ambiguity_needs_touch_id_before_project_names() async {
        makeBroker(caller: .human)
        auth.fails = true

        let response = await run(only: ["OPENAI_API_KEY"])

        XCTAssertEqual(response, .denied(reason: .touchIDFailed))
    }

    func test_unregistered_ai_gets_neither_names_nor_values() async {
        makeBroker(caller: .knownUnregisteredAI(name: "Codex"))

        let list = await broker.handle(.listKeys(project: nil), peerPID: 900)
        let ambiguous = await run(only: ["OPENAI_API_KEY"])
        let runResponse = await run(project: "alpha")
        XCTAssertEqual(list, .denied(reason: .unknownAIApp))
        XCTAssertEqual(ambiguous, .denied(reason: .unknownAIApp))
        XCTAssertEqual(runResponse, .denied(reason: .unknownAIApp))
        XCTAssertTrue(approvals.requests.isEmpty)
        XCTAssertTrue(auth.reasons.isEmpty)
    }

    func test_approve_deny_and_timeout_are_reported() async {
        makeBroker(caller: .registered(registration(.approve)))

        approvals.outcome = .deny
        let denied = await run(project: "alpha")
        approvals.outcome = .timedOut
        let timedOut = await run(project: "alpha")
        approvals.outcome = .allow
        let allowed = await run(project: "alpha", only: ["DB_URL"])
        approvals.outcome = .deny
        let again = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(denied, .denied(reason: .userDeclined))
        XCTAssertEqual(timedOut, .denied(reason: .timedOut))
        XCTAssertEqual(allowed, .runEnvironment(["DB_URL": "fake-alpha-db-0002"]))
        XCTAssertEqual(again, .denied(reason: .userDeclined), "a one-time allow grants nothing")
    }

    func test_key_deleted_while_prompt_is_up_is_not_returned() async throws {
        makeBroker(caller: .registered(registration(.approve)))
        let deleting = DeletingApprovals(service: service, keyName: "DB_URL")
        broker = CaseBroker(service: service, resolver: resolver, approvals: deleting, authenticator: auth,
                            now: { [unowned self] in self.clock })

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .unknownKey))
    }

    func test_unregister_during_allow_denies_values() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allow) {
            XCTAssertNoThrow(try self.service.mutate { $0.apps.removeAll { $0.id == app.id } })
        }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .notRegistered))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    func test_unregister_during_timed_allow_creates_no_grant() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) {
            XCTAssertNoThrow(try self.service.mutate { $0.apps.removeAll { $0.id == app.id } })
        }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .notRegistered))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    func test_rebound_registration_during_approval_denies_values_and_grant() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) {
            XCTAssertNoThrow(try self.service.mutate {
                $0.apps[0].identity = .executablePath("/fake/replacement-client")
            })
        }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .notRegistered))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    func test_changed_peer_during_approval_denies_values_and_grant() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) { self.resolver.caller = .human }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .notRegistered))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    func test_reregistered_app_cannot_use_old_pending_approval() async {
        let app = registration(.approve)
        var replacement = app
        replacement.id = UUID()
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) {
            XCTAssertNoThrow(try self.service.mutate { $0.apps = [replacement] })
            self.resolver.caller = .registered(replacement)
        }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .notRegistered))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
        XCTAssertFalse(broker.grants.isGranted(appID: replacement.id, projectID: alphaID, now: clock))
    }

    func test_deleted_project_during_timed_allow_creates_no_grant() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) {
            XCTAssertNoThrow(try self.service.mutate { payload in
                let ids = Set(payload.secrets.filter { $0.projectID == alphaID }.map(\.id))
                payload.projects.removeAll { $0.id == alphaID }
                payload.secrets.removeAll { ids.contains($0.id) }
                payload.values.removeAll { ids.contains($0.secretID) }
            })
        }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .unknownProject))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    func test_deleted_key_during_timed_allow_creates_no_grant() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) {
            XCTAssertNoThrow(try self.service.mutate { payload in
                let ids = Set(payload.secrets.filter { $0.name == "DB_URL" }.map(\.id))
                payload.secrets.removeAll { ids.contains($0.id) }
                payload.values.removeAll { ids.contains($0.secretID) }
            })
        }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .denied(reason: .unknownKey))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    func test_timed_answer_cannot_release_queued_requests_after_unregister() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        let prompts = CaseApprovalController(keyTap: SilentApprovalKeyTap(), schedule: { _, _ in {} })
        broker = CaseBroker(service: service, resolver: resolver, approvals: prompts, authenticator: auth,
                            now: { [unowned self] in self.clock })
        let first = Task { await self.run(project: "alpha", only: ["DB_URL"]) }
        for _ in 0..<200 where prompts.queuedCount < 1 { await Task.yield() }
        let second = Task { await self.run(project: "alpha", only: ["DB_URL"]) }
        for _ in 0..<200 where prompts.queuedCount < 2 { await Task.yield() }
        XCTAssertEqual(prompts.queuedCount, 2)
        XCTAssertNoThrow(try service.mutate { $0.apps.removeAll { $0.id == app.id } })

        prompts.resolve(.allowTimed(minutes: 15))
        let firstResponse = await first.value
        let secondResponse = await second.value

        XCTAssertEqual(firstResponse, .denied(reason: .notRegistered))
        XCTAssertEqual(secondResponse, .denied(reason: .notRegistered))
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
        XCTAssertEqual(prompts.queuedCount, 0)
    }

    func test_changed_caller_during_touch_id_gets_no_values_or_listing() async {
        let requests: [CaseBrokerRequest] = [
            .resolveRun(project: "alpha", only: ["DB_URL"], command: "npm test", cwd: "/tmp"),
            .listProjects,
            .listKeys(project: nil),
            .resolveRun(project: nil, only: ["OPENAI_API_KEY"], command: "npm test", cwd: "/tmp"),
        ]
        for request in requests {
            makeBroker(caller: .human)
            auth.onAuthenticate = { self.resolver.caller = .knownUnregisteredAI(name: "Codex") }

            let response = await broker.handle(request, peerPID: 900)

            XCTAssertEqual(response, .denied(reason: .notRegistered))
        }
    }

    func test_registration_label_change_during_approval_keeps_authorized_run() async {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        useMutatingApprovals(.allowTimed(minutes: 15)) {
            XCTAssertNoThrow(try self.service.mutate { $0.apps[0].displayName = "New label" })
        }

        let response = await run(project: "alpha", only: ["DB_URL"])

        XCTAssertEqual(response, .runEnvironment(["DB_URL": "fake-alpha-db-0002"]))
        XCTAssertTrue(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))
    }

    private func useMutatingApprovals(_ outcome: CaseApprovalOutcome, change: @escaping () throws -> Void) {
        broker = CaseBroker(service: service, resolver: resolver,
                            approvals: MutatingApprovals(outcome: outcome, change: change),
                            authenticator: auth, now: { [unowned self] in self.clock })
    }

    // MARK: Vault

    func test_vault_unavailable_when_it_cannot_load() async {
        makeBroker(caller: .registered(registration(.bypass)))
        store.loadError = CaseVaultStoreError.invalidEnvelope

        let response = await run(project: "alpha")

        XCTAssertEqual(response, .denied(reason: .vaultUnavailable))
        XCTAssertEqual(resolver.calls, 0)
    }

    func test_broker_reuses_loaded_vault_instead_of_reloading_per_request() async {
        makeBroker(caller: .registered(registration(.bypass)))

        _ = await run(project: "alpha")
        _ = await broker.handle(.listProjects, peerPID: 900)
        _ = await run(project: "beta")

        XCTAssertEqual(store.loadCount, 1)
    }

    func test_duplicate_names_are_refused_never_picked() async {
        // A vault from before the merge fix may hold two DB_URL keys in alpha.
        var payload = fixturePayload(apps: [])
        let twin = secret("DB_URL", in: alphaID)
        payload.secrets.append(twin)
        payload.values.append(CaseSecretValue(secretID: twin.id, value: "fake-alpha-db-twin-0006"))
        makeBroker(caller: .registered(registration(.bypass)), payload: payload)

        let named = await run(project: "alpha", only: ["DB_URL"])
        XCTAssertEqual(named, .denied(reason: .unknownKey))
        let whole = await run(project: "alpha")
        XCTAssertEqual(whole, .denied(reason: .unknownKey), "the environment would keep one value arbitrarily")
        let unscoped = await run(only: ["DB_URL"])
        XCTAssertEqual(unscoped, .denied(reason: .unknownKey))
        // Other keys and projects still work.
        let other = await run(project: "beta", only: ["STRIPE_KEY"])
        XCTAssertEqual(other, .runEnvironment(["STRIPE_KEY": "fake-beta-stripe-0004"]))

        // Two projects with the same exact name: neither is picked.
        var twins = fixturePayload(apps: [])
        twins.projects.append(project(UUID(), "alpha", "Second alpha"))
        makeBroker(caller: .registered(registration(.bypass)), payload: twins)
        let ambiguousProject = await run(project: "alpha", only: ["DB_URL"])
        XCTAssertEqual(ambiguousProject, .denied(reason: .unknownProject))
    }

    // MARK: Server

    private func tempSocketDir() throws -> URL {
        // sun_path is 104 bytes: keep it short.
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeServer(dir: URL, inspector: ServerInspector, readTimeout: TimeInterval = 5) -> CaseBrokerServer {
        let server = CaseBrokerServer(
            socketURL: dir.appendingPathComponent("b.sock"), broker: broker, inspector: inspector,
            helperURL: URL(fileURLWithPath: "/nonexistent/whytap"), readTimeout: readTimeout)
        addTeardownBlock { server.stop() }
        return server
    }

    private nonisolated static func call(_ socket: URL, _ request: CaseBrokerRequest) async throws -> CaseBrokerResponse {
        try await Task.detached {
            try UnixSocketBrokerClient(socketURL: socket, timeout: 10).send(request)
        }.value
    }

    func test_socket_permissions_0600_and_dir_0700() async throws {
        makeBroker(caller: .registered(registration(.bypass)))
        let dir = try tempSocketDir()
        let socketPath = dir.appendingPathComponent("b.sock").path
        // A stale socket from a crashed run is replaced.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in socketPath.utf8.enumerated() { raw[i] = b }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let server = makeServer(dir: dir, inspector: ServerInspector())
        try server.start()

        var info = stat()
        XCTAssertEqual(lstat(dir.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(socketPath, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let response = try await Self.call(URL(fileURLWithPath: socketPath), .resolveRun(
            project: "alpha", only: ["DB_URL"], command: "true", cwd: "/tmp"))
        XCTAssertEqual(response, .runEnvironment(["DB_URL": "fake-alpha-db-0002"]))

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func test_start_refuses_to_replace_a_regular_file() throws {
        makeBroker(caller: .registered(registration(.bypass)))
        let dir = try tempSocketDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("b.sock")
        try Data("not a socket".utf8).write(to: path)

        XCTAssertThrowsError(try makeServer(dir: dir, inspector: ServerInspector()).start()) {
            XCTAssertEqual($0 as? CaseBrokerServerError, .pathOccupied)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func test_untrusted_helper_rejected() async throws {
        makeBroker(caller: .registered(registration(.bypass)))
        let dir = try tempSocketDir()
        let inspector = ServerInspector()
        inspector.trusted = false
        let server = makeServer(dir: dir, inspector: inspector)
        try server.start()
        let socketURL = dir.appendingPathComponent("b.sock")

        // Through the real client: denied, broker never consulted.
        let response = try await Self.call(socketURL, .resolveRun(
            project: "alpha", only: nil, command: "true", cwd: "/tmp"))
        XCTAssertEqual(response, .denied(reason: .untrustedHelper))
        XCTAssertEqual(resolver.calls, 0)

        let controls = try await Self.call(socketURL, .appControl(AppControlRequest("get_state")))
        XCTAssertEqual(controls, .denied(reason: .untrustedHelper))
        XCTAssertEqual(store.loadCount, 0, "untrusted app controls must never reach the broker")

        // A peer that sends nothing still gets the answer at once: the
        // request body is never read for an untrusted peer.
        let started = Date()
        let raw = try await Task.detached { try Self.rawExchange(socketURL, send: nil) }.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(try CaseBrokerCodec.decodeLine(CaseBrokerResponse.self, from: raw),
                       .denied(reason: .untrustedHelper))
    }

    func test_stuck_and_oversized_clients_are_dropped_and_server_keeps_serving() async throws {
        makeBroker(caller: .registered(registration(.bypass)))
        let dir = try tempSocketDir()
        let server = makeServer(dir: dir, inspector: ServerInspector(), readTimeout: 0.5)
        try server.start()
        let socketURL = dir.appendingPathComponent("b.sock")

        // Sends nothing: closed after the read timeout with no answer.
        let started = Date()
        let silent = try await Task.detached { try Self.rawExchange(socketURL, send: nil) }.value
        XCTAssertTrue(silent.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        // Over the 64 KB limit without a newline: closed with no answer.
        let big = Data(repeating: 0x41, count: 70 * 1024)
        let oversized = try await Task.detached { try Self.rawExchange(socketURL, send: big) }.value
        XCTAssertTrue(oversized.isEmpty)

        // Garbage line: closed with no answer.
        let garbage = try await Task.detached { try Self.rawExchange(socketURL, send: Data("{nope}\n".utf8)) }.value
        XCTAssertTrue(garbage.isEmpty)
        XCTAssertEqual(resolver.calls, 0)

        let response = try await Self.call(socketURL, .listProjects)
        guard case .projects = response else { return XCTFail("server stopped serving") }
    }

    func test_client_that_hangs_up_while_prompt_is_up_gets_nothing_and_prompt_is_withdrawn() async throws {
        let app = registration(.approve)
        makeBroker(caller: .registered(app))
        let prompts = CaseApprovalController(keyTap: SilentApprovalKeyTap(), schedule: { _, _ in {} })
        broker = CaseBroker(service: service, resolver: resolver, approvals: prompts, authenticator: auth,
                            now: { [unowned self] in self.clock })
        let dir = try tempSocketDir()
        let server = makeServer(dir: dir, inspector: ServerInspector())
        try server.start()
        let socketURL = dir.appendingPathComponent("b.sock")

        let line = try CaseBrokerCodec.encodeLine(CaseBrokerRequest.resolveRun(
            project: "alpha", only: ["DB_URL"], command: "true", cwd: "/tmp"))
        let fd = try await Task.detached { try Self.connectAndSend(socketURL, line) }.value

        for _ in 0..<500 where prompts.current == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(prompts.current?.keyNames, ["DB_URL"], "the prompt is up")

        close(fd) // the CLI was killed (Ctrl-C) while waiting
        for _ in 0..<500 where prompts.current != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(prompts.current, "an abandoned request is never left on screen to be granted")
        XCTAssertEqual(prompts.queuedCount, 0)
        XCTAssertFalse(broker.grants.isGranted(appID: app.id, projectID: alphaID, now: clock))

        // The server keeps serving the next client.
        let next = Task { await self.broker.handle(.listProjects, peerPID: 900) }
        guard case .projects = await next.value else { return XCTFail("broker stopped answering") }
    }

    /// Connects and writes `payload`, leaving the socket open for the caller.
    private nonisolated static func connectAndSend(_ socketURL: URL, _ payload: Data) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in socketURL.path.utf8.enumerated() { raw[i] = b }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            throw CaseBrokerClientError.unavailable
        }
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress!, payload.count) }
        return fd
    }

    /// Connects, optionally writes `send`, half-closes nothing, reads until EOF (max 5 s).
    private nonisolated static func rawExchange(_ socketURL: URL, send payload: Data?) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in socketURL.path.utf8.enumerated() { raw[i] = b }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw CaseBrokerClientError.unavailable }
        if let payload {
            payload.withUnsafeBytes { raw in
                var sent = 0
                while sent < payload.count {
                    let n = write(fd, raw.baseAddress! + sent, payload.count - sent)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }
}

/// A key tap that never sees a key: the real prompt controller without Accessibility.
@MainActor
private final class SilentApprovalKeyTap: CaseApprovalKeyIntercepting {
    func start(onKey: @escaping @MainActor (CaseApprovalKey) -> Void,
               onUnarmedKeyDown: @escaping @MainActor () -> Void) throws {}
    func stop() {}
    func setArmed(_ armed: Bool) {}
}

@MainActor
private final class MutatingApprovals: CaseApprovalPresenting {
    let outcome: CaseApprovalOutcome
    let change: () throws -> Void

    init(outcome: CaseApprovalOutcome, change: @escaping () throws -> Void) {
        self.outcome = outcome
        self.change = change
    }

    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome {
        do { try change() } catch {
            XCTFail("fixture mutation failed: \(error)")
            return .deny
        }
        return outcome
    }
}

/// Deletes a key while the approval prompt is showing, then allows.
@MainActor
private final class DeletingApprovals: CaseApprovalPresenting {
    let service: CaseVaultService
    let keyName: String
    init(service: CaseVaultService, keyName: String) {
        self.service = service
        self.keyName = keyName
    }
    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome {
        try? service.mutate { payload in
            let ids = Set(payload.secrets.filter { $0.name == keyName && $0.projectID == alphaID }.map(\.id))
            payload.secrets.removeAll { ids.contains($0.id) }
            payload.values.removeAll { ids.contains($0.secretID) }
        }
        return .allow
    }
}
