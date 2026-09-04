import XCTest
@testable import Sidekey

/// pivot-2: AgentController submits to the local CLIProvider instead of a backend.
/// Privacy preferences (outputLanguage) are no longer forwarded in a request
/// payload — the CLI manages its own context via --resume.
///
/// This suite verifies that submitting a query calls the CLIProvider regardless of
/// privacy pref state, and that the PrivacyPreferences object doesn't crash the controller.
@MainActor
final class AgentControllerPrivacyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var prefs: PrivacyPreferences!

    override func setUp() {
        super.setUp()
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle
        suiteName = "test.sidekey.agent.privacy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        prefs = PrivacyPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        prefs = nil
        suiteName = nil
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle
        super.tearDown()
    }

    func test_submit_query_calls_provider_with_default_prefs() async throws {
        let provider = ManualCLIProviderPrivacy()
        let controller = makeController(provider: provider)
        let snapshot = makeSnapshot()

        controller.submitTextQuery("hi", snapshot: snapshot)
        await waitUntil { provider.calls.count == 1 }

        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertTrue(provider.calls.first?.prompt.contains("hi") == true)
    }

    func test_submit_query_calls_provider_with_output_language_set() async throws {
        prefs.selectedLanguage = AppLanguage.find(code: "ru")

        let provider = ManualCLIProviderPrivacy()
        let controller = makeController(provider: provider)
        let snapshot = makeSnapshot()

        controller.submitTextQuery("привет", snapshot: snapshot)
        await waitUntil { provider.calls.count == 1 }

        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertTrue(provider.calls.first?.prompt.contains("привет") == true)
    }

    func test_two_submits_both_call_provider() async throws {
        let provider = ManualCLIProviderPrivacy()
        let controller = makeController(provider: provider)
        let snapshot = makeSnapshot()

        // First submit.
        controller.submitTextQuery("first", snapshot: snapshot)
        await waitUntil { provider.calls.count == 1 }

        // Second submit while first is still in-flight — beginSubmit cancels the
        // prior consumeTask and starts a new one via the same provider.
        controller.submitTextQuery("second", snapshot: snapshot)
        await waitUntil { provider.calls.count == 2 }

        XCTAssertEqual(provider.calls.count, 2)
        XCTAssertTrue(provider.calls[0].prompt.contains("first") == true)
        XCTAssertTrue(provider.calls[1].prompt.contains("second") == true)
    }

    // MARK: - Helpers

    private func makeController(provider: ManualCLIProviderPrivacy) -> AgentController {
        AgentController(
            gestureMonitor: NoopGestureMonitor(),
            snapshotProvider: { nil },
            resolveProvider: { provider },
            privacyPreferences: prefs,
            agentEnabled: { true }
        )
    }

    private func makeSnapshot() -> FocusSnapshot {
        FocusSnapshot(
            targetPID: 1,
            bundleID: "com.example.A",
            appName: "A",
            selectionText: nil,
            isEditable: false,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not met", file: file, line: line)
    }
}

// MARK: - Mocks (private)

private final class ManualCLIProviderPrivacy: CLIProvider {
    let id: CLIProviderID = .claude
    let displayName = "Manual Claude"
    let installURL = URL(string: "https://example.com")!
    let lastSessionID: String? = nil
    private(set) var calls: [(prompt: String, resumeSessionID: String?)] = []
    private(set) var continuations: [AsyncStream<AgentSSEEvent>.Continuation] = []

    func discoverBinary() -> URL? { URL(fileURLWithPath: "/mock/claude") }
    func probe() async -> ConnectOutcome { .connected(sessionID: nil) }
    func respondToPermission(requestId: String, decision: PermissionDecision) {}

    func run(prompt: String, resumeSessionID: String?, options: AgentRunOptions) -> AsyncStream<AgentSSEEvent> {
        calls.append((prompt, resumeSessionID))
        return AsyncStream { [weak self] continuation in
            self?.continuations.append(continuation)
        }
    }
}

private final class NoopGestureMonitor: RightCmdGestureMonitoring {
    func start(
        onSnapshot: @escaping RightCmdGestureMonitor.SnapshotCallback,
        onTap: @escaping RightCmdGestureMonitor.Callback,
        onHoldStart: @escaping RightCmdGestureMonitor.Callback,
        onHoldEnd: @escaping RightCmdGestureMonitor.Callback,
        onCancel: @escaping RightCmdGestureMonitor.Callback
    ) {}
    func stop() {}
}
