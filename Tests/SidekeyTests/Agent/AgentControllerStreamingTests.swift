import Combine
import XCTest
@testable import Sidekey

/// Task 3: streaming voice deps + hold-start branch.
///
/// The streaming path is gated by `streamingVoiceEnabled: true` on the
/// controller (injected in tests; production wires `AgentFeatureGate.streamingVoiceEnabled`).
/// When the gate is on, `handleHoldStart` spawns a `realtimeRunTask` that calls
/// `agentVoiceStreamFactory()` and awaits `session.run()` — it does NOT fall
/// through to the legacy `voiceSessionFactory` path.
@MainActor
final class AgentControllerStreamingTests: XCTestCase {

    /// Fakes whose `run()` may still be suspended on their continuation when
    /// the test ends. `tearDown` resolves them via `cancel()` so the runtime
    /// does not flag a CheckedContinuation misuse (leaked continuation).
    private var liveFakes: [FakeRealtimeVoiceSession] = []

    private func makeFake() -> FakeRealtimeVoiceSession {
        let fake = FakeRealtimeVoiceSession()
        liveFakes.append(fake)
        return fake
    }

    override func setUp() {
        super.setUp()
        resetSharedAppState()
    }

    override func tearDown() async throws {
        for fake in liveFakes {
            await fake.cancel()
        }
        liveFakes = []
        resetSharedAppState()
    }

    // MARK: - Streaming path: hold-start enters voiceRecording state

    func testHoldStartStartsStreamingSessionWhenEnabled() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        let store = AskResponseStore()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { controller.state == .voiceRecording }

