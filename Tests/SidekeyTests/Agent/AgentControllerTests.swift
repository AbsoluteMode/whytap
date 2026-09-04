import XCTest
@testable import Sidekey

@MainActor
final class AgentControllerTests: XCTestCase {
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

    private func makeTempChatStore(
        clock: @escaping () -> Date = Date.init
    ) throws -> (ChatStackStore, SQLiteHistoryStore) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidekey-ctrl-tests-\(UUID().uuidString).sqlite"
        )
        tempPaths.append(url)
        let sqliteStore = try SQLiteHistoryStore(path: url.path)
        let chatStore = ChatStackStore(store: sqliteStore, clock: clock)
        return (chatStore, sqliteStore)
    }

    func testTapOpensComposingWingWithCapturedSnapshot() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
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

        XCTAssertEqual(controller.state, .textInput)
        XCTAssertEqual(controller.currentSnapshot, snapshot)
        // The composing wing is the only text-input surface; no answer panel
        // opens until a turn streams content.
        XCTAssertEqual(islandFlow.wing, .composing)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertEqual(AppState.shared.agentPhase, .textInputActive)
    }

    func testSecondTapTogglesAgentPhaseBackToIdle() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            agentEnabled: { true }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onTap?()
        await waitUntil { AppState.shared.agentPhase == .textInputActive }

        monitor.onTap?()
        await waitUntil { AppState.shared.agentPhase == .idle }

        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func testSecondRightCmdTapWhileComposingClosesWingAndReturnsIdle() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
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
        XCTAssertEqual(controller.state, .textInput)

        // Second tap toggles the composing wing closed (mirrors Esc): wing
        // hidden, snapshot dropped, back to idle. Focus restore runs against
        // the captured snapshot inside handleCancel (no panel host).
        monitor.onTap?()
        await waitUntil { controller.state == .idle }

        XCTAssertEqual(islandFlow.wing, .hidden, "second tap must hide the composing wing")
        XCTAssertNil(controller.currentSnapshot)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func testThirdRightCmdTapAfterToggleReopensComposingWing() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
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

        monitor.onTap?()
        await waitUntil { controller.state == .idle }
        await waitUntil { islandFlow.wing == .hidden }

        monitor.onSnapshot?(snapshot)
        monitor.onTap?()
        await waitUntil { controller.state == .textInput }

        XCTAssertEqual(controller.state, .textInput)
        XCTAssertEqual(islandFlow.wing, .composing, "third tap must reopen the composing wing after toggle-close")
    }

    func testRightCmdHoldStartIsUnaffectedByTapTogglePath() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let voice = MockAgentVoiceSession(audio: nil)
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            voiceSessionFactory: { voice },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { controller.state == .voiceRecording }

        XCTAssertEqual(controller.state, .voiceRecording)
        // Hold-start drives the recording wing, never the composing (text)
        // wing — the two share no state.
        XCTAssertEqual(islandFlow.wing, .recording(transcript: ""), "hold-start must drive the recording wing, not composing")
        XCTAssertEqual(voice.startCalls, 1)
    }

    func testTextSubmitClosesComposingSetsExecutingAndOpensAnswerPanelOnFirstBlock() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let block = UIBlock.textAnswer(TextAnswerBlock(title: "Answer", body: "Body"))
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
        controller.submitIslandText("question")
        await waitUntil { agentClient.calls.count == 1 }

        XCTAssertEqual(AppState.shared.agentPhase, .executing)
        // Composing wing closes on submit; the acting wing takes over while
        // the turn runs and the submitted query echoes for the answer row.
        await waitUntil { islandFlow.wing == .acting }
        XCTAssertEqual(islandFlow.queryText, "question")
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("question") == true)

        agentClient.continuations.first?.yield(.blockComplete(block))
        await waitUntil { !store.blocks.isEmpty }
        // Streamed content opens the island answer panel.
        await waitUntil { islandFlow.answerPanelVisible }

        XCTAssertEqual(store.blocks, [block])
        XCTAssertTrue(islandFlow.answerPanelVisible)
        XCTAssertEqual(AppState.shared.agentPhase, .executing)

        agentClient.continuations.first?.yield(.done(sources: []))
        await waitUntil { store.status == .ready }

        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        XCTAssertEqual(controller.state, .executing)
    }

    func testFreshSessionPromptIncludesSystemPreamble() async throws {
        // No stored session id => resumeSessionID == nil => the behavioural
        // preamble is prepended on this (first) turn.
        let snapshot = makeSnapshot().withSelectionText(nil)
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            agentSessionStore: InMemoryAgentSessionStore(),
            agentEnabled: { true }
        )

        controller.submitTextQuery("что помнить?", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        let prompt = try XCTUnwrap(agentClient.calls.first?.prompt)
        XCTAssertTrue(prompt.hasPrefix("You are Whytap"), "Preamble must lead the prompt; got: \(prompt.prefix(40))")
        XCTAssertTrue(prompt.contains("AGENTS.md in your working directory is your memory"))
        XCTAssertTrue(prompt.contains("Lead with the answer in your first sentence"))
        XCTAssertTrue(prompt.contains("useful.actions"))
        XCTAssertTrue(prompt.hasSuffix("что помнить?"))
        // The old internal-mechanics wording must be gone.
        XCTAssertFalse(prompt.contains("WHYTAP_MEMORY.md"))
        XCTAssertFalse(prompt.contains("provider-specific CLI sessions"))
    }

    func testResumedSessionPromptOmitsSystemPreamble() async throws {
        // A stored session id => resumeSessionID != nil => the preamble is
        // already in the CLI's history; do NOT resend it. The prompt is just
        // the query (no selection here).
        let snapshot = makeSnapshot().withSelectionText(nil)
        let agentClient = ManualCLIProvider()
        let sessionStore = InMemoryAgentSessionStore()
        sessionStore.setSessionID("existing-claude-session", for: .claude)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            agentSessionStore: sessionStore,
            agentEnabled: { true }
        )

        controller.submitTextQuery("снова привет", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        let prompt = try XCTUnwrap(agentClient.calls.first?.prompt)
        XCTAssertFalse(prompt.contains("You are Whytap"), "Resume turns must not repeat the preamble; got: \(prompt.prefix(40))")
        XCTAssertFalse(prompt.contains("AGENTS.md in your working directory is your memory"))
        XCTAssertFalse(prompt.contains("You are Whytap"))
        XCTAssertTrue(prompt.contains("Reply in the language of the user's latest request"))
        XCTAssertTrue(prompt.hasSuffix("снова привет"))
        // The resume id is the stored one, confirming this turn is a resume.
        XCTAssertEqual(agentClient.calls.first?.resumeSessionID, "existing-claude-session")
    }

    func testResumedSessionPromptStillCarriesSelectionWithoutPreamble() async throws {
        // On resume the preamble is dropped but a fresh selection must still
        // be forwarded with the query.
        let snapshot = makeSnapshot().withSelectionText("highlighted code")
        let agentClient = ManualCLIProvider()
        let sessionStore = InMemoryAgentSessionStore()
        sessionStore.setSessionID("existing-claude-session", for: .claude)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            agentSessionStore: sessionStore,
            agentEnabled: { true }
        )

        controller.submitTextQuery("explain", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        let prompt = try XCTUnwrap(agentClient.calls.first?.prompt)
        XCTAssertFalse(prompt.contains("You are Whytap"))
        XCTAssertTrue(prompt.contains("Selected text:\nhighlighted code"))
        XCTAssertTrue(prompt.hasSuffix("explain"))
    }

    func testSystemPreambleContainsLoadBearingMarkers() {
        // Guard: a future edit must not silently drop a whole block of the
        // preamble. Pin one marker per section.
        let preamble = AgentController.systemPromptPreambleForTesting
        XCTAssertTrue(preamble.contains("You are Whytap"))
        // ANSWERING — anti-preamble rule.
        XCTAssertTrue(preamble.contains("Lead with the answer in your first sentence"))
        // TOOLS — gating on freshness.
        XCTAssertTrue(preamble.contains("Use the web only when the answer depends on recent"))
        // MEMORY — file is the agent's own memory.
        XCTAssertTrue(preamble.contains("AGENTS.md in your working directory is your memory"))
        // Actionable-suggestions contract: the useful.actions fence with all
        // three item types, plus the reinforcement that it is IN ADDITION to
        // keeping the content in the text.
        XCTAssertTrue(preamble.contains("\"useful.actions\""))
        XCTAssertTrue(preamble.contains("\"link\""))
        XCTAssertTrue(preamble.contains("\"path\""))
        XCTAssertTrue(preamble.contains("\"copy\""))
        XCTAssertTrue(preamble.contains("the fence is in addition, not instead"))
        // The old link-only contract wording must be gone.
        XCTAssertFalse(preamble.contains("When useful links would help"))
    }

    func testOversizedSelectionIsBoundedAndMarked() {
        let selection = String(repeating: "a", count: AgentController.maximumSelectionCharacters + 8_000)
        let bounded = AgentController.selectionForPrompt(selection)

        XCTAssertEqual(bounded.count, AgentController.maximumSelectionCharacters)
        XCTAssertTrue(bounded.contains(AgentController.selectionTruncationMarker))
        XCTAssertEqual(
            AgentClientError.payloadTooLarge.description,
            "Too much text was selected. Select a smaller passage and try again."
        )
    }

    func testSubmittedTurnResumesAndPersistsProviderSession() async throws {
        let snapshot = makeSnapshot()
        let sessionStore = InMemoryAgentSessionStore()
        sessionStore.setSessionID("old-claude-session", for: .claude)
        let provider = SessionRecordingCLIProvider(id: .claude, lastSessionID: "new-claude-session")
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { provider },
            agentSessionStore: sessionStore,
            agentEnabled: { true }
        )

        controller.submitTextQuery("hi", snapshot: snapshot)
        await waitUntil { provider.calls.count == 1 }
        await waitUntil { sessionStore.sessionID(for: .claude) == "new-claude-session" }

        XCTAssertEqual(provider.calls.first?.resumeSessionID, "old-claude-session")
    }

    func testSubmitWithNoConnectedProviderShowsNotConnectedAndDoesNotRun() async {
        // Full Disconnect -> AgentProviderStore.activeProvider == nil -> the
        // production resolveProvider yields nil. The agent must refuse the turn
        // with a "connect first" message instead of silently running a CLI.
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { nil },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.submitTextQuery("привет", snapshot: snapshot)
        await waitUntil {
            if case .failed = islandFlow.wing { return true }
            return false
        }

        let hasNotConnected = store.blocks.contains {
            if case .stateError(let b) = $0 { return b.code == "not_connected" }
            return false
        }
        XCTAssertTrue(hasNotConnected, "expected a not-connected message; blocks: \(store.blocks)")
        XCTAssertEqual(controller.state, .idle)
        // The "connect first" prompt surfaces as a transient wing notice — the
        // turn never dispatched, so no answer panel opens.
        guard case .failed = islandFlow.wing else {
            XCTFail("Expected a transient failure notice in the wing.")
            return
        }
        XCTAssertFalse(islandFlow.answerPanelVisible)
    }

    func testGoogleSourceTextSubmitRoutesToGoogleClosureNotAgent() async {
        // Regression (Task 8 spec review): a composer Return while the island
        // flow's `activeSourceIsGoogle` is set must route the text to the
        // injected Google closure and NEVER dispatch the agent CLI — even
        // though a captured snapshot is present (the agent path would run
        // otherwise). Guards the `handleTextSubmit` google branch.
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let provider = MockCLIProvider(events: [])
        let monitor = MockRightCmdGestureMonitor()
        var googleSubmittedText: String?
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { provider },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        var googleCallbacks = AgentController.GoogleCallbacks()
        googleCallbacks.onTextSubmit = { text in googleSubmittedText = text }
        controller.start(googleCallbacks: googleCallbacks)

        // Make a captured snapshot present (the agent path's only gate) so the
        // test proves the Google branch wins even when the agent path COULD
        // run, not just because the snapshot was nil.
        monitor.onSnapshot?(snapshot)
        await waitUntil { controller.currentSnapshot == snapshot }

        // Flow is in Google mode — exactly the state after `onTextTap` opened
        // the Google composer.
        controller.startGoogleTextInputUI()
        islandFlow.setActiveSourceIsGoogle(true)
        XCTAssertTrue(islandFlow.activeSourceIsGoogle, "precondition: Google flag set")

        controller.submitIslandText("кофейни рядом")

        // The Google closure received the text; the agent CLI was never run.
        XCTAssertEqual(googleSubmittedText, "кофейни рядом")
        XCTAssertTrue(provider.calls.isEmpty, "agent CLI must not run for a Google submit")
    }

    func testNewTextSubmitClearsPriorResponseBlocksAndStreamingText() async {
        // When the user initiates a NEW request the prior answer must be
        // visually gone. Text submit doesn't tear the surface down (no
        // flicker — Pill 1's "Thinking" placeholder takes over) but the
        // store must reset so the old blocks / streamingText don't bleed
        // through to the new turn.
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true }
        )

        // First turn — produce a textAnswer block so the store carries
        // visible content into the second submit.
        controller.submitTextQuery("first", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(
            .blockComplete(.textAnswer(TextAnswerBlock(body: "First answer")))
        )
        await waitUntil { !store.blocks.isEmpty }
        XCTAssertFalse(store.blocks.isEmpty)

        // Second turn — submit must reset the store BEFORE the new
        // stream starts piping blocks in. Capture the store state right
        // after the synchronous submit call.
        controller.submitTextQuery("second", snapshot: snapshot)

        XCTAssertTrue(store.blocks.isEmpty)
        XCTAssertEqual(store.streamingText, "")
        XCTAssertFalse(store.streamCompleted)
        XCTAssertNil(store.errorCode)
    }

    func testVoiceHoldStartClearsAnswerPanelFromPriorTurn() async {
        // A new R-Cmd hold begins a fresh request. The visible answer panel
        // from the previous turn must be torn down before the recording
        // surface takes over, even when that prior turn is still in flight
        // (no `done`, so the cycle never passed through idle). The flow store
        // clears `answerPanelVisible` on the fresh `.voiceRecording` phase.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        // Prior turn produces a response and opens the answer panel.
        controller.start()
        monitor.onSnapshot?(snapshot)
        controller.submitTextQuery("first", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(
            .blockComplete(.textAnswer(TextAnswerBlock(body: "First answer")))
        )
        await waitUntil { !store.blocks.isEmpty }
        await waitUntil { islandFlow.answerPanelVisible }

        // New voice request starts: prior answer panel closes, recording wing
        // takes over, store reset.
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        await waitUntil { islandFlow.wing == .recording(transcript: "") }

        XCTAssertFalse(islandFlow.answerPanelVisible, "voice hold-start must close the previous answer panel")
        XCTAssertEqual(islandFlow.wing, .recording(transcript: ""))
        XCTAssertTrue(store.blocks.isEmpty, "voice hold-start must reset the response store")
        XCTAssertEqual(store.streamingText, "")
    }

    func testResponseDismissResetsStoreAndReturnsIdle() async {
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.submitTextQuery("question", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(.blockComplete(.textAnswer(TextAnswerBlock(body: "Body"))))
        await waitUntil { islandFlow.answerPanelVisible }

        // The island answer panel's dismiss affordance routes through the same
        // cancel path as ⌥Q / Esc.
        controller.cancelAgentFlowFromIsland()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentSnapshot)
        XCTAssertTrue(store.blocks.isEmpty)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func testHoldStartBeginsVoiceSessionWithoutInputOrAnswerSurfaces() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }

        XCTAssertEqual(controller.state, .voiceRecording)
        XCTAssertEqual(store.status, .recording)
        XCTAssertEqual(AppState.shared.agentPhase, .voiceRecording)
        // Recording wing only — no composing wing, no answer panel.
        XCTAssertEqual(islandFlow.wing, .recording(transcript: ""))
        XCTAssertFalse(islandFlow.answerPanelVisible)
    }

    func testGoogleHoldStartShowsRecordingOrbWithGooglePalette() async {
        // Parity with the agent voice hold-start above: the Google voice
        // gesture (R-Option hold) must bring the recording orb on screen the
        // same way the agent path does. The orb appears because the recording
        // surface re-renders off the response store's `.recording` local
        // status (the same signal the agent test asserts) and `agentPhase ==
        // .voiceRecording`; the Google palette additionally needs
        // `activeSourceIsGoogle` to survive so the orb resolves to .googleVoice
        // rather than the agent pink-violet. Reproduces the production
        // `AppDelegate.makeGoogleCallbacks().onHoldStart` sequence exactly:
        // `startGoogleRecordingUI()` then `setActiveSourceIsGoogle(true)`.
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { nil },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        // Exact onHoldStart order from makeGoogleCallbacks(): phase change
        // first, Google flag after (so recompute()'s `.voiceRecording` branch
        // can't clear it before the caller sets it).
        controller.startGoogleRecordingUI()
        islandFlow.setActiveSourceIsGoogle(true)

        // Drain the response store's async sink (it delivers on the main queue
        // via DispatchQueue.main). A later recompute from that sink must NOT
        // clear the Google flag that the caller just set.
        await waitUntil { islandFlow.wing == .recording(transcript: "") }

        // Orb-appearance signals — mirror the agent voice hold-start test.
        XCTAssertEqual(controller.state, .voiceRecording)
        XCTAssertEqual(store.status, .recording,
            "Google hold-start must mark the response store .recording so the orb re-renders into the recording state")
        XCTAssertEqual(AppState.shared.agentPhase, .voiceRecording)
        XCTAssertEqual(islandFlow.wing, .recording(transcript: ""))

        // Google palette survives the async sink so the orb is .googleVoice.
        XCTAssertTrue(islandFlow.activeSourceIsGoogle,
            "Google flag must survive the response-store sink's recompute")
        let mode = IslandState.listening.orbMode(
            phase: AppState.shared.phase,
            agentPhase: AppState.shared.agentPhase,
            activeSourceIsGoogle: islandFlow.activeSourceIsGoogle
        )
        XCTAssertEqual(mode, .googleVoice,
            "Google voice recording must resolve to the .googleVoice orb")
    }

    func testGoogleEndReturnsControllerStateToIdle() async {
        // `startGoogleRecordingUI()` now drives the state machine to
        // `.voiceRecording` (parity with the agent voice hold-start). The
        // Google teardown (`endGoogleUI`, fired on hold-end / cancel) must
        // return `state` to `.idle` so it does not leak: a stale
        // `.voiceRecording` would route the NEXT agent voice tap through
        // `agentVoiceTapRoute` to `.stopVoiceCapture` (toggle-stop) instead of
        // `.startVoiceCapture`, swallowing the user's first agent voice tap.
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { nil },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.startGoogleRecordingUI()
        XCTAssertEqual(controller.state, .voiceRecording, "precondition: recording state set")

        controller.endGoogleUI()

        XCTAssertEqual(controller.state, .idle,
            "Google teardown must reset the state machine so the next agent voice tap starts a capture")
        XCTAssertEqual(
            AgentController.agentVoiceTapRoute(state: controller.state),
            .startVoiceCapture,
            "after a Google session a fresh agent voice tap must START a capture, not stop one")
    }

    /// Reproduces the production `AppDelegate.makeGoogleCallbacks().onTextTap`
    /// toggle decision exactly: a second R-Option tap must CLOSE an open Google
    /// composer (mirroring the agent `handleTap` toggle). The real branch keys
    /// on `controller.isTextComposerOpen` (the Task B accessor) AND
    /// `islandFlow.activeSourceIsGoogle` (so an agent composer is NOT closed by
    /// the Google gesture). Encoded here as a local helper so the test drives
    /// the real predicate, not a copy of it.
    private func runGoogleTextTap(
        controller: AgentController,
        islandFlow: IslandAgentFlowStore
    ) {
        if controller.isTextComposerOpen, islandFlow.activeSourceIsGoogle {
            // Toggle-CLOSE: Google teardown (flag false + endGoogleUI). Order:
            // flag first, then controller teardown (matches AppDelegate).
            islandFlow.setActiveSourceIsGoogle(false)
            controller.endGoogleUI()
            return
        }
        // Toggle-OPEN: phase change first, flag after (recompute clears it).
        controller.startGoogleTextInputUI()
        islandFlow.setActiveSourceIsGoogle(true)
    }

    func testGoogleTextTapTogglesComposerClosedOnSecondTap() async {
        // Task B: R-Option tap opens the Google text composer; a SECOND tap
        // must close it (toggle), mirroring the agent R-Cmd text composer's
        // `handleTap` toggle. Before the fix `startGoogleTextInputUI()` never
        // set `state = .textInput`, so `isTextComposerOpen` was false and the
        // second tap re-opened instead of closing.
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { nil },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        // First tap → composer OPEN in Google mode.
        runGoogleTextTap(controller: controller, islandFlow: islandFlow)
        await waitUntil { islandFlow.wing == .composing }
        XCTAssertEqual(controller.state, .textInput,
            "first tap must put the controller into the text-input state so the open composer is detectable")
        XCTAssertTrue(controller.isTextComposerOpen,
            "first tap must leave the Google composer detectably open")
        XCTAssertTrue(islandFlow.activeSourceIsGoogle,
            "first tap must mark the composer as the Google one")
        XCTAssertEqual(AppState.shared.agentPhase, .textInputActive)
        let openMode = IslandState.listening.orbMode(
            phase: AppState.shared.phase,
            agentPhase: AppState.shared.agentPhase,
            activeSourceIsGoogle: islandFlow.activeSourceIsGoogle
        )
        XCTAssertEqual(openMode, .googleTextInputActive,
            "open Google composer must resolve to the .googleTextInputActive orb (Google colours)")

        // Second tap → composer CLOSED, fully torn down to idle.
        runGoogleTextTap(controller: controller, islandFlow: islandFlow)
        XCTAssertEqual(controller.state, .idle,
            "second tap must close the Google composer (toggle), not re-open it")
        XCTAssertFalse(controller.isTextComposerOpen,
            "second tap must leave the Google composer closed")
        XCTAssertFalse(islandFlow.activeSourceIsGoogle,
            "second tap must clear the Google source flag")
        XCTAssertEqual(AppState.shared.agentPhase, .idle,
            "second tap must return the agent phase to idle")
    }

    func testGoogleTextTapDoesNotCloseOpenAgentComposer() async {
        // Guard: an OPEN AGENT text composer (R-Cmd handleTap) must NOT be
        // closed by the Google gesture — only the Google composer toggles. The
        // agent composer also sets `state == .textInput && textInputActive`, so
        // the toggle MUST additionally confirm `activeSourceIsGoogle` before
        // tearing down. Here the agent composer is open but the Google flag is
        // false, so a Google tap must OPEN a Google composer (flip the flag),
        // never tear the agent composer down.
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )
        controller.start()

        // Open the AGENT composer via the real R-Cmd text trigger.
        controller.triggerTextAgent()
        await waitUntil { islandFlow.wing == .composing }
        XCTAssertTrue(controller.isTextComposerOpen,
            "precondition: agent composer sets the same state+flag the predicate keys on")
        XCTAssertFalse(islandFlow.activeSourceIsGoogle,
            "precondition: an agent composer is NOT a Google composer")

        // A Google tap must NOT close the agent composer (flag is not Google);
        // it opens the Google composer instead.
        runGoogleTextTap(controller: controller, islandFlow: islandFlow)
        XCTAssertEqual(controller.state, .textInput,
            "Google gesture must not tear down a composer that is not the Google one")
        XCTAssertTrue(islandFlow.activeSourceIsGoogle,
            "the Google tap opened the Google composer (flipped the flag)")
    }

    func testGoogleTextTapSingleTapOpensComposer() async {
        // Sanity: a single Google tap still opens the composer correctly
        // (the OPEN branch is unchanged by the toggle fix).
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { nil },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        runGoogleTextTap(controller: controller, islandFlow: islandFlow)
        await waitUntil { islandFlow.wing == .composing }
        XCTAssertEqual(controller.state, .textInput)
        XCTAssertTrue(controller.isTextComposerOpen)
        XCTAssertTrue(islandFlow.activeSourceIsGoogle)
        XCTAssertEqual(AppState.shared.agentPhase, .textInputActive)
    }

    func testHoldEndTranscribesAudioThenSubmitsTextAndOpensAnswerOnFirstBlock() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }

        XCTAssertEqual(AppState.shared.agentPhase, .transcribing)
        XCTAssertEqual(voiceSession.stopCalls, 1)
        XCTAssertEqual(transcriber.audioRequests, [Data("RIFF".utf8)])
        XCTAssertEqual(agentClient.calls.count, 0)

        transcriber.complete("transcribed question")
        await waitUntil { agentClient.calls.count == 1 }

        XCTAssertEqual(controller.state, .executing)
        XCTAssertEqual(AppState.shared.agentPhase, .executing)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("transcribed question") == true)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("selection") == true)
        // While the turn runs (no content yet) the acting wing shows; the
        // answer panel has not opened.
        await waitUntil { islandFlow.wing == .acting }
        XCTAssertFalse(islandFlow.answerPanelVisible)

        agentClient.continuations.first?.yield(.blockComplete(.textAnswer(TextAnswerBlock(body: "Voice"))))
        await waitUntil { !store.blocks.isEmpty }
        // First streamed content opens the island answer panel.
        await waitUntil { islandFlow.answerPanelVisible }
        XCTAssertTrue(islandFlow.answerPanelVisible)
    }

    func testHoldEndTranscriptionFailureShowsTransientNoticeAndReturnsIdle() async {
        // Batch-path transcription failure: STT throws after hold-end. The
        // failure surfaces as a transient wing notice (island is the sole
        // answer surface — no error block is written to the store, so the
        // answer panel never opens), no dispatch happens, and the UI returns
        // to idle.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }
        transcriber.fail(URLError(.badServerResponse))
        await waitUntil {
            if case .failed = islandFlow.wing { return true }
            return false
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        XCTAssertTrue(agentClient.calls.isEmpty)
        guard case .failed(let message) = islandFlow.wing else {
            XCTFail("Expected a transient failure notice in the wing.")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertTrue(store.blocks.isEmpty, "transcription failure must not write an answer block")
    }

    func testHoldEndWithShortGestureDoesNotCallTranscribe() async {
        // Quick-tap of Right Cmd — gesture lasts less than the silence
        // detector's minimum duration. Recorded audio is non-empty in
        // bytes (WAV header + a few PCM frames), so the existing
        // "empty audio -> return early" guard does NOT catch it; the
        // pre-flight silence guard must. /api/transcribe must not be
        // called, no error block must surface, UI returns to idle.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(
            audio: Data("RIFF".utf8),
            elapsedSeconds: 0.1,
            peakEnergy: 0.5
        )
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { controller.state == .idle }

        XCTAssertTrue(transcriber.audioRequests.isEmpty)
        XCTAssertTrue(agentClient.calls.isEmpty)
        XCTAssertEqual(store.status, .ready)
        XCTAssertTrue(store.blocks.isEmpty)
        // Silent close: every island surface returns hidden, no answer panel.
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func testHoldEndWithSilenceOnlyRecordingDoesNotCallTranscribe() async {
        // Long-hold gesture but the user never spoke. Captured WAV has
        // bytes, duration is well over the minimum, but the peak energy
        // never crossed the noise gate. Same outcome as the short-tap
        // case — no transcribe call, no error UI.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(
            audio: Data("RIFF".utf8),
            elapsedSeconds: 3.0,
            peakEnergy: 0.01
        )
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { controller.state == .idle }

        XCTAssertTrue(transcriber.audioRequests.isEmpty)
        XCTAssertTrue(agentClient.calls.isEmpty)
        XCTAssertEqual(store.status, .ready)
        XCTAssertTrue(store.blocks.isEmpty)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func testHoldEndWithEmptyAudioReturnsIdleWithoutShowingSurfaces() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: nil)
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { voiceSession.stopCalls == 1 }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        XCTAssertNil(controller.currentSnapshot)
        XCTAssertTrue(agentClient.calls.isEmpty)
        XCTAssertTrue(transcriber.audioRequests.isEmpty)
        XCTAssertEqual(store.status, .ready)
        // No island surface opens — neither a wing nor the answer panel.
        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertFalse(islandFlow.answerPanelVisible)
    }

    func testVoicePathWithEmptyTranscriptDoesNotCallAgentEndpoint() async {
        // Sub-second voice gesture -> Whisper returns "". The controller must
        // NOT call /api/agent (backend enforces min_length=1 and would return
        // 422), and must close the voice UI silently — no error block, no
        // response panel.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }
        transcriber.complete("")
        await waitUntil { controller.state == .idle }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        XCTAssertNil(controller.currentSnapshot)
        XCTAssertTrue(agentClient.calls.isEmpty)
        XCTAssertEqual(store.status, .ready)
        XCTAssertTrue(store.blocks.isEmpty)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertEqual(islandFlow.wing, .hidden)
    }

    func testVoicePathWithWhitespaceOnlyTranscriptDoesNotCallAgentEndpoint() async {
        // Whisper returns whitespace/newlines only — same as empty: skip
        // /api/agent, close silently.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }
        transcriber.complete("  \n\t  ")
        await waitUntil { controller.state == .idle }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        XCTAssertTrue(agentClient.calls.isEmpty)
        XCTAssertEqual(store.status, .ready)
        XCTAssertTrue(store.blocks.isEmpty)
        XCTAssertFalse(islandFlow.answerPanelVisible)
        XCTAssertEqual(islandFlow.wing, .hidden)
    }

    func testVoicePathWithSingleWordTranscriptStillCallsAgentEndpoint() async {
        // Regression guard: a tiny but non-empty transcript ("да") MUST still
        // be forwarded to /api/agent — empty-transcript guard must not trim
        // away legitimate short utterances.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            agentEnabled: { true }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }
        transcriber.complete("да")
        await waitUntil { agentClient.calls.count == 1 }

        XCTAssertEqual(agentClient.calls.count, 1)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("да") == true)
        XCTAssertEqual(controller.state, .executing)
    }

    func testTextPathWithNonEmptyMessageStillCallsAgentEndpoint() async {
        // Regression guard: the empty-transcript guard lives in the voice
        // branch only — the text path must continue to forward non-empty
        // messages to /api/agent unchanged.
        let snapshot = makeSnapshot()
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            agentEnabled: { true }
        )

        controller.submitTextQuery("hello", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        XCTAssertEqual(agentClient.calls.count, 1)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("hello") == true)
    }

    func testGestureCancelClosesComposingWingAndDropsSnapshot() async {
        // Esc via the gesture monitor's onCancel tears the composing wing
        // down: wing hidden, snapshot dropped (focus restore runs against the
        // captured snapshot inside handleCancel — no panel host), idle.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
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
        monitor.onCancel?()
        await waitUntil { controller.state == .idle }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentSnapshot)
        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func testCancelDuringVoiceSessionDropsRecordingAndDoesNotSubmit() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let agentClient = ManualCLIProvider()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            voiceSessionFactory: { voiceSession },
            agentEnabled: { true }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onCancel?()
        await waitUntil { controller.state == .idle }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        XCTAssertEqual(voiceSession.cancelCalls, 1)
        XCTAssertTrue(agentClient.calls.isEmpty)
    }

    func testVoiceSessionAutoStopTranscribesAudioOnce() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            agentEnabled: { true }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        voiceSession.triggerAutoStop()
        await waitUntil { transcriber.audioRequests.count == 1 }
        transcriber.complete("auto transcript")
        await waitUntil { agentClient.calls.count == 1 }
        monitor.onHoldEnd?()
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(controller.state, .executing)
        XCTAssertEqual(voiceSession.stopCalls, 1)
        XCTAssertEqual(transcriber.audioRequests.count, 1)
        XCTAssertEqual(agentClient.calls.count, 1)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("auto transcript") == true)
    }

    func testStopStopsMonitorAndClearsOpenSurfaces() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
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
        controller.stop()

        XCTAssertTrue(monitor.stopCalled)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        // Shutdown returns the island to idle, clearing the open wing.
        XCTAssertEqual(islandFlow.wing, .hidden)
        XCTAssertFalse(islandFlow.answerPanelVisible)
    }

    func testSubmitTextQueryBuildsRequestAndConsumesStream() async {
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let agentClient = MockCLIProvider(
            events: [
                .summaryDelta(text: "answer"),
                .done(sources: [])
            ]
        )
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true }
        )

        controller.submitTextQuery("question", snapshot: snapshot)
        await waitUntil { store.status == .ready }

        XCTAssertEqual(controller.state, .executing)
        XCTAssertEqual(agentClient.calls.count, 1)
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("question") == true)
        // Selection is now embedded in the prompt, not a separate field.
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("selection") == true)
        XCTAssertEqual(store.summary, "answer")
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func testErrorEventOpensAnswerPanelEvenWithoutBlock() async {
        // The user's bug: a dispatched turn returns error -> done with no
        // block.complete in between. The answer panel must open on the error
        // content so the failure is visible (the flow store opens it on
        // `errorMessage`), rather than the streaming preview dying silently.
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.submitTextQuery("question", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        agentClient.continuations.first?.yield(
            .error(code: "provider_error", message: "Provider failed", retryable: true)
        )
        await waitUntil { store.status == .failed }
        await waitUntil { islandFlow.answerPanelVisible }

        // A dispatched-turn error opens the island answer panel (carrying the
        // error content) — unlike a pre-dispatch STT failure, which shows the
        // transient wing notice instead.
        XCTAssertTrue(islandFlow.answerPanelVisible)
        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.errorCode, "provider_error")
    }

    func testAnswerPanelStaysOpenAfterErrorFollowedByDone() async {
        // A dispatched turn terminates the stream with error -> done. The
        // answer panel must open on error and stay open after done; the
        // error state must remain (the trailing done must not close it).
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.submitTextQuery("question", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }

        agentClient.continuations.first?.yield(
            .error(code: "provider_error", message: "Provider failed", retryable: true)
        )
        await waitUntil { islandFlow.answerPanelVisible }
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { store.streamCompleted }

        XCTAssertTrue(islandFlow.answerPanelVisible, "answer panel must stay open through error -> done")
        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.errorCode, "provider_error")
        XCTAssertEqual(store.errorMessage, "Provider failed")
    }

    func testTextTurnWritesAgentHistoryRowOnDone() async throws {
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let (chatStore, sqliteStore) = try makeTempChatStore(
            clock: { Date(timeIntervalSince1970: 42) }
        )
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            chatStackStore: chatStore,
            agentEnabled: { true }
        )

        controller.submitTextQuery("hello", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(.toolExecuting(tool: "search.web", label: "Searching"))
        agentClient.continuations.first?.yield(.blockComplete(.textAnswer(TextAnswerBlock(body: "Body"))))
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { store.streamCompleted }
        await waitUntil { chatStore.rows.first?.status == .done }

        // Regression: same row visible via the legacy `latestAgentEntries`
        // read path.
        let raw = try sqliteStore.latestAgentEntries(limit: 1)
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.queryText, "hello")
        XCTAssertEqual(raw.first?.queryMode, .text)
        XCTAssertEqual(raw.first?.responseMarkdown, "Body")
        XCTAssertEqual(raw.first?.toolNames, ["search.web"])
        XCTAssertEqual(raw.first?.createdAt, Date(timeIntervalSince1970: 42))
    }

    func testVoiceTurnWritesAgentHistoryRowWithVoiceMode() async throws {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let (chatStore, sqliteStore) = try makeTempChatStore(
            clock: { Date(timeIntervalSince1970: 9_000) }
        )
        let agentClient = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            chatStackStore: chatStore,
            agentEnabled: { true }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }
        transcriber.complete("spoken question")
        await waitUntil { agentClient.calls.count == 1 }

        agentClient.continuations.first?.yield(.blockComplete(.textAnswer(TextAnswerBlock(body: "Voice reply"))))
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { chatStore.rows.first?.status == .done }

        let raw = try sqliteStore.latestAgentEntries(limit: 1)
        XCTAssertEqual(raw.first?.queryText, "spoken question")
        XCTAssertEqual(raw.first?.queryMode, .voice)
        XCTAssertEqual(raw.first?.responseMarkdown, "Voice reply")
        XCTAssertEqual(raw.first?.createdAt, Date(timeIntervalSince1970: 9_000))
    }

    func testErrorTerminatedTurnWritesHistoryRowWithErrorMessage() async throws {
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let (chatStore, sqliteStore) = try makeTempChatStore(
            clock: { Date(timeIntervalSince1970: 7) }
        )
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            chatStackStore: chatStore,
            agentEnabled: { true }
        )

        controller.submitTextQuery("hi", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(
            .error(code: "provider_error", message: "Provider failed", retryable: true)
        )
        agentClient.continuations.first?.finish()
        await waitUntil { chatStore.rows.first?.status == .error }

        let raw = try sqliteStore.latestAgentEntries(limit: 1)
        XCTAssertEqual(raw.first?.queryText, "hi")
        XCTAssertEqual(raw.first?.queryMode, .text)
        XCTAssertEqual(raw.first?.responseMarkdown, "Provider failed")
    }

    func testHistoryRowWrittenOnlyOnceWhenErrorPrecedesDone() async throws {
        let snapshot = makeSnapshot()
        let store = AskResponseStore()
        let (chatStore, sqliteStore) = try makeTempChatStore()
        let agentClient = ManualCLIProvider()
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            responseStore: store,
            chatStackStore: chatStore,
            agentEnabled: { true }
        )

        controller.submitTextQuery("hi", snapshot: snapshot)
        await waitUntil { agentClient.calls.count == 1 }
        agentClient.continuations.first?.yield(
            .error(code: "provider_error", message: "Provider failed", retryable: true)
        )
        agentClient.continuations.first?.yield(.done(sources: []))
        agentClient.continuations.first?.finish()
        await waitUntil { store.streamCompleted }
        for _ in 0..<20 { await Task.yield() }

        // Exactly one row, kept in `.error` (the trailing `done` event must
        // not overwrite the failure marker with `.done`).
        let raw = try sqliteStore.latestAgentEntries(limit: 10)
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(chatStore.rows.first?.status, .error)
    }

    // MARK: - Cmd+C selection fallback wiring (v3)

    func testSubmitSkipsSelectionFallbackWhenAxSelectionPresent() async {
        var fallbackCallCount = 0
        let invoker = SelectionFallbackInvoker(invoke: { _, completion in
            fallbackCallCount += 1
            completion(nil)
        })
        let snapshot = makeSnapshot()  // selectionText = "selection"
        let agentClient = MockCLIProvider(events: [.done(sources: [])])
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            selectionFallbackInvoker: invoker,
            agentEnabled: { true }
        )

        controller.submitTextQuery("hello", snapshot: snapshot)
        await waitUntil { !agentClient.calls.isEmpty }

        XCTAssertEqual(fallbackCallCount, 0, "Fallback must NOT run when AX selection is non-empty.")
        XCTAssertTrue(agentClient.calls.first?.prompt.contains("selection") == true, "Selection must be embedded in prompt")
    }

    func testSubmitRunsSelectionFallbackWhenAxSelectionEmptyAndUpdatesSnapshot() async {
        var fallbackTargetPIDs: [pid_t] = []
        let invoker = SelectionFallbackInvoker(invoke: { targetPID, completion in
            fallbackTargetPIDs.append(targetPID)
            completion("captured-via-cmd-c")
        })
        let snapshot = FocusSnapshot(
            targetPID: 777,
            bundleID: "com.example.Electron",
            appName: "Electron",
            selectionText: nil,
            isEditable: false,
            capturedAt: Date(timeIntervalSince1970: 11)
        )
        let agentClient = MockCLIProvider(events: [.done(sources: [])])
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            selectionFallbackInvoker: invoker,
            agentEnabled: { true }
        )

        controller.submitTextQuery("hello", snapshot: snapshot)
        await waitUntil { !agentClient.calls.isEmpty }

        XCTAssertEqual(fallbackTargetPIDs, [777], "Fallback must be invoked with the snapshot's targetPID.")
        XCTAssertTrue(
            agentClient.calls.first?.prompt.contains("captured-via-cmd-c") == true,
            "Selection from fallback must be embedded in prompt."
        )
        XCTAssertEqual(
            controller.currentSnapshot?.selectionText,
            "captured-via-cmd-c",
            "currentSnapshot must be replaced with the fallback-updated snapshot."
        )
    }

    func testSubmitRunsSelectionFallbackWhenAxSelectionEmptyStringAndSubmitsWithNilOnFallbackEmpty() async {
        var fallbackCalls = 0
        let invoker = SelectionFallbackInvoker(invoke: { _, completion in
            fallbackCalls += 1
            completion(nil)
        })
        let snapshot = FocusSnapshot(
            targetPID: 778,
            bundleID: "com.example.Electron2",
            appName: "Electron2",
            selectionText: "",
            isEditable: false,
            capturedAt: Date(timeIntervalSince1970: 12)
        )
        let agentClient = MockCLIProvider(events: [.done(sources: [])])
        let controller = AgentController(
            gestureMonitor: MockRightCmdGestureMonitor(),
            snapshotProvider: { snapshot },
            resolveProvider: { agentClient },
            selectionFallbackInvoker: invoker,
            agentEnabled: { true }
        )

        controller.submitTextQuery("hello", snapshot: snapshot)
        await waitUntil { !agentClient.calls.isEmpty }

        XCTAssertEqual(fallbackCalls, 1, "Empty string selection triggers fallback just like nil.")
        // Fallback returned nil → prompt must not contain a selection prefix.
        XCTAssertFalse(
            agentClient.calls.first?.prompt.contains("Selected text:") == true,
            "Fallback returned nil → prompt must carry no selection prefix."
        )
    }

    // MARK: - Voice path always goes through STT → local provider (pivot-2)
    //
    // The direct-audio backend path (directAudioEnabled) was removed in pivot-2.
    // Voice always transcribes via audioTranscriber → submitQuery → CLIProvider.

    func testHoldEndVoiceAlwaysTranscribesAndSubmitsToProvider() async {
        // pivot-2: voice always transcribes via STT → text → local CLIProvider.
        // There is no separate "direct audio" path any more.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let provider = ManualCLIProvider()
        let transcriber = ManualAgentTranscriber()
        let voiceSession = MockAgentVoiceSession(audio: Data("RIFF".utf8))
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { provider },
            audioTranscriber: transcriber,
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow,
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        await waitUntil { voiceSession.startCalls == 1 }
        monitor.onHoldEnd?()
        await waitUntil { transcriber.audioRequests.count == 1 }

        XCTAssertEqual(voiceSession.stopCalls, 1)
        XCTAssertTrue(provider.calls.isEmpty, "provider must NOT be called until transcription completes")

        transcriber.complete("transcribed question")
        await waitUntil { provider.calls.count == 1 }

        XCTAssertEqual(controller.state, .executing)
        XCTAssertEqual(AppState.shared.agentPhase, .executing)
        // Dispatched turn drives the acting wing; the answer panel opens later
        // on streamed content (none here yet).
        await waitUntil { islandFlow.wing == .acting }
        XCTAssertEqual(islandFlow.queryText, "transcribed question")
        XCTAssertTrue(
            provider.calls.first?.prompt.contains("transcribed question") == true,
            "prompt must contain the transcribed text"
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
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition was not met.", file: file, line: line)
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

    private func resetSharedAppState() {
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle
        AppState.shared.rightCommandHeld = false
        AppState.shared.toolsExpanded = false
        AppState.shared.clearAudioLevels()
    }

    // MARK: - Capability gating (E2)

    func test_handleTap_requestsSetup_whenAgentDisabled() async {
        // Agent flag off: R-Cmd tap opens setup while leaving the agent flow
        // idle (no composer or snapshot-driven turn starts).
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        var setupRequests = 0
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            responseStore: store,
            agentEnabled: { false },
            onAgentSetupRequired: { setupRequests += 1 },
            islandAgentFlow: islandFlow
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onTap?()
        await waitUntil { setupRequests == 1 }

        XCTAssertEqual(setupRequests, 1)
        XCTAssertEqual(controller.state, .idle, "disabled tap must not open composer")
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
        XCTAssertEqual(islandFlow.wing, .hidden)
    }

    func test_handleTap_opensComposer_whenAgentEnabled() async {
        // Agent flag on: R-Cmd tap must open the composing wing as normal.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            responseStore: store,
            agentEnabled: { true },
            islandAgentFlow: islandFlow
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onTap?()
        await waitUntil { islandFlow.wing == .composing }

        XCTAssertEqual(controller.state, .textInput, "tap with agentEnabled=true must open composer")
        XCTAssertEqual(islandFlow.wing, .composing)
    }

    func test_handleTap_requestsSetup_whenNoProviderIsConfigured() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        var setupRequests = 0
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { nil },
            responseStore: store,
            agentEnabled: { true },
            onAgentSetupRequired: { setupRequests += 1 },
            islandAgentFlow: islandFlow
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onTap?()
        await waitUntil { setupRequests == 1 }

        XCTAssertEqual(setupRequests, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(islandFlow.wing, .hidden)
    }

    func test_handleHoldStart_requestsSetup_whenAgentDisabled() async {
        // Agent flag off: R-Cmd hold opens setup without starting recording.
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let store = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: store)
        let voiceSession = MockAgentVoiceSession(audio: nil)
        var setupRequests = 0
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            voiceSessionFactory: { voiceSession },
            responseStore: store,
            agentEnabled: { false },
            onAgentSetupRequired: { setupRequests += 1 },
            islandAgentFlow: islandFlow
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()

        // A brief yield is enough; the hold path transitions state
        // synchronously when allowed.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(setupRequests, 1)
        XCTAssertEqual(controller.state, .idle, "disabled hold must not start recording")
        XCTAssertEqual(voiceSession.startCalls, 0, "voice session must not start when agent is disabled")
        XCTAssertEqual(AppState.shared.agentPhase, .idle)
    }

    func test_handleHoldStart_requestsSetup_withoutStartingAudio_whenNoProviderIsConfigured() async {
        let snapshot = makeSnapshot()
        let monitor = MockRightCmdGestureMonitor()
        let voiceSession = MockAgentVoiceSession(audio: nil)
        var setupRequests = 0
        let controller = AgentController(
            gestureMonitor: monitor,
            snapshotProvider: { snapshot },
            resolveProvider: { nil },
            voiceSessionFactory: { voiceSession },
            agentEnabled: { true },
            onAgentSetupRequired: { setupRequests += 1 }
        )

        controller.start()
        monitor.onSnapshot?(snapshot)
        monitor.onHoldStart?()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(setupRequests, 1)
        XCTAssertEqual(voiceSession.startCalls, 0)
        XCTAssertEqual(controller.state, .idle)
    }
}

