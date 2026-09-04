import XCTest
@testable import Sidekey

/// `AppDelegate.dropFlowRoute(phase:mode:hasStreamingSession:)` is the
/// testable shim sitting under `onHotkey()`. It maps the current
/// `AppPhase` + cached `TranscriptionMode` + presence of an in-flight
/// streaming session to a concrete `DropFlowRoute` so the AppKit
/// hook can be a thin switch over the pure function.
///
/// The shim exists so the phase/mode/session routing can be covered as a
/// pure function without instantiating `NSApplication`. Both `fast` and
/// `smart` route to the WS streaming pipeline; mode only gates the
/// server-side gpt-5.4-mini cleanup in `/api/process`, so it no longer
/// changes the client route. The recorder/batch path remains the fallback
/// shape (reachable when a run did not open a streaming session).
@MainActor
final class AppDelegateDropFlowRouteTests: XCTestCase {

    // MARK: - .idle → start

    func test_idle_fast_routes_to_start_streaming_session() {
        let route = AppDelegate.dropFlowRoute(
            phase: .idle,
            mode: .fast,
            hasStreamingSession: false
        )
        XCTAssertEqual(route, .startStreamingSession)
    }

    func test_idle_smart_routes_to_start_streaming_session() {
        // Smart shares the SAME live WS streaming pipeline as fast. The only
        // difference is server-side: /api/process runs the gpt-5.4-mini
        // cleanup when transcription_mode == smart. Routing must NOT diverge
        // by mode here — otherwise smart falls back to the batch multipart
        // pipeline, which re-feeds the recorded WAV through the realtime
        // model server-side and pays ~the audio duration a second time.
        let route = AppDelegate.dropFlowRoute(
            phase: .idle,
            mode: .smart,
            hasStreamingSession: false
        )
        XCTAssertEqual(route, .startStreamingSession)
    }

    // MARK: - .recording → stop (mode-agnostic; what matters is which
    // pipeline opened the session, captured by `hasStreamingSession`)

    func test_recording_with_streaming_session_routes_to_stop_streaming() {
        // User started in fast mode, the streaming session is open.
        // Even if they flipped Settings to smart between start and
        // stop (race window) we MUST finalize the open WS — flipping
        // to `stopRecordingAndTranscribe` would leave the WS task
        // dangling and the recorder unused.
        let route = AppDelegate.dropFlowRoute(
            phase: .recording,
            mode: .smart,
            hasStreamingSession: true
        )
        XCTAssertEqual(route, .stopStreamingSession)
    }

    func test_recording_with_streaming_session_in_fast_mode_routes_to_stop_streaming() {
        let route = AppDelegate.dropFlowRoute(
            phase: .recording,
            mode: .fast,
            hasStreamingSession: true
        )
        XCTAssertEqual(route, .stopStreamingSession)
    }

    func test_recording_without_streaming_session_routes_to_stop_recording() {
        let route = AppDelegate.dropFlowRoute(
            phase: .recording,
            mode: .smart,
            hasStreamingSession: false
        )
        XCTAssertEqual(route, .stopRecordingAndTranscribe)
    }

    func test_recording_without_streaming_session_in_fast_mode_routes_to_stop_recording() {
        // Race window in the other direction: user flipped from smart
        // (HTTP path active) to fast in Settings while a recording is
        // in flight. The recorder is the source of truth — finalize
        // the in-flight HTTP path, the next press will route to the
        // streaming pipeline.
        let route = AppDelegate.dropFlowRoute(
            phase: .recording,
            mode: .fast,
            hasStreamingSession: false
        )
        XCTAssertEqual(route, .stopRecordingAndTranscribe)
    }

    // MARK: - .dropMaxHoldRoute (10-minute cap → auto-finalize like a release)

    func test_max_hold_with_streaming_session_routes_to_stop_streaming() {
        // At the 10-min cap we finalize EXACTLY as a recording-phase release:
        // the live WS is stopped and transcribed so the text is pasted, never
        // dropped. Same target as `dropHotkeyReleasedRoute(.recording)`.
        let route = AppDelegate.dropMaxHoldRoute(phase: .recording, hasStreamingSession: true)
        XCTAssertEqual(route, .stopStreamingSession)
    }

    func test_max_hold_without_streaming_session_routes_to_stop_recording() {
        let route = AppDelegate.dropMaxHoldRoute(phase: .recording, hasStreamingSession: false)
        XCTAssertEqual(route, .stopRecordingAndTranscribe)
    }

    func test_max_hold_when_not_recording_is_noop() {
        // The turn already finalized (a real release) or never started — there
        // is no live take to auto-stop. Guarantees idempotency when a real
        // release races the cap timer (first to flip the phase wins).
        XCTAssertEqual(AppDelegate.dropMaxHoldRoute(phase: .idle, hasStreamingSession: true), .noop)
        XCTAssertEqual(AppDelegate.dropMaxHoldRoute(phase: .transcribing, hasStreamingSession: true), .noop)
        XCTAssertEqual(AppDelegate.dropMaxHoldRoute(phase: .transcribing, hasStreamingSession: false), .noop)
    }

