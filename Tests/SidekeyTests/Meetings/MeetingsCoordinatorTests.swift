import XCTest
@testable import Sidekey

/// Stage 1a skeleton tests for `MeetingsCoordinator`. The coordinator is the
/// wiring shell that subscribes the (still stubbed) detector / pill / recorder
/// / store protocols. At this stage only the feature-flag
/// gate is exercised: `start()` must be a no-op when `MeetingsConfig.isEnabled`
/// is `false`, and must subscribe the injected detector once when `true`.
///
/// Concrete implementations land in Stages 2-9; this test file pins the
/// contract so the rest of the feature can grow on top of a tested skeleton.
@MainActor
final class MeetingsCoordinatorTests: XCTestCase {
    /// In-test isolated `UserDefaults` suite so flipping
    /// `MeetingsConfig.isEnabled` here never leaks into the user's real
    /// preferences or pollutes other tests in the same process.
    private var testDefaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "com.sidekey.meetings.tests.\(UUID().uuidString)"
        // `UserDefaults(suiteName:)` is the documented way to get an
        // isolated defaults store; force-unwrap is safe because the
        // suite name is non-nil and unique per test instance.
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        testDefaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    // MARK: - Feature flag gating

    func test_config_defaults_to_enabled_for_rollout() {
        let config = MeetingsConfig(defaults: testDefaults)

        XCTAssertTrue(
            config.isEnabled,
            "Missing UserDefaults key should run the prod detector by default."
        )
    }

    func test_config_explicit_false_remains_kill_switch() {
        let config = MeetingsConfig(defaults: testDefaults)

        config.isEnabled = false

        XCTAssertFalse(config.isEnabled)
    }

    func test_rounded_duration_seconds_rounds_nonzero_audio_up() {
        XCTAssertEqual(MeetingsCoordinator.roundedDurationSeconds(0), 0)
        XCTAssertEqual(MeetingsCoordinator.roundedDurationSeconds(-1), 0)
        XCTAssertEqual(MeetingsCoordinator.roundedDurationSeconds(.nan), 0)
        XCTAssertEqual(MeetingsCoordinator.roundedDurationSeconds(0.01), 1)
        XCTAssertEqual(MeetingsCoordinator.roundedDurationSeconds(1.0), 1)
        XCTAssertEqual(MeetingsCoordinator.roundedDurationSeconds(1.01), 2)
    }

    func test_start_is_noop_when_disabled() {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = false

        let detector = StubMeetingDetector()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            meetingsEnabled: { true }
        )

        coordinator.start()

