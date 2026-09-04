import Combine
import Foundation
import os.log

/// Wiring shell for the Meeting Notes feature. Owned by `AppDelegate` and
/// exposed via `AppState.meetingsCoordinator` so the rest of the app
/// (status menu, hotkey monitor, etc.) can ask "is a meeting recording
/// right now?" without reaching into module internals.
///
/// Stage 3 contract (on top of Stage 1a/2):
///
/// - `start()` reads `MeetingsConfig.isEnabled`. When off → logged no-op.
///   When on → subscribes the detector AND drains its event stream.
/// - On `.triggered(meetingId)`:
///     1. `buffer.start()` opens the 60s ring for new audio.
///     2. `pill.show(.suggesting(meetingId, deadline))` displays the
///        suggestion pill.
/// - On `.contextEnded`:
///     1. If the suggestion is still unanswered, hide it and gc the buffer.
///     2. Do not engage cooldown; leaving the meeting is not Skip.
/// - On `pill.events` → `.dismiss(reason:)`:
///     1. `buffer.gc()` zeroes the ring (privacy invariant).
///     2. `detector.engageCooldown()` locks new triggers for 30 min.
/// - On `pill.events` → `.accept(meetingId, snapshot)`:
///     1. Emits the snapshot via the coordinator's own `acceptEvents`
///        stream so Stage 4 MeetingRecorder can splice it onto the head
///        of the recording.
///
/// The injected protocol seams (`pill`, `buffer`) are optional so the
/// Stage 1a / 2 coordinator tests can continue to instantiate the
/// coordinator with just `config + detector` and exercise the
/// feature-flag gate. When both pill and buffer are nil, Stage 3 wiring
/// degrades to the Stage 2 "log triggers only" behaviour — this is the
/// path AppDelegate uses while Stage 3 is still being rolled out behind
/// the feature flag.

// MARK: - Stage 7 coordinator event stream

/// Events the coordinator broadcasts to its subscribers (the
/// AppDelegate listens so the menu bar can refresh, and Stage 8b will
/// listen so the sidebar can update).
///
/// Adding cases is non-breaking for `for await … in events` consumers
/// that ignore unknown values; switches that need to be exhaustive
/// must add a `default` clause.
enum MeetingsCoordinatorEvent: Sendable {
    /// Processing finished and the store now contains the meeting.
    case newMeetingAvailable(id: UUID)
    /// Processing failed. Surfaced as a failed row in the meetings list.
    case meetingFailed(id: UUID, error: String?)
}