        XCTAssertEqual(controller.state, .voiceRecording)
        XCTAssertEqual(AppState.shared.agentPhase, .voiceRecording)
        XCTAssertEqual(store.status, .recording)
    }

    // MARK: - Streaming path does NOT fall through to legacy voiceSessionFactory

    func testHoldStartStreamingPathSkipsLegacyVoiceSession() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        var legacyStartCalled = false
        let legacySession = MockLegacyVoiceSessionForStreaming(onStart: { legacyStartCalled = true })
        let store = AskResponseStore()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            voiceSessionFactory: { legacySession },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { controller.state == .voiceRecording }

        XCTAssertFalse(legacyStartCalled, "streaming path must not start the legacy voice session")
    }

    // MARK: - Legacy path still works when streaming is disabled

    func testHoldStartUsesLegacyPathWhenStreamingDisabled() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        var legacyStartCalled = false
        let legacySession = MockLegacyVoiceSessionForStreaming(onStart: { legacyStartCalled = true })
        let store = AskResponseStore()

        // streamingVoiceEnabled defaults to false — no agentVoiceStreamFactory needed
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            voiceSessionFactory: { legacySession },
            responseStore: store,
            agentEnabled: { true }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { legacyStartCalled }

        XCTAssertTrue(legacyStartCalled, "legacy path must start the old voice session when streaming is off")
        XCTAssertEqual(controller.state, .voiceRecording)
    }

    // MARK: - Hold-end: streaming path dispatches transcript to agent

    func testHoldEndStreamingDispatchesTranscriptToAgent() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        fake.resultToReturn = .transcript("what is voyage pricing")
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        // Wait until the run task suspends (session stored on controller).
        await waitUntil { fake.runCalled }

        // Release: stop() resolves run() → handleStreamResult fires.
        monitor.onHoldEnd?()
        await waitUntil { agentClient.calls.count == 1 }

        XCTAssertTrue(fake.stopped)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("what is voyage pricing") == true)
        // Voice goes through STT → text → CLIProvider. No separate audio path.
        XCTAssertEqual(controller.state, .executing)
        XCTAssertEqual(AppState.shared.agentPhase, .executing)
    }

    func testHoldEndStreamingEmptyTranscriptSkipsDispatch() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        fake.resultToReturn = .transcript("   ")
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { fake.runCalled }

        monitor.onHoldEnd?()
        // closeVoiceWithoutSubmit() sets .idle synchronously once the empty
        // transcript is handled — deterministic signal that the streaming
        // result has been processed without dispatching.
        await waitUntil { controller.state == .idle }

        XCTAssertTrue(fake.stopped)
        XCTAssertTrue(agentClient.calls.isEmpty, "empty transcript must not dispatch to agent")
        XCTAssertTrue(agentClient.calls.isEmpty /* audio path removed in pivot-2 */)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    // MARK: - Orphan-mic race: cancel / hold-end while the factory is in-flight

    /// The factory (JWT refresh) suspends; the user releases (hold-end) before
    /// it resolves. The run Task must be cancelled and, once the factory
    /// finally yields a session, that session must be cancel()'d — never
    /// run() — so no orphaned mic/WS recording starts.
    func testHoldEndDuringInFlightFactoryCancelsFreshSessionNoOrphan() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let gate = FactoryGate()
        let fake = makeFake()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: {
                // Suspend like a JWT refresh until the test releases the gate,
                // then hand back the fake session.
                await gate.wait()
                return fake
            },
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { controller.state == .voiceRecording }

        // Release while the factory is still suspended (session not yet built).
        monitor.onHoldEnd?()
        await waitUntil { controller.state == .idle }

        // Now let the factory resolve. The run Task is already cancelled, so
        // the post-factory isCancelled check must cancel the fresh session and
        // skip run().
        gate.open()
        await waitUntil { fake.cancelled }

        XCTAssertTrue(fake.cancelled, "freshly-built session must be cancelled after teardown-during-factory")
        XCTAssertFalse(fake.runCalled, "run() must not start once the run Task was cancelled")
        XCTAssertTrue(agentClient.calls.isEmpty, "no dispatch on aborted in-flight gesture")
        XCTAssertTrue(agentClient.calls.isEmpty /* audio path removed in pivot-2 */, "must not fall through to the batch audio path")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    /// `handleCancel` (Esc) while the factory is suspended must likewise close
    /// the freshly-built session once it lands.
    func testCancelDuringInFlightFactoryCancelsFreshSession() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let gate = FactoryGate()
        let fake = makeFake()
        let store = AskResponseStore()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: {
                await gate.wait()
                return fake
            },
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { controller.state == .voiceRecording }

        // Esc while the factory is suspended.
        monitor.onCancel?()
        await waitUntil { controller.state == .idle }

        gate.open()
        await waitUntil { fake.cancelled }

        XCTAssertTrue(fake.cancelled, "Esc-during-factory must cancel the fresh session")
        XCTAssertFalse(fake.runCalled, "run() must not start after cancel")
    }

    // MARK: - Factory returns nil → .failed surfaces error, no dispatch

    func testFactoryReturningNilSurfacesFailureNoDispatch() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            // Factory yields nil (e.g. JWT read failed) — the run Task routes
            // straight to handleStreamResult(.failed(.transportFailed)).
            agentVoiceStreamFactory: { nil },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        // The transient failure notice in the wing is the terminal signal:
        // handleHoldStart flips to .voiceRecording, then the run Task resolves
        // .failed → showTranscriptionError → island sttFailed + .idle. Waiting
        // on the `.failed` wing (not bare .idle, which matches the
        // pre-handleHoldStart initial state) is the deterministic gate.
        await waitUntil {
            if case .failed = islandFlow.wing { return true }
            return false
        }

        XCTAssertTrue(agentClient.calls.isEmpty, "nil factory must not dispatch to agent")
        XCTAssertTrue(agentClient.calls.isEmpty /* audio path removed in pivot-2 */)
        // Island surfaces the failure as a transient wing notice (the sole
        // answer surface now — the orb-era error panel is gone). No error
        // block is written to the store, so the answer panel never opens.
        guard case .failed(let message) = islandFlow.wing else {
            XCTFail("Expected a transient failure notice in the wing.")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertTrue(store.blocks.isEmpty, "STT failure must not write an answer block")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    // MARK: - Island agent-flow routing (Task 10)

    /// Voice flow drives the island flow store end-to-end: hold-start arms
    /// recording, partial transcripts surface in the wing, hold-end submits
    /// and flips the wing to `.acting` with the final query echoed.
    func testVoiceFlowDrivesIslandAgentFlowStore() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        fake.resultToReturn = .transcript("найди PR")
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { islandFlow.wing == .recording(transcript: "") }
        // Wait until the run task has wired `onTranscriptUpdate` (it does so
        // right before `run()` suspends) so the partial below is delivered.
        await waitUntil { fake.runCalled }

        // A live partial lands in the wing while the user is still speaking.
        fake.emitTranscript("найди PR")
        await waitUntil { islandFlow.wing == .recording(transcript: "найди PR") }

        // Release: stop() resolves run() → submit → wing flips to acting and
        // the submitted query is echoed for the answer panel's query row.
        monitor.onHoldEnd?()
        await waitUntil { agentClient.calls.count == 1 }
        await waitUntil { islandFlow.wing == .acting }

        XCTAssertEqual(islandFlow.queryText, "найди PR")
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("найди PR") == true)
    }

    /// Cancel during recording clears every island surface back to hidden /
    /// no answer panel.
    func testCancelClearsIslandSurfaces() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { islandFlow.wing == .recording(transcript: "") }

        monitor.onCancel?()
        await waitUntil { islandFlow.wing == .hidden }

        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertFalse(islandFlow.answerPanelVisible)
    }

    /// An STT failure after hold-end shows a transient failure notice in the
    /// wing instead of an answer panel.
    func testSttFailureShowsTransientNotice() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        fake.resultToReturn = .failed(.transportFailed)
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { fake.runCalled }

        monitor.onHoldEnd?()
        await waitUntil {
            if case .failed = islandFlow.wing { return true }
            return false
        }

        guard case .failed(let message) = islandFlow.wing else {
            XCTFail("Expected a transient failure notice in the wing.")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(agentClient.calls.isEmpty, "STT failure must not dispatch to agent")
        XCTAssertFalse(islandFlow.answerPanelVisible)
    }

    /// Text-tap flow drives the island flow store: the composing wing opens
    /// and a submitted prompt echoes into `queryText` + flips to `.acting`.
    func testTextFlowDrivesIslandAgentFlowStore() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onTap?()
        await waitUntil { islandFlow.wing == .composing }

        controller.submitIslandText("открой issue")
        await waitUntil { agentClient.calls.count == 1 }
        await waitUntil { islandFlow.wing == .acting }

        XCTAssertEqual(islandFlow.queryText, "открой issue")
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("открой issue") == true)
    }

    /// Esc (`cancelAgentFlowFromIsland`) tears the island surfaces down from
    /// the composing wing.
    func testCancelFromIslandClearsComposingWing() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onTap?()
        await waitUntil { islandFlow.wing == .composing }

        controller.cancelAgentFlowFromIsland()
        await waitUntil { islandFlow.wing == .hidden }

        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertEqual(controller.state, .idle)
    }

    /// The ⌥Q close hotkey registers when the island answer panel becomes
    /// visible (a real turn streams answer content) and tears down when the
    /// flow returns to idle. Firing it routes through the same cancel path
    /// the dismiss affordances use (state back to idle).
    func testCloseHotkeyLifecycleTracksAnswerPanelVisibility() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let fakeCloseHotkey = FakeCloseHotkey()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
            closeHotkeyFactory: { fakeCloseHotkey },
        )
        controller.start()

        // Panel hidden initially → hotkey not started.
        XCTAssertEqual(fakeCloseHotkey.startCalls, 0)

        // A real turn that streams answer text opens the answer panel.
        controller.submitTextQuery("вопрос", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(.summaryDelta(text: "partial answer"))
        await waitUntil { islandFlow.answerPanelVisible }
        await waitUntil { fakeCloseHotkey.startCalls == 1 }

        // Firing ⌥Q funnels through cancel → idle, which tears the hotkey down.
        fakeCloseHotkey.fire()
        await waitUntil { controller.state == .idle }
        await waitUntil { !islandFlow.answerPanelVisible }
        await waitUntil { fakeCloseHotkey.stopCalls >= 1 }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertGreaterThanOrEqual(fakeCloseHotkey.stopCalls, 1)
    }

    /// Guaranteed-Esc close: the bare-Escape close monitor comes online once
    /// the answer panel is visible (a streamed answer), and tears down again
    /// when the panel closes — the same show/close lifecycle as ⌥Q, keyed off
    /// `answerPanelVisible`.
    func testEscapeCloseHotkeyRegistersWhileAnswerPanelVisible() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let fakeEscape = FakeCloseHotkey()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
            escapeCloseHotkeyFactory: { fakeEscape }
        )
        controller.start()

        // Idle initially → Escape hotkey not started.
        XCTAssertEqual(fakeEscape.startCalls, 0)

        // A streamed answer opens the panel → Escape registers.
        controller.submitTextQuery("вопрос", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(.summaryDelta(text: "partial answer"))
        await waitUntil { islandFlow.answerPanelVisible }
        await waitUntil { fakeEscape.startCalls == 1 }

        // Firing Esc funnels through cancel → idle, tearing the hotkey down.
        fakeEscape.fire()
        await waitUntil { controller.state == .idle }
        await waitUntil { !islandFlow.answerPanelVisible }
        await waitUntil { fakeEscape.stopCalls >= 1 }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertEqual(fakeEscape.startCalls, 1)
        XCTAssertGreaterThanOrEqual(fakeEscape.stopCalls, 1)
    }

    /// Regression guard for "Escape doesn't close the visible answer": whytap
    /// is an accessory app and the island answer panel is non-activating, so
    /// the app is virtually NEVER frontmost while the user reads an answer.
    /// The Escape-close monitor must therefore register purely off
    /// `answerPanelVisible` — no app-active gating. (Safe because the monitor
    /// is passive — it observes Escape without stealing it, so holding it
    /// while the user works elsewhere can no longer break Escape in other
    /// apps, which is what the removed frontmost gate existed to prevent.)
    /// WHY: docs/decisions/2026-07-02-escape-close-passive-monitor.md
    func testEscapeCloseHotkeyRegistersWhileAnswerPanelVisibleEvenWhenAppNotFrontmost() async throws {
        // Force the shared NSApplication to exist so the controller's default
        // app-active source reads a real, INACTIVE app — the production shape
        // of the bug (accessory app, non-activating panel, never frontmost).
        // Without this, NSApp is nil in an isolated runner and the source
        // falls back to `true`, hiding the accessory-app case. Skip
        // defensively if some other test left the app activated.
        _ = NSApplication.shared
        try XCTSkipIf(NSApplication.shared.isActive, "requires a non-frontmost app to reproduce the accessory-app shape")

        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let fakeEscape = FakeCloseHotkey()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
            escapeCloseHotkeyFactory: { fakeEscape }
        )
        controller.start()

        // An answer streams in while the app is NOT frontmost (the normal
        // voice-agent case: the user invoked the agent from another app).
        controller.submitTextQuery("вопрос", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(.summaryDelta(text: "partial answer"))
        await waitUntil { islandFlow.answerPanelVisible }

        // The Escape-close monitor must come online anyway.
        await waitUntil { fakeEscape.startCalls == 1 }
        XCTAssertEqual(fakeEscape.startCalls, 1, "Escape close must register while the answer is visible even though whytap is not frontmost")
        XCTAssertEqual(fakeEscape.stopCalls, 0, "monitor stays registered for the whole answer lifetime")

        // Esc fires → same cancel path as ✕/⌥Q → panel closes → teardown.
        fakeEscape.fire()
        await waitUntil { controller.state == .idle }
        await waitUntil { !islandFlow.answerPanelVisible }
        await waitUntil { fakeEscape.stopCalls >= 1 }
    }

    /// The Escape close monitor must stay off while only the acting slot is
    /// on screen (`wing == .acting`). A dispatched turn has no answer body
    /// yet — there is nothing for Escape to close, and observing Escape
    /// during the execution window would double-handle the key next to the
    /// gesture's own cancel path.
    func testEscapeCloseHotkeyStaysOffWhileOnlyActingSlotVisible() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let fake = makeFake()
        fake.resultToReturn = .transcript("найди PR")
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let fakeEscape = FakeCloseHotkey()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            streamingVoiceEnabled: true,
            agentVoiceStreamFactory: { fake },
            islandAgentFlow: islandFlow,
            escapeCloseHotkeyFactory: { fakeEscape }
        )
        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { islandFlow.wing == .recording(transcript: "") }
        await waitUntil { fake.runCalled }
        // Recording phase keeps Escape in the R-Cmd gesture's own cancel
        // path — the global Escape hotkey must NOT be registered here.
        XCTAssertEqual(fakeEscape.startCalls, 0, "recording wing must not register the Escape hotkey")

        // Release → submit → wing flips to `.acting` (no answer content yet).
        monitor.onHoldEnd?()
        await waitUntil { agentClient.calls.count == 1 }
        await waitUntil { islandFlow.wing == .acting }

        XCTAssertEqual(islandFlow.wing, .acting)
        XCTAssertFalse(islandFlow.answerPanelVisible, "acting precedes any answer body")
        XCTAssertEqual(fakeEscape.startCalls, 0, "the acting slot alone must not register the Escape hotkey")
    }

    /// The Escape close monitor stays OFF in the composing phase: the text
    /// field is the key window and owns Escape via `.onExitCommand`, so
    /// observing Escape there would double-handle the key next to the
    /// field's own cancel. A second tap returns to idle, which must also
    /// leave it off.
    func testEscapeCloseHotkeyStaysOffWhileComposingAndIdle() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let fakeEscape = FakeCloseHotkey()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
            escapeCloseHotkeyFactory: { fakeEscape }
        )
        controller.start()
        XCTAssertEqual(fakeEscape.startCalls, 0)

        // Tap → composing wing. Escape stays with the key-window text field.
        monitor.onTap?()
        await waitUntil { islandFlow.wing == .composing }
        XCTAssertEqual(fakeEscape.startCalls, 0, "composing wing must not register the Escape hotkey")

        // Second tap toggles back to idle — still off.
        monitor.onTap?()
        await waitUntil { controller.state == .idle }
        await waitUntil { islandFlow.wing == .hidden }
        XCTAssertEqual(fakeEscape.startCalls, 0, "idle must not register the Escape hotkey")
    }

    /// Once registered (answer panel open), the Escape hotkey is torn down
    /// when the panel closes — proving the teardown leg of the lifecycle
    /// independently of the firing path.
    func testEscapeCloseHotkeyTearsDownWhenPanelCloses() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let fakeEscape = FakeCloseHotkey()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
            escapeCloseHotkeyFactory: { fakeEscape }
        )
        controller.start()

        controller.submitTextQuery("вопрос", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(.summaryDelta(text: "partial answer"))
        await waitUntil { islandFlow.answerPanelVisible }
        await waitUntil { fakeEscape.startCalls == 1 }

        // A fresh voice gesture starts a NEW turn → the flow store closes the
        // previous answer panel (and drops out of acting/answer), tearing the
        // Escape hotkey down.
        controller.cancelAgentFlowFromIsland()
        await waitUntil { !islandFlow.answerPanelVisible }
        await waitUntil { fakeEscape.stopCalls >= 1 }

        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertGreaterThanOrEqual(fakeEscape.stopCalls, 1)
    }

    /// The useful-links hotkey family registers off the visible answer
    /// panel's links block: a streamed `useful_links` block drives the
    /// registration count, and the shared selection state mirrors its links.
    func testUsefulLinksHotkeyLifecycleTracksLinksBlock() async {
        let snapshot = makeSnapshot()
        let monitor = MockGestureMonitorForStreaming()
        let agentClient = ManualCLIProviderForStreaming()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let selection = UsefulLinksSelectionState()
        let recorder = RecordingUsefulLinksMonitor()

        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
            agentLinksSelection: selection,
            usefulLinksHotkeyFactory: {
                UsefulLinksHotkeyController(
                    configurationProvider: { HotkeyPreferences.shared.configuration },
                    monitorFactory: { _, _ in recorder.makeMonitor() }
                )
            },
        )
        controller.start()

        controller.submitTextQuery("ссылки", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        let links = [
            UsefulLink(url: URL(string: "https://a.example")!, description: "A"),
            UsefulLink(url: URL(string: "https://b.example")!, description: "B"),
        ]
        agentClient.continuations.first?.yield(
            .blockComplete(.usefulLinks(UsefulLinksBlock(links: links)))
        )
        await waitUntil { islandFlow.answerPanelVisible }
        await waitUntil { selection.links.count == 2 }
        // 2 links, link selected (open-capable) → all four monitors active
        // (Insert/Open/Next/Previous).
        await waitUntil { recorder.activeMonitorCount == 4 }

        XCTAssertEqual(selection.links.count, 2, "shared selection mirrors the rendered links")
        XCTAssertEqual(
            recorder.activeMonitorCount, 4,
            "two links register the full Insert/Open/Next/Previous family"
        )
    }

    // MARK: - Helpers

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not met.", file: file, line: line)
    }

    private func makeSnapshot() -> FocusSnapshot {
        FocusSnapshot(
            targetPID: 456,
            bundleID: "com.example.StreamingTest",
            appName: "StreamingTest",
            selectionText: "hello",
            isEditable: true,
            capturedAt: Date(timeIntervalSince1970: 42)
        )
    }

    private func resetSharedAppState() {
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle
        AppState.shared.rightCommandHeld = false
        AppState.shared.toolsExpanded = false
        AppState.shared.clearAudioLevels()
    }
}

