import Combine
import XCTest
@testable import Sidekey

/// Stage 4a: AgentController is migrated off the per-turn ivars
/// (`pendingHistoryQuery` / `pendingHistoryMode` / `pendingToolNames` /
/// `historyEntryWritten`) and the `finalizeHistoryEntry()` method onto
/// `ChatStackStore.startChat / updateTitle / recordTool / finalizeChat /
/// markChatError`. It also pulls the last 15 done turns from the chat
/// store and forwards them in the `history` field of `AgentRequest.Text`.
///
/// These tests exercise that migration end-to-end with a real
/// `ChatStackStore` backed by a temp on-disk SQLite — same harness used by
/// `ChatStackStoreTests` in Stage 3.
@MainActor
final class AgentControllerHistoryTests: XCTestCase {
    private var tempPaths: [URL] = []

    override func setUp() {
        super.setUp()
        resetSharedAppState()
    }

    override func tearDownWithError() throws {
        resetSharedAppState()
        for url in tempPaths {
            try? FileManager.default.removeItem(at: url)
        }
        tempPaths = []
        try super.tearDownWithError()
    }

    // MARK: - startChat

    func test_submit_text_query_calls_chat_stack_start_chat() async throws {
        let (chatStore, history, _) = try makeChatStore()
        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProviderHistory()
        let controller = makeController(
            snapshot: snapshot,
            agentClient: agentClient,
            chatStackStore: chatStore
        )

        controller.submitTextQuery("foo", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        XCTAssertEqual(chatStore.rows.count, 1)
        let row = try XCTUnwrap(chatStore.rows.first)
        XCTAssertEqual(row.queryText, "foo")
        XCTAssertEqual(row.queryMode, .text)
        XCTAssertEqual(row.status, .pending)
        // SQLite write went through — same row visible via the legacy reader.
        let raw = try history.latestAgentEntries(limit: 1)
        XCTAssertEqual(raw.first?.queryText, "foo")
    }

    // MARK: - history payload

    func test_submit_text_query_with_chat_history_calls_provider_once() async throws {
        // pivot-2: history forwarding in AgentRequest.Text is deleted.
        // The CLI uses --resume for session continuity. This test verifies
        // that submitting a query with prior chat history still calls the
        // provider (the history management is now internal to the CLI).
        var seconds: TimeInterval = 0
        let clock: () -> Date = {
            seconds += 1
            return Date(timeIntervalSince1970: seconds)
        }
        let (chatStore, _, _) = try makeChatStore(clock: clock)

        seedDoneChat(chatStore, query: "q1", markdown: "a1")
        seedDoneChat(chatStore, query: "q2", markdown: "a2")

        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProviderHistory()
        let controller = makeController(
            snapshot: snapshot,
            agentClient: agentClient,
            chatStackStore: chatStore
        )

        controller.submitTextQuery("q3", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        XCTAssertEqual(agentClient.calls.count, 1)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("q3") == true)
    }

    func test_voice_submit_uses_voice_mode_in_start_chat() async throws {
        let (chatStore, _, _) = try makeChatStore()
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitorHistory()
        let agentClient = ManualCLIProviderHistory()
        let transcriber = ManualAgentTranscriberHistory()
        let voiceSession = MockAgentVoiceSessionHistory(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            chatStackStore: chatStore,
            agentEnabled: { true }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }
        transcriber.complete("spoken query")
        await waitUntil { agentClient.calls.count == 1 }

        let row = try XCTUnwrap(chatStore.rows.first)
        XCTAssertEqual(row.queryMode, .voice)
        XCTAssertEqual(row.queryText, "spoken query")
    }

    // MARK: - SSE handling

    func test_voice_transcript_event_from_cli_updates_row_query_text() async throws {
        // pivot-2: voice always goes STT → text → CLIProvider. The voiceTranscript
        // event can still arrive from the CLI if it emits one. This test verifies
        // the row is updated when it does.
        let (chatStore, history, _) = try makeChatStore()
        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProviderHistory()
        let store = AskResponseStore()
        let controller = makeController(
            snapshot: snapshot,
            agentClient: agentClient,
            chatStackStore: chatStore,
            responseStore: store
        )

        controller.submitTextQuery("placeholder", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        let transcript = "Можешь скинуть ссылку на Anthropic?"
        agentClient.continuations.first?.yield(.voiceTranscript(text: transcript))
        await waitUntil { chatStore.rows.first?.queryText == transcript }

        agentClient.continuations.first?.yield(
            .blockComplete(.textAnswer(TextAnswerBlock(body: "https://anthropic.com")))
        )
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { chatStore.rows.first?.status == .done }

        let row = try XCTUnwrap(chatStore.rows.first)
        XCTAssertEqual(row.queryText, transcript)
        XCTAssertEqual(try history.latestAgentEntries(limit: 1).first?.queryText, transcript)
    }

    func test_done_event_calls_finalize_chat_with_blocks_and_markdown() async throws {
        let (chatStore, _, _) = try makeChatStore()
        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProviderHistory()
        let store = AskResponseStore()
        let controller = makeController(
            snapshot: snapshot,
            agentClient: agentClient,
            chatStackStore: chatStore,
            responseStore: store
        )

        controller.submitTextQuery("foo", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        let block = UIBlock.textAnswer(TextAnswerBlock(body: "Hello world"))
        agentClient.continuations.first?.yield(.blockComplete(block))
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { chatStore.rows.first?.status == .done }

        let row = try XCTUnwrap(chatStore.rows.first)
        XCTAssertEqual(row.status, .done)
        XCTAssertEqual(row.responseMarkdown, "Hello world")
        let json = try XCTUnwrap(row.blocksJSON)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([UIBlock].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.kind, .textAnswer)
    }

    func test_error_event_calls_mark_chat_error() async throws {
        let (chatStore, _, _) = try makeChatStore()
        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProviderHistory()
        let controller = makeController(
            snapshot: snapshot,
            agentClient: agentClient,
            chatStackStore: chatStore
        )

        controller.submitTextQuery("foo", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        agentClient.continuations.first?.yield(
            .error(code: "provider_error", message: "boom", retryable: true)
        )
        agentClient.continuations.first?.finish()
        await waitUntil { chatStore.rows.first?.status == .error }

        let row = try XCTUnwrap(chatStore.rows.first)
        XCTAssertEqual(row.status, .error)
        XCTAssertEqual(row.responseMarkdown, "boom")
    }

    func test_record_tool_appends_to_active_row() async throws {
        let (chatStore, _, _) = try makeChatStore()
        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProviderHistory()
        let controller = makeController(
            snapshot: snapshot,
            agentClient: agentClient,
            chatStackStore: chatStore
        )

        controller.submitTextQuery("foo", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        agentClient.continuations.first?.yield(.toolExecuting(tool: "search.web", label: "Searching"))
        agentClient.continuations.first?.yield(.toolExecuting(tool: "search.web", label: "Re-emitted"))
        agentClient.continuations.first?.yield(.toolExecuting(tool: "notion.search", label: "Notion"))
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { chatStore.rows.first?.status == .done }

        let row = try XCTUnwrap(chatStore.rows.first)
        // Dedupe: search.web appears once even though tool.executing was
        // emitted twice (default label + Nano-enriched label).
        XCTAssertEqual(row.toolNames, ["search.web", "notion.search"])
    }

    // MARK: - regression

    func test_finalize_chat_row_visible_in_latest_agent_entries() async throws {
        // After migration the `latestAgentEntries` read path still works
        // via SQLiteHistoryStore — proving that the ChatStackStore-driven
        // write path keeps that surface working is the primary regression
        // target for Stage 4a (see plan Risks #6).
        let (chatStore, history, _) = try makeChatStore()
        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProviderHistory()
        let controller = makeController(
            snapshot: snapshot,
            agentClient: agentClient,
            chatStackStore: chatStore
        )

        controller.submitTextQuery("regression query", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(
            .blockComplete(.textAnswer(TextAnswerBlock(body: "regression body")))
        )
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { chatStore.rows.first?.status == .done }

        let raw = try history.latestAgentEntries(limit: 1)
        XCTAssertEqual(raw.count, 1)
        let row = try XCTUnwrap(raw.first)
        XCTAssertEqual(row.queryText, "regression query")
        XCTAssertFalse(row.responseMarkdown.isEmpty)
        XCTAssertEqual(row.responseMarkdown, "regression body")
    }

    // MARK: - Helpers

    private func makeChatStore(
        clock: @escaping () -> Date = Date.init
    ) throws -> (ChatStackStore, SQLiteHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidekey-stage4a-ctrl-history-\(UUID().uuidString).sqlite"
        )
        tempPaths.append(url)
        let history = try SQLiteHistoryStore(path: url.path)
        let store = ChatStackStore(store: history, clock: clock)
        return (store, history, url)
    }

    private func seedDoneChat(
        _ store: ChatStackStore,
        query: String,
        markdown: String
    ) {
        let id = store.startChat(queryText: query, mode: .text)
        store.finalizeChat(rowId: id, blocks: [], markdown: markdown)
    }

    private func makeController(
        snapshot: FocusSnapshot,
        agentClient: ManualCLIProviderHistory,
        chatStackStore: ChatStackStore,
        responseStore: AskResponseStore? = nil
    ) -> AgentController {
        AgentController(
            gestureMonitor: MockRightCmdGestureMonitorHistory(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: responseStore,
            chatStackStore: chatStackStore,
            agentEnabled: { true }
        )
    }

    private func makeSnapshot() -> FocusSnapshot {
        FocusSnapshot(
            targetPID: 123,
            bundleID: "com.example.Target",
            appName: "Target",
            selectionText: "selection",
            isEditable: true,
            capturedAt: Date(timeIntervalSince1970: 9)
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not met.", file: file, line: line)
    }

    private func resetSharedAppState() {
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle
        AppState.shared.rightCommandHeld = false
        AppState.shared.toolsExpanded = false
        AppState.shared.clearAudioLevels()
    }
}

// MARK: - Mocks (private to this test file)

private final class MockRightCmdGestureMonitorHistory: RightCmdGestureMonitoring {
    private(set) var startCalled = false
    private(set) var stopCalled = false
    var onSnapshot: RightCmdGestureMonitor.SnapshotCallback?
    var onTap: RightCmdGestureMonitor.Callback?
    var onHoldStart: RightCmdGestureMonitor.Callback?
    var onHoldEnd: RightCmdGestureMonitor.Callback?
    var onCancel: RightCmdGestureMonitor.Callback?

    func start(
        onSnapshot: @escaping RightCmdGestureMonitor.SnapshotCallback,
        onTap: @escaping RightCmdGestureMonitor.Callback,
        onHoldStart: @escaping RightCmdGestureMonitor.Callback,
        onHoldEnd: @escaping RightCmdGestureMonitor.Callback,
        onCancel: @escaping RightCmdGestureMonitor.Callback
    ) {
        startCalled = true
        self.onSnapshot = onSnapshot
        self.onTap = onTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
        self.onCancel = onCancel
    }

    func stop() { stopCalled = true }
}

@MainActor
private final class MockAgentVoiceSessionHistory: AgentVoiceSessioning {
    private let audio: Data?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0
    var elapsedSeconds: Double = 2.0
    /// Default well above `voiceNoiseGate` so history-flow tests stay
    /// focused on row persistence rather than incidentally exercising
    /// the silence guard.
    var peakEnergy: Float = 0.5
    var onAutoStop: (() -> Void)?

    init(audio: Data?) { self.audio = audio }
    func start() { startCalls += 1 }
    func stop() async -> Data? {
        stopCalls += 1
        return audio
    }
    func cancel() { cancelCalls += 1 }
}

private final class ManualCLIProviderHistory: CLIProvider {
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

private final class ManualAgentTranscriberHistory: AgentAudioTranscribing {
    private(set) var audioRequests: [Data] = []
    private(set) var languages: [String?] = []
    private var continuations: [CheckedContinuation<String, Error>] = []

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            audioRequests.append(audioData)
            languages.append(language)
        }
    }

    func complete(_ text: String) {
        continuations.removeFirst().resume(returning: text)
    }
}