    // MARK: - Empty-transcript guard (Task 7d)

    func test_blank_streaming_transcript_is_treated_as_empty() {
        // A tap-tap misfire yields an empty / whitespace-only transcript.
        // Feeding it to /api/process lets the cleanup LLM hallucinate text
        // that then pastes. The guard trims and treats these as empty so we
        // return to idle WITHOUT a process call (mirrors the agent path).
        XCTAssertTrue(AppDelegate.streamingTranscriptIsEmpty(""))
        XCTAssertTrue(AppDelegate.streamingTranscriptIsEmpty("   "))
        XCTAssertTrue(AppDelegate.streamingTranscriptIsEmpty("\n\t  \n"))
    }

    func test_nonblank_streaming_transcript_is_not_empty() {
        XCTAssertFalse(AppDelegate.streamingTranscriptIsEmpty("hello"))
        XCTAssertFalse(AppDelegate.streamingTranscriptIsEmpty("  hi  "))
    }

    // MARK: - Local-STT cleanup routing (ROO-257)

    /// Smart mode on the on-device LLM route must NOT bypass — the local Qwen
    /// cleanup is its documented purpose and runs fully offline.
    func test_local_smart_localRoute_runs_cleanup() {
        XCTAssertFalse(AppDelegate.localTranscriptionBypassesPostProcessing(
            mode: .smart, route: .local
        ))
    }

    /// Smart mode on a BYOK direct route also runs cleanup (offline-capable —
    /// the user's own provider, never our backend).
    func test_local_smart_directRoute_runs_cleanup() {
        let route = LLMCleanupRoute.direct(
            DirectLLMRoute(endpoint: .openRouter(apiKey: "k"), model: "m")
        )
        XCTAssertFalse(AppDelegate.localTranscriptionBypassesPostProcessing(
            mode: .smart, route: route
        ))
    }

    /// Unresolved route (resolver threw: no key / base URL configured) →
    /// bypass; there is nothing to clean with.
    func test_local_smart_unresolvedRoute_bypasses() {
        XCTAssertTrue(AppDelegate.localTranscriptionBypassesPostProcessing(
            mode: .smart, route: nil
        ))
    }

    /// Fast mode always bypasses — raw output is the design, no cleanup.
    func test_local_fast_always_bypasses() {
        XCTAssertTrue(AppDelegate.localTranscriptionBypassesPostProcessing(
            mode: .fast, route: .local
        ))
    }

    // MARK: - Empty-cleanup-output guard (ROO-257)
    //
    // A degenerate on-device Qwen reply can be whitespace-only; `LocalLLMSession`
    // trims it to "" (and `DropFillerFilter` can also strip cleanup output to
    // ""). Without a guard, `runPostProcessAndPaste` would feed "" into the paste
    // tail, whose `deliverDropTranscript` early-returns on empty — silently
    // eating the paste with no error surfaced. The deliverable decision is
    // extracted here so the fallback is covered behaviorally.

    func test_empty_cleanup_output_falls_back_to_raw_transcript() {
        // Degenerate LLM cleanup → "" must NOT eat the paste; deliver the raw
        // transcript instead so a non-empty dictation is never silently dropped.
        XCTAssertEqual(
            AppDelegate.dropDeliverableAfterCleanup(cleaned: "", rawTranscript: "привет мир"),
            "привет мир"
        )
        XCTAssertEqual(
            AppDelegate.dropDeliverableAfterCleanup(cleaned: "   ", rawTranscript: "hello world"),
            "hello world"
        )
        XCTAssertEqual(
            AppDelegate.dropDeliverableAfterCleanup(cleaned: "\n\t  \n", rawTranscript: "raw"),
            "raw"
        )
    }

    func test_nonempty_cleanup_output_is_delivered_verbatim() {
        // The happy path: a real cleanup result is what gets pasted, untouched.
        XCTAssertEqual(
            AppDelegate.dropDeliverableAfterCleanup(cleaned: "Cleaned text.", rawTranscript: "cleaned text"),
            "Cleaned text."
        )
    }

    func test_empty_cleanup_with_empty_raw_stays_empty() {
        // Both empty → nothing to deliver; the downstream empty-guard still idles
        // without pasting (no hallucinated text onto the focused field).
        XCTAssertEqual(
            AppDelegate.dropDeliverableAfterCleanup(cleaned: "", rawTranscript: ""),
            ""
        )
    }

