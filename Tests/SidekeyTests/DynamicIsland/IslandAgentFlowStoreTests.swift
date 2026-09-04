import Combine
import XCTest
@testable import Sidekey

@MainActor
final class IslandAgentFlowStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The store observes `AppState.shared.$phase` for the drop wing; reset
        // the singleton so a prior test's drop phase can't leak in.
        AppState.shared.phase = .idle
    }

    override func tearDown() {
        AppState.shared.phase = .idle
        super.tearDown()
    }

    private func makeStore(
        dropProviderBrand: @escaping () -> TranscriptionProviderBrand? = { nil },
        dropCleanupBrand: @escaping () -> TranscriptionProviderBrand? = { nil },
        agentProviderBrand: @escaping () -> TranscriptionProviderBrand? = { nil }
    ) -> (IslandAgentFlowStore, AskResponseStore) {
        let response = AskResponseStore()
        let store = IslandAgentFlowStore(
            responseStore: response,
            dropProviderBrand: dropProviderBrand,
            dropCleanupBrand: dropCleanupBrand,
            agentProviderBrand: agentProviderBrand
        )
        return (store, response)
    }

    /// Drains one main-queue turn so `DispatchQueue.main`-scheduled Combine
    /// deliveries (the production `$phase` mirror) land before assertions.
    private func drainMain() async {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    /// Production regression: the drop wing must clear once `AppState.phase`
    /// returns to `.idle` via the `$phase` mirror (not a direct
    /// `dropPhaseChanged`), even with a trailing direct `dropTranscriptUpdated`.
    /// Repro for "short phrase pasted, island keeps spinning thinking…" on prod,
    /// where the accessory app is backgrounded right after the paste and the
    /// `RunLoop.main`-scheduled `.idle` never gets delivered.
    func test_dropWingClearsAfterIdleViaPhaseMirror_withLateTranscript() async {
        let (store, _) = makeStore()
        AppState.shared.phase = .inserting
        await drainMain()
        XCTAssertEqual(store.wing, .acting, "precondition: inserting shows thinking…")

        store.dropTranscriptUpdated("привет, как дела?")  // trailing STT partial
        AppState.shared.phase = .idle                       // drop finished
        await drainMain()

        XCTAssertEqual(store.wing, .hidden, "thinking… must clear after idle")
    }

    // `streamingText` / `currentToolLabel` / `status` on AskResponseStore are
    // `@Published private(set)` — they can only be mutated through the public
    // API (`consume` / `markLocalStatus`). These helpers drive that API to
    // reach the states the flow store derives from, without touching the
    // store's access control.
    private func stream(_ events: [AgentSSEEvent]) -> AsyncStream<AgentSSEEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func testIdleByDefault() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.wing, .hidden)
        XCTAssertFalse(store.answerPanelVisible)
    }

    func testVoiceRecordingShowsWingWithTranscript() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.voiceRecording)
        store.transcriptUpdated("привет мир")
        XCTAssertEqual(store.wing, .recording(transcript: "привет мир"))
    }

    /// Agent voice wing gets the same transient-empty latch as the drop wing —
    /// no collapse on an EL pause — while staying LIVE (a shorter re-segmented
    /// snapshot is shown, never frozen on a peak). Display-only; the agent query
    /// uses the session's resolved result.
    func testAgentTranscriptLatchesEmptyButStaysLiveOnShorter() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.voiceRecording)
        store.transcriptUpdated("привет мир как")
        XCTAssertEqual(store.wing, .recording(transcript: "привет мир как"))

        store.transcriptUpdated("")            // EL pause: empty — latched, no collapse
        XCTAssertEqual(
            store.wing,
            .recording(transcript: "привет мир как"),
            "empty pause-update must not collapse the agent wing"
        )

        store.transcriptUpdated("шесть")       // re-segment: shorter — stays live
        XCTAssertEqual(
            store.wing,
            .recording(transcript: "шесть"),
            "agent wing must stay live on a shorter update — not freeze"
        )
    }

    func testTextInputShowsComposingWing() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.textInputActive)
        XCTAssertEqual(store.wing, .composing)
    }

    func testComposingTextMirrorsTypedTextWhileComposing() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.textInputActive)
        store.composingTextChanged("hello wor")
        XCTAssertEqual(store.wing, .composing)
        // Drives `IslandAgentWingView.composingFaceWidth`, growing the capsule
        // with what is typed.
        XCTAssertEqual(store.composingText, "hello wor")
    }

    func testComposingTextClearedWhenComposerCloses() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.textInputActive)
        store.composingTextChanged("draft query")
        XCTAssertEqual(store.composingText, "draft query")
        // Leaving text-input (submit / cancel) must collapse the capsule back to
        // its placeholder floor — i.e. empty composing text.
        store.agentPhaseChanged(.idle)
        XCTAssertEqual(store.composingText, "")
    }

    func testExecutingShowsActingSlotUntilAnswerContent() async {
        let (store, response) = makeStore()
        store.agentPhaseChanged(.voiceRecording)
        store.querySubmitted("найди PR")
        XCTAssertEqual(store.queryText, "найди PR")
        store.agentPhaseChanged(.executing)
        if case .acting = store.wing {} else { XCTFail("expected acting, got \(store.wing)") }
        XCTAssertFalse(store.answerPanelVisible)

        // First content: a streaming delta lands (sets status=.thinking and
        // streamingText). No `done`, so the turn is still in flight.
        await response.consume(stream([.summaryDelta(text: "Нашёл")]))
        store.refreshFromResponseStore()
        XCTAssertTrue(store.answerPanelVisible)
        XCTAssertEqual(store.wing, .answerControls) // окно раскрыто -> крыло = [Esc] [✕]
    }

    func testReturnToIdleClearsQueryText() {
        let (store, _) = makeStore()
        store.querySubmitted("найди PR")
        XCTAssertEqual(store.queryText, "найди PR")
        store.agentPhaseChanged(.idle)
        XCTAssertEqual(store.queryText, "")
    }

    func testPermissionPromptOpensAnswerPanelEarly() {
        let (store, response) = makeStore()
        store.agentPhaseChanged(.executing)
        response.pendingPermission = PermissionPrompt(
            id: "1", toolName: "bash", summary: "run ls", inputJSON: "{}"
        )
        store.refreshFromResponseStore()
        XCTAssertTrue(store.answerPanelVisible)
        XCTAssertEqual(store.wing, .answerControls)

        // после решения окно остаётся
        response.pendingPermission = nil
        store.refreshFromResponseStore()
        XCTAssertTrue(store.answerPanelVisible)
    }

    func testReturnToIdleHidesEverythingAndClearsTranscript() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.voiceRecording)
        store.transcriptUpdated("раз")
        store.agentPhaseChanged(.idle)
        XCTAssertEqual(store.wing, .hidden)
        XCTAssertFalse(store.answerPanelVisible)
        store.agentPhaseChanged(.voiceRecording)
        XCTAssertEqual(store.wing, .recording(transcript: "")) // транскрипт прошлого цикла не протекает
    }

    func testActivityLabelUsesCategorizer() async {
        let (store, response) = makeStore()
        store.agentPhaseChanged(.executing)
        await response.consume(stream([.toolExecuting(tool: "web", label: "ищу в интернете")]))
        response.flushTypewritersForTesting()
        store.refreshFromResponseStore()
        XCTAssertEqual(store.activityLabel, "ищу в интернете")
    }

    func testSttFailureShowsTransientNoticeThenCollapses() async throws {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.voiceRecording)
        store.sttFailed(message: "не расслышал", autoDismissDelay: .milliseconds(20))
        XCTAssertEqual(store.wing, .failed(message: "не расслышал"))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(store.wing, .hidden)
    }

    func testTransientFailureSurvivesBackgroundRefreshAndIdleTail() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.voiceRecording)
        store.sttFailed(message: "не расслышал", autoDismissDelay: .seconds(60))
        // background response-store noise must not blink the notice away
        store.refreshFromResponseStore()
        XCTAssertEqual(store.wing, .failed(message: "не расслышал"))
        // the trailing idle from the cancel path must not either
        store.agentPhaseChanged(.idle)
        XCTAssertEqual(store.wing, .failed(message: "не расслышал"))
        // but starting a new cycle dismisses it early
        store.agentPhaseChanged(.voiceRecording)
        XCTAssertEqual(store.wing, .recording(transcript: ""))
    }

    // MARK: - Drop flow wing (hold-Space dictation)

    func testDropRecordingShowsListeningWingWithTranscript() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.recording)
        XCTAssertEqual(store.wing, .recording(transcript: ""))   // "listening…"
        store.dropTranscriptUpdated("привет мир")
        XCTAssertEqual(store.wing, .recording(transcript: "привет мир"))
    }

    /// ElevenLabs (segment-based) emits an empty partial on a speech pause: it
    /// commits the segment and resets its partial buffer until the next
    /// utterance. The drop wing must NOT collapse back to "listening…"/empty
    /// mid-turn on that transient empty — latch the last non-empty transcript
    /// until the turn ends (`.idle` clears it). Repro for the EL "right wing
    /// flickers / collapses on every pause" report.
    func testDropTranscriptLatchesThroughEmptyPauseUpdate() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.recording)
        store.dropTranscriptUpdated("привет мир")
        XCTAssertEqual(store.wing, .recording(transcript: "привет мир"))

        store.dropTranscriptUpdated("")   // EL pause: empty partial
        XCTAssertEqual(
            store.wing,
            .recording(transcript: "привет мир"),
            "empty pause-update must not collapse the wing to listening…"
        )

        store.dropTranscriptUpdated("привет мир, как дела")   // speech resumes
        XCTAssertEqual(store.wing, .recording(transcript: "привет мир, как дела"))
    }

    /// Regression for the long-dictation FREEZE: a prior length-gated latch
    /// (`count > current`) froze the wing once the snapshot stopped strictly
    /// growing — ElevenLabs re-segments and revises the tail on long speech, so
    /// the running length dips, and the gate then ignored everything below the
    /// peak forever. The wing must stay LIVE: a shorter, re-segmented snapshot
    /// is shown (only a transient empty is latched through).
    func testDropTranscriptStaysLiveOnShorterReSegment() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.recording)
        store.dropTranscriptUpdated("один два три четыре пять")   // long running text
        XCTAssertEqual(store.wing, .recording(transcript: "один два три четыре пять"))

        store.dropTranscriptUpdated("шесть")   // provider re-segments: SHORTER, new content
        XCTAssertEqual(
            store.wing,
            .recording(transcript: "шесть"),
            "wing must stay live on a shorter re-segmented update — not freeze on the peak line"
        )

        store.dropTranscriptUpdated("")        // transient empty pause: latched (no collapse)
        XCTAssertEqual(store.wing, .recording(transcript: "шесть"))
    }

    /// The recording wing's WIDTH is driven by `recordingFaceWidthHint` — the
    /// widest rendered transcript this turn — so it GROWS then HOLDS (never
    /// shrinks on a transient re-segment) while the displayed transcript stays
    /// live. Resets per turn. This is what removes the pause width-jump without
    /// freezing.
    func testRecordingFaceWidthHintHoldsPeakAndResetsPerTurn() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.recording)
        store.dropTranscriptUpdated("один два три четыре")   // grows
        XCTAssertEqual(store.recordingFaceWidthHint, "один два три четыре")

        store.dropTranscriptUpdated("шесть")                 // shorter re-segment
        XCTAssertEqual(store.wing, .recording(transcript: "шесть"), "display stays live")
        XCTAssertEqual(
            store.recordingFaceWidthHint,
            "один два три четыре",
            "width hint HOLDS the peak — wing does not shrink on a shorter partial"
        )

        store.dropTranscriptUpdated("")                      // empty pause: hint unchanged
        XCTAssertEqual(store.recordingFaceWidthHint, "один два три четыре")

        store.dropPhaseChanged(.idle)                        // turn ends
        XCTAssertEqual(store.recordingFaceWidthHint, "", "hint resets per turn")
    }

    func testRecordingFaceWidthHintUsesRenderedWidthNotCharacterCount() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.recording)
        store.dropTranscriptUpdated("WWWWWWWW")
        XCTAssertEqual(store.recordingFaceWidthHint, "WWWWWWWW")

        store.dropTranscriptUpdated("iiiiiiiiiiiiiiiiiiiiiiii")

        XCTAssertEqual(
            store.wing,
            .recording(transcript: "iiiiiiiiiiiiiiiiiiiiiiii"),
            "displayed text stays live even when the width hint holds a wider earlier string"
        )
        XCTAssertEqual(
            store.recordingFaceWidthHint,
            "WWWWWWWW",
            "a longer but visually narrower partial must not replace the peak width hint"
        )
    }

    /// Hint also resets on agent turn boundaries (shared between drop + agent
    /// flows, which never record at the same time).
    func testRecordingFaceWidthHintResetsOnAgentTurnBoundary() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.voiceRecording)
        store.transcriptUpdated("привет мир как")
        XCTAssertEqual(store.recordingFaceWidthHint, "привет мир как")

        store.agentPhaseChanged(.idle)
        XCTAssertEqual(store.recordingFaceWidthHint, "", "hint resets when the agent turn ends")
    }

    func testDropRecordingExposesCurrentProviderBrand() {
        let brand = TranscriptionProviderBrand(assetName: "deepgram", label: "Deepgram")
        let (store, _) = makeStore(dropProviderBrand: { brand })

        store.dropPhaseChanged(.recording)

        XCTAssertEqual(store.recordingProviderBrand, brand)
    }

    func testDropRecordingPublishesWingAndProviderBrandTogether() {
        let brand = TranscriptionProviderBrand(assetName: "deepgram", label: "Deepgram")
        let (store, _) = makeStore(dropProviderBrand: { brand })
        var publishCount = 0
        let cancellable = store.objectWillChange.sink { publishCount += 1 }
        defer { cancellable.cancel() }

        store.dropPhaseChanged(.recording)

        XCTAssertEqual(store.wing, .recording(transcript: ""))
        XCTAssertEqual(store.recordingProviderBrand, brand)
        XCTAssertEqual(publishCount, 1)
    }

    func testAgentRecordingDoesNotExposeDropProviderBrand() {
        // The drop brand must never leak into an agent voice turn: with only a
        // drop brand injected (no agent brand), agent recording shows nil.
        let brand = TranscriptionProviderBrand(assetName: "soniox", label: "Soniox")
        let (store, _) = makeStore(dropProviderBrand: { brand })

        store.agentPhaseChanged(.voiceRecording)

        XCTAssertNil(store.recordingProviderBrand)
    }

    func testAgentVoiceRecordingExposesAgentProviderBrandCodex() {
        let (store, _) = makeStore(
            agentProviderBrand: { TranscriptionProviderBrand.agent(.codex) }
        )

        store.agentPhaseChanged(.voiceRecording)

        XCTAssertEqual(store.recordingProviderBrand?.assetName, "codex")
    }

    func testAgentVoiceRecordingExposesAgentProviderBrandClaude() {
        let (store, _) = makeStore(
            agentProviderBrand: { TranscriptionProviderBrand.agent(.claude) }
        )

        store.agentPhaseChanged(.voiceRecording)

        XCTAssertEqual(store.recordingProviderBrand?.assetName, "claude-code")
    }

    func testGoogleVoiceRecordingExposesGoogleBrand() {
        // Reproduces the production `AppDelegate.makeGoogleCallbacks().onHoldStart`
        // ordering: drive the phase to `.voiceRecording` FIRST, then set the
        // Google flag. The agent-brand closure must be ignored once the source
        // is Google.
        let (store, _) = makeStore(
            agentProviderBrand: { TranscriptionProviderBrand.agent(.codex) }
        )

        store.agentPhaseChanged(.voiceRecording)
        store.setActiveSourceIsGoogle(true)

        XCTAssertEqual(store.recordingProviderBrand, TranscriptionProviderBrand.google)
        XCTAssertEqual(store.recordingProviderBrand?.assetName, "google")
    }

    func testAgentVoiceBrandClearsBackToAgentWhenGoogleFlagDrops() {
        // A turn that briefly had the Google flag set must fall back to the
        // agent brand if the flag is cleared while still recording (defensive:
        // the source is re-resolved on every Google-flag change).
        let (store, _) = makeStore(
            agentProviderBrand: { TranscriptionProviderBrand.agent(.claude) }
        )

        store.agentPhaseChanged(.voiceRecording)
        store.setActiveSourceIsGoogle(true)
        XCTAssertEqual(store.recordingProviderBrand?.assetName, "google")

        store.setActiveSourceIsGoogle(false)
        XCTAssertEqual(store.recordingProviderBrand?.assetName, "claude-code")
    }

    func testIdleExposesNoProviderBrand() {
        let (store, _) = makeStore(
            dropProviderBrand: { TranscriptionProviderBrand.agent(.codex) },
            agentProviderBrand: { TranscriptionProviderBrand.agent(.codex) }
        )

        store.agentPhaseChanged(.idle)

        XCTAssertNil(store.recordingProviderBrand)
    }

    func testDropProviderBrandClearsOutsideListeningWing() {
        let brand = TranscriptionProviderBrand(assetName: "openai", label: "OpenAI")
        let (store, _) = makeStore(dropProviderBrand: { brand })

        store.dropPhaseChanged(.recording)
        XCTAssertEqual(store.recordingProviderBrand, brand)
        store.dropPhaseChanged(.verifying)
        XCTAssertNil(store.recordingProviderBrand)
        store.dropPhaseChanged(.idle)
        XCTAssertNil(store.recordingProviderBrand)
    }

    func testDropProviderBrandClearsOnSttFailure() {
        let brand = TranscriptionProviderBrand(assetName: "elevenlabs", label: "ElevenLabs")
        let (store, _) = makeStore(dropProviderBrand: { brand })

        store.dropPhaseChanged(.recording)
        XCTAssertEqual(store.recordingProviderBrand, brand)
        store.sttFailed(message: "не расслышал", autoDismissDelay: .seconds(60))

        XCTAssertNil(store.recordingProviderBrand)
    }

    func testDropTranscribingStaysListeningNotThinking() {
        let (store, _) = makeStore()
        // `.transcribing` brackets recording (session setup + the brief stop
        // moment) — it stays the listening frame, never a premature "thinking…".
        store.dropPhaseChanged(.transcribing)
        XCTAssertEqual(store.wing, .recording(transcript: ""))
    }

    func testDropSmartPostProcessShowsThinkingSlot() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.recording)
        store.dropTranscriptUpdated("готовый текст")
        // Drop's LLM cleanup runs in `.verifying`.
        store.dropPhaseChanged(.verifying)
        if case .acting = store.wing {} else { XCTFail("expected acting, got \(store.wing)") }
        XCTAssertEqual(store.activityLabel, "thinking…")
        // the paste tail keeps the thinking slot until idle
        store.dropPhaseChanged(.inserting)
        if case .acting = store.wing {} else { XCTFail("expected acting, got \(store.wing)") }
    }

    func testDropSmartPostProcessExposesCleanupBrand() {
        let sttBrand = TranscriptionProviderBrand(assetName: "soniox", label: "Soniox")
        let cleanupBrand = TranscriptionProviderBrand.openRouter
        let (store, _) = makeStore(
            dropProviderBrand: { sttBrand },
            dropCleanupBrand: { cleanupBrand }
        )

        store.dropPhaseChanged(.recording)
        XCTAssertEqual(store.recordingProviderBrand, sttBrand)

        store.dropPhaseChanged(.verifying)
        if case .acting = store.wing {} else { XCTFail("expected acting, got \(store.wing)") }
        XCTAssertEqual(store.recordingProviderBrand, cleanupBrand)

        store.dropPhaseChanged(.inserting)
        if case .acting = store.wing {} else { XCTFail("expected acting, got \(store.wing)") }
        XCTAssertEqual(store.recordingProviderBrand, cleanupBrand)

        store.dropPhaseChanged(.idle)
        XCTAssertNil(store.recordingProviderBrand)
    }

    func testDropIdleHidesWingAndClearsTranscript() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.recording)
        store.dropTranscriptUpdated("раз")
        store.dropPhaseChanged(.idle)
        XCTAssertEqual(store.wing, .hidden)
        // a new dictation must not leak the prior transcript
        store.dropPhaseChanged(.recording)
        XCTAssertEqual(store.wing, .recording(transcript: ""))
    }

    func testAgentWingTakesPriorityOverDrop() {
        let (store, _) = makeStore()
        // The two never really coincide (different hotkeys + phases) but the
        // priority must be deterministic: an active agent flow owns the wing
        // even if a drop phase is live.
        store.dropPhaseChanged(.recording)
        store.agentPhaseChanged(.executing)
        if case .acting = store.wing {} else { XCTFail("expected agent acting, got \(store.wing)") }
        store.agentPhaseChanged(.voiceRecording)
        store.transcriptUpdated("agent words")
        XCTAssertEqual(store.wing, .recording(transcript: "agent words"))
    }

    // MARK: - agentActing ownership marker
    // Drop & agent share one wing; `.acting` arises for BOTH. Keep a separate
    // ownership marker so consumers never have to infer agent ownership from
    // `wing == .acting` alone.

    func testDropFinishingDoesNotMarkAgentActing() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.finishing)
        if case .acting = store.wing {} else {
            XCTFail("precondition: degraded Drop is .acting, got \(store.wing)")
        }
        XCTAssertFalse(store.agentActing, "Drop .finishing must not be marked as agent-owned")
    }

    func testDropVerifyingDoesNotMarkAgentActing() {
        let (store, _) = makeStore()
        store.dropPhaseChanged(.verifying)
        if case .acting = store.wing {} else {
            XCTFail("precondition: smart-cleaner Drop is .acting, got \(store.wing)")
        }
        XCTAssertFalse(store.agentActing, "Drop .verifying must not be marked as agent-owned")
    }

    func testAgentExecutingMarksAgentActing() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.executing)
        if case .acting = store.wing {} else {
            XCTFail("precondition: agent executing is .acting, got \(store.wing)")
        }
        XCTAssertTrue(store.agentActing, "Agent execution .acting is marked as agent-owned")
    }

    func testIdleClearsAgentActing() {
        let (store, _) = makeStore()
        store.agentPhaseChanged(.executing)
        XCTAssertTrue(store.agentActing, "precondition: agent acting")
        store.agentPhaseChanged(.idle)
        store.dropPhaseChanged(.idle)
        XCTAssertFalse(store.agentActing, "returning to idle clears agentActing")
    }
}