        XCTAssertEqual(detector.subscribeCallCount, 0)
    }

    func test_start_wires_detector_when_enabled() {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubMeetingDetector()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            meetingsEnabled: { true }
        )

        coordinator.start()

        XCTAssertEqual(detector.subscribeCallCount, 1)
    }

    // MARK: - Per-user meetingsEnabled gate (E4)

    /// OFF path: when the per-user meetingsEnabled flag is false, start()
    /// must NOT subscribe the detector even if the ops kill-switch is on.
    func test_start_noOp_whenMeetingsDisabled() {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubMeetingDetector()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            meetingsEnabled: { false }
        )

        coordinator.start()

        XCTAssertEqual(detector.subscribeCallCount, 0,
                       "start() must be a no-op when per-user meetingsEnabled is false")
    }

    /// ON path: when both the ops kill-switch and the per-user flag are
    /// true, start() must subscribe the detector exactly once.
    func test_start_subscribes_whenMeetingsEnabled() {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubMeetingDetector()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            meetingsEnabled: { true }
        )

        coordinator.start()

        XCTAssertEqual(detector.subscribeCallCount, 1,
                       "start() must subscribe the detector when both ops flag and per-user flag are true")
    }

    /// stop() must cancel the detector subscription without aborting an
    /// active recording — the coordinator becomes silent to new detector
    /// events after stop().
    func test_stop_cancelsDetectorConsumer() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { true }
        )
        coordinator.start()

        // Verify wired: trigger should propagate before stop().
        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))
        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 1.0)

        // Dismiss so pill goes back to hidden.
        await pill._testTapDismiss()
        await waitFor(condition: { pill.state == .hidden }, timeout: 1.0)

        // Now stop() — detector subscription must be cancelled.
        coordinator.stop()

        // Give a brief window for any stale tasks to drain.
        try await Task.sleep(nanoseconds: 20_000_000)

        // Feed another trigger: with the consumer cancelled it must NOT
        // transition the pill to .suggesting.
        detector.feed(.triggered(meetingId: UUID()))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(pill.state, .hidden,
                       "After stop(), detector events must not reach the pill")
    }

    // MARK: - E5 reactivity: off → on cycle re-subscribes

    /// Regression test for the capability opt-in gating off→on cycle bug (E5).
    ///
    /// `reconcileCapabilities()` calls `stop()` when meetings is disabled and
    /// `start()` when it is enabled.  Before the fix, `stop()` cancelled the
    /// detector consumer but did NOT reset `started`, so the second `start()`
    /// hit the idempotency guard and silently skipped re-subscription.
    ///
    /// This test asserts that after a `stop()` → `start()` cycle:
    /// (a) the detector's `subscribeCallCount` reaches 2 (re-subscribed), and
    /// (b) a detector event fed AFTER the second `start()` propagates to the
    ///     pill (consumer is live).
    func test_stop_then_start_resubscribes_detector() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { true }
        )

        // First start() — wires the detector.
        coordinator.start()
        XCTAssertEqual(detector.subscribeCallCount, 1,
                       "precondition: first start() must subscribe once")

        // Disable — stop() cancels consumer.
        coordinator.stop()

        // Re-enable — second start() must re-subscribe (not skip via guard).
        coordinator.start()
        XCTAssertEqual(detector.subscribeCallCount, 2,
                       "start() after stop() must re-subscribe the detector")

        // Verify the consumer is live: an event after the second start() must
        // reach the pill.
        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))

        await waitFor(condition: {
            if case .suggesting(let id, _) = pill.state { return id == meetingId }
            return false
        }, timeout: 1.0)

        if case .suggesting(let id, _) = pill.state {
            XCTAssertEqual(id, meetingId,
                           "Detector event after off→on cycle must reach the pill")
        } else {
            XCTFail("Pill must enter .suggesting after off→on cycle; got \(pill.state)")
        }
    }

    // MARK: - E5 pill-consumer leak regression (off→on cycle)

    /// Regression test for the pillEventConsumer leak introduced by the E5
    /// stop() fix that cancelled detectorEventConsumer but NOT pillEventConsumer.
    ///
    /// Bug: stop() left pillEventConsumer #1 alive. A subsequent start() then
    /// spawned pillEventConsumer #2 while #1 remained alive and draining the
    /// unicast pill.events AsyncStream. Two Tasks concurrently draining a
    /// unicast stream causes nondeterministic event delivery.
    ///
    /// Fix: stop() must cancel pillEventConsumer before resetting `started`.
    ///
    /// Determinism strategy: the race between stale and fresh consumers is
    /// inherently nondeterministic for behavioral assertions. Instead, we
    /// assert the structural invariant using the test-visible
    /// `pillConsumerGeneration` counter (incremented each time start() spawns
    /// a pill consumer) COMBINED with the post-stop behavorial contract:
    /// after stop(), a dismiss event issued to the pill must NOT trigger
    /// buffer.gc() — because the consumer should have been cancelled. With
    /// the bug (consumer not cancelled), the stale consumer is still alive
    /// and processes the post-stop dismiss, calling gc(). With the fix,
    /// gc() is NOT called after stop() because the consumer is cancelled.
    ///
    /// This makes the test deterministic: one specific observable event
    /// (gc() fired after stop()) is the RED condition.
    func test_stop_then_start_does_not_leak_pill_consumer() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { true }
        )

        // First start() — wires both consumers.
        coordinator.start()
        XCTAssertEqual(coordinator.pillConsumerGeneration, 1,
                       "first start() must spawn exactly one pill consumer (generation == 1)")

        // Drive the pill into .suggesting so _testTapDismiss() will fire.
        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))
        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 1.0)

        // Stop the coordinator — this should cancel the pill consumer.
        // After stop(), a dismiss event must NOT be processed (consumer is dead).
        coordinator.stop()

        // Capture gc count BEFORE issuing the post-stop dismiss.
        let gcAfterStop = buffer.gcCalls
        let cooldownAfterStop = detector.cooldownCalls

        // Issue a dismiss. With the BUG: the stale pillEventConsumer #1 is
        // still alive and will call handlePillEvent(.dismiss) → buffer.gc()
        // and detector.engageCooldown(). With the FIX: the consumer is
        // cancelled, so nobody handles the event.
        //
        // Note: the pill is still in .suggesting (stop() doesn't touch pill
        // state — it only tears down the consumer Task). So _testTapDismiss()
        // guard passes and the event IS yielded to pill.events.
        await pill._testTapDismiss()

        // Give a window for any stale consumer to process the event.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(buffer.gcCalls, gcAfterStop,
                       "After stop(), a dismiss must NOT call buffer.gc() — the pill consumer must be cancelled (bug: stale consumer still processes events)")
        XCTAssertEqual(detector.cooldownCalls, cooldownAfterStop,
                       "After stop(), a dismiss must NOT engage cooldown — the pill consumer must be cancelled")

        // Verify generation count: start() must have spawned exactly one consumer.
        XCTAssertEqual(coordinator.pillConsumerGeneration, 1,
                       "precondition: only one pill consumer was ever spawned")
    }

    /// Regression guard for the founder's exact sequence: capability ON →
    /// `start()` → capability OFF → `stop()` → ⌥M again. The enable nudge must
    /// STILL appear the second time (the "one-shot enable-nudge" symptom must
    /// NOT reproduce here) and the pill consumer must be re-armed, not leaked.
    ///
    /// This is the post-`stop()` cycle — distinct from
    /// `test_manual_toggle_capability_off_shows_prompt_and_accept_opts_in`
    /// (fresh: capability OFF from launch). It pins that `stop()` cancelling +
    /// nilling `pillEventConsumer` lets `ensurePillConsumer()` spin a FRESH
    /// consumer (generation 2) on the next capability-off toggle, so
    /// Accept/Skip on the second nudge still has a drainer. The test is green
    /// as written (the coordinator is correct today); it exists to keep a
    /// future `stop()` / `ensurePillConsumer` refactor from regressing the
    /// re-arm.
    func test_manual_toggle_after_stop_shows_prompt_again_and_rearms_consumer() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        // Per-user capability flips through the injected seam, mirroring the
        // Settings → Other toggle wired to `UserPreferencesCache` in prod.
        var capabilityOn = true
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { capabilityOn }
        )

        // Capability ON → start() wires exactly one pill consumer.
        coordinator.start()
        XCTAssertEqual(coordinator.pillConsumerGeneration, 1,
                       "first start() with capability on must spawn one pill consumer")

        // User disables Meeting Notes in Settings → reconcile calls stop(),
        // which cancels + nils the consumer.
        capabilityOn = false
        coordinator.stop()

        // ⌥M again with the capability now OFF: the standard enable nudge must
        // reappear (NOT a silent no-op / stuck one-shot).
        await coordinator.toggleManualRecording()

        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 1.0)

        guard case .suggesting = pill.state else {
            return XCTFail("post-stop ⌥M must re-show the enable nudge; got \(pill.state)")
        }
        // A fresh consumer was spun up (generation advanced) — the previous one
        // was cancelled by stop(), so this is a re-arm, not a leak of #1.
        XCTAssertEqual(coordinator.pillConsumerGeneration, 2,
                       "capability-off toggle after stop() must spin a FRESH pill consumer (generation 2), not reuse or leak the cancelled one")

        // And the fresh consumer actually drains: a dismiss issued to the pill
        // must reach the coordinator (buffer.gc + detector cooldown), proving
        // the re-armed consumer is live — the enable nudge is not inert.
        let gcBefore = buffer.gcCalls
        let cooldownBefore = detector.cooldownCalls
        await pill._testTapDismiss()
        await waitFor(condition: {
            buffer.gcCalls > gcBefore && detector.cooldownCalls > cooldownBefore
        }, timeout: 1.0)
        XCTAssertGreaterThan(buffer.gcCalls, gcBefore,
                             "dismiss on the re-shown nudge must reach the fresh consumer (buffer.gc)")
        XCTAssertGreaterThan(detector.cooldownCalls, cooldownBefore,
                             "dismiss on the re-shown nudge must reach the fresh consumer (detector cooldown)")
    }

    // MARK: - Protocol smoke test

    /// Smoke test: forces the compiler to materialise every protocol surface
    /// the Stage 1a skeleton exposes. If any signature changes between
    /// stages (e.g. concrete detector adds an argument), this test stops
    /// compiling and we revisit the contract intentionally.
    func test_meetings_feature_protocols_compile() {
        let detector: MeetingDetectorProtocol = StubMeetingDetector()
        let pill: MeetingPillDisplaying = StubMeetingPill()
        let recorder: MeetingRecording = StubMeetingRecorder()
        let store: MeetingsStoring = StubMeetingsStore()

        // Type-erase via Any so the compiler does not strip the bindings
        // as unused. The assertion is purely a "the bindings exist"
        // check; the real behaviour lives in Stages 2-9.
        let surfaces: [Any] = [detector, pill, recorder, store]
        XCTAssertEqual(surfaces.count, 4)
    }

    // MARK: - Manual toggle: capability-off enable prompt (⌥M / Record tile)

    /// ⌥M (or the Record tile) with the Meeting Notes capability OFF must not
    /// be a silent no-op: `toggleManualRecording()` shows the standard nudge
    /// as an enable prompt — spinning up the pill consumer that `start()`
    /// never launched (it is gated on the capability) — and accepting the
    /// nudge flips the capability on (opt-in) and starts the recorder in the
    /// same gesture.
    func test_manual_toggle_capability_off_shows_prompt_and_accept_opts_in() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let mic = TestMicSource()
        let sys = TestSystemSource()
        let micInUse = TestMicInUse()
        var factoryCalls: [UUID] = []
        let factory: MeetingsCoordinator.RecorderFactory = { meetingId in
            factoryCalls.append(meetingId)
            return MeetingRecorder(
                micSource: mic,
                systemSource: sys,
                micInUseProbe: micInUse,
                stagingRoot: stagingRoot,
                chunkRotationSeconds: 60,
                autoEndMicReleasedSeconds: 60,
                sampleRate: 16_000
            )
        }

        // Capability starts OFF and flips through the injected opt-in seam —
        // the same seam production wires to `UserPreferencesCache`.
        var capabilityOn = false
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            recorderFactory: factory,
            meetingsEnabled: { capabilityOn },
            enableMeetingsCapability: { capabilityOn = true }
        )
        // Mirrors production: AppDelegate always calls start(), but with the
        // capability off it is a gated no-op (no consumers spun up).
        coordinator.start()

        await coordinator.toggleManualRecording()

        guard case .suggesting = pill.state else {
            return XCTFail("capability-off toggle must show the enable nudge; got \(pill.state)")
        }
        XCTAssertFalse(coordinator.isRecording, "recording must not start before the user accepts")
        XCTAssertFalse(capabilityOn, "capability must not flip before the user accepts")

        await pill._testTapAccept()

        await waitFor(
            condition: { capabilityOn && coordinator.isRecording },
            timeout: 2.0
        )
        XCTAssertTrue(capabilityOn, "accepting the enable nudge IS the opt-in")
        XCTAssertEqual(factoryCalls.count, 1, "accept must start the recorder")
        if case .recording = pill.state {} else {
            XCTFail("pill must be .recording after accept; got \(pill.state)")
        }
    }

    // MARK: - Stage 3 wiring integration test

    /// Stage 3 integration: end-to-end wire-up of detector → pill +
    /// buffer, including the reverse path of pill dismiss → buffer.gc +
    /// detector.engageCooldown.
    ///
    /// The test exercises four observable contracts:
    ///
    /// 1. Feeding `.triggered` onto the detector's event stream causes
    ///    the buffer to `start()` and the pill to enter `.suggesting`.
    /// 2. Hitting the pill's No-button (test seam) causes the buffer to
    ///    `gc()` AND the detector's `engageCooldown()` to be called.
    /// 3. Hitting the pill's Yes-button causes the coordinator to emit
    ///    an `AcceptEvent` on its `acceptEvents` stream carrying the
    ///    snapshot bytes for Stage 4 MeetingRecorder.
    /// 4. The feature-flag is still respected — with the flag off the
    ///    wiring does nothing, even when pill and buffer are injected.
    // MARK: - Stage 4: accept event spins up recorder, transitions pill

    /// Stage 4 contract: when the pill emits `.accept`, the coordinator
    /// (a) yields an AcceptEvent on its own stream (Stage 3 contract,
    /// preserved), AND (b) calls the recorder factory with the
    /// meetingId, calls `start()` on the returned recorder, transitions
    /// the pill to `.recording`, and the `isRecording` flag goes true.
    func test_accept_event_starts_recorder_and_transitions_pill_to_recording() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let mic = TestMicSource()
        let sys = TestSystemSource()
        let micInUse = TestMicInUse()

        // Capture the factory invocation so the test can assert the
        // coordinator went through the recorder path on accept.
        var factoryCalls: [UUID] = []
        let factory: MeetingsCoordinator.RecorderFactory = { meetingId in
            factoryCalls.append(meetingId)
            return MeetingRecorder(
                micSource: mic,
                systemSource: sys,
                micInUseProbe: micInUse,
                stagingRoot: stagingRoot,
                chunkRotationSeconds: 60,
                autoEndMicReleasedSeconds: 60,
                sampleRate: 16_000
            )
        }

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            recorderFactory: factory,
            meetingsEnabled: { true }
        )
        coordinator.start()

        XCTAssertFalse(coordinator.isRecording, "isRecording is false before any accept")

        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))
        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 1.0)

        await pill._testTapAccept()

        await waitFor(
            condition: {
                if case .recording(let id, _, _) = pill.state, id == meetingId {
                    return coordinator.isRecording
                }
                return false
            },
            timeout: 2.0
        )

        XCTAssertEqual(factoryCalls, [meetingId],
                       "Factory must be called exactly once with the accepted meetingId")
        XCTAssertTrue(coordinator.isRecording,
                      "isRecording must flip true after recorder start")
        switch pill.state {
        case .recording(let id, _, _):
            XCTAssertEqual(id, meetingId, "Pill must reflect the recorder's meetingId")
        default:
            XCTFail("Pill must be in .recording after accept; got \(pill.state)")
        }
    }

    /// Stage 4 contract: auto-end watcher fires inside the recorder when
    /// the mic-in-use probe reports `false` for longer than the threshold;
    /// the coordinator observes the FinalizedEvent on the recorder's
    /// stream, clears `isRecording`, hides the pill.
    func test_auto_end_finalizes_recorder_and_hides_pill() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-coordinator-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let mic = TestMicSource()
        let sys = TestSystemSource()
        let micInUse = TestMicInUse()
        let factory: MeetingsCoordinator.RecorderFactory = { _ in
            // Short auto-end threshold (and no startup grace) so the
            // test does not wait 10s.
            MeetingRecorder(
                micSource: mic,
                systemSource: sys,
                micInUseProbe: micInUse,
                stagingRoot: stagingRoot,
                chunkRotationSeconds: 60,
                autoEndMicReleasedSeconds: 0.1,
                autoEndStartupGraceSeconds: 0,
                sampleRate: 16_000
            )
        }

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            recorderFactory: factory,
            meetingsEnabled: { true }
        )
        coordinator.start()

        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))
        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 1.0)
        await pill._testTapAccept()

        // Wait until the recorder actually starts.
        await waitFor(condition: {
            coordinator.isRecording && {
                if case .recording = pill.state { return true }
                return false
            }()
        }, timeout: 2.0)

        // Model a real call lifecycle. The initial cached `false` is not a
        // meeting-end signal; auto-end arms only after an active mic is later
        // released.
        micInUse.feed(true)
        micInUse.feed(false)

        // Wait for the coordinator to observe FinalizedEvent + clean up.
        await waitFor(condition: {
            !coordinator.isRecording && pill.state == .hidden
        }, timeout: 2.0)

        XCTAssertFalse(coordinator.isRecording,
                       "isRecording must flip false after auto-end FinalizedEvent")
        XCTAssertEqual(pill.state, .hidden,
                       "Pill must be hidden after auto-end finalize")
    }

    /// A rejoin well inside the 3-minute grace is a deliberate user
    /// return — the coordinator must ask via the Reconnect pill, not
    /// resume on its own.
    func test_rejoin_inside_grace_offers_previous_meeting_reconnect() async {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)
        let clock = MovableClock()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { true },
            now: { clock.now }
        )

        let previousId = UUID()
        await coordinator.handleFinalizedEvent(.init(
            meetingId: previousId,
            chunkURLs: [],
            totalDurationSeconds: 42,
            reason: .autoEnd
        ))

        // Well inside the grace period.
        clock.advance(by: 20)

        let freshDetectorId = UUID()
        await coordinator.handleDetectorEvent(.triggered(meetingId: freshDetectorId))

        guard case .suggestingReconnect(
            let shownDetectorId,
            let shownPreviousId,
            let gapSeconds,
            _
        ) = pill.state else {
            return XCTFail("Expected reconnect suggestion, got \(pill.state)")
        }
        XCTAssertEqual(shownDetectorId, freshDetectorId)
        XCTAssertEqual(shownPreviousId, previousId)
        XCTAssertEqual(gapSeconds, 20, accuracy: 0.5)
        XCTAssertLessThan(gapSeconds, MeetingsConfig.reconnectGracePeriodSeconds)
    }

    /// Whytap cannot tell "the user rejoined THIS meeting" from "the user
    /// walked into a different one" — a real Teams → Zoom hop re-fired 7
    /// seconds after the auto-end and got silently glued onto the previous
    /// recording (two meetings, one transcript, one summary). Resuming is
    /// the user's call, so every re-fire inside the grace window asks via
    /// the Notes / Reconnect / Skip pill, however fast it lands.
    func test_immediate_rejoin_after_auto_end_asks_before_resuming() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-rejoin-asks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        // A working factory: the coordinator *could* resume on its own here,
        // so a passing assertion means it chose to ask, not that it failed.
        let mic = TestMicSource()
        let sys = TestSystemSource()
        let micInUse = TestMicInUse()
        let factoryIds = FactoryIdBox()
        let factory: MeetingsCoordinator.RecorderFactory = { meetingId in
            factoryIds.ids.append(meetingId)
            return MeetingRecorder(
                micSource: mic,
                systemSource: sys,
                micInUseProbe: micInUse,
                stagingRoot: stagingRoot,
                chunkRotationSeconds: 60,
                autoEndMicReleasedSeconds: 60,
                sampleRate: 16_000
            )
        }

        let clock = MovableClock()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            pill: pill,
            buffer: buffer,
            recorderFactory: factory,
            meetingsEnabled: { true },
            now: { clock.now }
        )

        let previousId = UUID()
        await coordinator.handleFinalizedEvent(.init(
            meetingId: previousId,
            chunkURLs: [],
            totalDurationSeconds: 21,
            reason: .autoEnd
        ))

        // The gap measured in the field between leaving Teams and the Zoom
        // call re-arming the detector.
        clock.advance(by: 7)
        let freshDetectorId = UUID()
        await coordinator.handleDetectorEvent(.triggered(meetingId: freshDetectorId))

        XCTAssertFalse(
            coordinator.isRecording,
            "an immediate rejoin must not resume the previous recording on its own"
        )
        XCTAssertTrue(
            factoryIds.ids.isEmpty,
            "no recorder may start before the user answers the pill"
        )
        guard case .suggestingReconnect(
            let shownDetectorId,
            let shownPreviousId,
            let gapSeconds,
            _
        ) = pill.state else {
            return XCTFail("Expected reconnect suggestion, got \(pill.state)")
        }
        XCTAssertEqual(shownDetectorId, freshDetectorId)
        XCTAssertEqual(shownPreviousId, previousId)
        XCTAssertEqual(gapSeconds, 7, accuracy: 0.5)
    }

    /// While a user-accepted Reconnect is still suspended inside
    /// `recorder.start()` the coordinator has no `activeRecorder` yet — a
    /// manual ⌥M toggle in that window must treat the start as in flight
    /// (no-op), not spin up a second recorder that later fights the first
    /// over coordinator ownership.
    func test_manual_toggle_during_reconnect_start_does_not_double_start() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-inflight-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let gatedMic = GatedMicSource()
        let sys = TestSystemSource()
        let micInUse = TestMicInUse()
        let factoryIds = FactoryIdBox()
        let factory: MeetingsCoordinator.RecorderFactory = { meetingId in
            factoryIds.ids.append(meetingId)
            return MeetingRecorder(
                micSource: gatedMic,
                systemSource: sys,
                micInUseProbe: micInUse,
                stagingRoot: stagingRoot,
                chunkRotationSeconds: 60,
                autoEndMicReleasedSeconds: 60,
                sampleRate: 16_000
            )
        }

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            pill: pill,
            buffer: buffer,
            recorderFactory: factory,
            meetingsEnabled: { true }
        )

        let previousId = UUID()
        await coordinator.handleFinalizedEvent(.init(
            meetingId: previousId,
            chunkURLs: [],
            totalDurationSeconds: 21,
            reason: .autoEnd
        ))

        // The user answered the pill with Reconnect; its recorder start is
        // gated inside the audio stack.
        let reconnect = Task {
            await coordinator.handlePillEvent(.reconnect(
                previousMeetingId: previousId,
                gapSeconds: 7,
                bufferSnapshot: Data()
            ))
        }
        await waitFor(condition: { factoryIds.ids.count == 1 }, timeout: 1.0)

        // Manual toggle lands while that start is still suspended. Run it as
        // its own task: in the buggy world it spawns a second recorder that
        // also suspends on the gate, and an inline await here would deadlock
        // the test before the assertion.
        let toggle = Task {
            await coordinator.toggleManualRecording()
        }
        // Give the toggle a beat to reach the in-flight window in both the
        // fixed (no-op) and buggy (second factory call) worlds.
        try? await Task.sleep(nanoseconds: 150_000_000)

        gatedMic.open()
        await reconnect.value
        await toggle.value

        XCTAssertTrue(coordinator.isRecording)
        XCTAssertEqual(
            factoryIds.ids, [previousId],
            "manual toggle during an in-flight start must not create a second recorder"
        )
    }


    func test_reconnect_marker_is_inserted_at_segment_boundary() {
        let transcript = [
            TranscriptSegment(speaker: "A", start: 0, end: 2, text: "Hello"),
            TranscriptSegment(speaker: "B", start: 12, end: 14, text: "Back")
        ]
        let result = MeetingsCoordinator.insertingReconnectMarkers(
            [.init(afterAudioSeconds: 10, gapSeconds: 94)],
            into: transcript
        )

        XCTAssertEqual(result.map(\.text), ["Hello", "Reconnected after 1m 34s", "Back"])
        XCTAssertEqual(result[1].start, 10)
        XCTAssertEqual(result[1].speaker, "Whytap")
    }

    func test_detector_to_pill_wiring() async {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let expectedSnapshot = Data([0x01, 0x02, 0x03, 0x04])
        buffer.setSnapshotReturn(expectedSnapshot)
        let pill = MeetingPillController(buffer: buffer)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { true }
        )

        coordinator.start()

        // (1) Feed a trigger event onto the detector's stream.
        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))

        // Wait for the coordinator's draining task to observe the event
        // and propagate to buffer + pill. We poll with a short deadline
        // so a regression manifests as a quick failure, not a hang.
        await waitFor(
            condition: {
                guard buffer.startCalls >= 1 else { return false }
                guard case .suggesting(let id, _) = pill.state else { return false }
                return id == meetingId
            },
            timeout: 1.0
        )

        XCTAssertGreaterThanOrEqual(buffer.startCalls, 1,
                                    "Trigger must call buffer.start()")
        switch pill.state {
        case .suggesting(let id, _):
            XCTAssertEqual(id, meetingId)
        default:
            XCTFail("Expected pill.state == .suggesting, got \(pill.state)")
        }

        // (2) Dismiss via the pill's No-button seam. Expect buffer.gc()
        // and detector.engageCooldown() to be called by the coordinator
        // in reaction to the pill's `.dismiss` event.
        await pill._testTapDismiss()

        await waitFor(
            condition: { buffer.gcCalls >= 1 && detector.cooldownCalls >= 1 },
            timeout: 1.0
        )

        XCTAssertGreaterThanOrEqual(buffer.gcCalls, 1,
                                    "Dismiss must call buffer.gc()")
        XCTAssertGreaterThanOrEqual(detector.cooldownCalls, 1,
                                    "Dismiss must call detector.engageCooldown()")
        XCTAssertEqual(pill.state, .hidden,
                       "Pill must be hidden after dismiss")

        // (3) Accept flow: re-trigger, hit Yes-button, expect an
        // AcceptEvent on the coordinator's acceptEvents stream.
        let secondMeetingId = UUID()
        detector.feed(.triggered(meetingId: secondMeetingId))
        await waitFor(
            condition: {
                if case .suggesting(let id, _) = pill.state {
                    return id == secondMeetingId
                }
                return false
            },
            timeout: 1.0
        )

        // Drain one event from acceptEvents with a small deadline.
        let acceptStream = coordinator.acceptEvents
        let acceptTask = Task<MeetingsCoordinator.AcceptEvent?, Never> {
            for await event in acceptStream {
                return event
            }
            return nil
        }
        await pill._testTapAccept()
        let accept = await withTimeout(seconds: 1.0) {
            await acceptTask.value
        }
        acceptTask.cancel()

        XCTAssertNotNil(accept, "Expected an AcceptEvent within 1s")
        XCTAssertEqual(accept?.meetingId, secondMeetingId)
        XCTAssertEqual(accept?.bufferSnapshot, expectedSnapshot)
    }

    func test_context_end_hides_suggestion_without_cooldown() async {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { true }
        )

        coordinator.start()

        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))
        await waitFor(
            condition: {
                guard buffer.startCalls >= 1 else { return false }
                guard case .suggesting(let id, _) = pill.state else { return false }
                return id == meetingId
            },
            timeout: 1.0
        )

        detector.feed(.contextEnded)

        await waitFor(
            condition: { pill.state == .hidden && buffer.gcCalls >= 1 },
            timeout: 1.0
        )

        XCTAssertEqual(pill.state, .hidden)
        XCTAssertGreaterThanOrEqual(buffer.gcCalls, 1)
        XCTAssertEqual(
            detector.cooldownCalls,
            0,
            "Leaving the meeting should clear the suggestion without treating it as a user Skip."
        )
    }

    // MARK: - Finalized event -> local processing pipeline

    /// `handleFinalizedEvent` (user Stop) hands the recorded chunks to the
    /// configured processor in a detached task and returns immediately.
    /// Before processing starts a `manifest.json` is written next to the
    /// chunks so an app quit mid-processing keeps the recording recoverable.
    /// The spy processor never cleans the staging dir up (the real ones do),
    /// which lets the test observe that manifest afterwards.
    func test_handle_finalized_event_dispatches_to_processor_and_persists_manifest() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        PrivacyPreferences(defaults: testDefaults).selectedLanguage = AppLanguage.find(code: "ru")

        let detector = StubMeetingDetector()
        let directProcessor = RecordingMeetingDirectProcessor(active: true)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let recorderId = UUID()
        let recorderDir = tempRoot.appendingPathComponent(recorderId.uuidString)
        try FileManager.default.createDirectory(at: recorderDir, withIntermediateDirectories: true)
        let chunk0URL = try writeChunk(name: "chunk-000.wav", bytes: [0x01], in: recorderDir)
        let chunk1URL = try writeChunk(name: "chunk-001.wav", bytes: [0x02], in: recorderDir)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        let event = MeetingRecorder.FinalizedEvent(
            meetingId: recorderId,
            chunkURLs: [chunk0URL, chunk1URL],
            totalDurationSeconds: 60,
            reason: .user
        )

        await coordinator.handleFinalizedEvent(event)

        // Processing runs inside a `Task.detached`; poll until the processor
        // has been reached before asserting on it.
        await waitFor(condition: { directProcessor.calls.count == 1 }, timeout: 2.0)

        XCTAssertEqual(directProcessor.calls.count, 1)
        XCTAssertEqual(directProcessor.calls.first?.meetingId, recorderId)
        XCTAssertEqual(directProcessor.calls.first?.chunkURLs, [chunk0URL, chunk1URL])
        XCTAssertEqual(directProcessor.calls.first?.language, "ru")
        XCTAssertEqual(directProcessor.calls.first?.reason, .user)

        let manifestStore = MeetingFinalizeManifestStore()
        XCTAssertTrue(
            manifestStore.manifestExists(in: recorderDir),
            "manifest must be written next to the chunks before processing"
        )
        let scanned = manifestStore.scan(stagingRoot: tempRoot)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned.first?.manifest.recorderMeetingId, recorderId)
        XCTAssertEqual(scanned.first?.manifest.durationSeconds, 60)
        XCTAssertEqual(scanned.first?.manifest.language, "ru")
        XCTAssertEqual(scanned.first?.manifest.isFinal, true)
        XCTAssertEqual(
            scanned.first?.manifest.chunkFileNames,
            ["chunk-000.wav", "chunk-001.wav"]
        )
    }

    func test_handle_finalized_event_noop_when_flag_off() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = false

        let detector = StubMeetingDetector()
        let directProcessor = RecordingMeetingDirectProcessor(active: true)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-tests-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        let chunkURL = try writeChunk(name: "chunk-000.wav", bytes: [0x01], in: tempRoot)
        let event = MeetingRecorder.FinalizedEvent(
            meetingId: UUID(),
            chunkURLs: [chunkURL],
            totalDurationSeconds: 30,
            reason: .user
        )

        await coordinator.handleFinalizedEvent(event)
        // Give the detached dispatch a window to (wrongly) reach the processor.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(directProcessor.calls.isEmpty, "Feature off must not process the recording")
        XCTAssertFalse(
            MeetingFinalizeManifestStore().manifestExists(in: tempRoot),
            "Feature off must not stage a manifest"
        )
    }

    /// The BYOK route: an active direct processor receives the finalized
    /// event with the recording's absolute start and the pinned language,
    /// and a successful run broadcasts `.newMeetingAvailable`.
    func test_dispatch_routes_to_direct_processor_and_emits_new_meeting() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        PrivacyPreferences(defaults: testDefaults).selectedLanguage = AppLanguage.find(code: "ru")

        let detector = StubMeetingDetector()
        let directProcessor = RecordingMeetingDirectProcessor(active: true)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        let eventTask = Task<MeetingsCoordinatorEvent?, Never> {
            for await event in coordinator.events { return event }
            return nil
        }

        let meetingId = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_500_000)
        await coordinator.dispatchFinalizedForProcessing(
            event: MeetingRecorder.FinalizedEvent(
                meetingId: meetingId,
                chunkURLs: [],
                totalDurationSeconds: 60,
                reason: .user
            ),
            startedAt: startedAt
        )

        let emitted = await withTimeout(seconds: 1.0) { await eventTask.value }
        eventTask.cancel()

        XCTAssertEqual(directProcessor.calls.count, 1)
        XCTAssertEqual(directProcessor.calls.first?.meetingId, meetingId)
        XCTAssertEqual(directProcessor.calls.first?.startedAt, startedAt)
        XCTAssertEqual(directProcessor.calls.first?.language, "ru")

        if case .newMeetingAvailable(let id)? = emitted {
            XCTAssertEqual(id, meetingId)
        } else {
            XCTFail("Expected .newMeetingAvailable, got \(String(describing: emitted))")
        }
    }

    /// Neither pipeline configured (the BYOK processor declines, no local
    /// processor wired): the recording stays staged for a later launch and
    /// the meeting is surfaced as failed with the Settings > Models hint.
    func test_dispatch_marks_meeting_failed_when_no_processor_configured() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let directProcessor = RecordingMeetingDirectProcessor(active: false)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-no-processor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let recorderId = UUID()
        let recorderDir = tempRoot.appendingPathComponent(recorderId.uuidString)
        try FileManager.default.createDirectory(at: recorderDir, withIntermediateDirectories: true)
        let chunk0 = try writeChunk(name: "chunk-000.wav", bytes: [0x01], in: recorderDir)
        let store = try MeetingsStore(rootDirectory: tempRoot.appendingPathComponent("store"))

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            meetingsStore: store,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        let eventTask = Task<MeetingsCoordinatorEvent?, Never> {
            for await event in coordinator.events { return event }
            return nil
        }

        await coordinator.dispatchFinalizedForProcessing(
            event: MeetingRecorder.FinalizedEvent(
                meetingId: recorderId,
                chunkURLs: [chunk0],
                totalDurationSeconds: 30,
                reason: .user
            ),
            startedAt: Date()
        )

        let emitted = await withTimeout(seconds: 1.0) { await eventTask.value }
        eventTask.cancel()

        XCTAssertTrue(directProcessor.calls.isEmpty, "an inactive BYOK processor must not be invoked")
        if case .meetingFailed(let id, let error)? = emitted {
            XCTAssertEqual(id, recorderId)
            XCTAssertEqual(error, LocalModelMessaging.meetingProcessorNotConfigured)
        } else {
            XCTFail("Expected .meetingFailed, got \(String(describing: emitted))")
        }

        let row = try await store.list().first
        XCTAssertEqual(row?.id, recorderId)
        XCTAssertEqual(row?.progressStatus, .failed)
        XCTAssertEqual(row?.failureReason, LocalModelMessaging.meetingProcessorNotConfigured)

        // The staged recording is kept for a later launch.
        XCTAssertTrue(MeetingFinalizeManifestStore().manifestExists(in: recorderDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path))
    }

    // MARK: - Task 5a durability: manifest lifecycle + launch recovery

    /// Helper: write a WAV chunk into `dir`, returning its URL. Mirrors the
    /// chunk files `MeetingRecorder.ChunkWriter` lays down.
    private func writeChunk(name: String, bytes: [UInt8], in dir: URL) throws -> URL {
        let wav = dir.appendingPathComponent(name)
        try Data(bytes).write(to: wav)
        return wav
    }

    /// The manifest is written into the recorder's staging dir BEFORE the
    /// processor runs. The spy records whether it was already on disk at
    /// `process` time: that ordering is the durability guarantee itself.
    func test_dispatch_writes_manifest_before_processing() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-manifest-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let recorderId = UUID()
        let recorderDir = stagingRoot.appendingPathComponent(recorderId.uuidString)
        try FileManager.default.createDirectory(at: recorderDir, withIntermediateDirectories: true)
        let chunk0 = try writeChunk(name: "chunk-000.wav", bytes: [0x01], in: recorderDir)

        let manifestStore = MeetingFinalizeManifestStore()
        let directProcessor = RecordingMeetingDirectProcessor(active: true)
        var manifestPresentAtProcess: Bool?
        directProcessor.onProcess = { _ in
            manifestPresentAtProcess = manifestStore.manifestExists(in: recorderDir)
        }

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        await coordinator.dispatchFinalizedForProcessing(
            event: MeetingRecorder.FinalizedEvent(
                meetingId: recorderId,
                chunkURLs: [chunk0],
                totalDurationSeconds: 30,
                reason: .user
            ),
            startedAt: Date()
        )

        XCTAssertEqual(directProcessor.calls.count, 1)
        XCTAssertEqual(
            manifestPresentAtProcess, true,
            "manifest must already be on disk when the processor starts"
        )
    }

    /// When the processor throws, the manifest + chunks are left on disk so
    /// the next launch can retry, the store row is marked failed with the
    /// error, and `.meetingFailed` is broadcast. This is the core "never
    /// lose a recorded meeting" guarantee.
    func test_dispatch_keeps_manifest_and_marks_failed_when_processor_throws() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-manifest-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        // Recorder dir holds the chunks (recorder writes under
        // stagingRoot/<recorderUUID>/). The manifest must land here too.
        let recorderId = UUID()
        let recorderDir = stagingRoot.appendingPathComponent(recorderId.uuidString)
        try FileManager.default.createDirectory(at: recorderDir, withIntermediateDirectories: true)
        let chunk0 = try writeChunk(name: "chunk-000.wav", bytes: [0x01], in: recorderDir)
        let chunk1 = try writeChunk(name: "chunk-001.wav", bytes: [0x02], in: recorderDir)
        let store = try MeetingsStore(rootDirectory: stagingRoot.appendingPathComponent("store"))

        let failure = MeetingBYOKProcessingError.upstreamError("simulated 503")
        let expectedReason = String(describing: failure)
        let directProcessor = RecordingMeetingDirectProcessor(active: true)
        directProcessor.error = failure

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            meetingsStore: store,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        let eventTask = Task<MeetingsCoordinatorEvent?, Never> {
            for await event in coordinator.events { return event }
            return nil
        }

        await coordinator.dispatchFinalizedForProcessing(
            event: MeetingRecorder.FinalizedEvent(
                meetingId: recorderId,
                chunkURLs: [chunk0, chunk1],
                totalDurationSeconds: 90,
                reason: .user
            ),
            startedAt: Date()
        )

        let emitted = await withTimeout(seconds: 1.0) { await eventTask.value }
        eventTask.cancel()

        XCTAssertEqual(directProcessor.calls.count, 1)
        if case .meetingFailed(let id, let error)? = emitted {
            XCTAssertEqual(id, recorderId)
            XCTAssertEqual(error, expectedReason)
        } else {
            XCTFail("Expected .meetingFailed, got \(String(describing: emitted))")
        }

        // Manifest + chunks must survive for launch recovery.
        let manifestStore = MeetingFinalizeManifestStore()
        XCTAssertTrue(
            manifestStore.manifestExists(in: recorderDir),
            "Manifest must survive a processing failure so launch recovery can pick it up"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk1.path))

        // The persisted manifest carries the recording metadata so recovery
        // can rebuild the finalized event faithfully.
        let scanned = manifestStore.scan(stagingRoot: stagingRoot)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned.first?.manifest.recorderMeetingId, recorderId)
        XCTAssertEqual(scanned.first?.manifest.durationSeconds, 90)
        XCTAssertEqual(
            scanned.first?.manifest.chunkFileNames.sorted(),
            ["chunk-000.wav", "chunk-001.wav"]
        )

        let row = try await store.list().first
        XCTAssertEqual(row?.id, recorderId)
        XCTAssertEqual(row?.progressStatus, .failed)
        XCTAssertEqual(row?.failureReason, expectedReason)
    }

    /// End-to-end through a REAL accept -> start -> auto-end cycle (modeled
    /// on `test_auto_end_finalizes_recorder_and_hides_pill`): an auto-ended
    /// recording is held for the reconnect grace window (with its grace
    /// manifest already on disk), and resolving the next nudge WITHOUT
    /// reconnecting (Skip) releases it into the processing pipeline with the
    /// chunks the recorder actually wrote.
    func test_auto_end_then_skip_releases_recording_to_processor() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubEmittingDetector()
        let buffer = StubBuffer()
        let pill = MeetingPillController(buffer: buffer)
        let directProcessor = RecordingMeetingDirectProcessor(active: true)

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-autoend-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let mic = TestMicSource()
        let sys = TestSystemSource()
        let micInUse = TestMicInUse()
        let factory: MeetingsCoordinator.RecorderFactory = { _ in
            MeetingRecorder(
                micSource: mic,
                systemSource: sys,
                micInUseProbe: micInUse,
                stagingRoot: stagingRoot,
                chunkRotationSeconds: 60,
                autoEndMicReleasedSeconds: 0.1,
                autoEndStartupGraceSeconds: 0,
                sampleRate: 16_000
            )
        }

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            recorderFactory: factory,
            stagingRoot: { stagingRoot },
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )
        coordinator.start()

        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))
        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 1.0)
        await pill._testTapAccept()

        await waitFor(condition: {
            coordinator.isRecording && {
                if case .recording = pill.state { return true }
                return false
            }()
        }, timeout: 2.0)

        // Feed real mic samples so the recorder writes a non-empty chunk on
        // finalize (an empty recording would have nothing to hand over).
        mic.feed(Array(repeating: Float(0.5), count: 1600))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Model a real call lifecycle: auto-end arms only after an active mic
        // is later released.
        micInUse.feed(true)
        micInUse.feed(false)

        await waitFor(condition: {
            !coordinator.isRecording && pill.state == .hidden
        }, timeout: 2.0)

        XCTAssertTrue(
            directProcessor.calls.isEmpty,
            "auto-end holds the recording for reconnect; nothing is processed yet"
        )
        let manifestStore = MeetingFinalizeManifestStore()
        XCTAssertTrue(
            manifestStore.manifestExists(in: stagingRoot.appendingPathComponent(meetingId.uuidString)),
            "the grace manifest keeps the held recording recoverable across a quit"
        )

        // Skip on the next nudge releases the held recording into processing.
        await coordinator.handlePillEvent(.dismiss(reason: .user))

        await waitFor(condition: { directProcessor.calls.count == 1 }, timeout: 2.0)
        XCTAssertEqual(directProcessor.calls.count, 1)
        XCTAssertEqual(directProcessor.calls.first?.meetingId, meetingId)
        XCTAssertEqual(directProcessor.calls.first?.reason, .autoEnd)
        XCTAssertEqual(
            directProcessor.calls.first?.chunkURLs.isEmpty, false,
            "the recorder's chunks must reach the processor"
        )
    }

    /// Launch recovery from a staged manifest dir: the coordinator rebuilds
    /// the finalized event from the manifest (timestamps, chunks) and re-runs
    /// the SAME processing path the in-session Stop uses, so the note lands
    /// in the store and `.newMeetingAvailable` fires.
    func test_recover_from_manifest_reprocesses_and_emits_new_meeting() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubMeetingDetector()
        let directProcessor = RecordingMeetingDirectProcessor(active: true)

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-recover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let store = try MeetingsStore(rootDirectory: stagingRoot.appendingPathComponent("store"))

        // Seed a manifest dir as if a previous run crashed after Stop but
        // before processing finished.
        let recorderId = UUID()
        let recorderDir = stagingRoot.appendingPathComponent(recorderId.uuidString)
        try FileManager.default.createDirectory(at: recorderDir, withIntermediateDirectories: true)
        _ = try writeChunk(name: "chunk-000.wav", bytes: [0x01], in: recorderDir)
        _ = try writeChunk(name: "chunk-001.wav", bytes: [0x02], in: recorderDir)
        let manifestStore = MeetingFinalizeManifestStore()
        let recorderStartedAt = Date(timeIntervalSince1970: 1_700_400_000)
        let recorderEndedAt = Date(timeIntervalSince1970: 1_700_400_120)
        try await store.upsertProgress(
            meta: MeetingMetaWithLocalState(
                id: recorderId,
                startedAt: recorderStartedAt,
                endedAt: recorderEndedAt,
                durationSeconds: 120,
                title: nil,
                syncStatus: .new,
                serverVersion: 1,
                createdAt: recorderStartedAt,
                progressStatus: .failed,
                statusUpdatedAt: recorderEndedAt,
                failureReason: "Processing will retry when Whytap restarts"
            ),
            status: .failed,
            failureReason: "Processing will retry when Whytap restarts"
        )
        try manifestStore.write(
            MeetingFinalizeManifest(
                recorderMeetingId: recorderId,
                startedAt: recorderStartedAt,
                endedAt: recorderEndedAt,
                durationSeconds: 120,
                language: "en",
                chunkFileNames: ["chunk-000.wav", "chunk-001.wav"],
                isFinal: true
            ),
            to: recorderDir
        )

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            stagingRoot: { stagingRoot },
            meetingsStore: store,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        // Listen for the newMeetingAvailable event (processing finished).
        let eventTask = Task<MeetingsCoordinatorEvent?, Never> {
            for await event in coordinator.events {
                return event
            }
            return nil
        }

        await coordinator.recoverFinalizeManifestsOnLaunch()

        let event = await withTimeout(seconds: 2.0) { await eventTask.value }
        eventTask.cancel()

        // Processed once, with the manifest's metadata and both chunks.
        XCTAssertEqual(directProcessor.calls.count, 1)
        XCTAssertEqual(directProcessor.calls.first?.meetingId, recorderId)
        XCTAssertEqual(directProcessor.calls.first?.startedAt, recorderStartedAt)
        XCTAssertEqual(
            directProcessor.calls.first?.chunkURLs.map(\.lastPathComponent),
            ["chunk-000.wav", "chunk-001.wav"]
        )

        XCTAssertNotNil(event, "Recovery must re-run processing so the note lands in the store")
        if case .newMeetingAvailable(let id)? = event {
            XCTAssertEqual(id, recorderId)
        } else {
            XCTFail("Expected .newMeetingAvailable, got \(String(describing: event))")
        }

        let rows = try await store.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, recorderId)
        XCTAssertEqual(rows.first?.progressStatus, .ready)
        XCTAssertNil(rows.first?.failureReason)
    }

    /// Two launch-recovery passes kicked back-to-back (launch + wake) must
    /// serialize: the second scan runs only after the first finished, sees
    /// the meeting already `.ready` in the store, and reconciles the stale
    /// manifest instead of processing the same staged recording twice.
    func test_launch_recovery_serializes_concurrent_passes_without_double_processing() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = StubMeetingDetector()
        let directProcessor = RecordingMeetingDirectProcessor(active: true)
        directProcessor.delaySeconds = 0.15

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-recover-serialized-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let store = try MeetingsStore(rootDirectory: stagingRoot.appendingPathComponent("store"))

        let recorderId = UUID()
        let recorderDir = stagingRoot.appendingPathComponent(recorderId.uuidString)
        try FileManager.default.createDirectory(at: recorderDir, withIntermediateDirectories: true)
        _ = try writeChunk(name: "chunk-000.wav", bytes: [0x01], in: recorderDir)
        let manifestStore = MeetingFinalizeManifestStore()
        try manifestStore.write(
            MeetingFinalizeManifest(
                recorderMeetingId: recorderId,
                startedAt: Date(timeIntervalSince1970: 1_700_400_000),
                endedAt: Date(timeIntervalSince1970: 1_700_400_060),
                durationSeconds: 60,
                language: nil,
                chunkFileNames: ["chunk-000.wav"],
                isFinal: true
            ),
            to: recorderDir
        )

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            stagingRoot: { stagingRoot },
            meetingsStore: store,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        coordinator.resumePendingProcessingOnLaunch()
        coordinator.resumePendingProcessingOnLaunch()

        // The second pass, once it runs, finds the meeting stored and drops
        // the stale manifest; that is the visible end of both passes.
        await waitFor(condition: {
            !manifestStore.manifestExists(in: recorderDir)
        }, timeout: 3.0)

        XCTAssertEqual(
            directProcessor.calls.count, 1,
            "the second pass must skip the meeting the first pass already stored"
        )
        XCTAssertFalse(manifestStore.manifestExists(in: recorderDir))
        let row = try await store.list().first
        XCTAssertEqual(row?.id, recorderId)
        XCTAssertEqual(row?.progressStatus, .ready)
    }

    /// A row can say `.failed` while the complete note is already on disk (a
    /// stale status from an interrupted earlier run). Launch recovery must
    /// treat the durable local note as the truth: repair the row to `.ready`,
    /// drop the stale manifest, and NOT re-process the recording.
    func test_launch_recovery_repairs_false_failure_when_local_note_exists() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let meetingId = UUID()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-ready-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let meetingsRoot = tempRoot.appendingPathComponent("Meetings")
        let store = try MeetingsStore(rootDirectory: meetingsRoot)
        let meta = MeetingMetaWithLocalState(
            id: meetingId,
            startedAt: Date(timeIntervalSince1970: 1_700_500_000),
            endedAt: Date(timeIntervalSince1970: 1_700_500_120),
            durationSeconds: 120,
            title: "Complete local note",
            syncStatus: .read,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_500_130),
            progressStatus: .failed,
            failureReason: "Processing timed out"
        )
        try await store.insert(meta: meta, markdown: "# Complete local note\n\nDone.")

        let stagingRoot = tempRoot.appendingPathComponent("meetings-staging")
        let recorderDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        try FileManager.default.createDirectory(at: recorderDir, withIntermediateDirectories: true)
        _ = try writeChunk(name: "chunk-000.wav", bytes: [0xAB], in: recorderDir)
        let manifestStore = MeetingFinalizeManifestStore()
        try manifestStore.write(
            MeetingFinalizeManifest(
                recorderMeetingId: meetingId,
                startedAt: Date(timeIntervalSince1970: 1_700_500_000),
                endedAt: Date(timeIntervalSince1970: 1_700_500_120),
                durationSeconds: 120,
                language: nil,
                chunkFileNames: ["chunk-000.wav"],
                isFinal: true
            ),
            to: recorderDir
        )

        let directProcessor = RecordingMeetingDirectProcessor(active: true)
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            stagingRoot: { stagingRoot },
            meetingsStore: store,
            directProcessor: directProcessor,
            meetingsEnabled: { true }
        )

        await coordinator.recoverFinalizeManifestsOnLaunch()

        let repaired = try await store.list().first
        XCTAssertEqual(repaired?.progressStatus, .ready)
        XCTAssertNil(repaired?.failureReason)
        XCTAssertTrue(directProcessor.calls.isEmpty, "a durable local note must not be re-processed")
        XCTAssertFalse(
            manifestStore.manifestExists(in: recorderDir),
            "the stale manifest of a stored meeting is reconciled away"
        )
    }

    // MARK: - Manual refresh (repairLocalTitle)

    /// The sidebar "Refresh" item re-derives the row title from the LOCAL
    /// note's H1 (no network): a note whose heading no longer matches the
    /// stored title gets the stale title repaired in place.
    func test_repair_local_title_rederives_sidebar_title_from_note_h1() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let meetingId = UUID()
        let markdown = "<!-- protocol:v1 -->\n# Updated title\n\nbody"

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-repair-title-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
        let store = try MeetingsStore(rootDirectory: tempRoot)

        // Seed the store with a title that no longer matches the note's H1.
        let seedMeta = MeetingMetaWithLocalState(
            id: meetingId,
            startedAt: Date(timeIntervalSince1970: 1_700_500_000),
            endedAt: Date(timeIntervalSince1970: 1_700_500_120),
            durationSeconds: 120,
            title: "Stale title",
            syncStatus: .read,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_500_130)
        )
        try await store.insert(meta: seedMeta, markdown: markdown)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            meetingsStore: store,
            meetingsEnabled: { true }
        )

        await coordinator.repairLocalTitle(id: meetingId)

        let rows = try await store.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.title, "Updated title",
            "repairLocalTitle must refresh the sidebar title from the note's H1"
        )
        // Only the derived title changes: the note body and version are untouched.
        let storedMarkdown = try await store.markdown(id: meetingId)
        XCTAssertEqual(storedMarkdown, markdown)
        XCTAssertEqual(rows.first?.serverVersion, 1)
    }

    /// No local note (a meeting still processing, or one whose markdown never
    /// landed) means there is nothing to derive from: the existing title is
    /// preserved and the call completes without throwing.
    func test_repair_local_title_preserves_title_without_local_note() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let meetingId = UUID()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-repair-title-noop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
        let store = try MeetingsStore(rootDirectory: tempRoot)
        try await store.upsertProgress(
            meta: MeetingMetaWithLocalState(
                id: meetingId,
                startedAt: Date(timeIntervalSince1970: 1_700_500_000),
                endedAt: Date(timeIntervalSince1970: 1_700_500_120),
                durationSeconds: 120,
                title: "In progress",
                syncStatus: .new,
                serverVersion: 1,
                createdAt: Date(timeIntervalSince1970: 1_700_500_130),
                progressStatus: .transcribing
            ),
            status: .transcribing
        )

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: StubMeetingDetector(),
            meetingsStore: store,
            meetingsEnabled: { true }
        )

        await coordinator.repairLocalTitle(id: meetingId)

        let rows = try await store.list()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "In progress")
        XCTAssertEqual(rows.first?.progressStatus, .transcribing)
    }

    // MARK: - Async helpers

    /// Polls `condition` every 10ms up to `timeout`. Returns silently
    /// once the condition becomes true; XCTest assertions in the caller
    /// will then either pass or surface a precise failure.
    private func waitFor(
        condition: @escaping () async -> Bool,
        timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Runs `work` with a deadline. Returns nil on timeout. Useful for
    /// AsyncStream consumption where the alternative is a hung test.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        work: @escaping () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Stubs

/// Records `subscribe()` invocations from `MeetingsCoordinator.start()`.
/// Concrete `MeetingDetector` lands in Stage 2.
@MainActor
private final class StubMeetingDetector: MeetingDetectorProtocol {
    private(set) var subscribeCallCount = 0

    func subscribe() {
        subscribeCallCount += 1
    }
}

@MainActor
private final class StubMeetingPill: MeetingPillDisplaying {}

@MainActor
private final class StubMeetingRecorder: MeetingRecording {}

@MainActor
private final class StubMeetingsStore: MeetingsStoring {}

/// BYOK direct-processor spy: records every `process` call so the
/// coordinator tests can assert what flowed through the finalize / recovery
/// pipeline. Returns the recorder meeting id as the stored id, mirroring the
/// real processor. Never touches the staging dir, so manifests written by
/// the coordinator remain observable after processing.
@MainActor
private final class RecordingMeetingDirectProcessor: MeetingDirectProcessing {
    struct Call: Equatable {
        let meetingId: UUID
        let startedAt: Date
        let language: String?
        let storeProvided: Bool
        let chunkURLs: [URL]
        let reason: MeetingRecorderStopReason
    }

    var active: Bool
    /// When non-nil, `process` throws this instead of returning: drives the
    /// "processing failed, manifest survives" durability path.
    var error: Error?
    /// Artificial processing time so a test can overlap two recovery passes.
    var delaySeconds: TimeInterval = 0
    /// Observed at the top of `process`, before any delay or throw, so a test
    /// can inspect on-disk state at the moment processing starts.
    var onProcess: (@MainActor (MeetingRecorder.FinalizedEvent) -> Void)?
    private(set) var calls: [Call] = []

    init(active: Bool) {
        self.active = active
    }

    func shouldProcessDirectly() -> Bool {
        active
    }

    func process(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date,
        language: String?,
        meetingsStore: MeetingsStore?
    ) async throws -> UUID {
        calls.append(Call(
            meetingId: event.meetingId,
            startedAt: startedAt,
            language: language,
            storeProvided: meetingsStore != nil,
            chunkURLs: event.chunkURLs,
            reason: event.reason
        ))
        onProcess?(event)
        if delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if let error { throw error }
        return event.meetingId
    }
}

// MARK: - Stage 3 wiring test stubs

/// Detector stub conforming to `MeetingDetectorEventEmitting` so the
/// Stage 3 wiring test can feed `.triggered` events synchronously and
/// observe `engageCooldown()` calls without instantiating the real
/// `MeetingDetector` (which transitively pulls in FluidAudio and
/// CoreAudio). Headless and side-effect-free.
@MainActor
private final class StubEmittingDetector: MeetingDetectorEventEmitting {
    private(set) var subscribeCallCount = 0
    private(set) var cooldownCalls = 0

    let events: AsyncStream<MeetingDetectorEvent>
    private let continuation: AsyncStream<MeetingDetectorEvent>.Continuation

    init() {
        let (stream, cont) = AsyncStream<MeetingDetectorEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    func subscribe() {
        subscribeCallCount += 1
    }

    func engageCooldown() {
        cooldownCalls += 1
    }

    nonisolated func feed(_ event: MeetingDetectorEvent) {
        continuation.yield(event)
    }
}

/// Conforms to the buffer protocol so the Stage 3 wiring test can
/// observe `start()` / `gc()` / `snapshot()` calls without allocating
/// the real 1.9 MB `PrerecordBuffer`. Lock-guarded counters keep the
/// shared mutable state safe to read from XCTest's MainActor while the
/// coordinator may still be running its drain task in the background.
private final class StubBuffer: MeetingPillBufferAttaching, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCalls = 0
    private var _gcCalls = 0
    private var _snapshotReturn: Data = Data()

    var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
    var gcCalls: Int { lock.lock(); defer { lock.unlock() }; return _gcCalls }

    func setSnapshotReturn(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        _snapshotReturn = data
    }

    func start() async {
        lock.lock(); defer { lock.unlock() }
        _startCalls += 1
    }

    func snapshot() async -> Data {
        lock.lock(); defer { lock.unlock() }
        return _snapshotReturn
    }

    func gc() async {
        lock.lock(); defer { lock.unlock() }
        _gcCalls += 1
    }
}

// MARK: - Stage 4 recorder factory test stubs

/// Hand-driven mic source for the Stage 4 coordinator tests. Same shape
/// as `MeetingRecorderTests.StubMicSource` but kept locally so the two
/// test files do not have to share test-only types (and each test file
/// stays self-contained).
/// Movable test clock for the coordinator's injectable `now` seam. All
/// mutation happens on the test's MainActor context, so the unchecked
/// Sendable is safe in practice.
private final class MovableClock: @unchecked Sendable {
    private(set) var now = Date()
    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

/// Captures the meeting ids the coordinator hands to its recorder
/// factory. Class box so the @MainActor factory closure can append
/// without capturing a mutable local.
private final class FactoryIdBox: @unchecked Sendable {
    var ids: [UUID] = []
}

/// Mic source whose `start()` suspends until `open()` — lets tests hold
/// the coordinator inside `recorder.start()` and probe the in-flight
/// window (MainActor reentrancy) deterministically. The gate is
/// reusable: any number of `start()` calls suspend until `open()`, and
/// calls after `open()` pass straight through (a buggy double-start must
/// fail an assertion, not deadlock the suite). `failOnStart` makes the
/// gated start throw once released, exercising slow-failure paths.
private final class GatedMicSource: MicSourcing, @unchecked Sendable {
    let samples: AsyncStream<[Float]>
    private let samplesContinuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let failOnStart: Bool

    init(failOnStart: Bool = false) {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.samples = stream
        self.samplesContinuation = cont
        self.failOnStart = failOnStart
    }

    func start() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                cont.resume()
                return
            }
            waiters.append(cont)
            lock.unlock()
        }
        if failOnStart {
            throw NSError(
                domain: "GatedMicSource", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "simulated slow start failure"]
            )
        }
    }

    func stop() async {}

    /// Releases every suspended `start()` and lets future ones pass.
    func open() {
        lock.lock()
        opened = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

private final class TestMicSource: MicSourcing, @unchecked Sendable {
    let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    init() {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.samples = stream
        self.continuation = cont
    }

    func start() async throws {}
    func stop() async {}

    nonisolated func feed(_ chunk: [Float]) {
        continuation.yield(chunk)
    }
}

/// System audio source stub for the Stage 4 coordinator tests.
private final class TestSystemSource: SystemAudioBufferStreaming, @unchecked Sendable {
    private let stream: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    init() {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.stream = stream
        self.continuation = cont
    }

    func audioBufferStream() -> AsyncStream<[Float]> { stream }
}

/// MicInUseProbe stub for the Stage 4 coordinator tests.
private final class TestMicInUse: MicInUseProbing, @unchecked Sendable {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        self.stream = stream
        self.continuation = cont
    }

    func subscribe() -> AsyncStream<Bool> { stream }
    func stop() {}

    nonisolated func feed(_ inUse: Bool) {
        continuation.yield(inUse)
    }
}