private final class MockRightCmdGestureMonitor: RightCmdGestureMonitoring {
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

    func stop() {
        stopCalled = true
    }
}

@MainActor
private final class MockAgentVoiceSession: AgentVoiceSessioning {
    private let audio: Data?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0
    var elapsedSeconds: Double = 0
    var peakEnergy: Float = 0
    var onAutoStop: (() -> Void)?

    /// `elapsedSeconds` and `peakEnergy` default to values that pass
    /// `AudioSilenceDetector`'s pre-flight guard so existing voice tests
    /// — written before the guard existed — keep their "transcribe IS
    /// called" assumption. New tests that exercise the silence-drop
    /// branch pass values below the thresholds explicitly.
    init(audio: Data?, elapsedSeconds: Double = 2.0, peakEnergy: Float = 0.5) {
        self.audio = audio
        self.elapsedSeconds = elapsedSeconds
        self.peakEnergy = peakEnergy
    }

    func start() {
        startCalls += 1
    }

    func stop() async -> Data? {
        stopCalls += 1
        return audio
    }

    func cancel() {
        cancelCalls += 1
    }

    func triggerAutoStop() {
        onAutoStop?()
    }
}

/// Mock CLIProvider that yields scripted events immediately on run().
private final class MockCLIProvider: CLIProvider {
    let id: CLIProviderID = .claude
    let displayName = "Mock Claude"
    let installURL = URL(string: "https://example.com")!
    let lastSessionID: String? = nil
    private let events: [AgentSSEEvent]
    private(set) var calls: [(prompt: String, resumeSessionID: String?)] = []