// MARK: - Fakes

/// One-shot suspension gate. The session factory `await`s `wait()` to model a
/// JWT refresh in flight; the test calls `open()` to release it. `open()`
/// before `wait()` is safe — the next `wait()` returns immediately.
private actor FactoryGate {
    private var opened = false
    private var cont: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withCheckedContinuation { c in self.cont = c }
    }

    nonisolated func open() {
        Task { await self.resume() }
    }

    private func resume() {
        opened = true
        cont?.resume()
        cont = nil
    }
}

/// Suspends on `run()` until `stop()` or `cancel()` is called, matching the
/// real `DirectProviderStreamingSession` lifecycle. Lets tests assert the controller
/// entered `voiceRecording` while `run()` is still in-flight.
@MainActor
final class FakeRealtimeVoiceSession: AgentRealtimeVoiceSessioning {
    var resultToReturn: StreamingSessionResult = .transcript("streaming transcript")
    /// Mirrors the protocol requirement so the controller can wire its
    /// island-flow partial-transcript sink. Tests fire it via
    /// `emitTranscript(_:)` to drive the wing's live ticker.
    var onTranscriptUpdate: ((String) -> Void)?
    private(set) var runCalled = false
    private(set) var stopped = false
    private(set) var cancelled = false
    private var cont: CheckedContinuation<StreamingSessionResult, Never>?