@MainActor
final class MeetingsCoordinator {
    /// Distinct subsystem from `com.rootwise.sidekey` so meeting-related
    /// log lines can be filtered in Console.app without dragging in the
    /// rest of Sidekey's noise. Plan: `docs/plans/meetings.md` Stage 1a
    /// Observability section.
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "coordinator")

    private let config: MeetingsConfig
    private let detector: MeetingDetectorProtocol
    /// Per-user opt-in gate. Injected as a closure so tests can pass
    /// `{ false }` or `{ true }` without touching the shared singleton.
    /// Production default reads `UserPreferencesCache.shared.currentMeetingsEnabled`
    /// which defaults to `false` (opt-in).
    private let meetingsEnabled: @MainActor () -> Bool

    /// Flips the Meeting Notes capability ON (user opt-in). Injected for
    /// tests; production writes through `UserPreferencesCache`, which posts
    /// the capability notification so AppDelegate reconciles capabilities
    /// and `start()`s this coordinator (detector arms) in the background.
    private let enableMeetingsCapability: @MainActor () -> Void
    private let pill: MeetingPillController?
    private let buffer: MeetingPillBufferAttaching?
    /// Local cache the processors insert into once a note is ready.
    /// Optional because the early-stage tests construct the coordinator
    /// without a store.
    private let meetingsStore: MeetingsStore?
    /// Direct BYOK meeting processor. When the user has a full direct stack
    /// (BYOK STT + direct LLM), finalized meeting audio is transcribed and
    /// summarized through the user's own providers.
    private let directProcessor: (any MeetingDirectProcessing)?

    /// Fully-on-device meeting processor. When wired AND a finalized event
    /// carries retained separate tracks AND `localMeetingGate` passes (both
    /// transcription & LLM = .local), the coordinator transcribes, diarizes,
    /// aligns ("Me" / "Speaker N"), summarizes, and stores the note entirely
    /// on-device. Optional so the BYOK tests construct the coordinator
    /// without it.
    private let localProcessor: (any MeetingLocalProcessing)?

    /// Activation predicate: `true` when the fully-local meeting path should
    /// be taken (both transcription & LLM isolation = .local). Injected so
    /// tests drive the gate deterministically; production reads
    /// `SelfKeyPreferences` + the Apple Silicon probe.
    private let localMeetingGate: @MainActor () -> Bool

    /// Look up the id of the most recently started meeting in the local
    /// store. Used by `AppDelegate` when the user clicks the Dynamic
    /// Island "Notes" tile so the meetings window can auto-select the
    /// freshest note instead of showing an empty detail pane. Returns
    /// `nil` if the store is not wired (test fixtures) or empty.
    func latestMeetingId() async -> UUID? {
        guard let meetingsStore else { return nil }
        do {
            return try await meetingsStore.list().first?.id
        } catch {
            return nil
        }
    }

    /// Convert exact recorded-audio duration into the integer seconds the
    /// meetings list shows. A non-zero partial second is still real recorded
    /// audio, so round it up instead of losing it as 0.
    static func roundedDurationSeconds(_ duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int(ceil(duration))
    }

    /// Activation gate (pure): the fully-on-device meeting path is taken only
    /// when BOTH transcription and LLM isolation are `.local` AND the host is
    /// Apple Silicon. A half-local meeting (e.g. local STT but cloud LLM) is
    /// not a supported configuration, so both must be `.local` together. The
    /// `isAppleSilicon` gate (ROO-257 Stage 6) keeps the MLX/Core ML path from
    /// engaging on Intel under the universal binary — there it would fail at
    /// load time. Centralised + pure so the recorder factory (which flips
    /// `retainSeparateTracks`) and the coordinator's runtime gate read identical
    /// logic.
    static func isFullyLocalMeetingEnabled(
        transcriptionLevel: TranscriptionIsolationLevel,
        llmLevel: LLMIsolationLevel,
        isAppleSilicon: Bool = LocalModelSupport.isAppleSilicon
    ) -> Bool {
        isAppleSilicon && transcriptionLevel == .local && llmLevel == .local
    }

    // MARK: - Stage 4 recorder factory + active recorder

    /// Factory closure for the recorder. Injected so tests can stand in
    /// a stub `MeetingRecording` without depending on AVFoundation /
    /// CoreAudio. Production path is wired in `AppDelegate.installMeetingsCoordinator`
    /// to instantiate a real `MeetingRecorder` against the canonical
    /// staging directory under `Application Support/Sidekey/meetings-staging/`.
    typealias RecorderFactory = @MainActor (UUID) -> MeetingRecorder?

    private let recorderFactory: RecorderFactory?
    /// Where the recorder factory stages chunks; launch recovery scans it for
    /// leftover manifests. `nil` when no factory is wired.
    private let stagingRootProvider: (() -> URL)?
    private var activeRecorder: MeetingRecorder?
    private var recorderFinalizedTask: Task<Void, Never>?
    private var recorderAudioLevelTask: Task<Void, Never>?
    private var recorderDurationTask: Task<Void, Never>?

    /// The wall-clock when the active recorder started, captured by
    /// `startRecorder` so the processors get absolute timestamps.
    /// `MeetingRecorder.FinalizedEvent` only carries elapsed duration,
    /// not absolute timestamps; the coordinator owns the absolute time
    /// because it sees both edges of the recording lifecycle.
    private var activeRecorderStartedAt: Date?

    typealias TranscriptReconnectMarker = MeetingReconnectMarker

    private struct PendingReconnect {
        let event: MeetingRecorder.FinalizedEvent
        let startedAt: Date
        let endedAt: Date
        let markers: [TranscriptReconnectMarker]

        var deadline: Date {
            endedAt.addingTimeInterval(MeetingsConfig.reconnectGracePeriodSeconds)
        }
    }

    private struct ActiveReconnect {
        let startedAt: Date
        let accumulatedDuration: TimeInterval
        let markers: [TranscriptReconnectMarker]
    }

    /// Injectable clock for the reconnect grace/silent-window math so
    /// tests can move time without sleeping. Production: `Date.init`.
    private let now: () -> Date

    /// True while `startRecorder` is suspended in `recorder.start()`.
    /// The MainActor is re-entrant across that await; this flag is what
    /// keeps a concurrent start request (detector trigger, manual ⌥M,
    /// silent reconnect) from slipping past the nil-`activeRecorder`
    /// guard in that window.
    private var recorderStartInFlight = false

    private var pendingReconnect: PendingReconnect?
    private var pendingReconnectExpiryTask: Task<Void, Never>?
    private var activeReconnect: ActiveReconnect?

    /// Task draining the detector's `events` stream when the detector
    /// exposes one (Stage 2 real detector or any
    /// `MeetingDetectorEventEmitting` conformer). Stored so it can be
    /// cancelled if the coordinator is torn down. Nil for Stage 1a stubs
    /// that do not vend an event stream.
    private var detectorEventConsumer: Task<Void, Never>?

    /// Task draining the pill's `events` stream. Same lifecycle as the
    /// detector consumer above.
    private var pillEventConsumer: Task<Void, Never>?

    /// Counts how many times a pill consumer Task has been spawned. Starts
    /// at 0; incremented each time `start()` wires `pillEventConsumer`. Test-
    /// visible (internal) so `MeetingsCoordinatorTests` can assert that
    /// `stop()` + `start()` does NOT accumulate stale consumers — after an
    /// off→on cycle the generation count is exactly N spawns with no leaks.
    /// Production code never reads this value.
    private(set) var pillConsumerGeneration: Int = 0

    // MARK: - Task 5b: idempotency guard

    /// Set to `true` by the first successful `start()` call. Guards
    /// re-entry so `AppDelegate.startReady()` — which is invoked on every
    /// full wake and on re-login — does not install a second pair of
    /// detector/pill consumer Tasks. A second consumer would compete with
    /// the first over the same unicast `AsyncStream`, delivering events
    /// nondeterministically to either consumer after the first sleep/wake.
    private var started = false

    /// Serializes launch/wake recovery passes so two scans never process the
    /// same staged manifest concurrently.
    private var launchRecoveryTask: Task<Void, Never>?

    // MARK: - Task 5b: pause provenance

    /// Tracks WHO requested the most recent recorder pause so the wake
    /// path (`resumeRecordingIfPaused`) can decide whether to auto-resume.
    ///
    /// - `.user`: the user tapped the Pause button on the pill. Only the
    ///   user's own Resume tap (via `handlePillEvent(.resume)`) should
    ///   unpause — system wake must NOT override user intent.
    /// - `.system`: the coordinator paused the recorder on behalf of
    ///   the OS (sleep / `pauseRecordingIfActive`). Wake auto-resumes.
    ///
    /// Cleared to `nil` when the recorder stops (finalize or user stop)
    /// so a subsequent recording starts with no inherited provenance.
    enum PauseProvenance {
        case user
        case system
    }

    /// Nil when no recording is active or the recorder is not paused.
    private var pauseProvenance: PauseProvenance?

    // MARK: - Accept event stream (consumed by Stage 4 MeetingRecorder)

    /// Event the coordinator emits when the user clicks Yes on the pill.
    /// Stage 4 consumes this to spin up `MeetingRecorder` with the
    /// pre-record snapshot spliced at the head.
    struct AcceptEvent: Sendable, Equatable {
        let meetingId: UUID
        let bufferSnapshot: Data
    }

    let acceptEvents: AsyncStream<AcceptEvent>
    private let acceptEventsContinuation: AsyncStream<AcceptEvent>.Continuation

    // MARK: - Coordinator event stream

    /// Broadcast channel for `MeetingsCoordinatorEvent`. AppDelegate listens
    /// here so the open notes surfaces refresh when a new meeting lands.
    /// `AsyncStream` with default buffering policy is fine: events are rare
    /// (one per finalised meeting) and slow consumers should not drop them
    /// on the floor.
    let events: AsyncStream<MeetingsCoordinatorEvent>
    private let eventsContinuation: AsyncStream<MeetingsCoordinatorEvent>.Continuation

    /// Stateless manifest IO helper. Holding one instance avoids
    /// re-allocating it on every finalize / recovery pass.
    private let manifestStore = MeetingFinalizeManifestStore()

    // MARK: - Stage 8b window controller

    /// Lazy-constructed Meetings window. Built on first access (when the
    /// user clicks a submenu item) so app launch does not pay the
    /// WKWebView allocation cost. Held strongly so the WKWebView is not
    /// rebuilt every time the user reopens the window — the previously
    /// loaded markdown stays cached in BlockNote.
    ///
    /// Nil when `meetingsStore` is missing (the coordinator was
    /// constructed without a store — Stage 1a-6 test paths), because the
    /// window's sidebar and markdown provider both need the store.
    private var _meetingsWindowController: MeetingsWindowController?
    private var _settingsMeetingsContentController: MeetingsContentController?

    /// Bridge that surfaces note edits into `saveNoteEdit`. There are two
    /// notes surfaces (standalone window and Settings > Notes), so each
    /// content controller owns a bridge and cancellable.
    private var _editBridges: [MeetingsEditBridge] = []
    private var _editBridgeCancellables: [AnyCancellable] = []

    var meetingsWindowController: MeetingsWindowController? {
        if let cached = _meetingsWindowController { return cached }
        guard let store = meetingsStore else { return nil }
        let source = MeetingsStoreSidebarSource(store: store)
        let controller = MeetingsWindowController.makeProduction(
            source: source,
            markdownProvider: { id in try await store.markdown(id: id) },
            transcriptProvider: { id in try await store.transcript(id: id) },
            refreshHandler: { [weak self] id in
                await self?.repairLocalTitle(id: id)
            }
        )
        _meetingsWindowController = controller
        installEditPipeline(for: controller.contentController)
        return controller
    }

    var settingsMeetingsContentController: MeetingsContentController? {
        if let cached = _settingsMeetingsContentController { return cached }
        guard let store = meetingsStore else { return nil }
        let source = MeetingsStoreSidebarSource(store: store)
        let bundleURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "blocknote"
        )
        let controller = MeetingsContentController(
            source: source,
            markdownProvider: { id in try await store.markdown(id: id) },
            transcriptProvider: { id in try await store.transcript(id: id) },
            bundleURL: bundleURL,
            bundleAccessRoot: bundleURL?.deletingLastPathComponent(),
            refreshHandler: { [weak self] id in
                await self?.repairLocalTitle(id: id)
            },
            // Settings top bar sits in the detail pane (right of the sidebar) —
            // no traffic lights above it, so the big 72pt inset isn't needed.
            topBarLeadingInset: 16
        )
        _settingsMeetingsContentController = controller
        installEditPipeline(for: controller)
        return controller
    }

    /// Wire the edit pipeline: each visible content surface gets its own
    /// bridge that debounces edits into `saveNoteEdit`.
    private func installEditPipeline(for controller: MeetingsContentController) {
        let bridge = MeetingsEditBridge(
            debounceMilliseconds: MeetingsConfig.editDebounceMilliseconds
        )
        controller.attachEditBridge(bridge)
        _editBridges.append(bridge)
        _editBridgeCancellables.append(bridge.editEvents.sink { [weak self] event in
            Task { @MainActor in
                await self?.saveNoteEdit(
                    id: event.meetingId,
                    markdown: event.markdown,
                    clientVersion: event.clientVersion
                )
            }
        })
    }

    /// AppDelegate hook — invoked when a new meeting lands so the sidebar
    /// refreshes without forcing the user to reopen the window. Skips when
    /// the window has never been constructed (we don't want to allocate
    /// WKWebView resources just to drop them straight back).
    func refreshOpenWindowIfNeeded() {
        _meetingsWindowController?.refreshSidebar()
        _settingsMeetingsContentController?.refreshSidebar()
    }

    // MARK: - Init

    init(
        config: MeetingsConfig,
        detector: MeetingDetectorProtocol,
        pill: MeetingPillController? = nil,
        buffer: MeetingPillBufferAttaching? = nil,
        recorderFactory: RecorderFactory? = nil,
        stagingRoot: (() -> URL)? = nil,
        meetingsStore: MeetingsStore? = nil,
        directProcessor: (any MeetingDirectProcessing)? = nil,
        localProcessor: (any MeetingLocalProcessing)? = nil,
        localMeetingGate: @escaping @MainActor () -> Bool = { false },
        meetingsEnabled: @escaping @MainActor () -> Bool = { UserPreferencesCache.shared.currentMeetingsEnabled },
        enableMeetingsCapability: @escaping @MainActor () -> Void = { UserPreferencesCache.shared.setMeetingsEnabled(true) },
        now: @escaping () -> Date = Date.init
    ) {
        self.config = config
        self.detector = detector
        self.now = now
        self.meetingsEnabled = meetingsEnabled
        self.enableMeetingsCapability = enableMeetingsCapability
        self.pill = pill
        self.buffer = buffer
        self.recorderFactory = recorderFactory
        self.stagingRootProvider = stagingRoot
        self.meetingsStore = meetingsStore
        self.directProcessor = directProcessor
        self.localProcessor = localProcessor
        self.localMeetingGate = localMeetingGate
        let (acceptStream, acceptContinuation) = AsyncStream<AcceptEvent>.makeStream()
        self.acceptEvents = acceptStream
        self.acceptEventsContinuation = acceptContinuation
        let (eventStream, eventContinuation) = AsyncStream<MeetingsCoordinatorEvent>.makeStream()
        self.events = eventStream
        self.eventsContinuation = eventContinuation
    }

    /// True while a recorder is active. Read by `CarbonHotkeyMonitor` to
    /// guard Option+/ so dictation cannot fight the meeting mic. Stage 4
    /// invariant: only one meeting recorder runs at a time, and the
    /// answer is single-source-of-truth on the coordinator (not the
    /// recorder itself — the recorder may not exist yet).
    var isRecording: Bool { activeRecorder != nil }

    /// Launch-recovery hook. Called once from
    /// `AppDelegate.installMeetingsCoordinator()` at launch and again from
    /// `startReady()` (kept separate from `init` so tests can install the
    /// coordinator without immediately racing a background recovery task
    /// against a freshly-created staging dir).
    ///
    /// Idempotent — running it twice is a no-op once the staging dir is
    /// fully drained. Failures are logged but do not throw to the caller;
    /// pending recordings survive the next launch.
    func resumePendingProcessingOnLaunch() {
        guard config.isEnabled else { return }
        let previous = launchRecoveryTask
        launchRecoveryTask = Task { [weak self] in
            await previous?.value
            await self?.recoverFinalizeManifestsOnLaunch()
        }
    }

    deinit {
        // Cancel happens at protocol exit; the AsyncStream continuations
        // can be safely finished off the MainActor.
        acceptEventsContinuation.finish()
        eventsContinuation.finish()
        _editBridgeCancellables.forEach { $0.cancel() }
        launchRecoveryTask?.cancel()
        pendingReconnectExpiryTask?.cancel()
        // `MeetingsEditBridge.finish()` is @MainActor — `deinit` is
        // nonisolated. The bridge's own `deinit` already cancels its
        // internal subscription, so dropping the strong reference here
        // is the canonical cleanup; we just nil out the local property.
        _editBridges.removeAll()
    }

    // MARK: - Lifecycle

    /// Idempotent entry point. Stage 1a: gate on feature flag, log result,
    /// subscribe the detector when on. Stage 2 also drains the detector's
    /// event stream into os_log. Stage 3 wires the pill + buffer when
    /// both are injected.
    ///
    /// Re-entrant calls are safe and cheap: `guard !started` returns
    /// immediately after the first successful wiring so `AppDelegate`
    /// can call `start()` on every full wake and re-login without
    /// doubling the consumer Tasks or stealing events from the original
    /// consumer (both detector and pill expose unicast `AsyncStream`s —
    /// two concurrent drainers would split events nondeterministically).
    func start() {
        guard config.isEnabled, meetingsEnabled() else {
            os_log(
                "coordinator no-op (feature disabled or user opt-out)",
                log: Self.log,
                type: .info
            )
            return
        }

        // Idempotency guard: wiring is a one-shot operation. AppDelegate
        // calls start() on every full wake via rearmRuntimeAfterWake(.full)
        // → startReady(); without this guard each wake would spawn a new
        // detectorEventConsumer + pillEventConsumer Task, both competing
        // for the same unicast AsyncStream.
        guard !started else {
            os_log(
                "coordinator start skipped (already started)",
                log: Self.log,
                type: .info
            )
            return
        }
        started = true

        os_log(
            "coordinator start (isEnabled: true)",
            log: Self.log,
            type: .info
        )
        detector.subscribe()

        // Stage 2/3: if the injected detector vends a real event stream,
        // drain it. Stage 1a stubs do not conform — they remain a no-op
        // so the wiring shell tests keep working untouched.
        if let emitter = detector as? MeetingDetectorEventEmitting {
            let events = emitter.events
            detectorEventConsumer = Task { [weak self] in
                for await event in events {
                    await self?.handleDetectorEvent(event)
                }
            }
        }

        // Stage 3: drain the pill's events if a pill is wired. Stage 1a/2
        // path leaves this nil and only logs detector triggers.
        ensurePillConsumer()
    }

    /// One-shot spin-up of the pill event consumer, shared by `start()` and
    /// the capability-off enable prompt in `toggleManualRecording()` (which
    /// must drain Accept/Skip while the coordinator is otherwise not
    /// started). The `pillEventConsumer == nil` gate keeps the unicast
    /// `pill.events` stream single-drainer: a later full `start()` skips the
    /// spin-up instead of racing a second Task; `stop()` cancels AND nils the
    /// consumer, so the reactive off→on cycle re-arms as before.
    private func ensurePillConsumer() {
        guard pillEventConsumer == nil, let pill else { return }
        let pillEvents = pill.events
        pillConsumerGeneration += 1
        pillEventConsumer = Task { [weak self] in
            for await event in pillEvents {
                await self?.handlePillEvent(event)
            }
        }
    }

    /// Unsubscribes the detector and pill consumers so no NEW meeting is
    /// detected or suggested. Does NOT abort an in-flight recording — an
    /// active recorder finalizes on its own. Used by the capability-flag
    /// reconcile path (E5) to tear the coordinator down when the user opts
    /// out while the app is running.
    ///
    /// Cancels BOTH `detectorEventConsumer` AND `pillEventConsumer`. Without
    /// cancelling the pill consumer a subsequent `start()` after a `stop()`
    /// would spawn a second `pillEventConsumer` (#2) while #1 remains alive,
    /// leaking #1 and causing two Tasks to race on the unicast `pill.events`
    /// stream — "Take notes / Skip / Stop" taps would then be delivered
    /// nondeterministically to one of the two consumers.
    ///
    /// Cancelling `pillEventConsumer` stops handling of NEW pill events after
    /// opt-out — which is the intended semantics. An already-running recorder
    /// finalizes on its own (recording is not driven off this consumer), so
    /// this does NOT abort an in-flight recording.
    ///
    /// Resets `started` so a subsequent `start()` re-subscribes the detector
    /// and pill. This does not break the wake idempotency contract: the wake
    /// path (`rearmRuntimeAfterWake(.full) → startReady() → start()`) never
    /// calls `stop()` between wakes, so `started` remains true across wakes
    /// and the guard still prevents double-subscribe. `started` only resets
    /// on an explicit `stop()` (reconcile disable), which is exactly when a
    /// re-subscribe is needed.
    func stop() {
        detectorEventConsumer?.cancel()
        detectorEventConsumer = nil
        pillEventConsumer?.cancel()
        pillEventConsumer = nil
        started = false  // allow a later start() to re-subscribe (reactive on/off)
        os_log(
            "coordinator stopped (detector and pill consumers unsubscribed; in-flight recording unaffected)",
            log: Self.log,
            type: .info
        )
    }

    // MARK: - Detector events

    /// Stage 3: trigger event flips the buffer + pill on. If either is
    /// absent (Stage 1a/2 deployment) the method falls back to the
    /// Stage 2 log-only behaviour.
    func handleDetectorEvent(_ event: MeetingDetectorEvent) async {
        switch event {
        case .triggered(let meetingId):
            os_log(
                "coordinator received detector triggered (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
            // A recording is already running (manual ⌥M start, or the
            // detector's own from an earlier trigger) — or one is mid-start
            // (silent reconnect awaiting the audio stack) — suggesting a
            // new meeting on top would clobber the pill's `.recording`
            // state. Swallow the trigger and back the detector off.
            guard activeRecorder == nil, !recorderStartInFlight else {
                os_log(
                    "detector trigger ignored — recording already active",
                    log: Self.log, type: .info
                )
                if let emitter = detector as? MeetingDetectorEventEmitting {
                    emitter.engageCooldown()
                }
                return
            }
            if let buffer {
                await buffer.start()
            }
            if let pill {
                let deadline = Date().addingTimeInterval(
                    MeetingsConfig.pillDecisionTimeoutSeconds
                )
                if let previous = pendingReconnect, now() <= previous.deadline {
                    let gapSeconds = max(0, now().timeIntervalSince(previous.endedAt))
                    // Resuming into the previous recording is always the
                    // user's call, however fast the re-fire lands: the
                    // detector reports "a meeting is happening", never WHICH
                    // one, so a hop into a different call (Teams → Zoom in
                    // 7s) is indistinguishable from mic turbulence inside
                    // the same one. Guessing glued two meetings into one
                    // transcript; asking cannot.
                    // WHY: docs/decisions/2026-07-29-reconnect-always-asks.md
                    pill.show(.suggestingReconnect(
                        meetingId: meetingId,
                        previousMeetingId: previous.event.meetingId,
                        gapSeconds: gapSeconds,
                        deadline: deadline
                    ))
                } else {
                    if pendingReconnect != nil {
                        releasePendingReconnectForProcessing()
                    }
                    pill.show(.suggesting(meetingId: meetingId, deadline: deadline))
                }
            }
        case .contextEnded:
            os_log(
                "coordinator received detector context ended",
                log: Self.log, type: .info
            )
            guard let pill else { return }
            switch pill.state {
            case .suggesting, .suggestingReconnect:
                break
            default:
                return
            }
            pill.hide()
            if let buffer {
                await buffer.gc()
            }
        }
    }

    // MARK: - Pill events

    /// Stage 3: pill emits one of three events. Coordinator routes them:
    /// - `.dismiss` → gc the buffer, engage the detector's cooldown.
    /// - `.accept` → emit AcceptEvent for Stage 4 MeetingRecorder.
    /// - `.stop`   → Stage 4 (placeholder log here so we can observe
    ///   accidental Stage 4-only events in Stage 3 deployment).
    func handlePillEvent(_ event: MeetingPillEvent) async {
        switch event {
        case .dismiss(let reason):
            os_log(
                "coordinator received pill dismiss (reason: %{public}@)",
                log: Self.log, type: .info,
                reason == .user ? "user" : "timeout"
            )
            if let buffer {
                await buffer.gc()
            }
            if let emitter = detector as? MeetingDetectorEventEmitting {
                emitter.engageCooldown()
            }
            if pendingReconnect != nil {
                releasePendingReconnectForProcessing()
            }

        case .accept(let meetingId, let snapshot):
            os_log(
                "coordinator received pill accept (meetingId: %{public}@, snapshot_bytes: %{public}d)",
                log: Self.log, type: .info,
                meetingId.uuidString, snapshot.count
            )
            if pendingReconnect != nil {
                releasePendingReconnectForProcessing()
            }
            // Accepting a nudge while the capability is OFF is the opt-in
            // itself: the detector never arms with Meeting Notes disabled,
            // so the only way a `.suggesting` pill exists in that state is
            // the manual-toggle enable prompt (⌥M / Record tile). Flip the
            // capability first — the preferences write posts the capability
            // notification, so the rest of the stack (reconcile → start(),
            // detector arm) catches up while this recording starts now.
            if !meetingsEnabled() {
                os_log(
                    "pill accept with capability off → enabling Meeting Notes (opt-in)",
                    log: Self.log, type: .info
                )
                enableMeetingsCapability()
            }
            acceptEventsContinuation.yield(
                AcceptEvent(meetingId: meetingId, bufferSnapshot: snapshot)
            )
            await startRecorder(meetingId: meetingId, prerecordSnapshot: snapshot)

        case .reconnect(let previousMeetingId, let gapSeconds, let snapshot):
            guard let pending = pendingReconnect,
                  pending.event.meetingId == previousMeetingId,
                  now() <= pending.deadline else {
                os_log(
                    "reconnect ignored — candidate expired (previousMeetingId: %{public}@)",
                    log: Self.log, type: .info,
                    previousMeetingId.uuidString
                )
                return
            }
            pendingReconnectExpiryTask?.cancel()
            pendingReconnectExpiryTask = nil
            pendingReconnect = nil

            let marker = TranscriptReconnectMarker(
                afterAudioSeconds: pending.event.totalDurationSeconds,
                gapSeconds: max(0, gapSeconds)
            )
            activeReconnect = ActiveReconnect(
                startedAt: pending.startedAt,
                accumulatedDuration: pending.event.totalDurationSeconds,
                markers: pending.markers + [marker]
            )
            activeRecorderStartedAt = pending.startedAt
            let started = await startRecorder(
                meetingId: previousMeetingId,
                prerecordSnapshot: snapshot
            )
            if !started {
                activeReconnect = nil
                activeRecorderStartedAt = nil
                stagePendingReconnect(pending)
            }

        case .stop(let meetingId):
            os_log(
                "coordinator received pill stop (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
            await handleStop(meetingId: meetingId, reason: .user)

        case .pause(let meetingId):
            os_log(
                "coordinator received pill pause (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
            // Record that THIS pause originated from the user so the wake
            // path (`resumeRecordingIfPaused`) knows not to auto-resume.
            // Set BEFORE calling pause() so the provenance is in place if
            // any observer checks it synchronously in the same run-loop turn.
            pauseProvenance = .user
            await activeRecorder?.pause()

        case .resume(let meetingId):
            os_log(
                "coordinator received pill resume (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
            // User explicitly resumed via the pill play button — clear the
            // provenance so the coordinator is back to a clean state.
            pauseProvenance = nil
            do {
                try await activeRecorder?.resume()
            } catch {
                os_log(
                    "recorder resume failed (meetingId: %{public}@): %{public}@",
                    log: Self.log, type: .error,
                    meetingId.uuidString, String(describing: error)
                )
            }
        }
    }

    // MARK: - Stage 4 recorder lifecycle

    /// Spin up the recorder via the injected factory, push pill into
    /// `.recording`, subscribe to the recorder's audio level / duration /
    /// finalized streams so the pill UI reacts in real time and the
    /// coordinator notices auto-end (mic released).
    @discardableResult
    private func startRecorder(meetingId: UUID, prerecordSnapshot: Data) async -> Bool {
        guard activeRecorder == nil, !recorderStartInFlight else {
            os_log(
                "startRecorder skipped — another recorder is already active or starting",
                log: Self.log, type: .info
            )
            return false
        }
        // `recorder.start()` suspends the MainActor below; without this
        // flag a re-entrant caller (second detector trigger, manual ⌥M)
        // would pass the nil-recorder guard during that await and spin up
        // a second recorder that later fights this one over coordinator
        // ownership.
        recorderStartInFlight = true
        defer { recorderStartInFlight = false }
        guard let factory = recorderFactory,
              let recorder = factory(meetingId) else {
            os_log(
                "startRecorder skipped — no recorder factory wired (Stage 1a/2/3 path)",
                log: Self.log, type: .info
            )
            return false
        }

        do {
            try await recorder.start(prerecordSnapshot: prerecordSnapshot, meetingId: meetingId)
        } catch {
            os_log(
                "recorder start failed (meetingId: %{public}@): %{public}@",
                log: Self.log, type: .error,
                meetingId.uuidString, String(describing: error)
            )
            return false
        }

        self.activeRecorder = recorder
        if self.activeRecorderStartedAt == nil {
            self.activeRecorderStartedAt = Date()
        }
        os_log(
            "recorder active (meetingId: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString
        )

        // Transition pill into recording with initial zero values; the
        // audio level / duration drain tasks below will rebroadcast as
        // the recorder publishes.
        let durationBase = activeReconnect?.accumulatedDuration ?? 0
        pill?.show(.recording(
            meetingId: meetingId,
            audioLevel: 0,
            duration: durationBase
        ))

        // Subscribe to the recorder's audio level stream and forward to
        // the pill so the waveform reacts to real audio.
        let levelStream = recorder.audioLevelStream
        recorderAudioLevelTask = Task { [weak self] in
            for await level in levelStream {
                guard let self else { return }
                await MainActor.run {
                    let duration = self.currentRecorderDuration()
                    self.pill?.updateLiveState(audioLevel: level, duration: duration)
                }
            }
        }

        // Subscribe to the recorder's duration stream and forward to the
        // pill timer.
        let durationStream = recorder.durationStream
        recorderDurationTask = Task { [weak self] in
            for await duration in durationStream {
                guard let self else { return }
                await MainActor.run {
                    let level = self.currentPillAudioLevel()
                    self.pill?.updateLiveState(
                        audioLevel: level,
                        duration: durationBase + duration
                    )
                }
            }
        }

        // Subscribe to the recorder's finalize stream so we can clean up
        // when the auto-end watcher fires (or the user clicks Stop, since
        // the recorder yields on both paths).
        let finalizedStream = recorder.finalizedStream
        recorderFinalizedTask = Task { [weak self] in
            for await event in finalizedStream {
                guard let self else { return }
                await self.handleFinalizedEvent(event)
            }
        }
        return true
    }

    /// Read the recorder's current pill-visible duration without crossing
    /// the actor boundary — used by the audio level forwarder to keep
    /// the duration field in lockstep with the latest audio level emission.
    private func currentRecorderDuration() -> TimeInterval {
        guard let pill else { return 0 }
        switch pill.state {
        case .recording(_, _, let duration): return duration
        case .paused(_, _, let duration): return duration
        default: return 0
        }
    }

    /// Read the pill's current audio level so the duration forwarder
    /// does not overwrite the most recent level with 0.
    private func currentPillAudioLevel() -> Double {
        guard let pill else { return 0 }
        switch pill.state {
        case .recording(_, let level, _): return level
        case .paused(_, let level, _): return level
        default: return 0
        }
    }

    /// User clicked Stop on the pill. Forward to the recorder; the
    /// finalize handler will fire via the subscribed stream and clean
    /// up shared state.
    func handleStop(meetingId: UUID, reason: MeetingRecorderStopReason) async {
        guard let recorder = activeRecorder else { return }
        _ = await recorder.stop(reason: reason)
    }

    // MARK: - Manual recording toggle (⌥M / hover tile / Settings)

    /// Toggle a MANUAL meeting recording — the hotkey / hover-tile /
    /// Settings entry point that bypasses the detector nudge (mid-meeting
    /// starts, meetings the detector never recognized).
    ///
    /// A recorder is active (nudge-started or manual) → stop it, the same
    /// path as the pill Stop button; finalize/processing runs as usual. No
    /// recorder → start with an EMPTY pre-record snapshot (a manual start
    /// has no buffered lead-in) and engage the detector cooldown so the
    /// nudge does not fire on top of a recording the user already started.
    func toggleManualRecording() async {
        guard config.isEnabled else {
            // Kill switch — stays silent by design; the capability branch
            // below is the one a real user can hit.
            os_log(
                "manual record toggle ignored (feature disabled)",
                log: Self.log, type: .info
            )
            return
        }
        guard meetingsEnabled() else {
            // Explicit user gesture on a disabled capability: a silent
            // no-op reads as "the hotkey is dead". Show the standard nudge
            // instead — accepting it IS the opt-in (see the capability flip
            // in `handlePillEvent(.accept)`). The detector never arms while
            // the capability is off (`start()` is gated), so a `.suggesting`
            // pill in that state is unambiguously this enable prompt.
            os_log(
                "manual record toggle: capability off → showing enable nudge",
                log: Self.log, type: .info
            )
            if let pill {
                // The coordinator is not start()ed while the capability is
                // off, so nothing is draining pill.events yet — spin the
                // consumer up or Accept/Skip on this prompt would go nowhere.
                ensurePillConsumer()
                let deadline = Date().addingTimeInterval(
                    MeetingsConfig.pillDecisionTimeoutSeconds
                )
                pill.show(.suggesting(meetingId: UUID(), deadline: deadline))
            }
            return
        }
        if let recorder = activeRecorder {
            os_log("manual record toggle → stop", log: Self.log, type: .info)
            _ = await recorder.stop(reason: .user)
            return
        }
        if recorderStartInFlight {
            // A recorder start (e.g. silent reconnect) is awaiting the
            // audio stack — treating this tap as a fresh start would race
            // it. The window is a few hundred ms; a deliberate stop can
            // simply be pressed again once the pill shows .recording.
            os_log(
                "manual record toggle ignored — recorder start in flight",
                log: Self.log, type: .info
            )
            return
        }
        let meetingId = UUID()
        os_log(
            "manual record toggle → start (meetingId: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString
        )
        // A nudge may be on screen right now (its pre-record buffer running);
        // the manual start supersedes it — drop the buffered lead-in and let
        // `startRecorder` flip the pill straight into `.recording`.
        if let buffer {
            await buffer.gc()
        }
        if let emitter = detector as? MeetingDetectorEventEmitting {
            emitter.engageCooldown()
        }
        await startRecorder(meetingId: meetingId, prerecordSnapshot: Data())
    }

    /// Single point where finalize cleanup lives plus the processing entry.
    /// Tears down the active recorder reference, cancels subscription tasks,
    /// hides the pill, releases the pre-record buffer, then hands the
    /// finalized chunks to the local / BYOK processor.
    ///
    /// Processing failures are logged but do NOT propagate to the caller:
    /// the recorder's finalize stream is best-effort and the user has
    /// already moved on. A permanent error leaves the meeting marked
    /// `.failed` in the local store for the notes list to surface.
    func handleFinalizedEvent(_ event: MeetingRecorder.FinalizedEvent) async {
        os_log(
            "coordinator received recorder finalized (meetingId: %{public}@, chunks: %{public}d, reason: %{public}@, interruptedBySleep: %{public}@)",
            log: Self.log, type: .info,
            event.meetingId.uuidString, event.chunkURLs.count,
            Self.reasonLabel(event.reason),
            event.interruptedBySleep ? "true" : "false"
        )

        let startedAt = self.activeRecorderStartedAt ?? Date(
            timeIntervalSinceNow: -event.totalDurationSeconds
        )
        let reconnect = activeReconnect
        let combinedEvent = event

        // Cleanup runs first so isRecording flips false before the
        // processing pipeline (which can throw) gets a chance to fail.
        self.activeRecorder = nil
        self.activeRecorderStartedAt = nil
        self.activeReconnect = nil
        // Clear pause provenance: the recording is over, so there is no
        // current pause state to track. The next recording starts fresh.
        self.pauseProvenance = nil
        recorderAudioLevelTask?.cancel()
        recorderAudioLevelTask = nil
        recorderDurationTask?.cancel()
        recorderDurationTask = nil
        // CRITICAL: do NOT cancel `recorderFinalizedTask` here. This method
        // runs *inside* that task's `for await` loop — cancelling it would
        // mark the current Task as cancelled, and every subsequent `await`
        // in the processors would throw `CancellationError`.
        // The task's loop will iterate to the next event normally; if the
        // recorder finalizes for good its `finalizedStream` completes and
        // the loop exits on its own. No leak — the recorder owns the
        // stream lifecycle.
        if let buffer { await buffer.gc() }
        pill?.hide()

        if combinedEvent.reason == .autoEnd {
            stagePendingReconnect(PendingReconnect(
                event: combinedEvent,
                startedAt: reconnect?.startedAt ?? startedAt,
                endedAt: now(),
                markers: reconnect?.markers ?? []
            ))
            return
        }

        // Processing runs in a detached Task so it survives even if our
        // caller task does get cancelled later. The detach also disconnects
        // it from the recorder-event consumer's cancellation lineage.
        // Failures are logged inside `dispatchFinalizedForProcessing`;
        // nothing here needs to await its completion.
        Task.detached { [weak self] in
            await self?.dispatchFinalizedForProcessing(
                event: combinedEvent,
                startedAt: reconnect?.startedAt ?? startedAt,
                reconnectMarkers: reconnect?.markers ?? []
            )
        }
    }

    private func stagePendingReconnect(_ pending: PendingReconnect) {
        pendingReconnectExpiryTask?.cancel()
        pendingReconnect = pending
        persistReconnectGraceManifest(pending)
        if let store = meetingsStore {
            let meta = Self.progressMeta(
                id: pending.event.meetingId,
                startedAt: pending.startedAt,
                endedAt: pending.endedAt,
                durationSeconds: Self.roundedDurationSeconds(pending.event.totalDurationSeconds),
                status: .waitingToReconnect
            )
            Task { [weak self] in
                try? await store.upsertProgress(meta: meta, status: .waitingToReconnect)
                await MainActor.run { self?.refreshOpenWindowIfNeeded() }
            }
        }

        let delay = max(0, pending.deadline.timeIntervalSince(now()))
        pendingReconnectExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.pendingReconnect?.event.meetingId == pending.event.meetingId else {
                    return
                }
                self?.releasePendingReconnectForProcessing()
            }
        }
    }

    private func persistReconnectGraceManifest(_ pending: PendingReconnect) {
        guard !pending.event.chunkURLs.isEmpty else { return }
        persistFinalizeManifest(
            event: pending.event,
            startedAt: pending.startedAt,
            endedAt: pending.endedAt,
            language: config.preferredLanguage,
            reconnectMarkers: pending.markers
        )
    }

    private func releasePendingReconnectForProcessing() {
        guard let pending = pendingReconnect else { return }
        pendingReconnect = nil
        pendingReconnectExpiryTask?.cancel()
        pendingReconnectExpiryTask = nil
        if let store = meetingsStore {
            Task { [weak self] in
                try? await store.updateProgress(id: pending.event.meetingId, status: .transcribing)
                await MainActor.run { self?.refreshOpenWindowIfNeeded() }
            }
        }
        Task.detached { [weak self] in
            await self?.dispatchFinalizedForProcessing(
                event: pending.event,
                startedAt: pending.startedAt,
                endedAt: pending.endedAt,
                reconnectMarkers: pending.markers
            )
        }
    }

    // MARK: - FinalizedEvent -> processing pipeline

    /// Route a finalized recording to the fully-local processor (both
    /// isolation levels `.local`, separate tracks retained) or the BYOK
    /// processor (user's own STT + LLM providers). Pulled out of
    /// `handleFinalizedEvent` so the cleanup path stays readable.
    ///
    /// Durability: a `manifest.json` is written into the recorder's staging
    /// dir (alongside the WAV chunks) BEFORE processing starts. If the app
    /// quits mid-processing, the manifest + chunks survive on disk and the
    /// next launch's `recoverFinalizeManifestsOnLaunch` re-runs the whole
    /// sequence. On success the manifest is deleted with the staging dir.
    ///
    /// `internal` (not `private`) so tests can await it directly and assert
    /// on the manifest lifecycle without racing the detached task
    /// `handleFinalizedEvent` wraps it in.
    func dispatchFinalizedForProcessing(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date,
        endedAt: Date? = nil,
        reconnectMarkers: [TranscriptReconnectMarker] = []
    ) async {
        await dispatchFinalizedForProcessing(
            event: event,
            startedAt: startedAt,
            endedAt: endedAt,
            reconnectMarkers: reconnectMarkers,
            language: config.preferredLanguage
        )
    }

    /// Core of `dispatchFinalizedForProcessing` with the protocol language
    /// pinned explicitly: a fresh Stop passes the current preference, manifest
    /// recovery passes the language captured at Stop time so a toggle between
    /// the failed Stop and the relaunch does not change the recovered meeting.
    func dispatchFinalizedForProcessing(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date,
        endedAt: Date?,
        reconnectMarkers: [TranscriptReconnectMarker],
        language: String?
    ) async {
        guard config.isEnabled else {
            os_log(
                "handleFinalizedEvent processing no-op (feature disabled)",
                log: Self.log, type: .info
            )
            return
        }
        let endedAt = endedAt ?? Date()

        if let meetingsStore {
            let meta = Self.progressMeta(
                id: event.meetingId,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: Self.roundedDurationSeconds(event.totalDurationSeconds),
                status: .transcribing
            )
            try? await meetingsStore.upsertProgress(meta: meta, status: .transcribing)
            refreshOpenWindowIfNeeded()
        }

        // DURABILITY: persist the manifest before any processing so a crash
        // mid-transcription keeps the recording recoverable on next launch.
        persistFinalizeManifest(
            event: event,
            startedAt: startedAt,
            endedAt: endedAt,
            language: language,
            reconnectMarkers: reconnectMarkers
        )

        // Fully-on-device meeting path. When a local processor is wired, the
        // recorder retained separate mic/system tracks, AND the local-meeting
        // gate passes (both transcription & LLM = .local), transcribe +
        // diarize + align + summarize + store ENTIRELY on-device.
        if let localProcessor,
           let tracks = event.separateTrackURLs,
           localMeetingGate() {
            await processMeetingFullyLocally(
                processor: localProcessor,
                event: event,
                tracks: tracks,
                startedAt: startedAt,
                language: language,
                reconnectMarkers: reconnectMarkers
            )
            return
        }

        if let directProcessor, directProcessor.shouldProcessDirectly() {
            do {
                let meetingId = try await directProcessor.process(
                    event: event,
                    startedAt: startedAt,
                    language: language,
                    meetingsStore: meetingsStore
                )
                try await persistReconnectMarkersIfNeeded(
                    reconnectMarkers,
                    meetingId: meetingId
                )
                try? await meetingsStore?.updateProgress(id: meetingId, status: .ready)
                eventsContinuation.yield(.newMeetingAvailable(id: meetingId))
                refreshOpenWindowIfNeeded()
            } catch {
                os_log(
                    "handleFinalizedEvent BYOK processing failed (meetingId: %{public}@, error: %{public}@)",
                    log: Self.log,
                    type: .error,
                    event.meetingId.uuidString,
                    String(describing: error)
                )
                eventsContinuation.yield(.meetingFailed(id: event.meetingId, error: String(describing: error)))
                try? await meetingsStore?.updateProgress(
                    id: event.meetingId,
                    status: .failed,
                    failureReason: String(describing: error)
                )
                refreshOpenWindowIfNeeded()
            }
            return
        }

        // Neither pipeline is configured: the recording stays staged (manifest
        // + chunks) and is retried on the next launch once the user has set
        // up local models or BYOK keys in Settings -> Models.
        os_log(
            "handleFinalizedEvent no processor configured (meetingId: %{public}@) — recording kept for later",
            log: Self.log, type: .error,
            event.meetingId.uuidString
        )
        eventsContinuation.yield(.meetingFailed(id: event.meetingId, error: LocalModelMessaging.meetingProcessorNotConfigured))
        try? await meetingsStore?.updateProgress(
            id: event.meetingId,
            status: .failed,
            failureReason: LocalModelMessaging.meetingProcessorNotConfigured
        )
        refreshOpenWindowIfNeeded()
    }

    /// Write the recovery manifest next to the chunks. A manifest we could
    /// not persist is not fatal — processing still runs — but it means this
    /// meeting is NOT crash-safe, so log it loudly.
    private func persistFinalizeManifest(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date,
        endedAt: Date,
        language: String?,
        reconnectMarkers: [TranscriptReconnectMarker]
    ) {
        guard let firstChunkURL = event.chunkURLs.first else { return }
        let recorderDir = firstChunkURL.deletingLastPathComponent()
        var manifest = MeetingFinalizeManifest(
            recorderMeetingId: event.meetingId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: Self.roundedDurationSeconds(event.totalDurationSeconds),
            language: language,
            chunkFileNames: event.chunkURLs.map(\.lastPathComponent),
            isFinal: true
        )
        manifest.reconnectMarkers = reconnectMarkers
        do {
            try manifestStore.write(manifest, to: recorderDir)
        } catch {
            os_log(
                "manifest write failed (recorderId: %{public}@, error: %{public}@) — meeting not crash-safe",
                log: Self.log, type: .error,
                event.meetingId.uuidString, String(describing: error)
            )
        }
    }

    // MARK: - Stage 5b: fully-on-device meeting path

    /// Drive the fully-on-device meeting pipeline via `MeetingLocalProcessor`
    /// and surface the resulting note to the UI. On success the new-meeting
    /// event is emitted and the open notes window refreshed, exactly like the
    /// BYOK path; on failure a `.meetingFailed` event is emitted.
    ///
    /// `internal` so tests can assert the bypass without standing up the full
    /// model pipeline (an injected `MeetingLocalProcessing` spy suffices).
    func processMeetingFullyLocally(
        processor: any MeetingLocalProcessing,
        event: MeetingRecorder.FinalizedEvent,
        tracks: MeetingRecorder.SeparateTrackURLs,
        startedAt: Date,
        language: String?,
        reconnectMarkers: [TranscriptReconnectMarker] = []
    ) async {
        do {
            try? await meetingsStore?.updateProgress(
                id: event.meetingId,
                status: .transcribing
            )
            let meetingId = try await processor.process(
                event: event,
                startedAt: startedAt,
                language: language,
                meetingsStore: meetingsStore
            )
            try await persistReconnectMarkersIfNeeded(
                reconnectMarkers,
                meetingId: meetingId
            )
            try? await meetingsStore?.updateProgress(id: meetingId, status: .ready)
            eventsContinuation.yield(.newMeetingAvailable(id: meetingId))
            _meetingsWindowController?.refreshSidebar()
            _settingsMeetingsContentController?.refreshSidebar()
            os_log(
                "meeting processed fully on-device (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
        } catch {
            os_log(
                "fully-on-device meeting processing failed (meetingId: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                event.meetingId.uuidString, String(describing: error)
            )
            eventsContinuation.yield(
                .meetingFailed(id: event.meetingId, error: String(describing: error))
            )
            try? await meetingsStore?.updateProgress(
                id: event.meetingId,
                status: .failed,
                failureReason: String(describing: error)
            )
        }
    }

    // MARK: - Launch recovery from staged manifests

    /// Recover meetings whose processing never finished before a crash /
    /// quit: staging dirs with a `manifest.json` still present. For each,
    /// rebuild the finalized event from the manifest and re-run the
    /// processing pipeline so the fully recorded meeting reaches the UI.
    ///
    /// `internal` so the durability tests can await it directly. Wired
    /// into the launch flow by `resumePendingProcessingOnLaunch`.
    func recoverFinalizeManifestsOnLaunch() async {
        guard config.isEnabled, let stagingRoot = recorderStagingRoot else { return }
        let entries = manifestStore.scan(stagingRoot: stagingRoot)
        guard !entries.isEmpty else { return }

        os_log(
            "manifest recovery scan found candidates (count: %{public}d)",
            log: Self.log, type: .info,
            entries.count
        )

        for entry in entries {
            let dir = entry.dir
            // A meeting that already reached the store (note on disk) needs no
            // re-processing: drop the stale manifest and move on.
            if await restoreReadyLocalMeetingIfPresent(meetingId: entry.manifest.recorderMeetingId) {
                manifestStore.delete(in: dir)
                continue
            }
            // Recovered recordings never re-nudge for reconnect: they are
            // processed as-is (the grace window ended with the previous run).
            guard let event = Self.finalizedEvent(from: entry.manifest, in: dir) else {
                os_log(
                    "manifest recovery skipped — no chunks on disk (dir: %{public}@)",
                    log: Self.log, type: .error,
                    dir.lastPathComponent
                )
                continue
            }
            os_log(
                "manifest recovered (dir: %{public}@)",
                log: Self.log, type: .info,
                dir.lastPathComponent
            )
            await dispatchFinalizedForProcessing(
                event: event,
                startedAt: entry.manifest.startedAt,
                endedAt: entry.manifest.endedAt,
                reconnectMarkers: entry.manifest.reconnectMarkers ?? [],
                language: entry.manifest.language
            )
        }
    }

    /// Root the recorder factory stages chunks under, resolved from the
    /// injected `recorderStagingRoot` closure. `nil` when no factory is wired
    /// (early-stage tests).
    private var recorderStagingRoot: URL? { stagingRootProvider?() }

    /// Rebuild a `FinalizedEvent` from a persisted manifest. Chunks the
    /// manifest names but that no longer exist on disk are dropped; when no
    /// mixed chunk survives the recording is unrecoverable.
    static func finalizedEvent(
        from manifest: MeetingFinalizeManifest,
        in dir: URL
    ) -> MeetingRecorder.FinalizedEvent? {
        let fm = FileManager.default
        let chunkURLs = manifest.chunkFileNames
            .map { dir.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !chunkURLs.isEmpty else { return nil }
        var event = MeetingRecorder.FinalizedEvent(
            meetingId: manifest.recorderMeetingId,
            chunkURLs: chunkURLs,
            totalDurationSeconds: TimeInterval(manifest.durationSeconds),
            reason: .user,
            interruptedBySleep: false
        )
        // The fully-local pipeline consumes the whole un-mixed tracks the
        // recorder writes beside the chunks (`MeetingRecorder` names them
        // `mic.wav` / `system.wav`). Present only for recordings made with
        // `retainSeparateTracks` on.
        let micTrack = dir.appendingPathComponent("mic.wav")
        let systemTrack = dir.appendingPathComponent("system.wav")
        if fm.fileExists(atPath: micTrack.path), fm.fileExists(atPath: systemTrack.path) {
            event.separateTrackURLs = MeetingRecorder.SeparateTrackURLs(
                micURL: micTrack,
                systemURL: systemTrack
            )
        }
        return event
    }

    // MARK: - Stage 9 sleep / wake lifecycle hooks

    /// Called from `AppDelegate`'s `PowerStateCoordinator.onPause`
    /// (i.e. `NSWorkspace.willSleepNotification`) when system sleep is
    /// about to begin. If a meeting recording is active, flush the
    /// in-flight chunk to disk, release audio inputs, and
    /// transition the pill into `.paused` so the user sees the dimmed
    /// waveform + Paused affordance instead of a frozen recording
    /// indicator while the Mac is asleep.
    ///
    /// No-op when no recorder is active — concurrent state-transition
    /// guard for the case where sleep fires while the pill is still
    /// in `.suggesting` or `.hidden`.
    ///
    /// Wired pattern (Stage 9 plan §AppDelegate):
    /// ```
    /// PowerStateCoordinator(
    ///   onPause: { [weak self] in
    ///     self?.pauseRuntimeForSleep()
    ///     Task { @MainActor [weak self] in
    ///       await self?.meetingsCoordinator?.pauseRecordingIfActive()
    ///     }
    ///   },
    ///   ...
    /// )
    /// ```
    func pauseRecordingIfActive() async {
        guard let recorder = activeRecorder else {
            os_log(
                "sleep observed but no recording active — pause no-op",
                log: Self.log, type: .info
            )
            return
        }
        guard let meetingId = recorder.meetingId else { return }
        os_log(
            "sleep observed during recording (meetingId: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString
        )

        // Provenance guard: if the user already paused the recording
        // before sleep arrived, do NOT overwrite the user provenance with
        // `.system`. Doing so would let the subsequent wake call
        // auto-resume a recording the user deliberately paused — a
        // privacy violation. When the recording is already paused the
        // recorder.pause() call is also a no-op at the writer level
        // (MeetingRecorder's gate), so we can skip it safely.
        if recorder.isPaused && pauseProvenance == .user {
            os_log(
                "sleep observed but recording already user-paused — provenance unchanged",
                log: Self.log, type: .info
            )
            return
        }

        // Mark as system-paused BEFORE calling pause() so the provenance
        // is consistent with the recorder's state the instant pause() returns.
        pauseProvenance = .system
        await recorder.pause()
        // Transition the pill directly via `show(.paused(...))` so the
        // pill does NOT emit a `.pause` event (those are reserved for
        // the user-initiated path through the Pause button — calling
        // `controller.pause()` here would loop back into the coordinator
        // via `handlePillEvent`).
        let duration = currentRecorderDuration()
        pill?.show(.paused(
            meetingId: meetingId,
            audioLevel: 0,
            duration: duration
        ))
    }

    /// Called from `AppDelegate`'s `PowerStateCoordinator.onRearm` on
    /// both `.full` (paired sleep + wake) and `.soft` (wake without a
    /// preceding will-sleep). If `pauseProvenance == .system` (the
    /// coordinator paused on behalf of OS sleep), try to resume the recorder:
    ///
    /// - **Success** → pill flips back to `.recording`.
    /// - **Failure** (audio cannot be reattached post-sleep — Apple
    ///   known issue) → finalize the recording via
    ///   `recorder.stop(.systemError, interruptedBySleep: true)` so
    ///   the partial recording still reaches the processor with the
    ///   sleep marker set.
    ///
    /// `.soft` and `.full` take the same code path: per
    /// `PowerStateCoordinator` doc, `.soft` indicates the wake fired
    /// without a paired pause so the kernel may have silently invalidated
    /// audio output anyway — defensive reinstall + resume is the
    /// safest action in both cases.
    ///
    /// No-op when there is no active recorder, or when the pause was
    /// user-initiated (`pauseProvenance == .user`). User-paused
    /// recordings are only resumed by the user's own tap on the pill's
    /// play button (via `handlePillEvent(.resume)`), never by the wake
    /// path — that would silently override deliberate user intent (privacy
    /// bug: the user paused because they didn't want audio captured right
    /// now, and a wake-induced resume would restart capture without consent).
    ///
    /// Returns the forced `FinalizedEvent` when resume fails and the
    /// coordinator falls back to `recorder.stop(.systemError, ...)`.
    /// Returns `nil` on the success path and on no-op. Production
    /// callers (`AppDelegate`'s onRearm closure) discard the return —
    /// the event is also delivered through the recorder's finalize
    /// stream so the coordinator's existing drain task picks it up
    /// for upload. The return is here so unit tests can observe the
    /// `interruptedBySleep` flag without racing the stream consumer.
    @discardableResult
    func resumeRecordingIfPaused(
        reason: PowerStateCoordinator.WakeReason
    ) async -> MeetingRecorder.FinalizedEvent? {
        guard let recorder = activeRecorder, let meetingId = recorder.meetingId else {
            return nil
        }
        // Only auto-resume recordings that were paused by the SYSTEM (sleep).
        // A user-paused recording stays paused through sleep/wake cycles until
        // the user explicitly taps the play button. Checking provenance rather
        // than pill state avoids the ambiguity: both sleep-pause and user-pause
        // land the pill in `.paused`, so pill state alone cannot distinguish them.
        guard pauseProvenance == .system else {
            if pauseProvenance == .user {
                os_log(
                    "wake observed but pause was user-initiated — skipping auto-resume (meetingId: %{public}@)",
                    log: Self.log, type: .info,
                    meetingId.uuidString
                )
            }
            return nil
        }
        os_log(
            "wake observed (reason: %{public}@, meetingId: %{public}@)",
            log: Self.log, type: .info,
            reason == .full ? "full" : "soft",
            meetingId.uuidString
        )
        do {
            try await recorder.resume()
            // Resume succeeded: the recorder is active again, no current
            // pause. Clear provenance so the coordinator is back to a
            // clean running state.
            pauseProvenance = nil
            let duration = currentRecorderDuration()
            pill?.show(.recording(
                meetingId: meetingId,
                audioLevel: 0,
                duration: duration
            ))
            os_log(
                "recording resumed (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
            return nil
        } catch {
            os_log(
                "audio reattach failed (meetingId: %{public}@, error: %{public}@) — finalizing partial recording",
                log: Self.log, type: .error,
                meetingId.uuidString, String(describing: error)
            )
            // The pause is over either way — clear provenance here, at the
            // decision point. (`handleFinalizedEvent` also clears it via the
            // finalize stream, but this branch should not depend on that.)
            pauseProvenance = nil
            // Force-finalize: drop into the existing finalize stream
            // path with the sleep-interruption marker so the processing
            // pipeline can flag the partial transcript.
            let event = await recorder.stop(reason: .systemError, interruptedBySleep: true)
            os_log(
                "recording finalized due to reattach failure (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
            return event
        }
    }

    /// Map a stop reason to its observability label. Centralised so the
    /// `os_log` formatter in `handleFinalizedEvent` does not have to
    /// drift from the recorder's own `reasonLabel` if a new case lands.
    private static func reasonLabel(_ reason: MeetingRecorderStopReason) -> String {
        switch reason {
        case .user: return "user"
        case .autoEnd: return "auto_end"
        case .forced: return "forced"
        case .systemError: return "system_error"
        }
    }

    /// Returns true when a locally durable note makes recovery unnecessary.
    /// The markdown file is the source of truth: a row may say `.failed`,
    /// but the complete note still exists. Repair that stale status to
    /// `.ready` in place.
    private func restoreReadyLocalMeetingIfPresent(meetingId: UUID) async -> Bool {
        guard let store = meetingsStore else { return false }
        let status = try? await store.progressStatus(id: meetingId)
        let hasLocalNote = (try? await store.markdown(id: meetingId)) != nil
        guard status == .ready || hasLocalNote else { return false }

        if status != .ready, hasLocalNote {
            _ = try? await store.updateProgress(id: meetingId, status: .ready)
            refreshOpenWindowIfNeeded()
            os_log(
                "repaired stale progress status from durable local note (meetingId: %{public}@)",
                log: Self.log, type: .info,
                meetingId.uuidString
            )
        }
        return true
    }

    // MARK: - Edit persistence

    /// Persist a note edit. Called by `MeetingsEditBridge` once a 500 ms
    /// debounce window expires. Writes the new markdown into the local store
    /// with a bumped version so the sidebar / viewer stay in step.
    func saveNoteEdit(id: UUID, markdown: String, clientVersion: Int) async {
        guard let store = meetingsStore else {
            os_log(
                "saveNoteEdit no-op (meetingsStore nil)",
                log: Self.log, type: .info
            )
            return
        }
        let version = clientVersion + 1
        do {
            try await store.update(id: id, markdown: markdown, version: version)
            try await store.updateTitle(id: id, title: Self.extractH1Title(from: markdown))
            os_log(
                "save persisted (meetingId: %{public}@, version: %{public}d)",
                log: Self.log, type: .info,
                id.uuidString, version
            )
        } catch {
            os_log(
                "saveNoteEdit store update failed (meetingId: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
        }
    }

    // MARK: - Manual refresh (sidebar context menu)

    /// Re-derive the sidebar title from the stored note and refresh the open
    /// notes surfaces. Wired to the sidebar's "Refresh" context-menu item;
    /// safe to call from any context.
    func repairLocalTitle(id: UUID) async {
        guard let store = meetingsStore else {
            os_log(
                "repairLocalTitle no-op (meetingsStore nil, meetingId: %{public}@)",
                log: Self.log, type: .info,
                id.uuidString
            )
            return
        }
        await backfillLocalTitle(id: id, store: store)
        refreshOpenWindowIfNeeded()
        _meetingsWindowController?.reloadMeeting(id: id)
    }

    /// Repair a meeting's stored title from its LOCAL note markdown's H1 — no
    /// network. Fixes notes synced before the extractor skipped the protocol
    /// marker. Idempotent: a no-op when the title already matches.
    private func backfillLocalTitle(id: UUID, store: MeetingsStore) async {
        guard let markdown = (try? await store.markdown(id: id)) ?? nil else { return }
        guard let extracted = Self.extractH1Title(from: markdown) else { return }
        let current = (try? await store.list())?.first(where: { $0.id == id })?.title
        if extracted != current {
            try? await store.updateTitle(id: id, title: extracted)
            refreshOpenWindowIfNeeded()
        }
    }

    private static func progressMeta(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int,
        status: MeetingProgressStatus
    ) -> MeetingMetaWithLocalState {
        MeetingMetaWithLocalState(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            title: nil,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: endedAt,
            progressStatus: status,
            statusUpdatedAt: Date()
        )
    }

    static func insertingReconnectMarkers(
        _ markers: [TranscriptReconnectMarker],
        into transcript: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !markers.isEmpty else { return transcript }
        let synthetic = markers.map { marker in
            let seconds = max(0, Int(marker.gapSeconds.rounded()))
            let minutes = seconds / 60
            let remainder = seconds % 60
            let gap = minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
            return TranscriptSegment(
                speaker: "Whytap",
                start: marker.afterAudioSeconds,
                end: marker.afterAudioSeconds,
                text: "Reconnected after \(gap)"
            )
        }
        return (transcript + synthetic).sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
    }

    private func persistReconnectMarkersIfNeeded(
        _ markers: [TranscriptReconnectMarker],
        meetingId: UUID
    ) async throws {
        guard !markers.isEmpty, let meetingsStore,
              let transcript = try await meetingsStore.transcript(id: meetingId) else {
            return
        }
        try await meetingsStore.updateTranscript(
            id: meetingId,
            transcript: Self.insertingReconnectMarkers(markers, into: transcript)
        )
    }

    /// Pulls the first H1 heading out of `markdown` to use as the
    /// sidebar title. Tolerant of leading blank lines / BOM / extra
    /// whitespace; returns nil if no H1 sits at the top of the doc so
    /// the sidebar falls back to "Untitled". The prompt contract is
    /// that the markdown ALWAYS starts with `# <title>` — this helper
    /// just defends against weird LLM outputs without crashing.
    static func extractH1Title(from markdown: String) -> String? {
        for rawLine in markdown.split(separator: "\n", maxSplits: 16, omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Skip a leading HTML-comment marker (the structured-protocol
            // `<!-- protocol:v1 -->` tag) so the H1 right below it is found.
            if line.hasPrefix("<!--") { continue }
            guard line.hasPrefix("# ") else { return nil }
            let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }
}
