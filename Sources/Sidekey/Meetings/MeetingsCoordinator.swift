import Combine
import Foundation
import Security
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

    /// Shown on a meeting row when a recording finished but no provider is
    /// chosen to process it. The staged audio is kept for retries for up to
    /// `failedRecordingRetention`.
    static let processorNotConfiguredMessage =
        "Choose models for Meetings and Meeting notes in Settings > API & Models to process this meeting."

    /// Shown on a meeting whose note still failed when its audio expired.
    static let recordingExpiredMessage =
        "The recording was deleted after 24 hours without a finished note."

    /// A notes retry was cut short by quitting Whytap.
    static let notesInterruptedMessage =
        "Writing the notes was interrupted. " + MeetingNotesFailure.transcriptKept

    /// The same, when the transcript was already made: only the audio goes.
    static let recordingExpiredTranscriptKeptMessage =
        "The recording was deleted after 24 hours. " + MeetingNotesFailure.transcriptKept

    /// Whytap keeps meeting audio only while it can still become a note: a
    /// recording whose processing still fails this long after its last chunk
    /// is deleted, and nothing retries it.
    /// WHY: .project-docs/decisions/2026-10-22-no-retained-meeting-audio.md
    nonisolated static let failedRecordingRetention: TimeInterval = 24 * 60 * 60

    /// A staged directory without a manifest has no recovery path. It goes
    /// once nothing has written to it for this long; the margin covers a
    /// recording that is still being written or just stopping.
    nonisolated static let unmanagedRecordingGrace: TimeInterval = 60 * 60

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
        var continuation: MeetingContinuation? = nil
        var meetingId: UUID { continuation?.meetingId ?? event.meetingId }
        var audioDuration: TimeInterval { (continuation?.audioOffsetSeconds ?? 0) + event.totalDurationSeconds }
        var rootStartedAt: Date { continuation?.startedAt ?? startedAt }

        var answerDeadline: Date? = nil
        var eligibleUntil: Date { endedAt.addingTimeInterval(MeetingsConfig.reconnectGracePeriodSeconds) }
        var deadline: Date { max(eligibleUntil, answerDeadline ?? eligibleUntil) }
    }

    private struct ActiveReconnect {
        let recordingId: UUID
        let continuation: MeetingContinuation
        var accumulatedDuration: TimeInterval { continuation.audioOffsetSeconds }
    }

    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var processingTails: [UUID: UUID] = [:]
    /// Meetings whose notes are being written again from a kept transcript.
    private var notesRetries: Set<UUID> = []

    /// Injectable clock for the reconnect grace/silent-window math so
    /// tests can move time without sleeping. Production: `Date.init`.
    private let now: () -> Date

    /// True while `startRecorder` is suspended in `recorder.start()`.
    /// The MainActor is re-entrant across that await; this flag is what
    /// keeps a concurrent start request (detector trigger, manual ⌥M,
    /// silent reconnect) from slipping past the nil-`activeRecorder`
    /// guard in that window.
    private var recorderStartInFlight = false
    /// The recording whose recorder is still starting. Its staging directory
    /// exists before `activeRecorder` is set, while the microphone start may
    /// wait for the user's permission answer.
    private var startingRecorderId: UUID?

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
            },
            deleteHandler: { [weak self] id in
                await self?.deleteMeeting(id: id) ?? false
            }
        )
        _meetingsWindowController = controller
        controller.contentController.notesRecovery = notesRecovery(store: store)
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
            deleteHandler: { [weak self] id in
                await self?.deleteMeeting(id: id) ?? false
            },
            // Settings top bar sits in the detail pane (right of the sidebar) —
            // no traffic lights above it, so the big 72pt inset isn't needed.
            topBarLeadingInset: 16
        )
        controller.notesRecovery = notesRecovery(store: store)
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
        _editBridgeCancellables.append(bridge.editEvents.sink { [weak self, weak bridge] event in
            Task { @MainActor in
                guard let self, let bridge else { return }
                let saved = await self.saveNoteEdit(
                    id: event.meetingId,
                    markdown: event.markdown,
                    clientVersion: event.clientVersion
                )
                bridge.finishSave(event, succeeded: saved)
                if saved { self.refreshOpenWindowIfNeeded() }
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
    /// pending recordings survive the next launch. Audio that is no longer
    /// needed is released even with Meeting Notes switched off.
    func resumePendingProcessingOnLaunch() {
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
                if var previous = pendingReconnect, now() <= previous.eligibleUntil {
                    // A prompt offered just before three minutes must retain
                    // its candidate for the full visible decision window.
                    previous.answerDeadline = now().addingTimeInterval(MeetingsConfig.pillDecisionTimeoutSeconds)
                    stagePendingReconnect(previous)
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
                        previousMeetingId: previous.meetingId,
                        gapSeconds: gapSeconds,
                        deadline: deadline
                    ))
                } else {
                    if pendingReconnect != nil {
                        clearPendingReconnect()
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
                clearPendingReconnect()
            }

        case .accept(let meetingId, let snapshot):
            os_log(
                "coordinator received pill accept (meetingId: %{public}@, snapshot_bytes: %{public}d)",
                log: Self.log, type: .info,
                meetingId.uuidString, snapshot.count
            )
            if pendingReconnect != nil {
                clearPendingReconnect()
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
                  pending.meetingId == previousMeetingId,
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

            let continuation = MeetingContinuation(
                meetingId: previousMeetingId, precedingRecordingId: pending.event.meetingId,
                startedAt: pending.rootStartedAt, audioOffsetSeconds: pending.audioDuration,
                gapSeconds: max(0, gapSeconds), partNumber: (pending.continuation?.partNumber ?? 1) + 1
            )
            let recordingId = UUID()
            activeReconnect = ActiveReconnect(recordingId: recordingId, continuation: continuation)
            // Never reuse a directory that the first part's processor can
            // delete, or its provider checkpoint for a different audio set.
            if let root = recorderStagingRoot {
                var manifest = MeetingFinalizeManifest(recorderMeetingId: recordingId,
                    startedAt: now(), endedAt: now(), durationSeconds: 0,
                    language: config.preferredLanguage, chunkFileNames: [], isFinal: false)
                manifest.continuation = continuation
                do { try manifestStore.write(manifest, to: root.appendingPathComponent(recordingId.uuidString)) }
                catch {
                    activeReconnect = nil
                    stagePendingReconnect(pending)
                    return
                }
            }
            let started = await startRecorder(meetingId: recordingId, prerecordSnapshot: snapshot)
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
        startingRecorderId = meetingId
        defer {
            recorderStartInFlight = false
            startingRecorderId = nil
        }
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
        clearPendingReconnect()
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
        let continuation = activeReconnect?.continuation
        let combinedEvent = event
        let endedAt = now()
        let language = config.preferredLanguage

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
        pill?.hide()

        if combinedEvent.reason == .autoEnd {
            stagePendingReconnect(PendingReconnect(
                event: combinedEvent,
                startedAt: startedAt,
                endedAt: endedAt,
                continuation: continuation
            ))
        }

        if config.isEnabled {
            _ = enqueueFinalizedRecording(event: combinedEvent, startedAt: startedAt, endedAt: endedAt,
                reconnectMarkers: [], language: language, continuation: continuation)
        }
        // Publish the completed part and reconnect candidate before yielding.
        // Cleanup may suspend while the detector already reports a new call;
        // it must never hide that call's newer suggestion afterward.
        if let buffer { await buffer.gc() }
    }

    private func stagePendingReconnect(_ pending: PendingReconnect) {
        pendingReconnectExpiryTask?.cancel()
        pendingReconnect = pending
        let delay = max(0, pending.deadline.timeIntervalSince(now()))
        pendingReconnectExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  self?.pendingReconnect?.event.meetingId == pending.event.meetingId else { return }
            self?.clearPendingReconnect()
        }
    }

    /// The three-minute candidate is only a UI choice; processing already
    /// started when this part ended. Skip/expiry never dispatch it twice.
    private func clearPendingReconnect() {
        pendingReconnect = nil
        pendingReconnectExpiryTask?.cancel()
        pendingReconnectExpiryTask = nil
    }

    // MARK: - FinalizedEvent -> processing pipeline

    /// Route a finalized recording to the BYOK processor (user's own STT +
    /// LLM providers). Pulled out of `handleFinalizedEvent` so the cleanup
    /// path stays readable.
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
        reconnectMarkers: [TranscriptReconnectMarker] = [],
        continuation: MeetingContinuation? = nil
    ) async {
        await dispatchFinalizedForProcessing(
            event: event,
            startedAt: startedAt,
            endedAt: endedAt,
            reconnectMarkers: reconnectMarkers,
            language: config.preferredLanguage, continuation: continuation
        )
    }

    /// Core of `dispatchFinalizedForProcessing` with the protocol language
    /// pinned explicitly: a fresh Stop passes the current preference, manifest
    /// recovery passes the language captured at Stop time so a toggle between
    /// the failed Stop and the relaunch does not change the recovered meeting.
    func dispatchFinalizedForProcessing(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date, endedAt: Date?, reconnectMarkers: [TranscriptReconnectMarker],
        language: String?, continuation: MeetingContinuation? = nil
    ) async {
        guard config.isEnabled else { return }
        await enqueueFinalizedRecording(event: event, startedAt: startedAt, endedAt: endedAt ?? now(),
            reconnectMarkers: reconnectMarkers, language: language, continuation: continuation).value
    }

    /// Register the part before returning from Stop. Arrival order cannot be
    /// reversed by scheduling two detached tasks, and every queued part has its
    /// own durable manifest while earlier parts finish.
    private func enqueueFinalizedRecording(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date, endedAt: Date, reconnectMarkers: [TranscriptReconnectMarker],
        language: String?, continuation: MeetingContinuation?
    ) -> Task<Void, Never> {
        if let existing = processingTasks[event.meetingId] { return existing }
        let meetingId = continuation?.meetingId ?? event.meetingId
        persistFinalizeManifest(event: event, startedAt: startedAt, endedAt: endedAt,
            language: language, reconnectMarkers: reconnectMarkers, continuation: continuation)
        let previous = processingTails[meetingId].flatMap { processingTasks[$0] }
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.processFinalizedRecording(event: event, startedAt: startedAt, endedAt: endedAt,
                reconnectMarkers: reconnectMarkers, language: language, continuation: continuation)
            self.processingTasks[event.meetingId] = nil
            if self.processingTails[meetingId] == event.meetingId { self.processingTails[meetingId] = nil }
        }
        processingTasks[event.meetingId] = task
        processingTails[meetingId] = event.meetingId
        return task
    }

    private func processFinalizedRecording(
        event: MeetingRecorder.FinalizedEvent,
        startedAt: Date, endedAt: Date, reconnectMarkers: [TranscriptReconnectMarker],
        language: String?, continuation: MeetingContinuation?
    ) async {
        guard config.isEnabled else {
            os_log(
                "handleFinalizedEvent processing no-op (feature disabled)",
                log: Self.log, type: .info
            )
            return
        }
        let targetMeetingId = continuation?.meetingId ?? event.meetingId
        if (try? await meetingsStore?.hasProcessedRecording(event.meetingId)) == true {
            // A late duplicate must not reset the edited note's metadata or
            // version before the processor checks its idempotency receipt.
            _ = try? await meetingsStore?.updateProgress(id: targetMeetingId, status: .ready)
            if let directory = event.chunkURLs.first?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: directory)
            }
            eventsContinuation.yield(.newMeetingAvailable(id: targetMeetingId))
            refreshOpenWindowIfNeeded()
            return
        }
        let progressBeforeAttempt = try? await meetingsStore?.progressState(id: targetMeetingId)

        if let meetingsStore, continuation == nil {
            let meta = Self.progressMeta(
                id: targetMeetingId,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: Self.roundedDurationSeconds(event.totalDurationSeconds),
                status: .transcribing
            )
            try? await meetingsStore.upsertProgress(meta: meta, status: .transcribing)
            refreshOpenWindowIfNeeded()
        }

        if continuation != nil {
            try? await meetingsStore?.beginContinuationUpdate(id: targetMeetingId)
            refreshOpenWindowIfNeeded()
        }

        if let directProcessor, directProcessor.shouldProcessDirectly() {
            do {
                let meetingId = try await directProcessor.process(
                    event: event,
                    startedAt: startedAt,
                    language: language,
                    meetingsStore: meetingsStore, continuation: continuation, endedAt: endedAt
                )
                try await persistReconnectMarkersIfNeeded(
                    reconnectMarkers,
                    meetingId: meetingId
                )
                try? await meetingsStore?.updateProgress(id: meetingId, status: .ready)
                eventsContinuation.yield(.newMeetingAvailable(id: meetingId))
                refreshOpenWindowIfNeeded()
            } catch KeychainError.unhandledError(errSecInDarkWake) {
                // macOS cannot show a Keychain prompt in a dark wake or while
                // the lid closes, so this says nothing about the meeting. Keep
                // it staged without a failure event and put back the failure
                // the attempt replaced; startReady() after a full wake retries.
                // WHY: .project-docs/decisions/2026-10-18-meeting-recovery-dark-wake.md
                os_log(
                    "handleFinalizedEvent BYOK processing deferred until full wake (meetingId: %{public}@)",
                    log: Self.log,
                    type: .default,
                    event.meetingId.uuidString
                )
                if progressBeforeAttempt?.status == .failed {
                    try? await meetingsStore?.updateProgress(
                        id: targetMeetingId,
                        status: .failed,
                        failureReason: progressBeforeAttempt?.failureReason
                    )
                }
                refreshOpenWindowIfNeeded()
            } catch {
                os_log(
                    "handleFinalizedEvent BYOK processing failed (meetingId: %{public}@, error: %{public}@)",
                    log: Self.log,
                    type: .error,
                    event.meetingId.uuidString,
                    String(describing: error)
                )
                eventsContinuation.yield(.meetingFailed(id: targetMeetingId, error: String(describing: error)))
                try? await meetingsStore?.updateProgress(
                    id: targetMeetingId,
                    status: .failed,
                    failureReason: String(describing: error)
                )
                refreshOpenWindowIfNeeded()
            }
            return
        }

        // No provider is configured: the recording stays staged (manifest +
        // chunks) and is retried on the next launch once the user has set up
        // BYOK keys in Settings -> API & Models, for at most
        // `failedRecordingRetention`.
        os_log(
            "handleFinalizedEvent no processor configured (meetingId: %{public}@) — recording kept for later",
            log: Self.log, type: .error,
            event.meetingId.uuidString
        )
        eventsContinuation.yield(.meetingFailed(id: targetMeetingId, error: Self.processorNotConfiguredMessage))
        try? await meetingsStore?.updateProgress(
            id: targetMeetingId,
            status: .failed,
            failureReason: Self.processorNotConfiguredMessage
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
        reconnectMarkers: [TranscriptReconnectMarker],
        continuation: MeetingContinuation? = nil
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
        manifest.continuation = continuation
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

    // MARK: - Launch recovery from staged manifests

    /// Recover meetings whose processing never finished before a crash /
    /// quit: staging dirs with a `manifest.json` still present. For each,
    /// rebuild the finalized event from the manifest and re-run the
    /// processing pipeline so the fully recorded meeting reaches the UI.
    ///
    /// `internal` so the durability tests can await it directly. Wired
    /// into the launch flow by `resumePendingProcessingOnLaunch`.
    func recoverFinalizeManifestsOnLaunch() async {
        guard let stagingRoot = recorderStagingRoot else { return }
        await releaseUnneededStagedRecordings(in: stagingRoot)
        await failInterruptedNotesRetries(stagingRoot: stagingRoot)
        guard config.isEnabled else { return }
        let entries = manifestStore.scan(stagingRoot: stagingRoot)
        guard !entries.isEmpty else { return }

        os_log(
            "manifest recovery scan found candidates (count: %{public}d)",
            log: Self.log, type: .info,
            entries.count
        )

        for scannedEntry in entries.sorted(by: { $0.manifest.startedAt < $1.manifest.startedAt }) {
            var entry = scannedEntry
            let dir = entry.dir
            // Wake recovery must never consume or clean a live recorder's
            // partial continuation manifest, including its suspended start.
            if entry.manifest.recorderMeetingId == activeRecorder?.meetingId
                || entry.manifest.recorderMeetingId == activeReconnect?.recordingId { continue }
            if let task = processingTasks[entry.manifest.recorderMeetingId] { await task.value }
            // Earlier work can suspend this pass while Stop replaces a partial
            // manifest. Preserve the final chunk list, language and end time.
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(MeetingFinalizeManifest.fileName)),
                  let latest = try? JSONDecoder().decode(MeetingFinalizeManifest.self, from: data) else { continue }
            entry = MeetingFinalizeManifestStore.Entry(dir: dir, manifest: latest)
            // A meeting that already reached the store (note on disk) needs no
            // re-processing, and its staged recording is the leftover of a run
            // that stopped after the insert: release it and move on.
            let committed = (try? await meetingsStore?.hasProcessedRecording(entry.manifest.recorderMeetingId)) == true
            if committed {
                let target = entry.manifest.continuation?.meetingId ?? entry.manifest.recorderMeetingId
                _ = try? await meetingsStore?.updateProgress(id: target, status: .ready)
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            if entry.manifest.continuation == nil,
               await restoreReadyLocalMeetingIfPresent(meetingId: entry.manifest.recorderMeetingId) {
                releaseStagedRecording(in: dir)
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
                endedAt: entry.manifest.isFinal ? entry.manifest.endedAt
                    : entry.manifest.startedAt.addingTimeInterval(event.totalDurationSeconds),
                reconnectMarkers: entry.manifest.reconnectMarkers ?? [],
                language: entry.manifest.language, continuation: entry.manifest.continuation
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
    nonisolated static func finalizedEvent(
        from manifest: MeetingFinalizeManifest,
        in dir: URL
    ) -> MeetingRecorder.FinalizedEvent? {
        let fm = FileManager.default
        let names: [String]
        if manifest.isFinal {
            names = manifest.chunkFileNames
        } else {
            names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
                $0.hasPrefix("chunk-") && $0.hasSuffix(".wav")
            }.sorted()
        }
        let chunkURLs = names
            .map { dir.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !chunkURLs.isEmpty else { return nil }
        return MeetingRecorder.FinalizedEvent(
            meetingId: manifest.recorderMeetingId,
            chunkURLs: chunkURLs,
            totalDurationSeconds: manifest.isFinal ? TimeInterval(manifest.durationSeconds) : chunkURLs.reduce(0) {
                $0 + Double((try? MeetingPCM16WAVReader.readPCM16Data(from: $1).count) ?? 0) / 32_000
            },
            reason: .user,
            interruptedBySleep: false
        )
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

    /// Frees the staged recording of a meeting that is already stored. The
    /// processors remove it right after the insert, so what is still here
    /// belongs to a run that stopped in between. A ready row without a note
    /// loses it too: no audio is kept once processing is over.
    /// WHY: .project-docs/decisions/2026-10-18-delete-meeting-and-staged-audio.md,
    /// .project-docs/decisions/2026-10-22-no-retained-meeting-audio.md
    private func releaseStagedRecording(in dir: URL) {
        do {
            try FileManager.default.removeItem(at: dir)
            os_log(
                "released staged recording of a stored meeting (dir: %{public}@)",
                log: Self.log, type: .info,
                dir.lastPathComponent
            )
        } catch {
            os_log(
                "could not release staged recording (dir: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                dir.lastPathComponent, String(describing: error)
            )
            manifestStore.delete(in: dir)
        }
    }

    // MARK: - Staged audio retention

    /// Meeting audio stays on disk only while it can still become a note.
    /// A directory without a decodable manifest has no recovery path and goes
    /// once nothing wrote to it for `unmanagedRecordingGrace`
    /// (`failedRecordingRetention` when an unreadable manifest is present).
    /// A recording whose note still failed `failedRecordingRetention` after
    /// its last chunk is deleted, and its meeting keeps a failure saying so.
    /// The active recording, a live Reconnect part, recordings being processed
    /// and directories not named by a recording id are never touched.
    /// WHY: .project-docs/decisions/2026-10-22-no-retained-meeting-audio.md
    private func releaseUnneededStagedRecordings(in stagingRoot: URL) async {
        let current = now()
        let manifests = manifestStore
        // Listing, dating and removal stay off the main thread; what a
        // recording uses is checked here, again after every suspension.
        let found = await Task.detached(priority: .utility) {
            Self.releasableStagedRecordings(in: stagingRoot, at: current, manifestStore: manifests)
        }.value

        let unmanaged = found.unmanaged.filter { dir in
            UUID(uuidString: dir.lastPathComponent).map { !isStagedRecordingInUse($0) } ?? false
        }
        if !unmanaged.isEmpty {
            let removed = await Self.removeDirectories(unmanaged)
            os_log(
                "released staged recordings without a manifest (removed: %{public}d, candidates: %{public}d)",
                log: Self.log, type: .info,
                removed, unmanaged.count
            )
        }

        var changedRows = false
        for entry in found.expired {
            if await expireStagedRecording(entry) { changedRows = true }
        }
        if changedRows { refreshOpenWindowIfNeeded() }
    }

    /// Deletes one recording whose retry window is over and settles its
    /// meeting: a committed recording or a Reconnect part of a meeting that
    /// keeps its note leaves that meeting ready; anything else stays failed
    /// with `recordingExpiredMessage`. Returns whether a row changed.
    private func expireStagedRecording(_ entry: MeetingFinalizeManifestStore.Entry) async -> Bool {
        let recordingId = entry.manifest.recorderMeetingId
        guard !isStagedRecordingInUse(recordingId) else { return false }
        let target = entry.manifest.continuation?.meetingId ?? recordingId
        let committed = (try? await meetingsStore?.hasProcessedRecording(recordingId)) == true
        guard !isStagedRecordingInUse(recordingId),
              await Self.removeDirectories([entry.dir]) == 1 else { return false }
        os_log(
            "expired staged recording removed (dir: %{public}@, committed: %{public}d)",
            log: Self.log, type: .info,
            entry.dir.lastPathComponent, committed ? 1 : 0
        )
        var keepsNote = false
        if !committed, entry.manifest.continuation != nil {
            keepsNote = ((try? await meetingsStore?.markdown(id: target)) ?? nil) != nil
                && !hasContinuationWork(for: target)
        }
        let ready = committed || keepsNote
        // A transcript made before the note failed outlives the audio.
        var keptTranscript = false
        if entry.manifest.continuation != nil {
            // A continued call's part that never got its notes: its meeting
            // keeps the earlier note, and nothing can show or retry this
            // transcript once the audio is gone.
            try? await meetingsStore?.removePendingTranscript(recordingId: recordingId)
        } else if !ready {
            let kept = (try? await meetingsStore?.pendingTranscript(recordingId: recordingId)) ?? nil
            keptTranscript = kept?.isEmpty == false
        }
        // The store never moves `.ready` back, so a stored note stays ready.
        let updated = try? await meetingsStore?.updateProgress(
            id: target,
            status: ready ? .ready : .failed,
            failureReason: ready ? nil
                : keptTranscript ? Self.recordingExpiredTranscriptKeptMessage : Self.recordingExpiredMessage
        )
        return updated == true
    }

    /// Whether another part of `meetingId` is recording, queued, processing or
    /// still staged, so its status belongs to that part.
    private func hasContinuationWork(for meetingId: UUID) -> Bool {
        if activeReconnect?.continuation.meetingId == meetingId || processingTails[meetingId] != nil {
            return true
        }
        guard let stagingRoot = recorderStagingRoot else { return false }
        return manifestStore.scan(stagingRoot: stagingRoot)
            .contains { $0.manifest.continuation?.meetingId == meetingId }
    }

    private func isStagedRecordingInUse(_ id: UUID) -> Bool {
        id == activeRecorder?.meetingId || id == startingRecorderId
            || id == activeReconnect?.recordingId || processingTasks[id] != nil
    }

    /// UUID-named directories nothing can process any more (no decodable
    /// manifest, quiet for `unmanagedRecordingGrace`, or for
    /// `failedRecordingRetention` with an undecodable one) and recordings
    /// whose newest chunk is older than `failedRecordingRetention`.
    nonisolated static func releasableStagedRecordings(
        in stagingRoot: URL,
        at current: Date,
        manifestStore: MeetingFinalizeManifestStore
    ) -> (unmanaged: [URL], expired: [MeetingFinalizeManifestStore.Entry]) {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        guard !dirs.isEmpty else { return ([], []) }
        var managed: [String: MeetingFinalizeManifestStore.Entry] = [:]
        for entry in manifestStore.scan(stagingRoot: stagingRoot) {
            managed[entry.dir.lastPathComponent] = entry
        }
        var unmanaged: [URL] = []
        var expired: [MeetingFinalizeManifestStore.Entry] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  UUID(uuidString: dir.lastPathComponent) != nil else { continue }
            if let entry = managed[dir.lastPathComponent] {
                if let written = lastRecordedWrite(in: dir),
                   current.timeIntervalSince(written) >= failedRecordingRetention {
                    expired.append(entry)
                }
            } else {
                let window = manifestStore.manifestExists(in: dir)
                    ? failedRecordingRetention : unmanagedRecordingGrace
                if let written = lastWrite(in: dir), current.timeIntervalSince(written) >= window {
                    unmanaged.append(dir)
                }
            }
        }
        return (unmanaged, expired)
    }

    /// Removes the directories off the main thread; returns how many went.
    private nonisolated static func removeDirectories(_ dirs: [URL]) async -> Int {
        await Task.detached(priority: .utility) {
            dirs.filter { (try? FileManager.default.removeItem(at: $0)) != nil }.count
        }.value
    }

    /// When the recording's audio was last written: its newest chunk, which
    /// retries never rewrite (they rewrite the manifest and the Soniox
    /// checkpoint). Without chunks, the newest entry of the directory.
    nonisolated static func lastRecordedWrite(in dir: URL) -> Date? {
        guard let dates = modificationDates(in: dir) else { return nil }
        let chunks = dates.filter {
            $0.key.hasPrefix("chunk-") && $0.key.hasSuffix(".wav")
        }
        return chunks.values.max() ?? lastWrite(in: dir)
    }

    /// The newest modification of the directory itself or any direct entry;
    /// `nil` when the directory cannot be read, which keeps it.
    nonisolated static func lastWrite(in dir: URL) -> Date? {
        guard let own = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return nil }
        guard let dates = modificationDates(in: dir) else { return nil }
        return max(own, dates.values.max() ?? own)
    }

    private nonisolated static func modificationDates(in dir: URL) -> [String: Date]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var dates: [String: Date] = [:]
        for url in urls {
            // An incomplete view of the directory cannot prove that its
            // newest recording is old enough to delete.
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
                return nil
            }
            dates[url.lastPathComponent] = date
        }
        return dates
    }

    // MARK: - Edit persistence

    /// Persist a note edit. Called by `MeetingsEditBridge` once a 500 ms
    /// debounce window expires. Writes the new markdown into the local store
    /// with a bumped version so the sidebar / viewer stay in step. A save that
    /// lands after Delete finds no meeting and is dropped quietly: nothing is
    /// written and no alert is shown.
    @discardableResult
    func saveNoteEdit(id: UUID, markdown: String, clientVersion: Int) async -> Bool {
        guard let store = meetingsStore else {
            os_log(
                "saveNoteEdit no-op (meetingsStore nil)",
                log: Self.log, type: .info
            )
            return false
        }
        let version = clientVersion + 1
        do {
            guard try await store.update(id: id, markdown: markdown, version: version) else {
                os_log(
                    "save skipped: meeting no longer stored (meetingId: %{public}@)",
                    log: Self.log, type: .info,
                    id.uuidString
                )
                return false
            }
            try await store.updateTitle(id: id, title: Self.extractH1Title(from: markdown))
            os_log(
                "save persisted (meetingId: %{public}@, version: %{public}d)",
                log: Self.log, type: .info,
                id.uuidString, version
            )
            return true
        } catch {
            os_log(
                "saveNoteEdit store update failed (meetingId: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
            return false
        }
    }

    // MARK: - Delete

    /// Deletes one meeting for good: its staged recording, row, note and
    /// transcript. `false` when the meeting is unknown, still being
    /// processed, or something could not be removed; the meeting then stays in
    /// the list so the user can retry. The staged recording goes first: while
    /// its manifest exists, launch recovery would bring the meeting back.
    /// WHY: .project-docs/decisions/2026-10-18-delete-meeting-and-staged-audio.md
    private func notesRecovery(store: MeetingsStore) -> MeetingNotesRecovery {
        MeetingNotesRecovery(
            keptTranscript: { id in try await store.transcriptAwaitingNote(meetingId: id) },
            retryNotes: { [weak self] id in _ = await self?.retryNotes(meetingId: id) }
        )
    }

    /// Retry notes in the note pane: writes the note of a failed meeting from
    /// its kept transcript. The recording is not needed and the speech
    /// provider is not called. `false` when nothing was written.
    // WHY: .project-docs/decisions/2026-11-19-meeting-transcript-kept.md
    @discardableResult
    func retryNotes(meetingId: UUID) async -> Bool {
        guard let store = meetingsStore, let directProcessor,
              activeReconnect?.continuation.meetingId != meetingId, processingTails[meetingId] == nil,
              !notesRetries.contains(meetingId),
              let meta = (try? await store.list())?.first(where: { $0.id == meetingId }),
              meta.progressStatus == .failed
        else {
            // The pane is showing "Writing the notes…": put its real state back.
            refreshOpenWindowIfNeeded()
            return false
        }
        // While the recording is still staged, the retry is the ordinary
        // queued run: it keeps the language and reconnect markers captured at
        // Stop, cannot overlap launch recovery, and reuses the kept
        // transcript, so the speech provider is still not called.
        if let stagingRoot = recorderStagingRoot,
           let entry = manifestStore.scan(stagingRoot: stagingRoot).first(where: {
               $0.manifest.recorderMeetingId == meetingId && $0.manifest.continuation == nil
           }),
           let event = Self.finalizedEvent(from: entry.manifest, in: entry.dir) {
            await dispatchFinalizedForProcessing(
                event: event,
                startedAt: entry.manifest.startedAt,
                endedAt: entry.manifest.isFinal ? entry.manifest.endedAt
                    : entry.manifest.startedAt.addingTimeInterval(event.totalDurationSeconds),
                reconnectMarkers: entry.manifest.reconnectMarkers ?? [],
                language: entry.manifest.language, continuation: nil
            )
            refreshOpenWindowIfNeeded()
            return ((try? await store.progressState(id: meetingId)) ?? nil)?.status == .ready
        }
        notesRetries.insert(meetingId)
        defer {
            notesRetries.remove(meetingId)
            refreshOpenWindowIfNeeded()
        }
        let retry = MeetingNotesRetry(
            meetingId: meetingId, startedAt: meta.startedAt,
            endedAt: meta.endedAt ?? meta.startedAt.addingTimeInterval(TimeInterval(meta.durationSeconds)),
            durationSeconds: TimeInterval(meta.durationSeconds)
        )
        do {
            // The recording is gone, and with it the language captured at
            // Stop: the current preference is the best hint left.
            guard try await directProcessor.writeNotesFromKeptTranscript(
                retry, language: config.preferredLanguage, meetingsStore: store
            ) else { return false }
            eventsContinuation.yield(.newMeetingAvailable(id: meetingId))
            return true
        } catch {
            os_log(
                "retryNotes failed (meetingId: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                meetingId.uuidString, String(describing: type(of: error))
            )
            let reason = (error as? MeetingNotesFailure)?.description
                ?? MeetingNotesFailure(error).description
            eventsContinuation.yield(.meetingFailed(id: meetingId, error: reason))
            _ = try? await store.updateProgress(id: meetingId, status: .failed, failureReason: reason)
            return false
        }
    }

    /// A notes retry that the app quit in the middle of leaves its meeting
    /// "preparing the note" with no recording to recover it from. Such a
    /// meeting goes back to failed, with its transcript and Retry notes.
    private func failInterruptedNotesRetries(stagingRoot: URL) async {
        guard let store = meetingsStore, let metas = try? await store.list() else { return }
        let staged = Set(manifestStore.scan(stagingRoot: stagingRoot).map {
            $0.manifest.continuation?.meetingId ?? $0.manifest.recorderMeetingId
        })
        for meta in metas where meta.progressStatus == .generatingProtocol
            && !staged.contains(meta.id) && processingTails[meta.id] == nil
            && !notesRetries.contains(meta.id) && activeRecorder?.meetingId != meta.id {
            guard let kept = (try? await store.pendingTranscript(recordingId: meta.id)) ?? nil,
                  !kept.isEmpty else { continue }
            _ = try? await store.updateProgress(
                id: meta.id, status: .failed, failureReason: Self.notesInterruptedMessage
            )
        }
    }

    func deleteMeeting(id: UUID) async -> Bool {
        guard let store = meetingsStore else { return false }
        guard activeReconnect?.continuation.meetingId != id, processingTails[id] == nil,
              !notesRetries.contains(id) else { return false }
        guard let status = (try? await store.progressStatus(id: id)) ?? nil else {
            os_log(
                "deleteMeeting refused: unknown meeting (meetingId: %{public}@)",
                log: Self.log, type: .info,
                id.uuidString
            )
            return false
        }
        guard status.canBeDeleted else {
            os_log(
                "deleteMeeting refused: still processing (meetingId: %{public}@, status: %{public}@)",
                log: Self.log, type: .info,
                id.uuidString, status.rawValue
            )
            return false
        }
        // The store lookup above suspends the MainActor; a Reconnect or a
        // processing job may have begun while that lookup was in flight.
        guard activeReconnect?.continuation.meetingId != id, processingTails[id] == nil,
              !notesRetries.contains(id) else { return false }
        if let stagedDir = stagingRootProvider?().appendingPathComponent(id.uuidString),
           FileManager.default.fileExists(atPath: stagedDir.path) {
            do {
                try FileManager.default.removeItem(at: stagedDir)
            } catch {
                os_log(
                    "deleteMeeting failed to remove the staged recording (meetingId: %{public}@, error: %{public}@)",
                    log: Self.log, type: .error,
                    id.uuidString, String(describing: error)
                )
                return false
            }
        }
        if pendingReconnect?.meetingId == id { clearPendingReconnect() }
        if let stagingRoot = recorderStagingRoot {
            for entry in manifestStore.scan(stagingRoot: stagingRoot)
                where entry.manifest.continuation?.meetingId == id {
                do { try FileManager.default.removeItem(at: entry.dir) }
                catch { return false }
            }
        }
        do {
            try await store.delete(id: id)
        } catch {
            os_log(
                "deleteMeeting failed to delete the stored meeting (meetingId: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
            return false
        }
        os_log(
            "meeting deleted (meetingId: %{public}@)",
            log: Self.log, type: .info,
            id.uuidString
        )
        refreshOpenWindowIfNeeded()
        return true
    }

    // MARK: - Title repair (list shown, meeting selected)

    /// Re-derive the sidebar title from the stored note and refresh the open
    /// notes surfaces. The notes UI calls it for every meeting when the list
    /// is shown (`MeetingsContentController.refreshAllOnShow`) and for one
    /// meeting when it is selected (`sidebarDidSelectMeeting`); safe to call
    /// from any context.
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