    func run() async -> StreamingSessionResult {
        runCalled = true
        return await withCheckedContinuation { c in self.cont = c }
    }

    /// Delivers a live transcript snapshot through the wired sink, exactly
    /// as `DirectProviderStreamingSession` does as words land.
    func emitTranscript(_ text: String) {
        onTranscriptUpdate?(text)
    }

    func stop() async {
        stopped = true
        cont?.resume(returning: resultToReturn)
        cont = nil
    }

    func cancel() async {
        cancelled = true
        cont?.resume(returning: .cancelled)
        cont = nil
    }
}

private final class MockGestureMonitorForStreaming: RightCmdGestureMonitoring {
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
        self.onSnapshot = onSnapshot
        self.onTap = onTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
        self.onCancel = onCancel
    }

    func stop() {}
}

@MainActor
private final class MockLegacyVoiceSessionForStreaming: AgentVoiceSessioning {
    var elapsedSeconds: Double = 2.0
    var peakEnergy: Float = 0.5
    var onAutoStop: (() -> Void)?
    private let onStartCallback: () -> Void

    init(onStart: @escaping () -> Void) {
        self.onStartCallback = onStart
    }

    func start() {
        onStartCallback()
    }

    func stop() async -> Data? { nil }
    func cancel() {}
}

/// Records CLIProvider run() calls for streaming-path tests.
private final class ManualCLIProviderForStreaming: CLIProvider {
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

/// Fake ⌥Q close hotkey: records start/stop and lets the test fire the
/// wired handler, standing in for the real shortcut adapter without touching
/// the kernel hotkey table.
@MainActor
private final class FakeCloseHotkey: AgentResponseCloseHotkeyControlling {
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private var onHotkey: (() -> Void)?