    init(events: [AgentSSEEvent] = []) {
        self.events = events
    }

    func discoverBinary() -> URL? { URL(fileURLWithPath: "/mock/claude") }
    func probe() async -> ConnectOutcome { .connected(sessionID: nil) }
    func respondToPermission(requestId: String, decision: PermissionDecision) {}

    func run(prompt: String, resumeSessionID: String?, options: AgentRunOptions) -> AsyncStream<AgentSSEEvent> {
        calls.append((prompt, resumeSessionID))
        let events = self.events
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Manual CLIProvider that lets tests drive the stream by yielding events.
private final class ManualCLIProvider: CLIProvider {
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

private final class SessionRecordingCLIProvider: CLIProvider {
    let id: CLIProviderID
    let displayName = "Session Provider"
    let installURL = URL(string: "https://example.com")!
    let lastSessionID: String?
    private(set) var calls: [(prompt: String, resumeSessionID: String?)] = []

    init(id: CLIProviderID, lastSessionID: String?) {
        self.id = id
        self.lastSessionID = lastSessionID
    }

    func discoverBinary() -> URL? { URL(fileURLWithPath: "/mock/agent") }
    func probe() async -> ConnectOutcome { .connected(sessionID: nil) }
    func respondToPermission(requestId: String, decision: PermissionDecision) {}

    func run(prompt: String, resumeSessionID: String?, options: AgentRunOptions) -> AsyncStream<AgentSSEEvent> {
        calls.append((prompt, resumeSessionID))
        return AsyncStream { continuation in
            continuation.yield(.done(sources: []))
            continuation.finish()
        }
    }
}

@MainActor
private final class InMemoryAgentSessionStore: AgentSessionStoring {
    private var sessions: [CLIProviderID: String] = [:]

    func sessionID(for provider: CLIProviderID) -> String? {
        sessions[provider]
    }

    func setSessionID(_ sessionID: String?, for provider: CLIProviderID) {
        sessions[provider] = sessionID
    }
}

private final class ManualAgentTranscriber: AgentAudioTranscribing {
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

    func fail(_ error: Error) {
        continuations.removeFirst().resume(throwing: error)
    }
}

private final class RecordingSelectionFallback {
    private(set) var invokedTargetPIDs: [pid_t] = []
    private let stubbed: String?

    init(stubbed: String?) {
        self.stubbed = stubbed
    }

    /// Builds an invoker that records the target pid and synchronously
    /// completes with the stubbed selection — stands in for the real Cmd+C
    /// dance so the controller's fallback wiring can be asserted.
    func makeInvoker() -> SelectionFallbackInvoker {
        SelectionFallbackInvoker(invoke: { targetPID, completion in
            self.invokedTargetPIDs.append(targetPID)
            completion(self.stubbed)
        })
    }
}