    func test_streaming_setup_failure_before_stop_falls_back_to_recorder() {
        XCTAssertTrue(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: false,
            error: .transportFailed
        ))
    }

    func test_streaming_failure_after_stop_does_not_start_new_recording() {
        XCTAssertFalse(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: true,
            error: .transportFailed
        ))
        // Post-stop failures stay no-fallback regardless of cause.
        XCTAssertFalse(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: true,
            error: .watchdogTimeout
        ))
        XCTAssertFalse(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: true,
            error: .endOfStreamSendFailed
        ))
    }

    func test_end_of_stream_send_failure_before_stop_does_not_fall_back_to_recorder() {
        // The realtime socket opened and then failed while committing EOF. This
        // is not setup failure; re-arming recorder makes the user wait through a
        // second, slow batch path after the realtime path already broke.
        XCTAssertFalse(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: false,
            error: .endOfStreamSendFailed
        ))
    }

    func test_unknown_upstream_failure_before_stop_does_not_fall_back_to_recorder() {
        // Direct-provider `.unknown` comes from an already-open upstream
        // emitting an error, not from `adapter.open` setup failure. Treat it as
        // a failed realtime turn rather than starting an unexpected batch
        // recording.
        XCTAssertFalse(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: false,
            error: .unknown
        ))
    }

    func test_audio_engine_failure_never_falls_back_to_recorder() {
        // Task 7 review fix 4: the engine-failure watcher fires MID-recording
        // (stopRequested == false), which previously satisfied the fallback
        // predicate and re-armed the batch recorder against the same dead
        // device the route change just killed. audioEngineFailed must veto
        // the fallback in BOTH stop states.
        XCTAssertFalse(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: false,
            error: .audioEngineFailed
        ))
        XCTAssertFalse(AppDelegate.shouldFallbackToRecorderOnStreamingFailure(
            stopRequested: true,
            error: .audioEngineFailed
        ))
    }

    func test_hold_press_starts_streaming_and_second_press_is_noop() {
        let startRoute = AppDelegate.dropHotkeyPressedRoute(
            gesture: .hold,
            phase: .idle,
            mode: .smart,
            hasStreamingSession: false
        )
        let secondPressRoute = AppDelegate.dropHotkeyPressedRoute(
            gesture: .hold,
            phase: .recording,
            mode: .smart,
            hasStreamingSession: false
        )

        XCTAssertEqual(startRoute, .startStreamingSession)
        XCTAssertEqual(secondPressRoute, .noop)
    }

    func test_hold_release_only_stops_drop_recording() {
        let releaseRoute = AppDelegate.dropHotkeyReleasedRoute(
            gesture: .hold,
            phase: .recording,
            hasStreamingSession: false
        )
        let tapReleaseRoute = AppDelegate.dropHotkeyReleasedRoute(
            gesture: .tap,
            phase: .recording,
            hasStreamingSession: false
        )

        XCTAssertEqual(releaseRoute, .stopRecordingAndTranscribe)
        XCTAssertEqual(tapReleaseRoute, .noop)
    }

    // MARK: - Pending-stop during streaming setup (Task 7c)

    func test_transcribing_during_streaming_setup_records_pending_stop() {
        // Press set phase=.transcribing synchronously; session setup (JWT
        // read / refresh) is still in flight, so hasStreamingSession=false
        // AND isStreamingSetupInProgress=true. A stop arriving now must be
        // REMEMBERED, not dropped, so it can finalize once the session
        // reaches .recording.
        let route = AppDelegate.dropFlowRoute(
            phase: .transcribing,
            mode: .smart,
            hasStreamingSession: false,
            isStreamingSetupInProgress: true
        )
        XCTAssertEqual(route, .recordPendingStop)
    }

    func test_hold_release_during_streaming_setup_records_pending_stop() {
        // Hold-gesture release landing during async setup: the old contract
        // required phase==.recording and silently dropped this, leaving the
        // mic recording indefinitely. Now it records a pending stop.
        let route = AppDelegate.dropHotkeyReleasedRoute(
            gesture: .hold,
            phase: .transcribing,
            hasStreamingSession: false,
            isStreamingSetupInProgress: true
        )
        XCTAssertEqual(route, .recordPendingStop)
    }

    func test_tap_stop_during_streaming_setup_records_pending_stop() {
        // Tap-gesture stop during setup (tap-tap flow): also remembered.
        let route = AppDelegate.dropHotkeyPressedRoute(
            gesture: .tap,
            phase: .transcribing,
            mode: .fast,
            hasStreamingSession: false,
            isStreamingSetupInProgress: true
        )
        XCTAssertEqual(route, .recordPendingStop)
    }

    func test_transcribing_after_stop_is_still_noop() {
        // After the user stopped (session exists, phase flipped to
        // .transcribing while awaiting the server's terminal frame) a
        // further press must NOT record another pending stop — the stop is
        // already in flight. isStreamingSetupInProgress=false distinguishes
        // this from the setup window.
        let route = AppDelegate.dropFlowRoute(
            phase: .transcribing,
            mode: .smart,
            hasStreamingSession: true,
            isStreamingSetupInProgress: false
        )
        XCTAssertEqual(route, .noop)
    }

    // MARK: - Escape cancel (hold-Space Drop discard)

    func test_cancel_while_recording_with_streaming_session_cancels_session() {
        // Escape during a hold-Space recording backed by a WS streaming
        // session: tear the session down (no transcript, no paste).
        let route = AppDelegate.dropHotkeyCancelRoute(
            phase: .recording,
            hasStreamingSession: true
        )
        XCTAssertEqual(route, .cancelStreamingSession)
    }

    func test_cancel_while_recording_without_streaming_session_cancels_recorder() {
        // Escape during a recorder-backed (non-streaming) hold: discard the
        // in-flight WAV without transcribing.
        let route = AppDelegate.dropHotkeyCancelRoute(
            phase: .recording,
            hasStreamingSession: false
        )
        XCTAssertEqual(route, .cancelRecording)
    }

    func test_cancel_when_not_recording_is_noop() {
        // Nothing in flight to discard — Escape is a no-op outside `.recording`.
        for phase in [AppPhase.idle, .transcribing, .verifying, .inserting] {
            for hasSession in [false, true] {
                let route = AppDelegate.dropHotkeyCancelRoute(
                    phase: phase,
                    hasStreamingSession: hasSession
                )
                XCTAssertEqual(
                    route, .noop,
                    "Expected noop cancel for phase=\(phase) hasSession=\(hasSession)"
                )
            }
        }
    }

    // MARK: - .deliveryFailed is escapable (Task 7 — no roach-motel)

    func test_hold_press_in_delivery_failed_discards_failed_take_and_starts() {
        // The bug: a turn parked in `.deliveryFailed` (total-offline) trapped
        // the user — hold-Space was a no-op (guard phase == .idle), so a fresh
        // dictation could not be started and the only escape was a *successful*
        // Retry or an app restart. A Drop press must instead abandon the failed
        // take and start a new recording.
        let route = AppDelegate.dropHotkeyPressedRoute(
            gesture: .hold,
            phase: .deliveryFailed,
            mode: .smart,
            hasStreamingSession: false
        )
        XCTAssertEqual(route, .discardFailedTakeAndStart)
    }

    func test_tap_in_delivery_failed_discards_failed_take_and_starts() {
        // Same escape for the tap-toggle gesture.
        let route = AppDelegate.dropHotkeyPressedRoute(
            gesture: .tap,
            phase: .deliveryFailed,
            mode: .fast,
            hasStreamingSession: false
        )
        XCTAssertEqual(route, .discardFailedTakeAndStart)
    }

    func test_dropFlowRoute_delivery_failed_discards_failed_take_and_starts() {
        // The shared decision function must also map `.deliveryFailed` to the
        // discard-and-start route (was grouped with `.finishing` → `.noop`).
        for mode in TranscriptionMode.allCases {
            let route = AppDelegate.dropFlowRoute(
                phase: .deliveryFailed,
                mode: mode,
                hasStreamingSession: false
            )
            XCTAssertEqual(
                route, .discardFailedTakeAndStart,
                "Expected discard-and-start for .deliveryFailed mode=\(mode)"
            )
        }
    }

    func test_finishing_phase_stays_noop_during_recovery() {
        // Regression guard for the `.finishing`/`.deliveryFailed` split: while
        // batch recovery is IN FLIGHT (`.finishing`) a Drop press must NOT
        // interrupt it — only the TERMINAL `.deliveryFailed` is escapable.
        for mode in TranscriptionMode.allCases {
            for hasSession in [false, true] {
                let route = AppDelegate.dropFlowRoute(
                    phase: .finishing,
                    mode: mode,
                    hasStreamingSession: hasSession
                )
                XCTAssertEqual(
                    route, .noop,
                    "Expected noop for .finishing mode=\(mode) hasSession=\(hasSession)"
                )
            }
        }
    }

    // MARK: - In-flight phases → no-op (existing contract)

    func test_transcribing_phase_is_noop_regardless_of_mode() {
        // Batch/HTTP transcription in flight (no session, not setting up a
        // stream) stays a no-op — same as before. Only the streaming-setup
        // window records a pending stop.
        for mode in TranscriptionMode.allCases {
            for hasSession in [false, true] {
                let route = AppDelegate.dropFlowRoute(
                    phase: .transcribing,
                    mode: mode,
                    hasStreamingSession: hasSession,
                    isStreamingSetupInProgress: false
                )
                XCTAssertEqual(
                    route, .noop,
                    "Expected noop for .transcribing mode=\(mode) hasSession=\(hasSession)"
                )
            }
        }
    }

    func test_verifying_phase_is_noop_regardless_of_mode() {
        for mode in TranscriptionMode.allCases {
            for hasSession in [false, true] {
                let route = AppDelegate.dropFlowRoute(
                    phase: .verifying,
                    mode: mode,
                    hasStreamingSession: hasSession
                )
                XCTAssertEqual(
                    route, .noop,
                    "Expected noop for .verifying mode=\(mode) hasSession=\(hasSession)"
                )
            }
        }
    }

    func test_inserting_phase_is_noop_regardless_of_mode() {
        for mode in TranscriptionMode.allCases {
            for hasSession in [false, true] {
                let route = AppDelegate.dropFlowRoute(
                    phase: .inserting,
                    mode: mode,
                    hasStreamingSession: hasSession
                )
                XCTAssertEqual(
                    route, .noop,
                    "Expected noop for .inserting mode=\(mode) hasSession=\(hasSession)"
                )
            }
        }
    }

    // MARK: - Task 4: degraded → batch-recover decision (pure)

    func test_batch_recovery_runs_with_audio_and_transcriber() {
        // Happy path: a degraded turn that retained audio and has the local
        // batch transcriber available must attempt batch recovery.
        XCTAssertTrue(AppDelegate.shouldAttemptBatchRecovery(
            hasAudio: true,
            hasBatchTranscriber: true
        ))
    }

    func test_batch_recovery_skipped_without_audio() {
        // Empty retained PCM → nothing to transcribe. The router must fail to
        // idle WITHOUT pasting (no empty paste onto the focused field), even if
        // the batch transcriber is available.
        XCTAssertFalse(AppDelegate.shouldAttemptBatchRecovery(
            hasAudio: false,
            hasBatchTranscriber: true
        ))
    }

    func test_batch_recovery_skipped_without_batch_transcriber() {
        // Local model not downloaded → can't batch-transcribe. Fall to the
        // salvage rungs without a batch attempt.
        XCTAssertFalse(AppDelegate.shouldAttemptBatchRecovery(
            hasAudio: true,
            hasBatchTranscriber: false
        ))
        XCTAssertFalse(AppDelegate.shouldAttemptBatchRecovery(
            hasAudio: false,
            hasBatchTranscriber: false
        ))
    }

    // MARK: - Task 4: degraded router wiring (source inspection)
    //
    // `handleStreamingResult` / `recoverViaBatch` are private instance methods
    // on the AppKit-bound `AppDelegate`, which no test instantiates (it owns an
    // `AutoPasteEngine`, event monitors, etc.). The batch-recover decision is
    // covered as a pure function above; here we pin the integration wiring by
    // source inspection — the same pattern `OnboardingWindowControllerTests`
    // uses for AppDelegate drop-delivery wiring.

    func test_degraded_result_routes_to_batch_recovery() throws {
        let source = try appDelegateSource()

        // The interim Task-3 stub is gone: a degraded turn must route through the
        // unified delivery resolver. After the Task-3 unification this is
        // `resolveViaSink` (→ resolveDelivery ladder → batch recovery), shared
        // with the .transcript path — NOT a direct recoverViaBatch call (that is
        // now the manual-retry entry point only).
        XCTAssertTrue(
            source.contains("case .transcript, .endpointDetected, .degraded:"),
            "A .degraded result must share the unified resolver switch case."
        )
        XCTAssertTrue(
            source.contains("await resolveViaSink(result: result, stopRequested: stopRequested, capturedPCM: capturedPCM"),
            "A .degraded result must route through resolveViaSink with the stop flag + captured PCM."
        )
        XCTAssertFalse(
            source.contains("batch recovery not yet wired (Task 4)"),
            "The interim Task-3 .degraded stub must be replaced by the real router."
        )
    }

    func test_failed_turn_skips_resolver_when_resilient_off() throws {
        let source = try appDelegateSource()
        // Flag-off parity / rollback guarantee: the resolver's recovery rungs
        // (batch + raw-partial salvage) ARE the resilient-delivery feature. With
        // the flag off, a non-veto streaming `.failed` must take the
        // pre-resilient path (fail to idle), NOT route through `resolveViaSink`.
        // Otherwise turning the flag off would not fully disable the new
        // delivery behavior (the audio tee + UI partial are populated either
        // way, so the resolver would still salvage/batch-recover).
        XCTAssertTrue(
            source.contains("if !AgentFeatureGate.resilientDropDeliveryEnabled {"),
            "handleStreamingResult must short-circuit .failed to idle when resilient delivery is off (flag-off parity)."
        )
    }

    func test_abnormal_transcript_without_stop_batch_recovers() throws {
        // Long-hold truncation fix: a `.transcript` that resolved WITHOUT a user
        // stop (the upstream/provider closed the stream mid-hold — e.g. ElevenLabs'
        // keepalive cutting a long dictation at ~40 s) must route to batch recovery
        // of the captured audio, NOT paste the truncated realtime fragment. The
        // wiring is handleStreamingResult → resolveViaSink(stopRequested:) →
        // resolveDelivery, whose abnormal branch falls into recoverOrSalvage.
        let source = try appDelegateSource()
        // resolveViaSink must thread the stop flag into the resolver — otherwise
        // the resolver's `stopRequested` defaults to true and the abnormal branch
        // is dead code (the bug returns silently).
        XCTAssertTrue(
            source.contains("result: result, stopRequested: stopRequested,"),
            "resolveViaSink must thread stopRequested into resolveDelivery."
        )
        // The resolver routes an abnormal (no-stop) `.transcript` to batch recovery.
        XCTAssertTrue(
            source.contains("if case .transcript = result, !stopRequested {"),
            "resolveDelivery must batch-recover an abnormal .transcript (no user stop), not deliver the fragment."
        )
    }

    func test_captured_pcm_snapshotted_before_session_cleared() throws {
        let source = try appDelegateSource()

        guard let captureRange = source.range(
            of: "let capturedPCM = streamingSession?.capturedAudioPCM16() ?? Data()"
        ) else {
            XCTFail("handleStreamingResult must snapshot capturedAudioPCM16() for the degraded path.")
            return
        }
        guard let clearRange = source.range(
            of: "streamingSession = nil",
            range: captureRange.upperBound..<source.endIndex
        ) else {
            XCTFail("handleStreamingResult must still clear streamingSession.")
            return
        }
        XCTAssertLessThan(
            captureRange.lowerBound,
            clearRange.lowerBound,
            "The captured PCM must be snapshotted BEFORE streamingSession is set to nil."
        )
    }

    func test_local_streaming_result_routes_post_processing_by_cleanup_route() throws {
        let source = try appDelegateSource()

        // ROO-257: local STT no longer bypasses cleanup unconditionally. It
        // recognizes the local session, then resolves the cleanup route to
        // decide (Smart + usable route → run on-device/BYOK cleanup; Fast or
        // no usable LLM route → bypass to a raw, offline paste).
        XCTAssertTrue(
            source.contains("let isLocalTranscription = streamingSession is LocalTranscriptionSession"),
            "handleStreamingResult must recognize the local STT route before clearing the session."
        )
        XCTAssertTrue(
            source.contains("Self.localTranscriptionBypassesPostProcessing("),
            "Local delivery must decide bypass-vs-cleanup via the route-aware helper."
        )
        XCTAssertTrue(
            source.contains("postProcessor?.cleanupRouteForDrop()"),
            "The local bypass decision must consult the resolved cleanup route."
        )
        XCTAssertTrue(
            source.contains("bypassesPostProcessing: bypassesPostProcessing"),
            "Local streaming delivery must thread the bypass flag into the delivery sink."
        )
        XCTAssertTrue(
            source.contains("or when no LLM route is configured"),
            "The raw-paste branch must keep Drop usable without any LLM route."
        )
    }

    // Task 7 refactor: the transcribe→decide→deliver tail moved into the
    // closure-driven `runBatchRecovery` state machine so its arms are covered
    // BEHAVIORALLY (success / batch-throws→.deliveryFailed+retain / empty / no
    // input / retry) in `DropBatchRecoveryTests` without instantiating the
    // AppKit-bound `AppDelegate`. This source-inspection check is now reduced to
    // pinning the WIRING that the behavioral tests cannot reach: that
    // `recoverViaBatch` delegates to the seam and binds the real transcribe +
    // paste-tail side effects.
    func test_recoverViaBatch_delegates_to_batch_recovery_seam() throws {
        let source = try appDelegateSource()

        guard let fnRange = source.range(
            of: "private func recoverViaBatch(pcm: Data, targetApp: String?, targetPID: pid_t?) async"
        ) else {
            XCTFail("recoverViaBatch(pcm:targetApp:targetPID:) must exist with the Task-7-stable signature.")
            return
        }
        let body = String(source[fnRange.lowerBound...])

        // The wrapper drives the testable state machine instead of inlining the
        // transcribe→decide→deliver logic.
        XCTAssertTrue(
            body.contains("await Self.runBatchRecovery("),
            "recoverViaBatch must delegate to the testable runBatchRecovery seam."
        )

        // It still binds the real on-device batch transcribe of the retained PCM …
        XCTAssertTrue(body.contains("let transcriber = localBatchTranscriber"))
        XCTAssertTrue(body.contains("transcriber.transcribe("))

        // … and delivers through the SHARED `dropDeliverySink` (the same sink the
        // unified resolver path uses), whose `deliver` closure routes a recovered
        // transcript through the normal post-process + paste tail — so a
        // recovered turn pastes exactly once via the SAME tail as the live path.
        XCTAssertTrue(
            body.contains("sink: dropDeliverySink("),
            "recoverViaBatch must deliver through the shared dropDeliverySink."
        )
        XCTAssertTrue(
            source.contains("await self.runPostProcessAndPaste("),
            "dropDeliverySink.deliver must route through the normal post-process + paste tail."
        )
        // And it arms the manual-retry state on a retained-audio failure.
        XCTAssertTrue(body.contains("pendingRetryPCM ="))
        XCTAssertTrue(body.contains("retryPendingDelivery"))
    }

    // The behavioral arms live in `runBatchRecovery`; pin that the seam exists
    // with the contractual reasons + the `.deliveryFailed`/retain failure arm.
    func test_runBatchRecovery_seam_encodes_contractual_arms() throws {
        let source = try appDelegateSource()

        guard let fnRange = source.range(
            of: "static func runBatchRecovery("
        ) else {
            XCTFail("runBatchRecovery seam must exist for behavioral testing.")
            return
        }
        let body = String(source[fnRange.lowerBound...])

        // No-input guard → no paste, no retry.
        XCTAssertTrue(body.contains("shouldAttemptBatchRecovery("))
        XCTAssertTrue(body.contains("\"degraded_no_audio\""))
        // Calm working state during recovery.
        XCTAssertTrue(body.contains("setPhase(.finishing)"))
        // Empty recovered transcript → no paste, no retry.
        XCTAssertTrue(body.contains("streamingTranscriptIsEmpty(raw)"))
        XCTAssertTrue(body.contains("\"degraded_empty\""))
        // Total offline → retain audio + .deliveryFailed, never paste.
        XCTAssertTrue(body.contains("retainForRetry(pcm)"))
        XCTAssertTrue(body.contains("setPhase(.deliveryFailed)"))
        XCTAssertTrue(body.contains("\"degraded_batch_failed\""))
    }

    // MARK: - Task 9: resilient scoping (source inspection)
    //
    // `makeStreamingSession` is a private AppDelegate method; the scoping
    // contract (Drop gets the flag value; agent-voice and Google get false) is
    // structural and can't be driven as a behavioral test without instantiating
    // the AppKit-bound `AppDelegate`. Source inspection is the right tool here:
    // it pins the three call-site values precisely. If any call site drifts, the
    // corresponding assertion fails with an actionable error message.

    func test_drop_callsite_passes_resilient_flag() throws {
        let source = try appDelegateSource()
        XCTAssertTrue(
            source.contains("makeStreamingSession(resilient: AgentFeatureGate.resilientDropDeliveryEnabled)"),
            "Drop call site must pass resilient: AgentFeatureGate.resilientDropDeliveryEnabled — not a literal or a default."
        )
    }

    func test_agent_voice_callsite_passes_resilient_false() throws {
        let source = try appDelegateSource()
        // The closure body is: `return try? await self.makeStreamingSession(resilient: false)`.
        // There must be exactly two `resilient: false` occurrences (agent-voice +
        // Google-search); we check the shared comment anchor instead so this
        // assertion doesn't depend on order.
        XCTAssertTrue(
            source.contains("resilient: false — agent-voice must never resolve .degraded"),
            "agentVoiceStreamFactory must pass resilient: false with the scoping comment."
        )
    }

    func test_google_search_callsite_passes_resilient_false() throws {
        let source = try appDelegateSource()
        XCTAssertTrue(
            source.contains("resilient: false — Google-search must never resolve .degraded"),
            "GoogleSearchController voiceSessionFactory must pass resilient: false with the scoping comment."
        )
    }

    // MARK: - Manual Retry robustness (Task 7 — no permanent no-op, no clobber)

    func test_retry_gate_blocks_concurrent_and_empty() {
        // A retry may begin ONLY when none is already in flight AND there is
        // retained audio. The old design consumed the PCM up front, so a
        // recovery that hung / never re-armed turned Retry into a permanent
        // silent no-op (phase stuck `.deliveryFailed`, `pendingRetryPCM == nil`).
        XCTAssertTrue(
            AppDelegate.shouldBeginRetry(inFlight: false, hasPendingAudio: true),
            "Retry with retained audio and nothing in flight must begin."
        )
        XCTAssertFalse(
            AppDelegate.shouldBeginRetry(inFlight: true, hasPendingAudio: true),
            "A second Retry while one is in flight must be blocked (no double-launch / no clobber)."
        )
        XCTAssertFalse(
            AppDelegate.shouldBeginRetry(inFlight: false, hasPendingAudio: false),
            "Retry with nothing retained is a no-op."
        )
        XCTAssertFalse(
            AppDelegate.shouldBeginRetry(inFlight: true, hasPendingAudio: false)
        )
    }

    func test_retry_clears_stale_take_when_outcome_did_not_rearm() throws {
        // Fix C retains the PCM until the OUTCOME decides. The non-re-arming
        // retry outcomes (no-audio / empty / unauthorized) idle the phase
        // WITHOUT calling clearPendingRetry — which, now that the PCM is no
        // longer consumed up front, would leave captured audio + an AX target
        // retained in memory with no retry UI (a leak Fix C would otherwise
        // introduce). The retry Task drops the take whenever the outcome did
        // NOT re-arm `.deliveryFailed`.
        let source = try appDelegateSource()
        guard let fnRange = source.range(of: "func retryPendingDelivery()") else {
            XCTFail("retryPendingDelivery() must exist.")
            return
        }
        let body = String(source[fnRange.lowerBound...].prefix(1500))
        XCTAssertTrue(
            body.contains("AppState.shared.phase != .deliveryFailed"),
            "The retry Task must detect a non-re-armed outcome."
        )
        XCTAssertTrue(
            body.contains("discardPendingRetry()"),
            "The retry Task must drop the retained take when the outcome did not re-arm."
        )
    }

    func test_retry_uses_inflight_gate_not_upfront_pcm_consumption() throws {
        let source = try appDelegateSource()
        guard let fnRange = source.range(of: "func retryPendingDelivery()") else {
            XCTFail("retryPendingDelivery() must exist.")
            return
        }
        let body = String(source[fnRange.lowerBound...].prefix(900))
        // The fragile "consume PCM up front" line is gone: the PCM is retained
        // until the recovery OUTCOME decides (success → clearPendingRetry,
        // failure → retainForRetry), so a hung recovery can't strand Retry.
        XCTAssertFalse(
            body.contains("pendingRetryPCM = nil"),
            "retryPendingDelivery must not nil the retained PCM up front."
        )
        // Double-launch (and the Fix-A-exposed stale-retry-over-new-turn clobber)
        // is prevented by an explicit in-flight gate instead.
        XCTAssertTrue(
            body.contains("shouldBeginRetry("),
            "retryPendingDelivery must gate on shouldBeginRetry."
        )
        XCTAssertTrue(
            body.contains("retryInFlight = true"),
            "retryPendingDelivery must mark the retry in flight."
        )
        // It closes the race window synchronously: a fast second press (or a
        // fresh Drop) must see an in-flight phase, not the escapable terminal.
        XCTAssertTrue(
            body.contains("AppState.shared.phase = .finishing"),
            "retryPendingDelivery must surface .finishing synchronously to close the race window."
        )
    }

    // MARK: - Stale streaming-result guard (Task 7 — defense-in-depth for B)

    func test_streaming_result_applies_only_for_the_current_generation() {
        // A resolved `session.run()` applies its result only while it still owns
        // the streaming slot. A newer turn bumps `streamingSetupGeneration`, so a
        // stale continuation (different generation) must be ignored rather than
        // clobber the new turn's phase / session / telemetry.
        XCTAssertTrue(
            AppDelegate.shouldApplyStreamingResult(resultGeneration: 7, currentGeneration: 7),
            "The current turn's result must apply."
        )
        XCTAssertFalse(
            AppDelegate.shouldApplyStreamingResult(resultGeneration: 7, currentGeneration: 8),
            "A stale result (a newer turn claimed the slot) must be ignored."
        )
        XCTAssertFalse(
            AppDelegate.shouldApplyStreamingResult(resultGeneration: 6, currentGeneration: 8)
        )
    }

    func test_handleStreamingResult_guards_on_generation() throws {
        let source = try appDelegateSource()
        // The run() result is dispatched with the generation captured when the
        // session started …
        XCTAssertTrue(
            source.contains("await handleStreamingResult(result, startedAt: startedAt, generation: setupGeneration)"),
            "session.run()'s result must be dispatched with its turn generation."
        )
        // … and handleStreamingResult ignores it if a newer turn claimed the slot.
        guard let fnRange = source.range(of: "func handleStreamingResult(") else {
            XCTFail("handleStreamingResult must exist.")
            return
        }
        let body = String(source[fnRange.lowerBound...].prefix(900))
        XCTAssertTrue(
            body.contains("shouldApplyStreamingResult("),
            "handleStreamingResult must guard the stale-generation case before mutating phase/session."
        )
    }

    // MARK: - .discardFailedTakeAndStart handler wiring (source inspection)
    //
    // `handleDropHotkeyRoute` is a private AppDelegate method; the side-effect
    // wiring (clear retry audio → start a fresh turn) is pinned by source
    // inspection, the same pattern the degraded-router checks above use.

    func test_discard_failed_take_route_drops_retained_audio_then_starts() throws {
        let source = try appDelegateSource()

        // A dedicated helper drops BOTH the retained retry PCM and its paste
        // target — otherwise a later Retry could resurrect the abandoned take
        // and paste it over the new turn's destination.
        guard let helperRange = source.range(of: "private func discardPendingRetry()") else {
            XCTFail("discardPendingRetry() helper must exist to drop the parked take.")
            return
        }
        let helperBody = String(source[helperRange.lowerBound...].prefix(400))
        XCTAssertTrue(
            helperBody.contains("pendingRetryPCM = nil"),
            "discardPendingRetry must clear the retained PCM."
        )
        XCTAssertTrue(
            helperBody.contains("pendingRetryTarget = nil"),
            "discardPendingRetry must clear the retained paste target."
        )

        // The route handler must drop the parked take and reach the normal
        // start path via fallthrough to `.startStreamingSession`.
        guard let fnRange = source.range(of: "private func handleDropHotkeyRoute(") else {
            XCTFail("handleDropHotkeyRoute must exist.")
            return
        }
        // Keep enough of the function to include the normal start switch even
        // when a product-profile gate is present before it.
        let fn = String(source[fnRange.lowerBound...].prefix(3000))
        XCTAssertTrue(
            fn.contains("discardPendingRetry()"),
            "handleDropHotkeyRoute must drop the parked take for the escape route."
        )
        guard let caseRange = fn.range(of: "case .discardFailedTakeAndStart:") else {
            XCTFail("handleDropHotkeyRoute must handle .discardFailedTakeAndStart.")
            return
        }
        let afterCase = String(fn[caseRange.upperBound...].prefix(400))
        XCTAssertTrue(
            afterCase.contains("fallthrough"),
            "The escape case must reuse the normal start path via fallthrough to .startStreamingSession."
        )
    }

    private func appDelegateSource() throws -> String {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("AppDelegate.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "AppDelegateDropFlowRouteTests", code: 1)
    }
}