    func setOnHotkey(_ handler: @escaping () -> Void) {
        onHotkey = handler
    }

    func start() throws {
        startCalls += 1
    }

    func stop() {
        stopCalls += 1
    }

    func fire() {
        onHotkey?()
    }
}

/// Records how many useful-links monitors a `UsefulLinksHotkeyController`
/// registered via its `monitorFactory`, so the test can assert the
/// link-count → registration mapping without real Carbon hotkeys.
@MainActor
private final class RecordingUsefulLinksMonitor {
    /// Net active monitors (start +1, stop -1). The controller now
    /// re-registers the whole family whenever the selection moves or prefs
    /// change — each cycle stops the prior monitors and starts a fresh set — so
    /// a cumulative start count would balloon. The *active* count is the
    /// invariant the test cares about: how many monitors are live right now.
    private(set) var activeMonitorCount = 0

    func makeMonitor() -> UsefulLinksHotkeyControlling {
        StubMonitor(owner: self)
    }

    private final class StubMonitor: UsefulLinksHotkeyControlling {
        private weak var owner: RecordingUsefulLinksMonitor?
        private var started = false
        init(owner: RecordingUsefulLinksMonitor) { self.owner = owner }
        func setOnHotkey(_ handler: @escaping () -> Void) {}
        func start() throws {
            guard !started else { return }
            started = true
            owner?.activeMonitorCount += 1
        }
        func stop() {
            guard started else { return }
            started = false
            owner?.activeMonitorCount -= 1
        }
    }
}
