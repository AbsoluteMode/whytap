import AppKit
import AVFoundation
import Combine
import Foundation
import os.log
import WhytapCaseKit

/// How the drop streaming session failed to start. No chosen provider or a
/// missing BYOK key is the user's configuration — surfaced, never fatal.
/// Lives at file scope so the classification is unit-testable without
/// standing up the AppDelegate.
enum StreamingSessionSetupError: Error {
    case byokMisconfigured(FeatureRouteError)
}

/// Outcome of `AppDelegate.dropFlowRoute(phase:mode:hasStreamingSession:)`.
/// One enum case per code-path the AppKit hotkey hook may take so the
/// switch in the drop hotkey handlers stays a thin dispatcher and the routing rules
/// can be unit-tested in isolation.
enum DropFlowRoute: Equatable {
    case startStreamingSession
    case startRecording
    case stopStreamingSession
    case stopRecordingAndTranscribe
    /// A stop (hold-release or stop-tap) arrived while the streaming session
    /// is still being built (`phase == .transcribing`, no session yet). The
    /// stop is remembered and applied as soon as the session reaches
    /// `.recording`, so a start-then-immediately-stop goes through the normal
    /// finalize path instead of being dropped (which left the mic recording
    /// indefinitely). See Task 7(c).
    case recordPendingStop
    /// A Drop press landed while a prior turn is parked in the terminal
    /// `.deliveryFailed` state (total-offline). The failed take is abandoned
    /// (its retained retry audio discarded) and a FRESH recording starts — so
    /// `.deliveryFailed` is never a roach-motel: pressing Drop again always
    /// moves on instead of being a no-op. The manual Retry pill stays the way
    /// to RECOVER the prior take; this route is the way to DROP it. See Task 7.
    case discardFailedTakeAndStart
    case noop
}

/// Routing decision for an Escape-cancel during a hold-Space Drop recording.
/// Distinct from `DropFlowRoute` because cancel **discards** the in-flight
/// take — no transcript, no paste — rather than finalizing it.
enum DropCancelRoute: Equatable {
    /// A WS streaming session is in flight — tear it down (mirrors
    /// `cancelStreamingSessionIfNeeded`).
    case cancelStreamingSession
    /// A recorder-backed capture is in flight — drop its audio.
    case cancelRecording
    /// Nothing to discard (not in `.recording`).
    case noop
}

// No @main here: the library is entered from the thin executable in
// Sources/SidekeyApp via `SidekeyAppMain.run()` → `AppDelegate.main()`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var translationWindowController: TranslationWindowController?
    private var meetingAssistantPanel: MeetingAssistantPanel?
    private var screenshotCoordinator: ScreenshotCoordinator?
    private let recorder = AudioRecorder()
    /// Batch transcriber for the Drop recorder fallback, the resilient-delivery
    /// batch rung and Retry: the provider, model and key of the route the take
    /// started with (`DropTake`), read on every call. Without that key it is
    /// unavailable and the audio goes nowhere; it never falls back to another
    /// provider.
    /// WHY: .project-docs/decisions/2026-10-18-provider-batch-transcription.md
    private let dropBatchTranscriber: any BatchTranscribing = ProviderBatchTranscriber.forDrop()
    /// Batch transcriber for the agent's voice path: the Agent voice route.
    private let agentBatchTranscriber: any BatchTranscribing = ProviderBatchTranscriber.forFeature(.agentVoice)
    /// In-flight streaming session for the Drop flow. Both `.fast` and
    /// `.smart` open one — they share the live realtime pipeline; `.smart`
    /// differs only after the stop, when the transcript runs through the
    /// cleanup LLM. Non-nil between hotkey-down (start) and the resolved
    /// session outcome; nil outside an active drop (or on a recorder
    /// fallback run). The second-tap `onHotkey` reads this to decide
    /// between stopping streaming vs the recorder.
    private var streamingSession: (any StreamingSessionRunning)?
    /// Set when the user has explicitly asked the in-flight stream to finish.
    /// A transport failure before this point is a setup failure, so the Drop
    /// UX can fall back to the recorder instead of blinking away. A failure
    /// after this point is a finalization failure and must not start a new
    /// recording behind the user's back.
    private var streamingStopRequested = false
    /// Last realtime transcript snapshot for the in-flight Drop turn. Fed by the
    /// `onTranscriptUpdate` sink; read by `resolveDelivery` as the raw-partial
    /// salvage rung when both the live terminal and batch recovery are unavailable
    /// (offline). Reset at turn start. Length only is ever logged (privacy #3).
    private var lastDropPartial: String = ""
    /// True between the synchronous `phase = .transcribing` at the top of
    /// `startStreamingSession()` and the moment the session is assigned (or
    /// setup fails). Distinguishes the streaming-setup window from the
    /// post-stop / batch transcribing states, so a stop arriving during setup
    /// can be remembered (`streamingPendingStop`) instead of dropped. See
    /// Task 7(c).
    private var streamingSetupInProgress = false
    /// Set when a stop (hold-release or stop-tap) arrived during streaming
    /// setup. Consumed the instant the session reaches `.recording`, routing
    /// through the normal `stopStreamingSession()` finalize path so a
    /// start-then-immediately-stop never leaves the mic recording forever.
    private var streamingPendingStop = false
    /// Monotonic token identifying WHICH turn owns the current setup window.
    /// Bumped at the top of every `startStreamingSession()`. The setup Task
    /// captures its own value and re-checks after `makeStreamingSession()`
    /// returns: a mismatch means a NEWER turn started while this one was
    /// suspended (possible after a sleep-cancel set phase back to `.idle` on
    /// wake) — the stale task must tear down its session and touch nothing
    /// else, because the flags / phase / telemetry now belong to the new
    /// turn. Without this token, `streamingSetupInProgress == true` set by
    /// the new turn would be indistinguishable from "my own window is still
    /// open".
    private var streamingSetupGeneration: UInt64 = 0
    private let autoPasteEngine = AutoPasteEngine()
    private var hotkey: HotkeyShortcutMonitor?
    private var helpHotkey: CarbonHotkeyMonitor?
    /// ROO-208: unified `⌥V` hotkey for the history strip. Replaces the
    /// trio of per-mode `⌥1` / `⌥2` / `⌥3` monitors that used to live
    /// in `historyHotkeys: [CarbonHotkeyMonitor]`.
    private var historyHotkey: CarbonHotkeyMonitor?
    /// Independent monitors for the user's tool bindings, regardless of layout.
    private var toolHotkeys: [HotkeyShortcutMonitor] = []
    /// Manual Meeting-record toggle (default ⌥M) — tap starts a recording
    /// bypassing the detector nudge, tap again stops it.
    private var meetingRecordHotkey: HotkeyShortcutMonitor?
    private var hotkeyPreferenceCancellables: Set<AnyCancellable> = []
    /// Monotonic token for `AppState.programmaticHoverPanelRequest` so two
    /// consecutive ⌥N presses opening the same inline panel are distinct
    /// `@Published` events the island's `onChange` can both observe.
    private var hoverPanelRequestToken = 0
    /// A `whytap://` link that arrived before launch finished (cold start).
    private var pendingLinkRequest: WhytapLinkRequest?
    private var acceptsLinkRequests = false
    /// One link confirmation at a time; links arriving meanwhile are dropped.
    private var isConfirmingLinkChange = false
    private var helpWindowController: HelpWindowController?
    private var panel: FloatingDotPanel?
    private var keybindingsHintPanel: KeybindingsHintPanel?
    /// Round 3: separate overlay panel above orb+helper hosting the
    /// rounded-rect frame + 3-row actions cluster. Lifecycle tied to
    /// `panel` — created lazily once the orb panel exists so the
    /// overlay can read its frame.
    private var actionsOverlayPanel: OrbActionsOverlayPanel?
    private var postProcessor: PostProcessor?
    /// Resilient-Drop manual-retry state (Task 7). When degraded batch recovery
    /// also fails (total offline), the captured PCM + its paste target are
    /// retained here so the user can retry once the network is back. Set on the
    /// `.degraded` path (resilient-delivery flag on) and RETAINED across a Retry
    /// attempt — the recovery OUTCOME owns it. It is NOT consumed when a retry
    /// launches (that previously stranded Retry as a permanent no-op if recovery
    /// hung), so it can be non-nil in both `.deliveryFailed` and the transient
    /// `.finishing` while a Retry is in flight. Cleared on: a successful
    /// (re)delivery (`clearPendingRetry`); the user abandoning the take by
    /// starting a fresh Drop (`discardPendingRetry`); or a Retry that resolves to
    /// any NON-re-arming outcome (the retry Task drops it unless the outcome
    /// re-armed `.deliveryFailed`) — so a no-audio/empty/unauthorized retry never
    /// leaves captured audio stranded in memory.
    private var pendingRetryPCM: Data?
    private var pendingProcessingRetry: DropProcessingRetry?
    private var pendingRetryTarget: (app: String?, pid: pid_t?)?
    /// True while a manual Retry's batch recovery is in flight. Gates
    /// `retryPendingDelivery` (via `shouldBeginRetry`) so a second press can't
    /// launch a concurrent recovery, and — together with the synchronous
    /// `.finishing` phase — so a stale retry can't paste over a fresh turn the
    /// user started by abandoning the failed take. Reset when recovery returns.
    private var retryInFlight = false
    private var agentController: AgentController?
    /// Retained alongside `agentController`; handles the R-Option Google
    /// gesture (text tap / hold voice). Created in `startAgentIfEnabled`.
    private var googleSearchController: GoogleSearchController?
    private var historyStore: SQLiteHistoryStore?
    private var chatStackStore: ChatStackStore?
    private var dropHistoryRecorder: DropHistoryRecorder?
    /// Kept on the delegate so multiple "Settings…" and "Memory…"
    /// opens reuse the same tabbed window and the user's in-flight
    /// memory edits survive a brief window close.
    private var settingsWindowController: SettingsWindowController?
    private var quitConfirmationController: SidekeyQuitConfirmationController?
    /// Monotonic guard for background Drop Mode saves fired from the
    /// Dynamic Island. If the user toggles Smart/Fast repeatedly, only
    /// the newest save is allowed to re-hydrate the local cache.
    private var islandDropModeSaveGeneration = 0
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var powerStateCoordinator: PowerStateCoordinator?
    /// Stage 1a skeleton: feature-flag gated wiring shell for Meeting
    /// Notes. Held strongly so the `weak` ref in `AppState` survives.
    private var meetingsCoordinator: MeetingsCoordinator?
    /// Stage 3: pill controller + panel + buffer. Held strongly so the
    /// NSPanel does not deallocate while the coordinator's draining
    /// task still expects it on the next detector trigger.
    private var meetingPillController: MeetingPillController?
    private var meetingPillPanel: MeetingPillPanel?
    private var meetingPrerecordBuffer: PrerecordBuffer?
    /// Stage 7: local cache for transcribed meetings. Held strongly so
    /// the actor's SQLite handle survives the lifetime of the app.
    private var meetingsStore: MeetingsStore?
    /// Background task that drains the coordinator's event stream. Held
    /// so it cancels cleanly on teardown.
    private var meetingsEventConsumer: Task<Void, Never>?

    /// Now Playing (Dynamic Island music) coordinator + controller. Held
    /// strongly so the `weak` ref in `AppState` survives. Feature-flag
    /// gated (`NowPlayingConfig`); when off, `start()` is a logged no-op.
    private var nowPlayingCoordinator: NowPlayingCoordinator?
    /// Case broker socket for the bundled `whytap` helper; running app only.
    private var caseBrokerServer: CaseBrokerServer?
    private var appControlController: AppControlController?
    /// Case Approve prompts in the island (Y / N / A keys) and their panel.
    private var caseApprovalController: CaseApprovalController?
    private var caseApprovalPanel: CaseApprovalPanel?
    private var caseApprovalCancellable: AnyCancellable?
    private var nowPlayingController: NowPlayingController?

    /// Volume ducking: smoothly lowers the system output volume while the user
    /// records voice (Drop / agent-voice) and restores it after — only if WE
    /// lowered it. Held strongly for the app lifetime; driven from `$phase` /
    /// `$agentPhase` via `volumeDuckCancellables`. Toggle-gated live through
    /// `VolumeDuckConfig` (no relaunch). Volume is moved via CoreAudio's device
    /// scalar (the same slider the user moves) — no audio capture, no TCC grant.
    private var volumeDuckController: VolumeDuckController?
    private var volumeFader: VolumeFader?
    private var systemOutputVolume: SystemOutputVolume?
    private var volumeDuckCancellables: Set<AnyCancellable> = []

    /// DEBUG-only: preview the update UX (download spinner → "Updated" pill)
    /// end-to-end without a real Sparkle download. Never passed in production.
    private static let demoUpdateArgument = "--demo-update"

    /// Combine subscriptions owned by the delegate. Currently holds the
    /// sink that observes `DisplayPreferences.hideHelpers` so the
    /// `KeybindingsHintPanel` opens / closes in real time as the user
    /// flips the "Hide Helpers" preference.
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - History Strip
    /// Bottom-strip orchestrator. Mode state + Esc / outside-click
    /// handling. SwiftUI views inside `HistoryStripPanel` and
    /// `HistoryExpandedPanel` observe its `@Published` properties.
    private var historyStripController: HistoryStripController?
    private var historyStripFeed: HistoryStripFeed?
    private var historyStripPanel: HistoryStripPanel?
    private var historyExpandedPanel: HistoryExpandedPanel?
    private var copiedToastController: CopiedToastController?
    private var copiedToastPanel: CopiedToastPanel?
    private var clipboardWatcher: ClipboardWatcher?
    private var assetsDirectory: URL?
    private var permissionRepairWindowController: PermissionRepairWindowController?
    private var didCompleteReadyStartup = false
    private var runtimeAccessibilityGranted = false
    private var runtimePermissionsObserver: NSObjectProtocol?
    private var openHotkeySettingsObserver: NSObjectProtocol?
    private var permissionCaptureEndObserver: AnyCancellable?
    private var permissionRecoveryTimer: Timer?
    private var permissionRecoverySession: UUID?
    private var permissionRecoveryBudget = DropHotkeyRecoveryPollBudget()
    private var dropRegistrationFailure: DropHotkeyStatus?
    private var dropMonitorGeneration = UUID()
    private var permissionMonitorRebuildPending = false

    /// Sparkle update flow (ROO-186). Owns `SPUUpdater` + `IslandUpdateUserDriver`
    /// via `UpdateController`, which translates driver stage emits into
    /// `AppState.updateAvailable` for the Dynamic Island pill.
    /// Held strongly here because `SPUUpdater` weakly references its delegate,
    /// so the UpdateController must outlive every scheduled check —
    /// i.e. the whole app lifetime.
    ///
    /// Stored `let` (not `lazy var`) so initialisation happens at
    /// `AppDelegate.init` time and does not depend on a hostage call from
    /// `applicationDidFinishLaunching` to fire the lazy. `AppState.shared`
    /// is a dependency-free singleton (`private init() {}`), so reading it
    /// during `AppDelegate.init` is safe.
    private let updateController: UpdateController = {
        let controller = UpdateController(
            appState: AppState.shared,
            updatesEnabled: BuildConfig.allowsPackagedUpdates
        )
        AppState.shared.updateController = controller
        return controller
    }()

    /// Dynamic Island idle-hide engine. Installed once, after the panel is
    /// shown, by `installIslandIdleControllerIfNeeded()`. Nil until then so it
    /// is never created before the panel is available.
    private var islandIdleController: IslandIdleController?

    /// User's on/off switch for idle auto-hide (Settings → Other). The
    /// controller reads it live through its `isEnabled` closure; Settings writes
    /// it and posts `didChangeNotification`, which we observe to poke the
    /// controller. One instance so reads/writes share the same store.
    private let islandIdlePreferences = IslandIdlePreferences()

    /// Combine subscriptions for the idle controller bridges (blocker mirror +
    /// visibility mirror). Held separately so a re-install is a clean rewire.
    private var islandIdleCancellables: Set<AnyCancellable> = []

    /// Subsystem-scoped logger. We never log raw transcript text, only
    /// metadata (counts, latency, status) so user content never enters
    /// the system console.
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "pipeline")

    /// Hotkey-scoped logger for `registerHotkey` failures. The hot-key path
    /// itself (Carbon `RegisterEventHotKey`) also emits to this subsystem /
    /// category from `CarbonHotkeyMonitor`.
    private static let hotkeyLog = OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey")


    /// Lifecycle-scoped logger for activation-policy diagnostics and other
    /// boot-time invariants. Visible to users via `Console.app` filtered by
    /// subsystem `com.rootwise.sidekey` + category `lifecycle` so we can
    /// debug Dock-icon retention reports from teammates remotely.
    private static let lifecycleLog = OSLog(subsystem: "com.rootwise.sidekey", category: "lifecycle")

    static func main() {
        setlinebuf(stdout)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // First attempt — pre-`run()`. Defence-in-depth: the canonical place
        // is `applicationWillFinishLaunching(_:)` below, but we also set it
        // here so a delegate-method failure still leaves us with a best-effort
        // accessory policy.
        let mainAccepted = app.setActivationPolicy(.accessory)
        os_log(
            "lifecycle_activation_policy stage=main accepted=%{public}@ policy=%d",
            log: Self.lifecycleLog, type: .info,
            mainAccepted ? "true" : "false",
            app.activationPolicy().rawValue
        )
        app.run()
    }

    /// Canonical AppKit hook for hiding a menu-bar app from the Dock. Runs
    /// AFTER LaunchServices registration but BEFORE AppKit shows the Dock
    /// icon, which is the documented insertion point that consistently
    /// wins over the bundle's default `.regular` policy on first launch.
    /// We saw Dock-icon retention on teammates' fresh installs because the
    /// `static func main()` call alone was racing AppKit's Dock paint on
    /// some macOS versions (Tahoe 26 included).
    func applicationWillFinishLaunching(_ notification: Notification) {
        let accepted = NSApp.setActivationPolicy(.accessory)
        os_log(
            "lifecycle_activation_policy stage=will_finish accepted=%{public}@ policy=%d",
            log: Self.lifecycleLog, type: .info,
            accepted ? "true" : "false",
            NSApp.activationPolicy().rawValue
        )
        // Before launch finishes, so a link that launched the app is delivered.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Runs after this method returns, once the island and its actions exist.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.acceptsLinkRequests = true
            if let request = self.pendingLinkRequest {
                self.pendingLinkRequest = nil
                self.handle(request)
            }
        }
        LocalNotificationHub.shared.openMeeting = { [weak self] id in
            guard let self else { return }
            self.openSettingsWindow(tab: .notes)
            self.ensureSettingsWindowController().selectNoteMeeting(id: id)
        }
        NotifyScriptSupervisor.shared.start()
        Task { await AgentSettingsStore.shared.refreshCodexCatalog() }
        // Final-rubber-stamp diagnostic + last-resort retry. If we reach
        // `applicationDidFinishLaunching` with a non-`.accessory` policy
        // both earlier attempts lost the race to AppKit's Dock paint, so
        // try once more and surface the outcome.
        os_log(
            "lifecycle_activation_policy stage=did_finish_enter policy=%d",
            log: Self.lifecycleLog, type: .info,
            NSApp.activationPolicy().rawValue
        )
        if NSApp.activationPolicy() != .accessory {
            let accepted = NSApp.setActivationPolicy(.accessory)
            os_log(
                "lifecycle_activation_policy stage=did_finish_retry accepted=%{public}@ policy=%d",
                log: Self.lifecycleLog, type: .info,
                accepted ? "true" : "false",
                NSApp.activationPolicy().rawValue
            )
        }

        // Move legacy plaintext `.token` files into the keychain before the
        // first credential read (CAN-001). Idempotent, cheap.
        CredentialMigration().run()

        // Carry the old Models-tab provider and model choices into per-feature
        // routes, once. After the key migration so the keys are in the
        // keychain; synchronous, reads only, no network.
        AIRoutingMigration.live().run()

        // Free the retired on-device models' disk space once
        // (Application Support/Sidekey/Local*Models, up to a few GB); off the
        // main thread so launch never waits on the removal.
        // WHY: .project-docs/decisions/2026-10-18-legacy-model-cleanup.md
        DispatchQueue.global(qos: .utility).async {
            LegacyLocalModelCleanup().run()
            // Packaged builds keep no meeting research audio.
            // WHY: .project-docs/decisions/2026-10-22-no-retained-meeting-audio.md
            MeetingLiveTestSettings.removeCapturesIfUnavailable()
        }

        // Restore standard text-editing shortcuts (⌘V/⌘C/⌘X/⌘A) for the app's
        // text fields. Accessory apps have no menu bar, so without this the
        // Settings → API & Models API-key field (and any other field) can't paste.
        AppMainMenu.installIfNeeded()

        // Avoid a cold PDF decode in the Dynamic Island's first drop-recording
        // ticker for each transcription provider mark.
        ProviderBrandIconAsset.prewarmTranscriptionProviderAssets()

        self.postProcessor = PostProcessor()
        // Local history persistence. Failure to open the file just disables
        // history; the app must keep working without it.
        do {
                let store = try SQLiteHistoryStore.shared()
                self.historyStore = store
                self.dropHistoryRecorder = DropHistoryRecorder(store: store)
            // Same on-disk DB as the History menu — chat stack writes land
            // in `agent_entries` so `latestAgentEntries(limit:)` (read by
            // the History window) keeps surfacing new turns post-migration.
                self.chatStackStore = ChatStackStore(store: store)

            // History strip: assets dir for clipboard image sidecars,
            // clipboard watcher, strip controller + feed. Feed is a
            // read-only adapter over the same store; controller owns
            // open/close state and orchestrates the strip + expanded
            // panels via @Published events.
                let assets = try HistoryStoreLocation.prepareAssetsDirectory()
                self.assetsDirectory = assets
            // Clipboard history belongs to the local workspace and survives
            // restarts. The watcher retains the newest 50 entries and removes
            // evicted image sidecars; starting it must not erase saved copies.
            // WHY: .project-docs/decisions/2026-10-18-clipboard-retention.md
                let watcher = ClipboardWatcher(
                    store: store,
                    assetsDirectory: assets
                )
                watcher.start()
                self.clipboardWatcher = watcher
                os_log(
                    "history_strip_init store=ok assets=%{public}@ watcher=started",
                    log: Self.log,
                    type: .info,
                    assets.path
                )
            // Once per database file, VACUUM away what deletes made before
            // secure_delete left in free pages. Off the main thread; keeps
            // every row; a skipped or failed pass retries on the next launch.
            // WHY: .project-docs/decisions/2026-10-22-history-free-page-scrub.md
                let scrubLog = Self.log
                store.scrubFreePagesInBackground { result in
                    switch result {
                    case .success(let outcome):
                        os_log(
                            "history_free_page_scrub %{public}@",
                            log: scrubLog, type: .info,
                            outcome.logDescription
                        )
                    case .failure(let error):
                        // SQLite's error text ("database or disk is full"),
                        // never row content.
                        os_log(
                            "history_free_page_scrub failed: %{public}@",
                            log: scrubLog, type: .error,
                            String(describing: error)
                        )
                    }
                }

                let controller = HistoryStripController()
                self.historyStripController = controller
                let feed = HistoryStripFeed(store: store)
                self.historyStripFeed = feed

            // Round 2 UX 5: "Copied" toast — centered pill that flashes
            // when the user clicks a strip card's body. Tied to a
            // singleton controller so any code path that copies via
            // the strip can opt-in via `controller.show()` without
            // owning its own NSPanel.
                let toast = CopiedToastController()
                self.copiedToastController = toast
        } catch {
            os_log(
                "history store unavailable: %{public}@",
                log: Self.log, type: .error,
                String(describing: type(of: error))
            )
        }

        printBanner()
        reportPermissions()

        // `updateController` is a stored `let` — initialised at
        // `AppDelegate.init` time, BEFORE this method runs. By the time we
        // reach `applicationDidFinishLaunching`, Sparkle's scheduled
        // gentle-reminder checks are already configured, the updater is
        // started, and `AppState.updateController` is wired for Stage 2's
        // pill UI. The explicit read below is kept as defensive
        // documentation — its removal would not change behaviour, but its
        // presence makes the init-order contract obvious to readers.
        _ = updateController

        installMeetingsCoordinator()
        installNowPlayingCoordinator()
        installCaseBroker()
        installDisplayPreferenceObserver()
        installWorkspacePowerObservers()

        startReady()
        ArtifactBackupEngine.shared.register(meetings: meetingsStore, usage: AIUsageStore.shared)
        BackupViewModel.shared.start()

        if FirstLaunchPermissions.consumePresentation(
            in: .standard,
            requiredPermissionsGranted: PermissionsHelper.allRequiredPermissionsGranted(),
            screenRecordingGranted: PermissionsHelper.screenRecordingGranted()
        ) {
            openSettingsWindow(tab: .permissions)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshRuntimePermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRuntimeSurfaceAfterReopen()
        return true
    }

    private func showRuntimeSurfaceAfterReopen() {
        refreshRuntimePermissions()
        IslandPanel.shared.show()
        IslandNotificationPanel.shared.show()
        ensureMeetingAssistant().prepare()
        registerIslandHotkeyActivity()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenshotCoordinator?.cancel(restoreFocus: false)
        translationWindowController?.cancel()
        meetingAssistantPanel?.suspend()
        BackupViewModel.shared.stop()
        // Give the display its own transfer table back; Extra never changes the backlight.
        ScreenBrightnessController.shared.shutdown()
        BrightnessKeys.shared.stop()
        NotifyScriptSupervisor.shared.stop()
        stopPermissionRecoveryPolling()
        permissionCaptureEndObserver?.cancel()
        permissionCaptureEndObserver = nil
        if let runtimePermissionsObserver { NotificationCenter.default.removeObserver(runtimePermissionsObserver) }
        if let openHotkeySettingsObserver { NotificationCenter.default.removeObserver(openHotkeySettingsObserver) }
        removeWorkspacePowerObservers()
        recorder.cancel()
        // Cancel any in-flight streaming session so the WS task doesn't
        // hang the process tear-down. Both Drop modes stream, so this
        // fires whenever a drop is mid-flight; no-op when no session is
        // open (idle, or a recorder-fallback run).
        cancelStreamingSessionIfNeeded()
        hotkey?.stop()
        stopHistoryHotkey()
        agentController?.stop()
        clipboardWatcher?.stop()
        // Terminate the MediaRemote `run.pl stream` child synchronously;
        // otherwise it outlives the app as an orphan (PPID 1).
        nowPlayingCoordinator?.shutdown()
        // Waiting Approve prompts are denied (and the key tap removed) before the socket closes.
        caseApprovalController?.cancelAll()
        caseBrokerServer?.stop()
        caseBrokerServer = nil
        IslandPanel.shared.hide()
        IslandNotificationPanel.shared.hide()
        meetingsEventConsumer?.cancel()
        meetingsEventConsumer = nil
    }

    // MARK: - Permission repair

    private func observeRuntimePermissionsIfNeeded() {
        guard runtimePermissionsObserver == nil else { return }
        runtimePermissionsObserver = NotificationCenter.default.addObserver(
            forName: .sidekeyRuntimePermissionsRefresh, object: nil, queue: .main
        ) { [weak self] note in
            let retry = note.userInfo?["retry"] as? Bool ?? false
            let resumePolling = note.userInfo?["resumePolling"] as? Bool ?? true
            Task { @MainActor [weak self] in
                self?.refreshRuntimePermissions(forceRebuild: retry, resumePolling: resumePolling)
            }
        }
        openHotkeySettingsObserver = NotificationCenter.default.addObserver(
            forName: .sidekeyOpenHotkeySettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.ensureSettingsWindowController().show(tab: .hotkeys) }
        }
        permissionCaptureEndObserver = Self.observeDropCaptureEnd(
            AppState.shared.$phase.eraseToAnyPublisher(),
            captureIsActive: { [weak self] in
                AppState.shared.phase == .recording || self?.streamingSetupInProgress == true
            },
            hasPendingRebuild: { [weak self] in self?.permissionMonitorRebuildPending == true },
            onCaptureEnded: { [weak self] in
                // A long take may outlive the bounded repair poll. Service its
                // deferred rebuild directly, without restarting that poll.
                self?.refreshRuntimePermissions(resumePolling: false)
            }
        )
    }

    /// Published sends in willSet; queue delivery reads the completed phase
    /// assignment and also rejects stale queued transitions of a new take.
    /// Kept injectable so the long-capture/expired-poll path needs no real input.
    static func observeDropCaptureEnd(
        _ phases: AnyPublisher<AppPhase, Never>,
        captureIsActive: @escaping () -> Bool,
        hasPendingRebuild: @escaping () -> Bool,
        onCaptureEnded: @escaping () -> Void
    ) -> AnyCancellable {
        phases.dropFirst().receive(on: DispatchQueue.main).sink { _ in
            guard hasPendingRebuild(), !captureIsActive() else { return }
            onCaptureEnded()
        }
    }

    /// Never requests a grant. Reconciles actual installation as well as AX,
    /// including a tap that failed while AX itself remained granted.
    private func refreshRuntimePermissions(forceRebuild: Bool = false, resumePolling: Bool = true) {
        guard didCompleteReadyStartup else { return }
        let snapshot = PermissionsHelper.snapshot()
        let accessibilityChanged = snapshot.accessibilityGranted != runtimeAccessibilityGranted
        runtimeAccessibilityGranted = snapshot.accessibilityGranted
        let captureActive = AppState.shared.phase == .recording || streamingSetupInProgress
        switch DropHotkeyRecovery.reconcileDecision(
            installed: hotkey != nil,
            accessibilityChanged: accessibilityChanged,
            forceRebuild: forceRebuild,
            rebuildPending: permissionMonitorRebuildPending,
            captureActive: captureActive
        ) {
        case .deferRebuild:
            // Keep the current stop/release hook until the active take ends.
            permissionMonitorRebuildPending = true
        case .rebuild:
            permissionMonitorRebuildPending = false
            teardownHotkeyMonitorsForRebuild()
            registerHotkey()
            agentController?.start(googleCallbacks: makeGoogleCallbacks())
        case .install:
            registerHotkey()
        case .none:
            break
        }
        publishDropHotkeyStatus(snapshot: snapshot)
        if AppState.shared.dropHotkeyStatus == .ready && !permissionMonitorRebuildPending {
            stopPermissionRecoveryPolling()
        } else if resumePolling {
            startPermissionRecoveryPollingIfNeeded()
        }
    }

    private func publishDropHotkeyStatus(snapshot: PermissionsHelper.Snapshot? = nil) {
        let status = DropHotkeyRecovery.status(
            snapshot: snapshot ?? PermissionsHelper.snapshot(),
            installed: hotkey != nil,
            failure: dropRegistrationFailure
        )
        if AppState.shared.dropHotkeyStatus != status { AppState.shared.dropHotkeyStatus = status }
        AppState.shared.hotkeyRegistrationFailed = dropRegistrationFailure != nil
    }

    private func startPermissionRecoveryPollingIfNeeded() {
        guard permissionRecoveryTimer == nil else { return }
        permissionRecoveryBudget = DropHotkeyRecoveryPollBudget()
        let session = UUID()
        permissionRecoverySession = session
        permissionRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.permissionRecoverySession == session else { return }
                guard self.permissionRecoveryBudget.consume() else {
                    self.stopPermissionRecoveryPolling()
                    return
                }
                self.refreshRuntimePermissions(resumePolling: false)
            }
        }
    }

    private func stopPermissionRecoveryPolling() {
        permissionRecoveryTimer?.invalidate()
        permissionRecoveryTimer = nil
        permissionRecoverySession = nil
    }

    /// Only a user invocation shows this window. A background loss or transient
    /// tap failure updates status and retries quietly instead of interrupting.
    private func explainMissingDropPermission() {
        publishDropHotkeyStatus()
        startPermissionRecoveryPollingIfNeeded()
        presentPermissionRepair { [weak self] in self?.refreshRuntimePermissions(forceRebuild: true) }
    }

    private func presentPermissionRepair(onComplete: @escaping () -> Void) {
        if permissionRepairWindowController == nil {
            permissionRepairWindowController = PermissionRepairWindowController(onComplete: { [weak self] in
                self?.permissionRepairWindowController?.close()
                self?.permissionRepairWindowController = nil
                onComplete()
            })
        }
        permissionRepairWindowController?.show()
    }

    private func startReady() {
        didCompleteReadyStartup = true
        runtimeAccessibilityGranted = PermissionsHelper.accessibilityGranted(prompt: false)
        showFloatingPanelIfNeeded()
        // The island and Settings are available immediately. Permissions and
        // provider configuration gate the corresponding action, never launch.
        IslandPanel.shared.actions = makeIslandActions()
        configureSettingsDeps(from: IslandPanel.shared.actions)
        IslandPanel.shared.show()
        IslandNotificationPanel.shared.show()
        ensureMeetingAssistant().prepare()
        installIslandIdleControllerIfNeeded()
        // Post-relaunch "Updated" indicator (variant A): if the previous
        // session installed an update and this is the new binary, surface a
        // transient "Updated vX.Y" pill in the island. No-op on a normal launch.
        // Runs after the panel is on screen + the idle controller is installed
        // so the indicator both renders and holds the island awake.
        updateController.showJustInstalledIndicatorIfNeeded()
        #if DEBUG
        // DEBUG-only preview: `--demo-update` drives the real update views
        // (download spinner → "Updated" pill) without a Sparkle download.
        // Gated strictly on the launch argument — no production launch passes
        // it, and this whole branch is compiled out of release builds.
        if ProcessInfo.processInfo.arguments.contains(Self.demoUpdateArgument) {
            updateController.runDemoUpdatePreview()
        }
        #endif
        observeHotkeyPreferences()
        observeRuntimePermissionsIfNeeded()
        registerHotkey()
        if AppState.shared.dropHotkeyStatus != .ready { startPermissionRecoveryPollingIfNeeded() }
        // Reactive reconcile: re-evaluate arm/disarm + meetings start/stop
        // whenever any capability flag flips (posted by UserPreferencesCache E1).
        NotificationCenter.default.addObserver(
            forName: .sidekeyCapabilityFlagsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileCapabilities()
            }
        }
        startAgentIfEnabled()
        // Invoke the Meeting Notes coordinator's gated `start()`.
        // `MeetingsConfig` defaults to on for rollout, while an explicit
        // stored `false` remains a logged kill-switch no-op.
        Task { @MainActor in
            AppState.shared.meetingsCoordinator?.start()
            // Recovery is idempotent: a recording finalized while the app was
            // quitting is processed on the next launch.
            AppState.shared.meetingsCoordinator?.resumePendingProcessingOnLaunch()
        }
        // Now Playing: gated `start()`. `NowPlayingConfig` defaults to on;
        // an explicit stored `false` is a logged kill-switch no-op.
        nowPlayingCoordinator?.start()
        print("Ready. Press \(HotkeyPreferences.shared.dropVoiceShortcut.title) to start/stop recording.")
    }

    /// Thread the island's action closures into the Settings shell (Toolbox
    /// deps + Other-tab capability toggles).
    private func configureSettingsDeps(from actions: IslandActions) {
        ensureSettingsWindowController().configure(toolboxDeps: ToolboxDeps(
            toggleDropMode: actions.toggleDropMode,
            currentDropMode: actions.currentDropMode,
            openClipboard: actions.openClipboard,
            historyCards: actions.historyCards,
            copyHistoryCard: actions.copyHistoryCard,
            deleteHistoryCard: actions.deleteHistoryCard,
            toggleMeetingRecord: actions.toggleMeetingRecord,
            openScreenshot: actions.openScreenshot,
            openMeetingAssistant: actions.openMeetingAssistant,
            openHoverPanel: { [weak self] panel in self?.show(.hoverPanel(panel)) },
            quitApplication: actions.quitApplication,
            translationController: { [weak self] in self?.ensureTranslationController() },
            endToolSessions: { [weak self] in _ = self?.translationWindowController?.endEmbedding() },
            vocabulary: actions.vocabulary,
            currentLanguage: actions.currentLanguage,
            currentTargetLanguage: actions.currentTargetLanguage,
            setLanguage: actions.setLanguage,
            setTargetLanguage: actions.setTargetLanguage
        ))
        ensureSettingsWindowController().configureOtherDeps(
            onAgentToggle: { isOn in
                UserPreferencesCache.shared.setAgentEnabled(isOn)
            },
            onMeetingsToggle: { isOn in
                UserPreferencesCache.shared.setMeetingsEnabled(isOn)
            },
            onGoogleToggle: { isOn in
                UserPreferencesCache.shared.setGoogleEnabled(isOn)
            }
        )
    }

    // MARK: - Sleep / wake lifecycle

    /// Subscribes to workspace power notifications and wires them through
    /// `PowerStateCoordinator`. We listen to both `didWakeNotification`
    /// (system sleep) and `screensDidWakeNotification` (display sleep)
    /// because some macOS sleep modes fire only one of them — and either
    /// can leave Carbon `RegisterEventHotKey` registrations and
    /// `NSEvent.addGlobalMonitorForEvents` handles in a broken state
    /// where Sidekey appears frozen for ~30s until the kernel re-routes
    /// events on its own.
    ///
    /// `willSleep` is observed but not strictly required for the wake
    /// path to work — the coordinator's `.soft` re-arm path covers the
    /// case where macOS skipped the will-sleep entirely (display-only
    /// sleep, dark sleep, lid-close on docked external displays).
    private func installWorkspacePowerObservers() {
        let coordinator = PowerStateCoordinator(
            onPause: { [weak self] in
                Task { @MainActor in
                    self?.pauseRuntimeForSleep()
                    // Stage 9: if a meeting recording is active, flush
                    // the current chunk + release inputs + flip pill to
                    // `.paused`. No-op when no recorder is running.
                    await AppState.shared.meetingsCoordinator?.pauseRecordingIfActive()
                }
            },
            onRearm: { [weak self] reason in
                Task { @MainActor in
                    self?.rearmRuntimeAfterWake(reason: reason)
                    // Stage 9: if the pill is in `.paused` because we
                    // paused on sleep, try to resume the recorder.
                    // On reinstall failure the coordinator finalizes
                    // the partial recording with interruptedBySleep=true.
                    await AppState.shared.meetingsCoordinator?
                        .resumeRecordingIfPaused(reason: reason)
                }
            }
        )
        self.powerStateCoordinator = coordinator

        let center = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    coordinator.handleWillSleep()
                }
            }
        )
        workspaceNotificationObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    coordinator.handleDidWake()
                }
            }
        )
        // Some sleep modes (display-only sleep, dark sleep) fire only
        // `screensDidWakeNotification`. Subscribing to both ensures we
        // always get a wake signal regardless of which path macOS took.
        // `PowerStateCoordinator` debounces back-to-back notifications
        // so we won't double-rearm when both fire.
        workspaceNotificationObservers.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    coordinator.handleDidWake()
                }
            }
        )
    }

    private func removeWorkspacePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.forEach { center.removeObserver($0) }
        workspaceNotificationObservers.removeAll()
    }

    /// Called by `PowerStateCoordinator` on `willSleepNotification`. Stops
    /// runtime subsystems so the kernel can suspend the process cleanly
    /// without leaving in-flight resources (recorder, capture stream)
    /// half-alive.
    ///
    /// Also orders the orb panel OUT before sleep. The hosted SwiftUI
    /// tree drives a `TimelineView(.animation)` at 60Hz; if the panel
    /// stays on screen across a sleep, on wake the cross-sleep `Date()`
    /// jump (hours) combined with parent `.animation(_:value:)`
    /// modifiers can throw `BlobShape.animatableData` into a
    /// never-converging `DefaultCombiningAnimation` interpolation that
    /// pins the main thread. Ordering the panel out tears the
    /// TimelineView down so no animation state survives the sleep
    /// window. This is belt-and-suspenders with the animation-side
    /// fix in `VoiceOrbView` (`@State` time anchor + `.transaction
    /// { animation = nil }`); either fix alone would close most of
    /// the hang surface, both together close the corner cases.
    private func pauseRuntimeForSleep() {
        screenshotCoordinator?.cancel(restoreFocus: false)
        os_log("power_will_sleep pausing runtime", log: Self.log, type: .info)
        stopPermissionRecoveryPolling()
        translationWindowController?.cancel()
        meetingAssistantPanel?.suspend()

        recorder.cancel()
        // Same reasoning as `applicationWillTerminate` — sleep should not
        // leave a half-open WS task spinning the URLSession.
        cancelStreamingSessionIfNeeded()
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle

        // Full-wake path reboots via `startReady() → registerHotkey()`, whose
        // registrars early-return on a live ref. Clear the WHOLE monitor set
        // (incl. ⌥M / ⌥1..⌥5) here so they actually rebuild on wake, not just
        // Drop / Help / History.
        teardownHotkeyMonitorsForRebuild()

        agentController?.stop()
        agentController = nil
        googleSearchController = nil
        clipboardWatcher?.stop()

        // Order the orb panel OUT so its SwiftUI TimelineView stops
        // ticking before the system suspends the process. On wake,
        // `rearmRuntimeAfterWake(reason: .full)` calls `startReady()`
        // which re-runs `showFloatingPanelIfNeeded` → `panel?.showOnTop()`
        // to put it back. The panel instance is retained (orderOut does
        // not destroy it) so the panel-level subscriptions and
        // luminance window-ID bookkeeping survive the sleep.
        panel?.orderOut(nil)
        IslandPanel.shared.hide()
        IslandNotificationPanel.shared.hide()

        Task { @MainActor in
            await BackgroundLuminanceObserver.shared.stop()
        }
    }

    /// Called by `PowerStateCoordinator` on `didWakeNotification` or
    /// `screensDidWakeNotification`.
    ///
    /// * `.full` (we observed the matching will-sleep): everything was
    ///   torn down in `pauseRuntimeForSleep` — wait for macOS services
    ///   to settle, then run the full `startReady()` boot.
    /// * `.soft` (wake without paired pause): subsystems are still alive
    ///   but the kernel may have invalidated Carbon hot-key registrations
    ///   and the global NSEvent monitor under us. Reinstall the event
    ///   monitors defensively, but skip heavyweight work (luminance reseed)
    ///   that would only thrash a healthy app.
    private func rearmRuntimeAfterWake(reason: PowerStateCoordinator.WakeReason) {
        os_log(
            "power_did_wake reason=%{public}@ rearming runtime",
            log: Self.log, type: .info,
            reason == .full ? "full" : "soft"
        )

        clipboardWatcher?.start()

        switch reason {
        case .full:
            Task { @MainActor in
                // Brief settle delay — TCC and input services come back
                // ~hundreds of ms after the wake notification fires.
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard self.didCompleteReadyStartup else {
                    return
                }
                self.startReady()
            }
        case .soft:
            // Soft path: no teardown happened, so we only need to make
            // sure the event monitors are healthy. `forceReregister...`
            // calls `stop()` before re-installing, so the operation is
            // idempotent — safe even when the existing handle was still
            // good.
            guard didCompleteReadyStartup else { return }
            forceReregisterEventMonitors()
        }
    }

    /// Tears down and re-registers all event monitors that the kernel
    /// power-management layer can silently invalidate during sleep:
    /// Carbon `RegisterEventHotKey` (drop / help / history hotkeys) and
    /// the Right-Cmd `NSEvent.addGlobalMonitorForEvents` inside
    /// `AgentController`.
    ///
    /// Idempotent: each underlying `start()` calls `stop()` first, so
    /// invoking this on a healthy app is safe and cheap (no observable
    /// flicker, just a re-handshake with the WindowServer).
    private func forceReregisterEventMonitors() {
        teardownHotkeyMonitorsForRebuild()

        registerHotkey()
        if AppState.shared.dropHotkeyStatus != .ready { startPermissionRecoveryPollingIfNeeded() }

        // `AgentController.start()` re-installs `gestureMonitor.start()`
        // which itself calls `stop()` first. Calling it on the live
        // controller therefore reinstalls the NSEvent monitor without
        // tearing down chat state, response panel, or in-flight SSE.
        agentController?.start(googleCallbacks: makeGoogleCallbacks())
    }

    /// Stop AND clear every Carbon / CGEventTap hotkey monitor that must be
    /// rebuilt before `registerHotkey()` can re-create it. `registerHotkey()`
    /// and its per-monitor registrars all early-return on a non-nil / non-empty
    /// handle (`guard hotkey == nil`, `guard meetingRecordHotkey == nil`,
    /// `guard toolHotkeys.isEmpty`), so any rebuild path that leaves a
    /// stale ref behind silently no-ops that monitor. Every rebuild site (soft
    /// wake, full-wake teardown, Accessibility re-grant) funnels through here so
    /// the whole set is torn down symmetrically — a Carbon hotkey added later is
    /// covered by all three paths at once instead of drifting (the ⌥M / ⌥1..⌥5
    /// dead-hotkey-after-wake bug was exactly this drift). `stop()` is
    /// idempotent and `start()` self-stops, so a redundant call is cheap.
    private func teardownHotkeyMonitorsForRebuild() {
        Self.teardownHotkeyMonitorsForRebuild(
            [hotkey, helpHotkey, historyHotkey, meetingRecordHotkey] + toolHotkeys
        )
        hotkey = nil
        dropMonitorGeneration = UUID()
        helpHotkey = nil
        historyHotkey = nil
        meetingRecordHotkey = nil
        toolHotkeys = []
        // The setting stays; registerHotkey installs the tap again.
        BrightnessKeys.shared.stop()
    }

    /// Test seam for the rebuild teardown: stops each supplied monitor,
    /// skipping `nil` handles. Kept pure over the handles so a test can assert
    /// the Meeting-record / Hover-slot monitors are torn down without
    /// constructing an `AppDelegate` (whose real `start()` would touch Carbon).
    static func teardownHotkeyMonitorsForRebuild(_ monitors: [HotkeyShortcutMonitoring?]) {
        for monitor in monitors {
            monitor?.stop()
        }
    }

    private func showFloatingPanelIfNeeded() {
        // Bottom-right orb panels (FloatingDotPanel, KeybindingsHintPanel,
        // OrbActionsOverlayPanel) moved to IslandPanel (PoC). Classes kept
        // for easy revert. The history strip still anchors to the orb's
        // frame; with the orb absent it falls back to `.zero` and the
        // strip uses the full visible width.
        showHistoryStripPanelsIfNeeded()
    }

    private func showActionsOverlayPanelIfNeeded() {
        if actionsOverlayPanel == nil {
            let overlay = OrbActionsOverlayPanel(
                orbFrame: { [weak self] in self?.panel?.frame ?? .zero },
                hintFrame: { [weak self] in self?.keybindingsHintPanel?.frame },
                onAction: { [weak self] id in
                    self?.handleOrbAction(id)
                }
            )
            // Start ordered out — the orderFront happens on the first
            // `orbHovered = true` tick from the SwiftUI subscription
            // inside the overlay itself.
            self.actionsOverlayPanel = overlay
        }
        // Tell the orb panel where the overlay sits so its hover
        // controller can include the overlay's frame in the hover
        // region (the overlay extends past orb+hint, so the cursor
        // must stay latched while it travels over the cluster).
        panel?.overlayFrameProvider = { [weak self] in
            guard let overlay = self?.actionsOverlayPanel, overlay.isVisible else {
                return nil
            }
            return overlay.frame
        }

        showHistoryStripPanelsIfNeeded()
    }

    /// Lazy-creates the bottom strip + centered expanded panel. Both
    /// panels stay alive across mode switches; they order themselves
    /// in / out based on `HistoryStripController` published events.
    private func showHistoryStripPanelsIfNeeded() {
        guard let controller = historyStripController,
              let feed = historyStripFeed,
              let assets = assetsDirectory
        else {
            return
        }

        if historyStripPanel == nil {
            // ROO-208 iter 4: the strip spans the full screen width
            // (`visible.minX + sideMargin` … `visible.maxX - sideMargin`),
            // so no orb-hover-frame closure is needed here. The orb +
            // strip no longer share a horizontal band visually — the
            // 5-up rubbery cards row needs the full width to fan out.
            let strip = HistoryStripPanel(
                controller: controller,
                feed: feed,
                assetsDirectory: assets,
                toast: copiedToastController,
                autoPasteEngine: autoPasteEngine,
                deleteCard: { [weak self] card in
                    await self?.deleteHistoryCard(card) ?? false
                }
            )
            self.historyStripPanel = strip
        }

        if historyExpandedPanel == nil {
            let expanded = HistoryExpandedPanel(
                controller: controller,
                assetsDirectory: assets
            )
            self.historyExpandedPanel = expanded
        }

        if copiedToastPanel == nil, let toast = copiedToastController {
            self.copiedToastPanel = CopiedToastPanel(controller: toast)
        }
    }

    /// Builds the `IslandActions` struct fed into `IslandPanel.shared`
    /// before `show()`. Each closure routes the toolbar click through
    /// the same code path the corresponding hotkey already uses, so
    /// telemetry, AppState transitions, and side effects (target
    /// capture, snapshot, etc.) match the keyboard-driven flow.
    ///
    /// **Useful Links** is intentionally a no-op: the `⌥↓` hotkey is
    /// only registered when an `AgentResponsePanel` is on screen with
    /// a `usefulLinks` block, and there's no standalone "Useful Links
    /// picker" surface today. Flagged in the toolbar PR's concerns.
    private func makeIslandActions() -> IslandActions {
        IslandActions(
            startDictate: { [weak self] in
                self?.onDropHotkeyPressed()
            },
            startVoiceAgent: { [weak self] in
                self?.agentController?.triggerVoiceAgent()
            },
            stopVoiceAgent: { [weak self] in
                self?.agentController?.triggerVoiceAgentEnd()
            },
            openTextAgent: { [weak self] in
                self?.agentController?.triggerTextAgent()
            },
            openClipboard: { [weak self] in
                self?.toggleHistoryStrip(.clipboard)
            },
            openHistory: { [weak self] in
                self?.openHistoryFromIsland() ?? .clipboard
            },
            historyCards: { [weak self] mode in
                // The closure is main-actor isolated, so read the feed
                // reference here, then hand the synchronous SQLite read to a
                // detached task so the panel's body never blocks the main
                // thread on disk I/O.
                guard let feed = self?.historyStripFeed else { return [] }
                return await IslandHistoryCards.load(mode: mode) { feed.cards(for: $0) }
            },
            selectHistoryMode: { [weak self] mode in
                self?.historyStripController?.rememberFilter(mode)
            },
            copyHistoryCard: { [weak self] card in
                self?.copyHistoryCardFromIsland(card)
            },
            historyAssetsDirectory: { [weak self] in
                self?.assetsDirectory
            },
            pasteHistoryCard: { [weak self] card in
                self?.pasteHistoryCardFromIsland(card)
            },
            deleteHistoryCard: { [weak self] card in
                await self?.deleteHistoryCard(card) ?? false
            },
            historyPasteTargetName: { [weak self] in
                self?.historyStripController?.targetAppName
            },
            openUsefulLinks: {
                // No global Useful Links entry point — the hotkey only
                // exists while a response panel with a usefulLinks block
                // is on screen. Logged no-op so a future global picker
                // (if added) only needs to swap this closure body.
                os_log(
                    "Island toolbar Useful Links click — no global picker; ignored",
                    log: Self.log, type: .info
                )
            },
            openMeetings: { [weak self] in
                self?.openMeetingsWindowFromIsland()
            },
            openMonitor: { [weak self] in
                guard let self else { return }
                self.registerIslandHotkeyActivity()
                AppState.shared.programmaticHoverExpansion = true
                self.hoverPanelRequestToken += 1
                AppState.shared.programmaticHoverPanelRequest = HoverPanelRequest(
                    panel: .monitor, token: self.hoverPanelRequestToken
                )
            },
            openCalendar: { [weak self] in
                guard let self else { return }
                self.registerIslandHotkeyActivity()
                AppState.shared.programmaticHoverExpansion = true
                self.hoverPanelRequestToken += 1
                AppState.shared.programmaticHoverPanelRequest = HoverPanelRequest(
                    panel: .calendar, token: self.hoverPanelRequestToken
                )
            },
            openTranslate: { [weak self] in self?.openTranslation(.text) },
            openSubtitles: { [weak self] in self?.openTranslation(.subtitles) },
            openMeetingAssistant: { [weak self] in self?.openMeetingAssistant() },
            setMeetingAssistantEnabled: { [weak self] enabled in self?.ensureMeetingAssistant().setMeetingEnabled(enabled) },
            prepareMeetingAssistant: { [weak self] in self?.ensureMeetingAssistant().prepare() },
            openScreenshot: { [weak self] in self?.openScreenshot() },
            openSettings: { [weak self] in
                self?.openSettingsWindow(tab: .apiAndModels)
            },
            openHelp: { [weak self] in
                self?.openHelpWindow()
            },
            openHotkeys: { [weak self] in
                self?.openHotkeysWindowFromIsland()
            },
            quitApplication: { [weak self] in
                self?.quitApplicationFromIsland()
            },
            stopMeetingRecording: { [weak self] in
                self?.meetingPillController?.stopRecording()
            },
            toggleMeetingRecord: {
                Task { @MainActor in
                    await AppState.shared.meetingsCoordinator?.toggleManualRecording()
                }
            },
            retryDelivery: { [weak self] in
                self?.retryPendingDelivery()
            },
            musicPrevious: { [weak self] in
                self?.nowPlayingCoordinator?.previous()
            },
            musicPlayPause: { [weak self] in
                self?.nowPlayingCoordinator?.playPause()
            },
            musicNext: { [weak self] in
                self?.nowPlayingCoordinator?.next()
            },
            currentLanguage: {
                PrivacyPreferences.shared.selectedLanguage
            },
            setLanguage: { [weak self] language in
                self?.setLanguageFromIsland(language)
            },
            currentTargetLanguage: {
                PrivacyPreferences.shared.targetLanguage
            },
            setTargetLanguage: { [weak self] language in
                self?.setTargetLanguageFromIsland(language)
            },
            currentDropMode: {
                UserPreferencesCache.shared.currentMode
            },
            toggleDropMode: { [weak self] in
                self?.toggleDropModeFromIsland()
                    ?? UserPreferencesCache.shared.currentMode
            },
            vocabulary: { .shared }
        )
    }

    /// Toggle the same cached preference the Drop hotkey reads. The local
    /// cache updates synchronously so the very next Drop uses the selected
    /// route.
    private func toggleDropModeFromIsland() -> TranscriptionMode {
        let nextMode = IslandDropModeControl.nextMode(
            after: UserPreferencesCache.shared.currentMode
        )
        UserPreferencesCache.shared.setMode(nextMode)
        return nextMode
    }

    private func setLanguageFromIsland(_ language: AppLanguage?) {
        PrivacyPreferences.shared.selectedLanguage = language
    }

    private func setTargetLanguageFromIsland(_ language: AppLanguage?) {
        PrivacyPreferences.shared.targetLanguage = language
    }

    /// The output-language code handed to the cleanup LLM, or nil. Translation
    /// is Smart-only and only when a target language is set and differs from
    /// the input language.
    private func outputLanguageCodeForDrop(mode: TranscriptionMode) -> String? {
        guard mode == .smart else { return nil }
        let prefs = PrivacyPreferences.shared
        guard let target = prefs.targetLanguage?.code else { return nil }
        return target == prefs.selectedLanguage?.code ? nil : target
    }

    /// Bring up Settings > Notes from the Dynamic Island toolbar.
    /// The user clicked the generic "Notes" tile, so we open the Settings
    /// tab on the **meeting list** — the home screen — and let the user
    /// pick which meeting to read. (Previously this auto-opened the most
    /// recent meeting, which fought the list-first navigation: clicking
    /// "Notes" jumped straight into a note instead of showing the list.)
    private func openMeetingsWindowFromIsland() {
        guard meetingsCoordinator != nil else {
            os_log(
                "Island toolbar notes click — coordinator unavailable",
                log: Self.log, type: .info
            )
            return
        }
        openSettingsWindow(tab: .notes)
    }

    private func openHotkeysWindowFromIsland() {
        openHotkeysWindow()
    }

    private func quitApplicationFromIsland() {
        showQuitConfirmation()
    }

    private func showQuitConfirmation() {
        if quitConfirmationController == nil {
            quitConfirmationController = SidekeyQuitConfirmationController(
                onConfirmQuit: {
                    NSApp.terminate(nil)
                }
            )
        }
        quitConfirmationController?.show()
    }

    private func openHotkeysWindow() {
        openSettingsWindow(tab: .hotkeys)
    }

    private func openSettingsWindow(tab: SettingsWindowTab = .apiAndModels, feature: AIFeature? = nil) {
        ensureSettingsWindowController().show(tab: tab, feature: feature)
    }

    @discardableResult
    private func ensureSettingsWindowController() -> SettingsWindowController {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                screenshotProtectionChanged: { [weak self] enabled in
                    IslandPanel.setScreenshotProtectionEnabled(enabled)
                    IslandNotificationPanel.setScreenshotProtectionEnabled(enabled)
                    self?.meetingAssistantPanel?.setProtection(enabled)
                },
                notesControllerProvider: { [weak self] in
                    self?.meetingsCoordinator?.settingsMeetingsContentController
                }
            )
        }
        return settingsWindowController!
    }

    /// Orb-action click handler. Mode-icon clicks toggle / switch /
    /// close the strip via `HistoryStripController`.
    private func handleOrbAction(_ id: OrbActionsView.IconID) {
        guard historyStripController != nil else { return }
        switch id {
        case .agent: toggleHistoryStrip(.agent)
        case .drop: toggleHistoryStrip(.drop)
        case .clipboard: toggleHistoryStrip(.clipboard)
        }
    }

    private func showKeybindingsHintIfNeeded() {
        guard !DisplayPreferences.shared.hideHelpers else { return }
        if keybindingsHintPanel == nil {
            let hint = KeybindingsHintPanel()
            hint.showOnTop()
            self.keybindingsHintPanel = hint
        } else {
            keybindingsHintPanel?.showOnTop()
        }
    }

    private func deliverDropTranscript(_ text: String, formatting: SmartFormattingProfile = .plain) async -> Bool {
        guard !text.isEmpty else { return false }

        return await autoPasteEngine.paste(text, formatting: formatting)
    }

    private func finishDropDelivery(
        text: String,
        rawTranscript: String,
        targetApp: String?,
        formatting: SmartFormattingProfile = .plain
    ) async {
        let cleaned = text
        AppState.shared.phase = .inserting
        let pasted = await deliverDropTranscript(cleaned, formatting: formatting)
        if !pasted {
            // Fallback: text is already in the clipboard (AutoPasteEngine
            // writes up-front). No UI toast surface exists in this PR;
            // user can press ⌘V manually.
            // TODO: surface a transient "Copied, press ⌘V" notification.
            os_log(
                "autopaste_fallback_clipboard_only",
                log: Self.log,
                type: .info
            )
        }
        // The user-visible deliverable landed (either direct paste or
        // clipboard fallback). Either way the turn closes as completed.
        discardPendingRetry()
        completeDropTurnTelemetry()
        dropHistoryRecorder?.record(
            rawTranscript: rawTranscript,
            formattedText: cleaned,
            targetApp: targetApp
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        AppState.shared.phase = .idle
    }

    private static func pipelineErrorDescription(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    /// - Parameters:
    ///   - dropShortcut / dropGesture: the Drop binding to register. Defaults
    ///     read `HotkeyPreferences.shared` for the launch path, but the runtime
    ///     re-registration sink passes the just-published value explicitly:
    ///     `@Published` fires in `willSet`, so re-reading `shared` here would
    ///     observe the PRIOR value and build the wrong monitor (ROO-234 race).
    private func registerHotkey(
        dropShortcut: HotkeyShortcut? = nil,
        dropGesture: HotkeyGesture? = nil
    ) {
        registerHistoryHotkey()
        registerHelpHotkey()
        registerToolHotkeys()
        registerMeetingRecordHotkey()
        // Brightness keys install their tap only when switched on in Settings -> Toolbox.
        BrightnessKeys.shared.start(showStrip: { [weak self] in self?.showBrightnessGlance() })
        guard hotkey == nil else { return }
        // Keep Drop working during meetings. Meeting mic capture and the
        // Drop voice route can coexist, so configurable drop shortcuts
        // register without the old meeting suppression gate.
        let dropVoiceHotkey = dropShortcut ?? HotkeyPreferences.shared.dropVoiceShortcut
        let dropVoiceGesture = HotkeyConfiguration.normalizedDropGesture(
            shortcut: dropVoiceHotkey,
            gesture: dropGesture ?? HotkeyPreferences.shared.dropVoiceGesture
        )
        let dropHoldSwallow = HotkeyShortcutMonitor.isDropHoldTap(
            shortcut: dropVoiceHotkey,
            gesture: dropVoiceGesture
        )
        guard DropHotkeyRecovery.canRegister(
            shortcut: dropVoiceHotkey,
            gesture: dropVoiceGesture,
            accessibilityGranted: PermissionsHelper.accessibilityGranted(prompt: false)
        ) else {
            dropRegistrationFailure = nil
            publishDropHotkeyStatus()
            return
        }
        let monitorGeneration = UUID()
        dropMonitorGeneration = monitorGeneration
        let hotkey = HotkeyShortcutMonitor(
            shortcut: dropVoiceHotkey,
            hotKeyIDValue: CarbonHotkeyMonitor.dropHotKeyID,
            onHotkey: { [weak self] in self?.onDropHotkeyPressed() },
            onHotkeyReleased: dropVoiceGesture == .hold ? { [weak self] in
                self?.onDropHotkeyReleased()
            } : nil,
            // Escape-cancel discard, honoured only by the `SpaceHoldMonitor`
            // path (hold-Space and a swallowed hold-combo Drop); the
            // Carbon/modifier monitors have no cancel gesture and ignore it.
            onCancel: { [weak self] in self?.onDropHotkeyCancelled() },
            // Route a hold-combo Drop through the swallowing CGEventTap instead
            // of Carbon (so the bound character never prints); `.holdSpace`
            // already taps and ignores this flag.
            dropHoldSwallow: dropHoldSwallow,
            // A disabled tap may be a transient failure, not a revoked grant.
            // Recover quietly; permission UI is shown only on user invocation.
            onAccessibilityLost: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.dropMonitorGeneration == monitorGeneration else { return }
                    if AppState.shared.phase == .recording || self.streamingSetupInProgress {
                        // The lost hold tap can no longer receive keyUp. Finish
                        // the captured audio instead of leaving the mic open.
                        self.handleDropHotkeyRoute(Self.dropHotkeyReleasedRoute(
                            gesture: dropVoiceGesture,
                            phase: AppState.shared.phase,
                            hasStreamingSession: self.streamingSession != nil,
                            isStreamingSetupInProgress: self.streamingSetupInProgress
                        ))
                    }
                    self.hotkey?.stop()
                    self.hotkey = nil
                    self.refreshRuntimePermissions(forceRebuild: true)
                }
            },
            allowPermissionRequests: false
        )
        do {
            try hotkey.start()
            self.hotkey = hotkey
            dropRegistrationFailure = nil
            publishDropHotkeyStatus()
        } catch {
            // Failed starts remain uninstalled. Settings shows a useful
            // distinction between a permission issue and a shortcut collision.
            os_log(
                "registerHotkey failed: %{public}@",
                log: Self.hotkeyLog, type: .error,
                String(describing: error)
            )
            dropRegistrationFailure = DropHotkeyRecovery.failure(
                for: error,
                inputMonitoringGranted: PermissionsHelper.inputMonitoringGranted(prompt: false)
            )
            publishDropHotkeyStatus()
        }
    }

    /// ROO-208: registers the unified `⌥V` strip hotkey. Calls
    /// `HistoryStripController.toggleUnified()` so the controller picks
    /// the last-remembered filter (defaulting to Clipboard) and
    /// open/close-toggles in place.
    private func registerHistoryHotkey() {
        guard historyHotkey == nil else { return }
        guard historyStripController != nil else { return }

        let monitor = CarbonHotkeyMonitor(
            keyCode: CarbonHotkeyMonitor.vKeyCode,
            modifiers: CarbonHotkeyMonitor.optionModifier,
            hotKeyIDValue: CarbonHotkeyMonitor.historyUnifiedHotKeyID
        ) { [weak self] in
            self?.toggleUnifiedHistoryStrip()
        }
        do {
            try monitor.start()
            self.historyHotkey = monitor
        } catch {
            os_log(
                "registerHistoryHotkey failed: %{public}@",
                log: Self.hotkeyLog, type: .error,
                String(describing: error)
            )
        }
    }

    private func stopHistoryHotkey() {
        historyHotkey?.stop()
        historyHotkey = nil
    }

    private func registerHelpHotkey() {
        guard helpHotkey == nil else { return }
        let monitor = CarbonHotkeyMonitor(
            keyCode: CarbonHotkeyMonitor.hKeyCode,
            modifiers: CarbonHotkeyMonitor.optionModifier,
            hotKeyIDValue: CarbonHotkeyMonitor.helpHotKeyID
        ) { [weak self] in
            self?.openHelpWindow()
        }
        do {
            try monitor.start()
            self.helpHotkey = monitor
        } catch {
            os_log(
                "registerHelpHotkey failed: %{public}@",
                log: Self.hotkeyLog, type: .error,
                String(describing: error)
            )
        }
    }

    private func observeHotkeyPreferences() {
        guard hotkeyPreferenceCancellables.isEmpty else { return }

        AppDelegate.observeDropShortcut(HotkeyPreferences.shared) { [weak self] shortcut in
            self?.reregisterDropHotkey(shortcut: shortcut)
        }
        .store(in: &hotkeyPreferenceCancellables)
        AppDelegate.observeDropGesture(HotkeyPreferences.shared) { [weak self] gesture in
            self?.reregisterDropHotkey(gesture: gesture)
        }
        .store(in: &hotkeyPreferenceCancellables)

        Self.observeToolShortcuts(HotkeyPreferences.shared) { [weak self] shortcuts in
            self?.reregisterToolHotkeys(shortcuts: shortcuts)
        }.store(in: &hotkeyPreferenceCancellables)

        // Re-register the Meeting-record monitor on rebind. Same willSet
        // hazard as Drop / Hover slots: the published value is threaded
        // straight through instead of re-reading the stored property.
        HotkeyPreferences.shared.$meetingRecordShortcut
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.reregisterMeetingRecordHotkey(shortcut: shortcut)
            }
            .store(in: &hotkeyPreferenceCancellables)
    }

    /// Pass the published dictionary through: @Published emits before storage
    /// changes, so rereading preferences here would register stale bindings.
    static func observeToolShortcuts(
        _ preferences: HotkeyPreferences,
        onResolved: @escaping ([HoverTool: HotkeyShortcut]) -> Void
    ) -> AnyCancellable {
        preferences.$toolShortcuts.dropFirst().removeDuplicates().sink(receiveValue: onResolved)
    }

    /// Install the synchronous re-registration sink for the Drop *shortcut*.
    ///
    /// `@Published` emits in `willSet`, so this `sink` runs BEFORE the stored
    /// property updates. The published `shortcut` is therefore threaded straight
    /// through to `onResolved` — re-reading `preferences.dropVoiceShortcut` here
    /// would observe the prior (stale) value and rebuild Drop on the wrong
    /// monitor (the ROO-234 runtime race).
    static func observeDropShortcut(
        _ preferences: HotkeyPreferences,
        onResolved: @escaping (HotkeyShortcut) -> Void
    ) -> AnyCancellable {
        preferences.$dropVoiceShortcut
            .dropFirst()
            .removeDuplicates()
            .sink { newValue in onResolved(newValue) }
    }

    /// Install the synchronous re-registration sink for the Drop *gesture*.
    /// Same willSet/stale-read hazard as `observeDropShortcut` — the published
    /// gesture is threaded straight through.
    static func observeDropGesture(
        _ preferences: HotkeyPreferences,
        onResolved: @escaping (HotkeyGesture) -> Void
    ) -> AnyCancellable {
        preferences.$dropVoiceGesture
            .dropFirst()
            .removeDuplicates()
            .sink { newValue in onResolved(newValue) }
    }

    private func reregisterDropHotkey(
        shortcut: HotkeyShortcut? = nil,
        gesture: HotkeyGesture? = nil
    ) {
        hotkey?.stop()
        hotkey = nil
        dropMonitorGeneration = UUID()
        registerHotkey(dropShortcut: shortcut, dropGesture: gesture)
        if AppState.shared.dropHotkeyStatus != .ready { startPermissionRecoveryPollingIfNeeded() }
    }

    private func registerToolHotkeys(shortcuts: [HoverTool: HotkeyShortcut]? = nil) {
        guard toolHotkeys.isEmpty else { return }
        let shortcuts = shortcuts ?? HotkeyPreferences.shared.toolShortcuts
        var unavailable = Set<HoverTool>()
        for binding in ToolHotkeyBinding.resolve(shortcuts) {
            let monitor = HotkeyShortcutMonitor(
                shortcut: binding.shortcut,
                hotKeyIDValue: binding.hotKeyID,
                onHotkey: { [weak self] in self?.onToolHotkeyActivated(binding.tool) }
            )
            do {
                try monitor.start()
                toolHotkeys.append(monitor)
            } catch {
                unavailable.insert(binding.tool)
                os_log("registerToolHotkey failed: %{public}@", log: Self.hotkeyLog,
                       type: .error, String(describing: error))
            }
        }
        HotkeyPreferences.shared.unavailableToolShortcuts = unavailable
    }

    private func stopToolHotkeys() {
        toolHotkeys.forEach { $0.stop() }
        toolHotkeys = []
    }

    /// Register the manual Meeting-record toggle (default ⌥M). Idempotent —
    /// a no-op while a monitor is installed (`reregisterMeetingRecordHotkey()`
    /// tears it down first). Only the fact of the trigger is ever logged —
    /// never keystrokes (invariant #2).
    /// - Parameter override: freshly published shortcut from the Settings-Save
    ///   sink; `@Published` fires in willSet, so re-reading `shared` there
    ///   would observe the stale value (same ROO-234 race as Drop and the
    ///   Hover slots).
    private func registerMeetingRecordHotkey(override: HotkeyShortcut? = nil) {
        guard meetingRecordHotkey == nil else { return }
        let shortcut = override ?? HotkeyPreferences.shared.meetingRecordShortcut
        let monitor = HotkeyShortcutMonitor(
            shortcut: shortcut,
            hotKeyIDValue: CarbonHotkeyMonitor.meetingRecordHotKeyID,
            onHotkey: { [weak self] in self?.onMeetingRecordHotkey() }
        )
        do {
            try monitor.start()
            meetingRecordHotkey = monitor
        } catch {
            os_log(
                "registerMeetingRecordHotkey failed: %{public}@",
                log: Self.hotkeyLog, type: .error,
                String(describing: error)
            )
        }
    }

    private func reregisterMeetingRecordHotkey(shortcut: HotkeyShortcut) {
        meetingRecordHotkey?.stop()
        meetingRecordHotkey = nil
        registerMeetingRecordHotkey(override: shortcut)
    }

    /// ⌥M (or the rebound shortcut) — toggle a manual meeting recording.
    private func onMeetingRecordHotkey() {
        registerIslandHotkeyActivity()
        Task { @MainActor in
            await AppState.shared.meetingsCoordinator?.toggleManualRecording()
        }
    }

    private func reregisterToolHotkeys(shortcuts: [HoverTool: HotkeyShortcut]) {
        stopToolHotkeys()
        registerToolHotkeys(shortcuts: shortcuts)
    }

    /// Shares the tile's effect, independent of visibility and layout order.
    private func onToolHotkeyActivated(_ tool: HoverTool) {
        if tool != .screenshot { registerIslandHotkeyActivity() }
        let effect = HoverSlotRouter.effect(for: tool)

        switch effect {
        case .openPanel(let panel):
            // Inline-panel tools render their sub-panel INSIDE the drawer, so
            // they need programmatic expansion (still gated on `allowsExpansion`
            // in `IslandView`, D4).
            AppState.shared.programmaticHoverExpansion = true
            hoverPanelRequestToken += 1
            AppState.shared.programmaticHoverPanelRequest = HoverPanelRequest(
                panel: panel,
                token: hoverPanelRequestToken
            )
        case .toggleDropMode:
            // The keyboard path bypasses the hover tile, so the toggled mode must
            // be published for IslandView to sync its tile state AND show the
            // transient ON Smart/Fast right-band status — otherwise the toggle is
            // invisible and reads as "the hotkey does nothing".
            let newMode = IslandPanel.shared.actions.toggleDropMode()
            AppState.shared.publishDropModeHotkeyToggle(newMode)
        case .openSettings, .openHotkeys, .openNotes, .toggleMeetingRecord, .openMonitor, .openCalendar, .openTranslate, .openSubtitles, .openMeetingAssistant, .openScreenshot, .quit:
            // Action/navigate tools open their own surfaces (window / toggle)
            // instantly — forcing the drawer open here would flash an empty
            // Hover for ~4s (Stage 3 review fix). Run the effect directly
            // without requesting expansion.
            effect.invoke(on: IslandPanel.shared.actions)
        }
    }

    // MARK: - whytap:// links

    /// `kAEGetURL` handler. Malformed links are ignored; the URL itself is not logged.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                         withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string),
              let request = WhytapLink.request(for: url)
        else {
            os_log("whytap_link rejected", log: Self.log, type: .info)
            return
        }
        if acceptsLinkRequests {
            handle(request)
        } else {
            pendingLinkRequest = request
        }
    }

    private func handle(_ request: WhytapLinkRequest) {
        guard !isConfirmingLinkChange else { return }
        switch request {
        case .show(let destination):
            show(destination)
        case .propose(let change):
            propose(change)
        }
    }

    /// The only path from a link to a change: Whytap's own confirmation,
    /// then the same validated `HotkeyPreferences.apply` as Settings Save.
    /// WHY: .project-docs/decisions/2026-10-21-whytap-link-hotkeys.md
    private func propose(_ change: WhytapLinkChange) {
        guard !isConfirmingLinkChange else { return }
        registerIslandHotkeyActivity()
        let preferences = HotkeyPreferences.shared
        isConfirmingLinkChange = true
        defer { isConfirmingLinkChange = false }
        switch change.plan(for: preferences.configuration) {
        case .unchanged:
            break
        case .conflict(let owners):
            WhytapLinkConfirmation.showConflict(change, owners: owners)
        case .confirm(let current):
            guard WhytapLinkConfirmation.confirm(change, replacing: current),
                  // Settings may have changed while the dialog was open.
                  change.plan(for: preferences.configuration) == .confirm(current: current)
            else { break }
            do {
                try preferences.apply(change.applied(to: preferences.configuration))
            } catch {
                os_log("whytap_link change not applied", log: Self.log, type: .error)
            }
        }
        show(.settings(.tab(.hotkeys)))
    }

    /// Shows the link's place. Never runs a tool's action.
    /// WHY: .project-docs/decisions/2026-10-20-whytap-links.md
    private func show(_ destination: WhytapLinkDestination) {
        registerIslandHotkeyActivity()
        switch destination {
        case .hoverPanel(let panel):
            AppState.shared.programmaticHoverExpansion = true
            hoverPanelRequestToken += 1
            AppState.shared.programmaticHoverPanelRequest = HoverPanelRequest(
                panel: panel, token: hoverPanelRequestToken
            )
        case .settings(let target):
            let controller = ensureSettingsWindowController()
            if case .tab(let tab) = target {
                controller.show(tab: tab)
            } else {
                controller.show()
            }
            controller.selection.setHighlight(target)
        case .toolboxTool(let tool):
            let controller = ensureSettingsWindowController()
            controller.show(tab: .toolbox)
            controller.selection.focus(tool)
            controller.selection.setHighlight(.tab(.toolbox))
        case .meetingAssistant:
            openMeetingAssistant()
        case .translation(let mode):
            openTranslation(mode)
        case .island:
            // Already woken above: a link this version does not know.
            break
        }
    }

    private func openMeetingAssistant() {
        registerIslandHotkeyActivity()
        ensureMeetingAssistant().show()
    }

    private func ensureMeetingAssistant() -> MeetingAssistantPanel {
        if meetingAssistantPanel == nil {
            meetingAssistantPanel = MeetingAssistantPanel(
                openSettings: { [weak self] feature in self?.openSettingsWindow(tab: .apiAndModels, feature: feature) },
                activityChanged: { active, editing in
                    if AppState.shared.meetingAssistantActive != active { AppState.shared.meetingAssistantActive = active }
                    if AppState.shared.meetingAssistantEditing != editing { AppState.shared.meetingAssistantEditing = editing }
                },
                hoverChanged: { state in
                    if AppState.shared.meetingAssistantHover != state { AppState.shared.meetingAssistantHover = state }
                }
            )
        }
        return meetingAssistantPanel!
    }

    private func openTranslation(_ mode: TranslationWindowController.Mode) {
        registerIslandHotkeyActivity()
        ensureTranslationController().show(mode)
    }

    private func ensureTranslationController() -> TranslationWindowController {
        if translationWindowController == nil {
            translationWindowController = TranslationWindowController(
                openSettings: { [weak self] feature in self?.openSettingsWindow(tab: .apiAndModels, feature: feature) },
                activityChanged: { AppState.shared.translationActive = $0 }
            )
        }
        return translationWindowController!
    }

    private func openScreenshot() {
        if screenshotCoordinator == nil {
            screenshotCoordinator = ScreenshotCoordinator(
                activityChanged: { AppState.shared.screenshotActive = $0 },
                preparationChanged: { [weak self] preparing in
                    AppState.shared.screenshotPreparing = preparing
                    if !preparing { self?.registerIslandHotkeyActivity() }
                }
            )
        }
        screenshotCoordinator?.start()
    }

    private func openHelpWindow() {
        registerIslandHotkeyActivity()
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.show()
    }

    /// ROO-208 iter 22: Dynamic Island toolbar (clipboard icon) and
    /// orb-action mode switches enter the strip through this single
    /// `toggle(_:)` path. Without `captureAndValidatePasteTargetIfOpening()`
    /// here, the strip would open without ever asking `AutoPasteEngine`
    /// what the frontmost app was — so the bottom hint bar would render
    /// only "Click to copy" with no right-hand "Paste to <App> ↵"
    /// affordance, and the local Enter handler would silently no-op
    /// (because `controller.targetAppName` stays `nil`). Mirroring the
    /// `⌥V` hotkey's pre-open capture aligns all three entry points.
    private func toggleHistoryStrip(_ mode: HistoryStripMode) {
        captureAndValidatePasteTargetIfOpening()
        historyStripController?.toggle(mode)
    }

    private func openHistoryFromIsland() -> HistoryStripMode {
        captureAndValidatePasteTargetForHistory()
        return historyStripController?.rememberedFilter() ?? .clipboard
    }

    private func copyHistoryCardFromIsland(_ card: HistoryStripCard) {
        guard let controller = historyStripController,
              let assets = assetsDirectory
        else {
            return
        }

        ClipboardSuppression.shared.setSuppressed(true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            ClipboardSuppression.shared.setSuppressed(false)
        }

        controller.writeCardToPasteboard(card, assetsDirectory: assets)
        copiedToastController?.show()
    }

    /// Delete… on a clipboard row in any History surface. The ⌥V strip
    /// reads the feed on every render, so a revision bump refreshes it even
    /// when the request came from the island or Toolbox.
    /// WHY: .project-docs/decisions/2026-10-22-clipboard-entry-delete.md
    private func deleteHistoryCard(_ card: HistoryStripCard) async -> Bool {
        guard let store = historyStore, let assets = assetsDirectory else { return false }
        let outcome = await ClipboardEntryDeletion(store: store, assetsDirectory: assets).delete(card)
        guard outcome.removesEntry else { return false }
        historyStripController?.clipboardEntryRemoved(card)
        return true
    }

    private func pasteHistoryCardFromIsland(_ card: HistoryStripCard) {
        guard let controller = historyStripController,
              controller.targetAppName != nil,
              let assets = assetsDirectory
        else {
            return
        }

        controller.writeCardToPasteboard(card, assetsDirectory: assets)
        Task { @MainActor in
            _ = await autoPasteEngine.pasteAlreadyOnPasteboard()
        }
    }

    /// Captures the user's last-focused app via `AutoPasteEngine` and
    /// runs `PasteTargetValidator.appHasFocusedTextInput` on it. Pushes
    /// the result (or `nil` when the target failed AX validation /
    /// is in the blacklist) into `historyStripController.setTargetAppName`.
    ///
    /// Called BEFORE the strip's toggle so the capture happens while
    /// the user's real app is still frontmost — once
    /// `HistoryStripPanel.applyVisibility` calls `makeKey()`, AppKit
    /// briefly hands key status to the panel and `frontmostApplication`
    /// would return Sidekey itself. Cheap on the close path (we just
    /// overwrite the remembered target with whatever's frontmost; the
    /// next `toggleUnified` close branch clears `targetAppName`
    /// anyway).
    ///
    /// Shared by all three open entry points:
    ///   * `toggleUnifiedHistoryStrip()` — `⌥V` Carbon hotkey.
    ///   * `toggleHistoryStrip(_:)` — Dynamic Island clipboard icon
    ///     (via `IslandActions.openClipboard`) and orb-action icons
    ///     (`OrbActionsView.IconID.{agent, drop, clipboard}` →
    ///     `handleOrbAction`).
    private func captureAndValidatePasteTargetIfOpening() {
        autoPasteEngine.rememberTargetBeforeRecording()
        // Only validate when we're OPENING the strip — the close path
        // doesn't need a target. `openMode == nil` here means the
        // upcoming `toggle*()` call will transition to open.
        let willOpen = historyStripController?.openMode == nil
        guard willOpen else { return }
        historyStripController?.setTargetAppName(validatedPasteTargetName())
    }

    private func captureAndValidatePasteTargetForHistory() {
        autoPasteEngine.rememberTargetBeforeRecording()
        historyStripController?.setTargetAppName(validatedPasteTargetName())
    }

    private func validatedPasteTargetName() -> String? {
        let target = autoPasteEngine.currentTarget()
        if let pid = target?.pid,
           PasteTargetValidator.appHasFocusedTextInput(
               pid: pid,
               bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
           )
        {
            return target?.name
        }
        return nil
    }

    /// ROO-208: `⌥V` entry point. Routes through
    /// `HistoryStripController.toggleUnified()` so the strip opens on
    /// the user's last-picked filter (defaults to Clipboard) and closes
    /// regardless of the active filter on a re-press.
    ///
    /// ROO-208 iter 15: capture the frontmost app BEFORE the strip
    /// panel orders front. Once the panel becomes key on hover, AppKit
    /// briefly reports Sidekey active and `frontmostApplication` would
    /// return Sidekey itself — too late to know which app the user was
    /// just typing in. Capturing here mirrors the drop-pipeline's
    /// `rememberTargetBeforeRecording()` callsite (also pre-UI).
    /// Cheap when the strip is being closed (we just overwrite the
    /// remembered target with whatever's frontmost; nothing reads it
    /// until the next paste).
    ///
    /// ROO-208 iter 17: gate the "Paste to <App> ↵" hint on whether
    /// the captured app actually has a focused text-editing element.
    /// `rememberTargetBeforeRecording()` captures ANY frontmost app
    /// (Finder/Safari/Desktop included); without the validation step
    /// the hint reads "Paste to Finder ↵" but pressing Enter posts
    /// Cmd+V to a non-editable surface and nothing lands — the user
    /// sees a silent failure. `PasteTargetValidator` queries the AX
    /// API for the captured pid's focused element; only roles like
    /// `AXTextField` / `AXTextArea` / `AXComboBox` / `AXWebArea`
    /// (or subroles `AXSearchField` / `AXContentEditableElement`)
    /// produce a non-nil `targetAppName` on the controller, and only
    /// a non-nil value renders the hint and arms the Enter-paste
    /// handler.
    private func toggleUnifiedHistoryStrip() {
        registerIslandHotkeyActivity()
        captureAndValidatePasteTargetIfOpening()
        historyStripController?.toggleUnified()
    }

    // MARK: - Capability reconciliation

    /// Pure, testable decision: given the current flag values and whether the
    /// agent monitor is already armed, compute what should change. All branching
    /// lives here so tests cover every path without wiring up AppDelegate.
    struct CapabilityReconcileDecision: Equatable {
        let armMonitor: Bool
        let disarmMonitor: Bool
        let startMeetings: Bool
        let stopMeetings: Bool
    }

    nonisolated static func reconcileDecision(
        agent _: Bool,
        google _: Bool,
        meetings: Bool,
        monitorArmed: Bool
    ) -> CapabilityReconcileDecision {
        // Keep the lightweight gesture monitor alive after both capabilities
        // are switched off. R-Cmd can then open Settings > Agents and explain
        // how to re-enable Agent instead of becoming a silent no-op.
        let needMonitor = true
        return CapabilityReconcileDecision(
            armMonitor: needMonitor && !monitorArmed,
            disarmMonitor: !needMonitor && monitorArmed,
            startMeetings: meetings,
            stopMeetings: !meetings
        )
    }

    /// Effectful applier: reads live flags, computes the decision, and applies
    /// it by calling the existing arm/disarm/start/stop entry points.
    @MainActor private func reconcileCapabilities() {
        let d = Self.reconcileDecision(
            agent: UserPreferencesCache.shared.currentAgentEnabled,
            google: UserPreferencesCache.shared.currentGoogleEnabled,
            meetings: UserPreferencesCache.shared.currentMeetingsEnabled,
            monitorArmed: agentController != nil)
        if d.disarmMonitor {
            agentController?.stop()
            agentController = nil
            googleSearchController = nil
        }
        if d.armMonitor { startAgentIfEnabled() }
        if d.startMeetings { AppState.shared.meetingsCoordinator?.start() }
        if d.stopMeetings { AppState.shared.meetingsCoordinator?.stop() }
    }

    private func startAgentIfEnabled() {
        guard AgentFeatureGate.isEnabled,
              agentController == nil else { return }
        let claudeProvider: any CLIProvider = ClaudeCodeProvider()
        let codexProvider: any CLIProvider = CodexProvider()
        let nativeProvider: any CLIProvider = NativeAgentProvider()
        // ONE shared response store backs both the controller's agent stream
        // and the island flow store the answer panel renders from. Building
        // the flow store here (not letting the controller mint its own) lets
        // us hand the SAME instance to the island panel and the controller —
        // a second instance would leave the panel rendering a dead store.
        let responseStore = AskResponseStore()
        let islandFlow = IslandAgentFlowStore(responseStore: responseStore)
        let agentController = AgentController(
            resolveProvider: {
                // nil when nothing is connected (full Disconnect) -> the agent
                // refuses the turn instead of defaulting to Claude.
                switch AgentProviderStore.shared.activeProvider {
                case .claude: return claudeProvider
                case .codex: return codexProvider
                case .opencode, .native: return nativeProvider
                case nil: return nil
                }
            },
            audioTranscriber: BatchAgentAudioTranscriber(batch: agentBatchTranscriber),
            responseStore: responseStore,
            chatStackStore: chatStackStore,
            // Stage 2 capability gate: read the live flag on every gesture so
            // changes in Settings take effect without restarting the controller.
            agentEnabled: { UserPreferencesCache.shared.currentAgentEnabled },
            onAgentSetupRequired: { [weak self] in
                self?.openSettingsWindow(tab: .agentMode)
            },
            streamingVoiceEnabled: AgentFeatureGate.streamingVoiceEnabled,
            agentVoiceStreamFactory: { [weak self] in
                guard let self else { return nil }
                // resilient: false — agent-voice must never resolve .degraded
                // (the handler ignores it, silently dropping dictation).
                return try? await self.makeStreamingSession(feature: .agentVoice, resilient: false)
            },
            islandAgentFlow: islandFlow,
            // The island answer panel renders its useful-links chip from this
            // exact selection instance — share it so the hotkey controller's
            // index moves the on-screen chip.
            agentLinksSelection: IslandPanel.shared.agentLinksSelection
        )
        self.agentController = agentController
        // GoogleSearchController shares the same streaming session factory as
        // the agent. Retained on the delegate so it lives as long as
        // `agentController`.
        let googleSearchController = GoogleSearchController(
            voiceSessionFactory: { [weak self] in
                guard let self else { return nil }
                // resilient: false — Google-search must never resolve .degraded
                // (the handler ignores it, silently dropping dictation).
                return try? await self.makeStreamingSession(feature: .voiceSearch, resilient: false)
            },
            // Bridge live partials into the same island wing the agent uses
            // (Google rides the agent flow store via activeSourceIsGoogle).
            onTranscript: { IslandPanel.shared.agentFlow.transcriptUpdated($0) }
        )
        self.googleSearchController = googleSearchController
        // Connect the island surfaces to the live store + action handlers so
        // the agent flow renders in the island instead of the orb panels.
        IslandPanel.shared.installAgentFlow(islandFlow)
        IslandPanel.shared.installAgentActions(
            submitText: { [weak agentController] text in
                agentController?.submitIslandText(text)
            },
            cancelFlow: { [weak agentController] in
                agentController?.cancelAgentFlowFromIsland()
            }
        )
        agentController.start(googleCallbacks: makeGoogleCallbacks())
    }

    /// Build the R-Option Google-search gesture callbacks.
    /// Uses weak references to both controllers so they can be passed to
    /// `AgentController.start(googleCallbacks:)` at any call site — including
    /// the monitor-reinstall path after Accessibility loss — without creating
    /// retain cycles. Returns `.noOp` when `googleSearchController` has not
    /// yet been created (before `startAgentIfEnabled` runs).
    private func makeGoogleCallbacks() -> AgentController.GoogleCallbacks {
        guard let googleSearchController else { return .noOp }
        var callbacks = AgentController.GoogleCallbacks()
        // R-Option tap -> toggle the Google composer (open, or close if the
        // Google composer is already open — mirrors the agent `handleTap`
        // toggle).
        // WHY: docs/decisions/2026-06-18-right-option-google-search.md
        callbacks.onTextTap = Self.gatedGoogleCallback(
            isEnabled: { UserPreferencesCache.shared.currentGoogleEnabled }
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let flow = self.islandAgentFlowForGoogle()
                // Toggle-CLOSE: only when the OPEN composer is the GOOGLE one.
                // `isTextComposerOpen` (state == .textInput && textInputActive)
                // is also true for an agent composer, so pair it with
                // `activeSourceIsGoogle` — together they read "an open text
                // composer that is the Google one." Never close an agent
                // composer from the Google gesture.
                if self.agentController?.isTextComposerOpen == true,
                   flow?.activeSourceIsGoogle == true {
                    flow?.setActiveSourceIsGoogle(false)
                    self.agentController?.endGoogleUI()
                    return
                }
                // Toggle-OPEN. ORDER MATTERS: drive the phase to
                // .textInputActive FIRST, then set the flag.
                // `startGoogleTextInputUI()` drives the phase via
                // `setAgentPhase`, which synchronously runs the flow store's
                // `agentPhaseChanged`, whose `.textInputActive` branch resets
                // `activeSourceIsGoogle = false` (the agent-composer leak
                // guard). Setting the flag AFTER that survives until submit;
                // setting it before would be cleared by that reset and route
                // Return to the agent.
                self.agentController?.startGoogleTextInputUI()
                flow?.setActiveSourceIsGoogle(true)
            }
        }
        // R-Option voice tap (toggle gesture; default is hold, so this is
        // rarely reached). Treat as a no-op for now — hold is the canonical
        // Google voice path, and adding toggle semantics can be a follow-on.
        callbacks.onVoiceTap = Self.gatedGoogleCallback(
            isEnabled: { UserPreferencesCache.shared.currentGoogleEnabled }
        ) {}
        // R-Option hold -> record voice, open Google recording UI.
        // ORDER MATTERS (same reason as onTextTap): drive the phase to
        // .voiceRecording FIRST, then set the flag. The `.voiceRecording`
        // branch of `agentPhaseChanged` (run synchronously by `setAgentPhase`)
        // also resets `activeSourceIsGoogle = false`, so setting the flag after
        // the phase change keeps the orb in .googleVoice (Google colours) for
        // the whole hold. The Google voice session now wires `transcriptUpdated`
        // (live partials -> island wing), firing mid-recording recomputes — but
        // those do NOT clear the flag: the reset lives in `agentPhaseChanged`
        // (once per phase transition), not in `recompute()`.
        callbacks.onHoldStart = Self.gatedGoogleCallback(
            isEnabled: { UserPreferencesCache.shared.currentGoogleEnabled }
        ) { [weak self, weak googleSearchController] in
            Task { @MainActor in
                guard let self else { return }
                self.agentController?.startGoogleRecordingUI()
                self.islandAgentFlowForGoogle()?.setActiveSourceIsGoogle(true)
                googleSearchController?.handleHoldStart()
            }
        }
        // R-Option release -> finish recording, let GoogleSearchController
        // open the browser, then return to idle.
        callbacks.onHoldEnd = Self.gatedGoogleCallback(
            isEnabled: { UserPreferencesCache.shared.currentGoogleEnabled }
        ) { [weak self, weak googleSearchController] in
            Task { @MainActor in
                await googleSearchController?.handleHoldEnd()
                guard let self else { return }
                self.islandAgentFlowForGoogle()?.setActiveSourceIsGoogle(false)
                self.agentController?.endGoogleUI()
            }
        }
        // Escape / modifier-abort -> discard, return to idle.
        callbacks.onCancel = Self.gatedGoogleCallback(
            isEnabled: { UserPreferencesCache.shared.currentGoogleEnabled }
        ) { [weak self, weak googleSearchController] in
            Task { @MainActor in
                googleSearchController?.handleCancel()
                guard let self else { return }
                self.islandAgentFlowForGoogle()?.setActiveSourceIsGoogle(false)
                self.agentController?.endGoogleUI()
            }
        }
        // Composer Return in Google mode -> open browser, return to idle.
        callbacks.onTextSubmit = Self.gatedGoogleCallbackWithArg(
            isEnabled: { UserPreferencesCache.shared.currentGoogleEnabled }
        ) { [weak self, weak googleSearchController] text in
            Task { @MainActor in
                googleSearchController?.submitText(text)
                guard let self else { return }
                self.islandAgentFlowForGoogle()?.setActiveSourceIsGoogle(false)
                self.agentController?.endGoogleUI()
            }
        }
        return callbacks
    }

    /// Wraps a no-argument Google-gesture callback so it no-ops unless
    /// `isEnabled()` returns true at call time.
    /// Read-on-use: the flag is checked at gesture time, so a capability toggle
    /// takes effect immediately without re-arming the monitor.
    /// `internal` (not private) so unit tests can call it directly.
    nonisolated static func gatedGoogleCallback(
        isEnabled: @escaping () -> Bool,
        _ body: @escaping () -> Void
    ) -> () -> Void {
        return { if isEnabled() { body() } }
    }

    /// Wraps a single-argument Google-gesture callback (e.g. `onTextSubmit`)
    /// so it no-ops unless `isEnabled()` returns true at call time.
    nonisolated static func gatedGoogleCallbackWithArg<T>(
        isEnabled: @escaping () -> Bool,
        _ body: @escaping (T) -> Void
    ) -> (T) -> Void {
        return { arg in if isEnabled() { body(arg) } }
    }

    /// Returns the island flow store used by the Google path.
    /// `AgentController` holds the store internally; reach it via the shared
    /// `IslandPanel` instance (which was given the same store in
    /// `installAgentFlow`). Returns nil before the panel is wired.
    private func islandAgentFlowForGoogle() -> IslandAgentFlowStore? {
        IslandPanel.shared.agentFlow
    }

    // MARK: - Hotkey orchestration

    /// Pure-function routing decision driven by current phase + cached
    /// user mode + presence of an in-flight streaming session. Extracted
    /// from the drop hotkey handlers so the mode-routing logic can be unit-tested
    /// without instantiating `NSApplication` (see
    /// `AppDelegateDropFlowRouteTests`).
    ///
    /// Routing rules:
    ///   - `.idle` (either mode) → open a streaming session. Fast and
    ///     smart share the live streaming pipeline; mode only decides
    ///     whether the cleanup LLM runs after the stop, so both route the
    ///     same way.
    ///   - `.recording` + session in flight → finalize streaming (stop
    ///     wins over mode — the user could flip mode between start/stop
    ///     and we MUST resolve the open WS regardless)
    ///   - `.recording` + no session → finalize the recorder (fallback
    ///     path when a run did not open a streaming session)
    ///   - `.transcribing` + streaming setup in progress (no session yet) →
    ///     record a pending stop (Task 7c): the user released/tapped while we
    ///     were still building the session, so remember it and finalize when
    ///     the session reaches `.recording`. Without this the stop is dropped
    ///     and the mic records indefinitely.
    ///   - any other in-flight phase (transcribing-after-stop / verifying /
    ///     inserting) → no-op
    static func dropFlowRoute(
        phase: AppPhase,
        mode: TranscriptionMode,
        hasStreamingSession: Bool,
        isStreamingSetupInProgress: Bool = false
    ) -> DropFlowRoute {
        switch phase {
        case .idle:
            // Both modes use the live streaming pipeline. The fast/smart
            // distinction only decides whether the transcript runs through
            // the cleanup LLM after the stop. Kept as an exhaustive switch
            // so a future third mode forces an explicit routing decision.
            switch mode {
            case .fast, .smart: return .startStreamingSession
            }
        case .recording:
            return hasStreamingSession
                ? .stopStreamingSession
                : .stopRecordingAndTranscribe
        case .transcribing:
            // `.transcribing` is ambiguous: it covers (1) streaming session
            // setup in flight, (2) post-stop wait for the provider's terminal
            // frame, and (3) batch/HTTP transcription. Only (1) — setup in
            // progress with no session yet — should remember a stop. (2) has
            // a session (stop already in flight) and (3) is the recorder
            // path; both stay no-ops.
            if isStreamingSetupInProgress, !hasStreamingSession {
                return .recordPendingStop
            }
            return .noop
        case .verifying, .inserting:
            return .noop
        case .finishing:
            // Resilient-Drop batch recovery IN FLIGHT (Task 7, `.degraded`
            // path). A Drop press is a no-op like the other in-flight phases —
            // interrupting recovery would strand the retained audio.
            return .noop
        case .deliveryFailed:
            // WHY: docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md
            // TERMINAL total-offline state (Task 7). Unlike the in-flight
            // phases this is ESCAPABLE: a Drop press abandons the failed take
            // (discarding its retained retry audio) and starts a FRESH
            // recording, so the user is never trapped in a roach-motel. The
            // manual Retry pill stays the way to RECOVER the prior take instead.
            return .discardFailedTakeAndStart
        }
    }

    static func dropHotkeyPressedRoute(
        gesture: HotkeyGesture,
        phase: AppPhase,
        mode: TranscriptionMode,
        hasStreamingSession: Bool,
        isStreamingSetupInProgress: Bool = false
    ) -> DropFlowRoute {
        switch gesture {
        case .tap:
            // Tap-tap flow: the *press* both starts and stops. A press during
            // streaming setup is therefore a stop intent → defer to
            // `dropFlowRoute`, which records a pending stop.
            return dropFlowRoute(
                phase: phase,
                mode: mode,
                hasStreamingSession: hasStreamingSession,
                isStreamingSetupInProgress: isStreamingSetupInProgress
            )
        case .hold:
            // Hold flow: the *press* only ever starts; the *release* stops
            // (handled in `dropHotkeyReleasedRoute`). A press in an in-flight
            // phase is the same hold still down, never a stop → no-op. The two
            // start-able phases are `.idle` (fresh turn) and the TERMINAL
            // `.deliveryFailed` (abandon the failed take + start fresh — see
            // `dropFlowRoute`); every other phase stays a no-op.
            guard phase == .idle || phase == .deliveryFailed else { return .noop }
            return dropFlowRoute(
                phase: phase,
                mode: mode,
                hasStreamingSession: hasStreamingSession,
                isStreamingSetupInProgress: isStreamingSetupInProgress
            )
        }
    }

    static func dropHotkeyReleasedRoute(
        gesture: HotkeyGesture,
        phase: AppPhase,
        hasStreamingSession: Bool,
        isStreamingSetupInProgress: Bool = false
    ) -> DropFlowRoute {
        guard gesture == .hold else { return .noop }
        switch phase {
        case .recording:
            return hasStreamingSession ? .stopStreamingSession : .stopRecordingAndTranscribe
        case .transcribing:
            // Release landed during streaming setup (session still being
            // built): remember the stop so the session finalizes the moment
            // it reaches .recording. Before Task 7c this required
            // phase==.recording and dropped the release, leaving the mic
            // recording indefinitely.
            if isStreamingSetupInProgress, !hasStreamingSession {
                return .recordPendingStop
            }
            return .noop
        default:
            return .noop
        }
    }

    /// Pure routing for the 10-minute max-hold cap. At the cap we finalize
    /// EXACTLY as a recording-phase release: whichever capture is live is
    /// stopped and transcribed so the text is pasted — never discarded. Any
    /// non-`.recording` phase is a no-op (the turn already finalized via a real
    /// release, or never started), which also makes the cap idempotent when a
    /// real release races the timer. Gesture-AGNOSTIC on purpose: the cap
    /// applies to hold AND toggle Drop, so — unlike `dropHotkeyReleasedRoute` —
    /// it does not gate on `.hold`.
    static func dropMaxHoldRoute(phase: AppPhase, hasStreamingSession: Bool) -> DropFlowRoute {
        guard phase == .recording else { return .noop }
        return hasStreamingSession ? .stopStreamingSession : .stopRecordingAndTranscribe
    }

    /// Pure routing for an Escape-cancel of a hold-Space Drop. Only the
    /// `.recording` phase has an in-flight take to discard; everything else is
    /// a no-op. Whichever capture is live (streaming session vs recorder) is
    /// torn down WITHOUT producing a transcript or paste.
    static func dropHotkeyCancelRoute(
        phase: AppPhase,
        hasStreamingSession: Bool
    ) -> DropCancelRoute {
        guard phase == .recording else { return .noop }
        return hasStreamingSession ? .cancelStreamingSession : .cancelRecording
    }

    private func onDropHotkeyPressed() {
        registerIslandHotkeyActivity()
        let route = AppDelegate.dropHotkeyPressedRoute(
            gesture: HotkeyPreferences.shared.configuration.normalizedDropGesture,
            phase: AppState.shared.phase,
            mode: UserPreferencesCache.shared.currentMode,
            hasStreamingSession: streamingSession != nil,
            isStreamingSetupInProgress: streamingSetupInProgress
        )
        handleDropHotkeyRoute(route)
    }

    private func onDropHotkeyReleased() {
        let route = AppDelegate.dropHotkeyReleasedRoute(
            gesture: HotkeyPreferences.shared.configuration.normalizedDropGesture,
            phase: AppState.shared.phase,
            hasStreamingSession: streamingSession != nil,
            isStreamingSetupInProgress: streamingSetupInProgress
        )
        handleDropHotkeyRoute(route)
    }

    /// Escape pressed while a hold-Space Drop is recording → discard the take.
    /// Wired as the `onCancel` callback on the `.holdSpace` monitor. Unlike
    /// release (`onDropHotkeyReleased`), this produces NO transcript and NO
    /// paste: it tears down whichever capture is live, returns to `.idle`, and
    /// closes the drop-turn telemetry as a cancellation.
    private func onDropHotkeyCancelled() {
        let route = AppDelegate.dropHotkeyCancelRoute(
            phase: AppState.shared.phase,
            hasStreamingSession: streamingSession != nil
        )
        switch route {
        case .cancelStreamingSession:
            cancelDropRecording(streaming: true)
        case .cancelRecording:
            cancelDropRecording(streaming: false)
        case .noop:
            break
        }
    }

    /// Shared discard implementation for `onDropHotkeyCancelled`. Tears down the
    /// in-flight capture (the streaming session via its existing `cancel()`
    /// teardown, or the recorder via `cancel()` which deletes the temp WAV),
    /// resets the phase, and marks the drop turn cancelled. Never transcribes
    /// or pastes.
    private func cancelDropRecording(streaming: Bool) {
        os_log("drop gesture cancelled streaming=%{public}@", log: Self.log, type: .info, streaming ? "true" : "false")
        if streaming {
            // Mirror `cancelStreamingSessionIfNeeded`: detach first so the
            // `run()` continuation's `handleStreamingResult` sees no session,
            // then signal cancellation so the receive loop unwinds.
            if let session = streamingSession {
                streamingSession = nil
                streamingStopRequested = false
                Task { @MainActor in
                    await session.cancel()
                }
            }
        } else {
            recorder.cancel()
        }
        failDropTurnTelemetry(reason: "user_cancelled")
        AppState.shared.phase = .idle
    }

    private func handleDropHotkeyRoute(_ route: DropFlowRoute) {
        if DropHotkeyRecovery.requiresStartPermission(route) {
            let snapshot = PermissionsHelper.snapshot()
            guard snapshot.accessibilityGranted,
                  snapshot.microphoneStatus != .denied,
                  snapshot.microphoneStatus != .restricted else {
                explainMissingDropPermission()
                return
            }
            // The OS may show the initial microphone prompt when capture starts.
            // Never put this check on stop/finalize/release routes.
        }
        // Escaping a parked total-offline take must ALWAYS clear the banner.
        if route == .discardFailedTakeAndStart {
            discardPendingRetry()
            AppState.shared.phase = .idle
        }

        switch route {
        case .discardFailedTakeAndStart:
            // The parked take was already discarded + the phase idled above;
            // just run the normal start path below.
            fallthrough
        case .startStreamingSession:
            // Capture the target app BEFORE any panel shows / state mutation —
            // friend's section 5: activating any UI before this captures the
            // wrong target. (FloatingDotPanel is non-activating today, so this
            // is belt-and-suspenders, but it is the contract the engine
            // documents.)
            autoPasteEngine.rememberTargetBeforeRecording()
            startDropTurnTelemetry()
            startDropVoiceCapture()
        case .startRecording:
            autoPasteEngine.rememberTargetBeforeRecording()
            startDropTurnTelemetry()
            startRecording()
        case .stopStreamingSession:
            stopStreamingSession()
        case .stopRecordingAndTranscribe:
            stopRecordingAndTranscribe()
        case .recordPendingStop:
            // The user released / tapped-stop while the session was still
            // being built. Remember it; `startStreamingSession()` applies it
            // the instant the session reaches `.recording` (see Task 7c).
            streamingPendingStop = true
            os_log(
                "drop: stop arrived during streaming setup; deferring finalize",
                log: Self.log, type: .info
            )
        case .noop:
            break
        }
    }

    private func startDropVoiceCapture() {
        // Every provider streams live; the batch recorder is only the
        // fallback when a session fails to open.
        startStreamingSession()
    }

    /// Drop-path turn diagnostics. The active turn's `DropTurnTrace` (nil
    /// between turns) doubles as the "turn in flight" guard the old
    /// `dropTurnStarted`/`dropTurnTerminated` bools provided: created at start,
    /// cleared on the single terminal emit. Carries a real `turn_id` now (was
    /// hardcoded `"pending"`) so a turn's started/completed/failed events
    /// correlate, plus a phase timeline to localise where a turn stalls.
    private var dropTurnTrace: DropTurnTrace?
    /// Fires if a turn never reaches a terminal event — the infinite-hang case
    /// that otherwise emits NOTHING (only an orphaned `voice_turn_started`,
    /// because `run()` never returns so `handleStreamingResult` never runs).
    /// Reports `last_phase` so we learn WHERE it stalled. Diagnostic only.
    private var dropTurnWatchdog: Task<Void, Never>?
    /// Hard recording-length cap. When it fires the Drop auto-finalizes through
    /// the normal stop→transcribe→paste path so a long dictation is pasted, not
    /// lost. Cancelled in `endDropTurn`, so a normal finish before the cap
    /// pre-empts it. WHY: docs/decisions/2026-06-22-drop-10min-cap-autostop.md
    private var dropMaxHoldTimer: Task<Void, Never>?
    /// Holds a ProcessInfo activity assertion for the lifetime of the turn so
    /// App Nap cannot throttle the watchdog timers while the app is backgrounded.
    private let dropActivity = DropActivityGuard()
    /// Hard cap on a single Drop recording (hold OR toggle). At the cap the turn
    /// auto-finalizes via `dropMaxHoldRoute`. 10 min is a client-side max-hold
    /// cap: long enough for any real dictation, short enough that a forgotten
    /// hold cannot keep a realtime STT session open indefinitely.
    private static let dropMaxHoldTimeout: Duration = .seconds(600)
    /// Set beyond the max hold PLUS the longest finalize (the session's own
    /// ~10 s post-stop watchdog + paste) so the diagnostic turn-watchdog fires
    /// ONLY for true hangs and never preempts a legitimate long hold (≤10 min)
    /// or its terminal.
    private static let dropTurnWatchdogTimeout: Duration = .seconds(640)

    private func startDropTurnTelemetry() {
        // The one place a new take starts: the mode and its route are fixed
        // here and every later read of the take's mode uses `DropTake`.
        let mode = UserPreferencesCache.shared.currentMode
        DropTake.shared.begin(mode: mode, route: AIRoutingStore.shared.route(for: .drop(mode)))
        AppState.shared.dropDeliveryFailureMessage = nil
        lastDropPartial = ""
        let trace = DropTurnTrace()
        dropTurnTrace = trace
        dropActivity.begin(reason: "drop voice turn")
        armDropTurnWatchdog(for: trace)
        armDropMaxHoldTimer(for: trace)
        os_log("drop turn %{public}@ started mode=%{public}@", log: Self.log, type: .info, trace.turnId, DropTake.shared.mode.rawValue)
    }

    private func completeDropTurnTelemetry() {
        guard let trace = endDropTurn() else { return }
        trace.mark(.done)
        os_log(
            "drop turn %{public}@ completed last_phase=%{public}@ finishing_ms=%{public}d resolving_ms=%{public}d release_to_done_ms=%{public}d",
            log: Self.log, type: .info, trace.turnId, trace.lastPhase.label,
            trace.durationMs(from: .stopRequested, to: .resolving) ?? -1,
            trace.durationMs(from: .resolving, to: .done) ?? -1,
            trace.durationMs(from: .stopRequested, to: .done) ?? -1
        )
    }

    private func failDropTurnTelemetry(reason: String) {
        guard let trace = endDropTurn() else { return }
        os_log(
            "drop turn %{public}@ failed reason=%{public}@ last_phase=%{public}@",
            log: Self.log, type: .error, trace.turnId, reason, trace.lastPhase.label
        )
    }

    /// Tears down the in-flight turn's diagnostics exactly once: cancels the
    /// watchdog and clears the trace, returning it for the terminal emit.
    /// Returns nil when no turn is in flight (already terminated) — the guard
    /// that prevents a double terminal emit.
    private func endDropTurn() -> DropTurnTrace? {
        guard let trace = dropTurnTrace else { return nil }
        dropTurnWatchdog?.cancel()
        dropTurnWatchdog = nil
        dropMaxHoldTimer?.cancel()
        dropMaxHoldTimer = nil
        dropTurnTrace = nil
        dropActivity.end()
        return trace
    }

    private func armDropTurnWatchdog(for trace: DropTurnTrace) {
        dropTurnWatchdog?.cancel()
        dropTurnWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dropTurnWatchdogTimeout)
            guard !Task.isCancelled, let self, self.dropTurnTrace === trace else { return }
            // The turn never reached a terminal event. Report where it stalled.
            // Diagnostic only: phase/flow are left untouched so the repro is
            // preserved for the follow-up fix.
            self.dropTurnTrace = nil
            self.dropActivity.end()   // release the App Nap guard (trace niled directly above for repro)
            os_log(
                "drop turn %{public}@ STUCK last_phase=%{public}@",
                log: Self.log, type: .error, trace.turnId, trace.lastPhase.label
            )
        }
    }

    /// Arms the hard recording cap. When it fires, the Drop auto-finalizes via
    /// the SAME route a recording-phase release takes (`dropMaxHoldRoute` →
    /// `handleDropHotkeyRoute`), so the captured transcript is pasted, never
    /// dropped. `endDropTurn` cancels it (release / complete / cancel all route
    /// through `endDropTurn`), so any normal finish before the cap pre-empts it.
    /// The `dropTurnTrace === trace` guard plus the `.noop` route for a
    /// non-`.recording` phase make it idempotent with a real release that races
    /// the cap: whichever flips the phase out of `.recording` first wins.
    private func armDropMaxHoldTimer(for trace: DropTurnTrace) {
        dropMaxHoldTimer?.cancel()
        dropMaxHoldTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dropMaxHoldTimeout)
            guard !Task.isCancelled, let self, self.dropTurnTrace === trace else { return }
            let route = AppDelegate.dropMaxHoldRoute(
                phase: AppState.shared.phase,
                hasStreamingSession: self.streamingSession != nil
            )
            guard route != .noop else { return }
            os_log(
                "drop turn %{public}@ hit recording cap → auto-finalizing",
                log: Self.log, type: .info, trace.turnId
            )
            self.handleDropHotkeyRoute(route)
        }
    }

    private func startRecording() {
        do {
            try recorder.start()
            dropTurnTrace?.mark(.recording)
            AppState.shared.phase = .recording
        } catch {
            FileHandle.standardError.write(Data("✗ start recording failed: \(error)\n".utf8))
            AppState.shared.phase = .idle
        }
    }

    private func stopRecordingAndTranscribe() {
        dropTurnTrace?.mark(.stopRequested)
        // `AutoPasteEngine.rememberTargetBeforeRecording()` ran at hotkey-down
        // time (see `onHotkey`), so the engine's captured target is the
        // authoritative source. Fall back to the live frontmost only if the
        // engine has nothing (e.g. the very first hotkey before remember runs).
        let target = autoPasteEngine.currentTarget()
        let targetApp = target?.name
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
        let targetPID = target?.pid

        let wav: Data
        do {
            wav = try recorder.stop()
        } catch {
            FileHandle.standardError.write(Data("✗ stop recording failed: \(error)\n".utf8))
            // Stage 0b: recorder failed before transcribe — close the funnel.
            failDropTurnTelemetry(reason: "recorder_stop_failed")
            AppState.shared.phase = .idle
            return
        }

        // Pre-flight silence guard, same reasoning as the Agent path in
        // `AgentController.handleHoldEnd`: a quick Drop tap can produce a tiny
        // non-empty WAV containing no speech. The Drop path doesn't surface a
        // visible error UI (it falls through to `phase = .idle`), but we still
        // avoid the wasted decode and log a single line for parity with the
        // Agent path.
        let detector = AudioSilenceDetector()
        let durationSeconds = recorder.lastDurationSeconds
        let peakEnergy = recorder.peakEnergy
        switch detector.decide(durationSeconds: durationSeconds, peakEnergy: peakEnergy) {
        case .drop(let reason):
            os_log(
                "drop gesture dropped pre-transcribe reason=%{public}@ duration_ms=%{public}d peak_energy=%{public}.3f",
                log: Self.log,
                type: .info,
                reason.rawValue,
                Int(durationSeconds * 1000),
                Double(peakEnergy)
            )
            // Stage 0b: silence guard rejected — close the funnel as failure.
            failDropTurnTelemetry(reason: "silence_guard_\(reason.rawValue)")
            AppState.shared.phase = .idle
            return
        case .proceed:
            break
        }

        AppState.shared.phase = .transcribing

        // Recorder fallback: transcribe the captured WAV with the batch
        // transcriber (the user's own provider). Without one configured it
        // throws and the take ends here (the audio is never sent anywhere).
        Task { @MainActor in
            let startedAt = Date()
            do {
                let prefs = PrivacyPreferences.shared
                let raw = try await dropBatchTranscriber.transcribe(
                    audio: wav,
                    language: prefs.selectedLanguage?.code
                )
                let transcribeMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                os_log(
                    "transcribe ok chars=%{public}d latency_ms=%{public}d",
                    log: Self.log, type: .info,
                    raw.count, transcribeMs
                )
                guard !Self.streamingTranscriptIsEmpty(raw) else {
                    failDropTurnTelemetry(reason: "silence_guard")
                    AppState.shared.phase = .idle
                    return
                }
                await runPostProcessAndPaste(rawText: raw, targetApp: targetApp, targetPID: targetPID)
            } catch {
                os_log(
                    "pipeline failed: %{public}@",
                    log: Self.log, type: .error,
                    Self.pipelineErrorDescription(error)
                )
                failDropTurnTelemetry(
                    reason: String(describing: type(of: error))
                )
                AppState.shared.phase = .idle
            }
        }
    }

    // MARK: - Streaming transcription (Phase 1)

    /// Full-clear of the Task 7(c) setup-window flags. Used by every path
    /// that abandons or resolves a turn (setup failure, cancellation, result
    /// handling). The ONE intentional exception is the success site inside
    /// `startStreamingSession()`, which clears the setup flag but *consumes*
    /// (not discards) a pending stop — keep that site inline.
    private func clearStreamingSetupWindow() {
        streamingSetupInProgress = false
        streamingPendingStop = false
    }

    /// Open a direct-to-provider streaming session, mirror the
    /// async path's UI states (`phase = .recording`), and resolve to a
    /// paste in `stopStreamingSession()`. If transport setup fails before
    /// the user stops the turn, fall back to the recorder path so Drop does
    /// not blink away without explanation.
    private func startStreamingSession() {
        streamingStopRequested = false
        // Open the pending-stop window: a hold-release / stop-tap arriving
        // before the session is assigned must be remembered, not dropped
        // (Task 7c). Reset any stale pending stop from a prior turn.
        streamingSetupInProgress = true
        streamingPendingStop = false
        // Claim the window for THIS turn (see `streamingSetupGeneration`).
        streamingSetupGeneration &+= 1
        let setupGeneration = streamingSetupGeneration
        AppState.shared.phase = .transcribing
        Task { @MainActor in
            let session: any StreamingSessionRunning
            do {
                // Drop is the only call site where resilient delivery is
                // enabled — agent-voice and Google-search pass resilient:false
                // so they can never resolve .degraded (their handlers ignore it,
                // which would silently drop the dictation).
                session = try await makeStreamingSession(
                    feature: DropTake.shared.feature,
                    resilient: AgentFeatureGate.resilientDropDeliveryEnabled
                )
            } catch {
                // Stale-turn gate: a newer turn claimed the window while we
                // were suspended — its setup will surface its own failures;
                // this task must not touch phase/flags/telemetry it no
                // longer owns.
                guard streamingSetupGeneration == setupGeneration else { return }
                // Config problem (no speech provider chosen, BYOK key
                // missing) — surface it and idle.
                clearStreamingSetupWindow()
                os_log(
                    "streaming: setup config problem (%{public}@)",
                    log: Self.log, type: .error,
                    String(describing: error)
                )
                failDropTurnTelemetry(reason: "byok_misconfigured")
                AppState.shared.phase = .idle
                // The problem is one the user fixes in Settings (no model set
                // for the feature yet, key or endpoint missing). On a fresh
                // install nothing is set, so idling silently would look like
                // a dead hotkey: open API & Models on the failing feature's
                // row, where its key and model are one click away.
                if case StreamingSessionSetupError.byokMisconfigured(let routeError) = error {
                    openSettingsWindow(tab: .apiAndModels, feature: routeError.feature)
                }
                return
            }

            // Cancellation-during-setup guard: `pauseRuntimeForSleep()` /
            // `applicationWillTerminate` may have fired WHILE we were
            // suspended in `makeStreamingSession()`. At that
            // point `streamingSession` was still nil, so
            // `cancelStreamingSessionIfNeeded()` had no session to cancel —
            // it cleared `streamingSetupInProgress` instead. Without this
            // guard we would assign and run a brand-new session on a machine
            // that was just told to sleep — on wake it records and pastes
            // pre-sleep speech. The session-internal cancel guards can't
            // help: cancel() was never called on a session that didn't exist
            // yet.
            //
            // Two stale flavors, checked in order:
            //   1. Generation mismatch — a NEWER turn started after our
            //      cancellation (sleep set phase back to .idle; user pressed
            //      again on wake before our setup resumed). Tear down our
            //      session and touch NOTHING else: flags, phase, and
            //      telemetry belong to the new turn now.
            //   2. Same generation, flag cleared — cancelled with no
            //      successor turn. Tear down, close the turn's telemetry,
            //      park the phase at idle.
            // Both catch branches return above, so reaching this point with
            // our generation intact and the flag still set unambiguously
            // means the window is still ours.
            guard streamingSetupGeneration == setupGeneration else {
                await session.cancel()
                return
            }
            guard streamingSetupInProgress else {
                os_log(
                    "streaming: cancelled during setup window; discarding fresh session",
                    log: Self.log, type: .info
                )
                // Tear the just-built session down. Today neither variant has
                // started its engine or resumed its transport before run(),
                // but cancel() is the contract-safe teardown if a future
                // session impl opens resources in init.
                await session.cancel()
                failDropTurnTelemetry(reason: "cancelled_during_setup")
                AppState.shared.phase = .idle
                return
            }

            self.streamingSession = session
            // Surface live STT partials in the island recording wing as words
            // land — the same `onTranscriptUpdate` sink the agent voice flow
            // uses (inherited via `StreamingSessionRunning:
            // AgentRealtimeVoiceSessioning`, called on `@MainActor`). The flow
            // store maps the drop phase → wing face on its own (it observes
            // `AppState.phase`), so wiring the transcript is all that's left.
            session.onTranscriptUpdate = { [weak self] text in
                // Count inbound tokens (count only — never the text) so the
                // trace can tell "the STT provider transcribed something" from "WS opened
                // but nothing arrived". First token also stamps `.firstToken`.
                self?.dropTurnTrace?.recordToken()
                self?.lastDropPartial = text
                IslandPanel.shared.agentFlow.dropTranscriptUpdated(text)
            }
            // Close the setup window now that the session exists. From here a
            // stop routes through `.stopStreamingSession` normally.
            streamingSetupInProgress = false
            dropTurnTrace?.mark(.recording)
            AppState.shared.phase = .recording

            // Apply any stop the user requested DURING setup. Must happen
            // after `phase = .recording` (so `stopStreamingSession()`'s
            // `streamingSession != nil` guard holds) and before `run()`
            // resolves. `stopStreamingSession()` launches `session.stop()`
            // in a detached Task, so it returns immediately; the subsequent
            // `await session.run()` then resolves via the stop's terminal
            // frame (or its watchdog). Without this, a start-then-instant-stop
            // would record into a live mic until the user pressed again.
            if streamingPendingStop {
                streamingPendingStop = false
                os_log(
                    "drop: applying stop deferred during streaming setup",
                    log: Self.log, type: .info
                )
                stopStreamingSession()
            }

            let startedAt = Date()
            let result = await session.run()
            await handleStreamingResult(result, startedAt: startedAt, generation: setupGeneration)
        }
    }

    /// Builds the real-time transcription session for `feature` (direct to the
    /// provider of that feature's own route) through
    /// `TranscriptionSessionFactory`. Shared by the drop flow, the agent voice
    /// factory and voice search so the construction recipe has one source of
    /// truth. A thrown route error (feature Not set, key missing, bad server
    /// address or language) surfaces as `.byokMisconfigured`.
    ///
    /// `resilient` must be `true` ONLY for the Drop call site. Agent-voice and
    /// Google-search pass `false` explicitly — their result handlers treat
    /// `.degraded` as a no-op and would silently drop dictation if the flag
    /// were accidentally inherited.
    private func makeStreamingSession(
        feature: AIFeature,
        resilient: Bool = false
    ) async throws -> any StreamingSessionRunning {
        let factory = TranscriptionSessionFactory()
        do {
            return try factory.make(
                feature: feature,
                language: PrivacyPreferences.shared.selectedLanguage?.code,
                resilient: resilient
            )
        } catch let error as FeatureRouteError {
            os_log(
                "streaming: BYOK factory failed: %{public}@",
                log: Self.log, type: .error,
                String(describing: error)
            )
            throw StreamingSessionSetupError.byokMisconfigured(error)
        }
    }

    /// Tear-down hook for app termination / sleep. Fires a cancellation
    /// at the session so its receive loop returns and the URLSession
    /// task closes. No-op when no session is in flight.
    private func cancelStreamingSessionIfNeeded() {
        // Always clear the setup/pending flags, even when no session exists
        // yet: a sleep/quit during the setup window must not leave a
        // pending stop that fires against the next turn's session. The
        // in-flight setup Task observes the cleared flag after
        // `makeStreamingSession()` returns and discards its fresh session.
        clearStreamingSetupWindow()
        guard let session = streamingSession else { return }
        streamingSession = nil
        streamingStopRequested = false
        Task { @MainActor in
            await session.cancel()
        }
    }

    /// Resolve the in-flight streaming session by signalling end-of-stream.
    /// The `run()` task above is already awaiting the terminal event; it
    /// will receive it and dispatch to `handleStreamingResult`.
    private func stopStreamingSession() {
        guard let session = streamingSession else { return }
        streamingStopRequested = true
        dropTurnTrace?.mark(.stopRequested)
        AppState.shared.phase = .transcribing
        Task { @MainActor in
            await session.stop()
        }
    }

    /// Dispatch the resolved streaming session result back through the
    /// existing post-processing + paste pipeline so the user-visible UX
    /// for Phase 1 matches the async path.
    private func handleStreamingResult(
        _ result: StreamingSessionResult,
        startedAt: Date,
        generation: UInt64
    ) async {
        // Defense-in-depth: only the turn that still owns the streaming slot may
        // apply its result. A newer turn bumps `streamingSetupGeneration`
        // (notably one started straight off a terminal failure via
        // `.discardFailedTakeAndStart`), so a stale `session.run()` continuation
        // must NOT clear the session / overwrite the phase / close telemetry that
        // now belong to the newer turn — just drop it.
        guard Self.shouldApplyStreamingResult(
            resultGeneration: generation,
            currentGeneration: streamingSetupGeneration
        ) else {
            os_log("streaming: dropping stale result (generation superseded)", log: Self.log, type: .info)
            return
        }
        dropTurnTrace?.mark(.resolving)
        let stopRequested = streamingStopRequested
        // Snapshot the locally-retained PCM BEFORE clearing the session: the
        // `.degraded` recovery path batch-transcribes it. Empty for every
        // non-degraded outcome (and for sessions that don't retain audio), so
        // capturing it unconditionally here is cheap and keeps the teardown in
        // one place.
        let capturedPCM = streamingSession?.capturedAudioPCM16() ?? Data()
        streamingSession = nil
        streamingStopRequested = false
        // The turn is resolving; clear the setup/pending window so a late
        // hotkey can't apply a pending stop to a finished session.
        clearStreamingSetupWindow()

        let target = autoPasteEngine.currentTarget()
        let targetApp = target?.name
            ?? NSWorkspace.shared.frontmostApplication?.localizedName
        let targetPID = target?.pid

        switch result {
        case .cancelled:
            os_log("streaming cancelled by user", log: Self.log, type: .info)
            failDropTurnTelemetry(reason: "cancelled")
            AppState.shared.phase = .idle
        case .failed(let err):
            os_log(
                "streaming failed: %{public}@",
                log: Self.log, type: .error,
                String(describing: err)
            )
            // Pre-stop setup failure: re-arm the batch recorder so the user's
            // speech is not silently lost (before they even hit stop). The
            // resolver doesn't cover this arm — it would try to batch-transcribe
            // audio that was never captured.
            if Self.shouldFallbackToRecorderOnStreamingFailure(
                stopRequested: stopRequested,
                error: err
            ) {
                os_log(
                    "streaming setup failed before stop; falling back to recorder",
                    log: Self.log,
                    type: .info
                )
                startRecording()
                return
            }
            // Mic hardware failure: the audio engine itself is dead. Routing
            // through the resolver produces a misleading "degraded_no_audio"
            // reason — emit the correct veto telemetry and return to idle,
            // matching pre-Task-3 behavior for this specific error.
            if case .audioEngineFailed = err {
                failDropTurnTelemetry(reason: "streaming_\(err)")
                AppState.shared.phase = .idle
                return
            }
            // Flag-off parity / rollback guarantee: the resolver's recovery rungs
            // (batch + raw-partial salvage) ARE the resilient-delivery feature.
            // With the flag off, a post-stop terminal failure must take the
            // pre-resilient path — fail to idle — so turning the flag off fully
            // disables the new delivery behavior. The audio tee and the UI
            // partial are populated regardless of the flag, so without this gate
            // the resolver would still salvage/batch-recover a flag-off turn.
            if !AgentFeatureGate.resilientDropDeliveryEnabled {
                failDropTurnTelemetry(reason: "streaming_\(err)")
                AppState.shared.phase = .idle
                return
            }
            // All other failures route through the resolver: salvage the
            // realtime partial or batch-transcribe retained audio instead of
            // silently idling.
            await resolveViaSink(result: result, stopRequested: stopRequested, capturedPCM: capturedPCM, startedAt: startedAt, targetApp: targetApp, targetPID: targetPID)
        case .transcript, .endpointDetected, .degraded:
            await resolveViaSink(
                result: result,
                stopRequested: stopRequested,
                capturedPCM: capturedPCM,
                startedAt: startedAt,
                targetApp: targetApp,
                targetPID: targetPID
            )
        }
    }

    /// Whether a streaming failure should re-arm the batch recorder.
    ///
    /// Two independent vetoes:
    ///   - `stopRequested` — the user already finalized; starting a NEW
    ///     recording behind their back after a finalization failure would be
    ///     a surprise mic activation.
    ///   - `.audioEngineFailed` — the mic itself is dead (input format went
    ///     invalid / route-change restart exhausted). Re-arming the recorder
    ///     points a second capture stack at the same dead device, recording
    ///     silence right after the route change killed the engine. Fail to
    ///     idle instead; the next user-initiated press retries with whatever
    ///     device CoreAudio has by then.
    /// Other errors keep the original semantics: pre-stop transport/setup
    /// failures fall back so Drop does not blink away unexplained.
    static func shouldFallbackToRecorderOnStreamingFailure(
        stopRequested: Bool,
        error: StreamingSessionError
    ) -> Bool {
        switch error {
        case .audioEngineFailed,
             .endOfStreamSendFailed,
             .watchdogTimeout,
             .unknown:
            return false
        default:
            break
        }
        return !stopRequested
    }

    /// Whether a resolved streaming transcript is effectively empty (Task 7d).
    /// Trims whitespace + newlines; an empty result means a tap-tap misfire or
    /// pure silence. The caller skips cleanup so the LLM can't hallucinate
    /// text onto the focused field. Pure so it is unit-tested in isolation.
    /// Mirrors the agent path's `trimmed.isEmpty`.
    static func streamingTranscriptIsEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fast bypasses the LLM; Smart either delivers processed text or retains
    /// its transcript for Retry. The mode belongs to the take, not the current
    /// preference when an asynchronous provider happens to finish.
    /// WHY: .project-docs/decisions/2026-10-19-strict-drop-modes.md
    @discardableResult
    private func runPostProcessAndPaste(
        rawText: String, targetApp: String?, targetPID: pid_t?,
        mode retryMode: TranscriptionMode? = nil
    ) async -> Bool {
        let mode = retryMode ?? DropTake.shared.mode
        let generation = streamingSetupGeneration
        let policy = DropOutputPolicy(mode: mode)
        let processStartedAt = ProcessInfo.processInfo.systemUptime
        let turnID = dropTurnTrace?.turnId ?? "unavailable"
        var contextMs = 0
        var cleanupStartedAt = processStartedAt
        var formatting = SmartFormattingProfile.plain
        var deliveryFormatting = SmartFormattingProfile.plain
        let targetBundleID = targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        if mode == .smart { AppState.shared.phase = .verifying }
        do {
            let final = try await policy.prepare(
                rawText: rawText, fillerTerms: FillerTermsStore().terms(),
                preservingMarkdown: { formatting != .plain }
            ) { [self] in
                guard let postProcessor else { throw OpenRouterLLMError.notConfigured }
                let snapshot = await AXContextReader.formattingSnapshot(forPID: targetPID)
                try Task.checkCancellation()
                formatting = SmartFormattingProfile.resolve(
                    bundleID: targetBundleID, appName: targetApp,
                    documentURL: snapshot?.documentURL, focusedRole: snapshot?.focusedRole
                )
                cleanupStartedAt = ProcessInfo.processInfo.systemUptime
                contextMs = Int((cleanupStartedAt - processStartedAt) * 1000)
                let prefs = PrivacyPreferences.shared
                let output = try await postProcessor.processOutput(
                    rawText, targetApp: targetApp, appContext: snapshot?.context,
                    screenshot: nil, language: prefs.selectedLanguage?.code,
                    outputLanguage: outputLanguageCodeForDrop(mode: mode),
                    transcriptionMode: mode.rawValue, formatting: formatting
                )
                deliveryFormatting = output.deliveryProfile(formatting)
                return output.text
            }
            guard !Task.isCancelled, generation == streamingSetupGeneration else { return false }
            os_log(
                "drop processing ok turn_id=%{public}@ mode=%{public}@ chars=%{public}d latency_ms=%{public}d ax_ms=%{public}d cleanup_ms=%{public}d",
                log: Self.log, type: .info, turnID, mode.rawValue, final.count,
                Int((ProcessInfo.processInfo.systemUptime - processStartedAt) * 1000), contextMs,
                mode == .smart ? Int((ProcessInfo.processInfo.systemUptime - cleanupStartedAt) * 1000) : 0
            )
            await finishDropDelivery(text: final, rawTranscript: rawText, targetApp: targetApp, formatting: deliveryFormatting)
            return true
        } catch {
            guard !Task.isCancelled, generation == streamingSetupGeneration else { return false }
            pendingProcessingRetry = DropProcessingRetry(
                rawText: rawText, targetApp: targetApp, targetPID: targetPID, mode: mode
            )
            let message = DropOutputPolicy.failureMessage(for: error)
            AppState.shared.dropDeliveryFailureMessage = message
            failDropTurnTelemetry(reason: "smart_cleanup_failed")
            AppState.shared.phase = .deliveryFailed
            os_log("drop cleanup failed: %{public}@", log: Self.log, type: .error, message)
            if DropOutputPolicy.requiresConfiguration(for: error) {
                openSettingsWindow(tab: .apiAndModels, feature: .dropSmartCleanup)
            }
            return false
        }
    }

    /// Whether a degraded turn has anything to recover. Pure so the empty/
    /// missing-prerequisite branch is unit-tested in isolation — mirrors
    /// `shouldFallbackToRecorderOnStreamingFailure` /
    /// `streamingTranscriptIsEmpty`. Returns `false` when there is no retained
    /// audio (nothing to transcribe) or no batch transcriber (none is wired);
    /// the caller then falls to the partial-salvage rungs WITHOUT a batch
    /// attempt.
    static func shouldAttemptBatchRecovery(
        hasAudio: Bool,
        hasBatchTranscriber: Bool
    ) -> Bool {
        hasAudio && hasBatchTranscriber
    }

    /// Whether a manual Retry of a parked total-offline take may begin. Pure so
    /// the gate is unit-tested without the AppKit-bound delegate. A retry begins
    /// only when none is already in flight AND there is retained audio — the
    /// in-flight latch (not consuming the PCM up front) is what keeps a hung
    /// recovery from stranding Retry as a permanent no-op, and blocks a stale
    /// retry from clobbering a fresh turn started via `.discardFailedTakeAndStart`.
    static func shouldBeginRetry(inFlight: Bool, hasPendingAudio: Bool) -> Bool {
        !inFlight && hasPendingAudio
    }

    /// Whether a resolved streaming `session.run()` result still owns the turn,
    /// i.e. no newer turn has claimed the streaming slot since this run started.
    /// Defense-in-depth: `handleStreamingResult` writes `AppState.phase` and
    /// tears down the session, so a stale continuation applying its result over
    /// a newer turn would clobber it (and `.discardFailedTakeAndStart` makes a
    /// fresh turn reachable straight from a terminal failure). Pure for tests.
    static func shouldApplyStreamingResult(resultGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        resultGeneration == currentGeneration
    }

    /// Production `DropBatchRecoverySink` for a given paste target. Shared by
    /// `recoverViaBatch` (manual Retry from `.degraded`) and `resolveViaSink`
    /// (unified resolver path for all non-cancelled turn outcomes) so the
    /// side-effect wiring — phase, paste tail, retry-state, telemetry, and
    /// raw-partial salvage — is defined in exactly one place.
    private func dropDeliverySink(targetApp: String?, targetPID: pid_t?) -> DropBatchRecoverySink {
        let mode = DropTake.shared.mode
        let generation = streamingSetupGeneration
        return DropBatchRecoverySink(
            setPhase: { AppState.shared.phase = $0 },
            deliver: { [weak self] raw in
                guard let self, generation == self.streamingSetupGeneration else { return false }
                return await self.runPostProcessAndPaste(
                    rawText: raw, targetApp: targetApp, targetPID: targetPID, mode: mode
                )
            },
            retainForRetry: { [weak self] pcm in
                self?.pendingRetryPCM = pcm
                self?.pendingRetryTarget = (targetApp, targetPID)
                os_log(
                    "batch recover failed; audio retained for manual retry",
                    log: Self.log, type: .error
                )
            },
            clearPendingRetry: { [weak self] in
                guard let self, generation == self.streamingSetupGeneration else { return }
                self.pendingRetryPCM = nil
                self.pendingRetryTarget = nil
            },
            failTelemetry: { [weak self] reason in
                self?.failDropTurnTelemetry(reason: reason)
            },
            pasteRaw: { [weak self] raw in
                // Direct paste of the raw realtime partial — no cleanup
                // (salvage rung). Returns whether the paste landed so
                // `salvageOrFail` can fall through to `.deliveryFailed` (retain
                // for retry) instead of silently losing the dictation. Only a
                // SUCCESSFUL paste parks the phase at `.idle`; on failure the
                // caller owns the phase (it flips to `.deliveryFailed`).
                guard let self else { return false }
                let pasted = await self.autoPasteEngine.paste(raw)
                if pasted { AppState.shared.phase = .idle }
                return pasted
            },
            requiresProcessingForPartial: mode == .smart
        )
    }

    /// Batch-transcribe the locally-retained audio with the batch transcriber
    /// when the live stream degraded, then deliver via the normal
    /// post-process + paste tail — so a network blip never silently loses the
    /// dictation. Only reached when the resilient-delivery flag is on (the
    /// session never resolves `.degraded` otherwise), so no extra flag check
    /// is needed here.
    ///
    /// Task 7: surfaces the calm `.finishing` state during recovery and, on a
    /// total-offline failure, retains the audio + flips to `.deliveryFailed` for
    /// a manual Retry (`retryPendingDelivery`). The transcribe→decide→deliver
    /// state machine lives in `runBatchRecovery` (unit-tested with spies); this
    /// wrapper binds the real side effects. The `(pcm:targetApp:targetPID:)`
    /// signature stays stable so the `.degraded` call site in `resolveViaSink`
    /// is untouched.
    private func recoverViaBatch(pcm: Data, targetApp: String?, targetPID: pid_t?) async {
        let prefs = PrivacyPreferences.shared
        let transcriber = dropBatchTranscriber
        let hasBatchTranscriber = await transcriber.isAvailable()
        await Self.runBatchRecovery(
            pcm: pcm,
            hasBatchTranscriber: hasBatchTranscriber,
            transcribe: { pcm in
                let raw = try await transcriber.transcribe(
                    audio: pcm,
                    language: prefs.selectedLanguage?.code
                )
                os_log("batch recover ok chars=%{public}d", log: Self.log, type: .info, raw.count)
                return raw
            },
            sink: dropDeliverySink(targetApp: targetApp, targetPID: targetPID)
        )
    }

    /// Production binding for `resolveDelivery`: wires the real transcribe call,
    /// paste tails, retry-state, telemetry, and the raw-partial salvage. Reuses
    /// the same sink shape as `recoverViaBatch` via `dropDeliverySink`.
    private func resolveViaSink(
        result: StreamingSessionResult, stopRequested: Bool, capturedPCM: Data,
        startedAt: Date, targetApp: String?, targetPID: pid_t?
    ) async {
        let partial = lastDropPartial
        let prefs = PrivacyPreferences.shared
        let transcriber = dropBatchTranscriber
        let hasBatchTranscriber = await transcriber.isAvailable()
        await Self.resolveDelivery(
            result: result, stopRequested: stopRequested,
            capturedPCM: capturedPCM, lastPartial: partial,
            startedAt: startedAt,
            hasBatchTranscriber: hasBatchTranscriber,
            transcribe: { pcm in
                try await transcriber.transcribe(
                    audio: pcm,
                    language: prefs.selectedLanguage?.code)
            },
            sink: dropDeliverySink(targetApp: targetApp, targetPID: targetPID))
    }

    /// Drop the retained total-offline take (Task 7): clears the PCM kept for a
    /// manual Retry and its captured paste target. Called when the user
    /// abandons a parked `.deliveryFailed` turn by starting a fresh Drop
    /// (`.discardFailedTakeAndStart`) — so a later Retry can never resurrect the
    /// discarded audio and paste it over the new turn's destination.
    private func discardPendingRetry() {
        pendingRetryPCM = nil
        pendingRetryTarget = nil
        pendingProcessingRetry = nil
        AppState.shared.dropDeliveryFailureMessage = nil
    }

    /// Manual retry for a total-offline degraded Drop (Task 7). Re-runs
    /// `recoverViaBatch` with the audio retained when delivery last failed,
    /// re-validating the paste target through the normal tail. Idempotent: a
    /// no-op when nothing is pending or a retry is already in flight
    /// (`shouldBeginRetry`).
    ///
    /// The retained PCM is NOT consumed up front — the recovery OUTCOME owns it
    /// (success → `clearPendingRetry`; failure → `retainForRetry` keeps it). A
    /// recovery that hangs or never re-arms therefore can't strand Retry as a
    /// permanent silent no-op (the old up-front nil left `pendingRetryPCM == nil`
    /// while the phase stayed `.deliveryFailed`). `.finishing` is surfaced
    /// synchronously so a fast second press — or a fresh Drop — sees an
    /// in-flight phase (routed to `.noop`), never the escapable terminal: that
    /// closes the window where a stale retry could paste over a new turn.
    func retryPendingDelivery() {
        if let pending = pendingProcessingRetry {
            guard !retryInFlight else { return }
            retryInFlight = true
            AppState.shared.phase = .verifying
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runPostProcessAndPaste(
                    rawText: pending.rawText, targetApp: pending.targetApp,
                    targetPID: pending.targetPID, mode: pending.mode
                )
                self.retryInFlight = false
            }
            return
        }
        guard Self.shouldBeginRetry(inFlight: retryInFlight, hasPendingAudio: pendingRetryPCM != nil),
              let pcm = pendingRetryPCM else { return }
        let target = pendingRetryTarget
        retryInFlight = true
        AppState.shared.phase = .finishing
        os_log("retrying degraded Drop delivery from retained audio", log: Self.log, type: .info)
        Task { @MainActor [weak self] in
            await self?.recoverViaBatch(
                pcm: pcm,
                targetApp: target?.app,
                targetPID: target?.pid
            )
            // Drop the take unless the outcome re-armed `.deliveryFailed`. The
            // non-re-arming arms (no-audio / empty / unauthorized) idle the phase
            // without calling `clearPendingRetry`; since the PCM is no longer
            // consumed up front, skipping this would strand captured audio + an
            // AX target in memory with no retry UI. Re-armed failures keep it.
            if AppState.shared.phase != .deliveryFailed {
                self?.discardPendingRetry()
            }
            self?.retryInFlight = false
        }
    }

    /// The side-effect surface the batch-recovery state machine
    /// (`runBatchRecovery`) drives. Every effect arrives as a closure so the
    /// state machine can be unit-tested with spies instead of instantiating the
    /// AppKit-bound `AppDelegate`. Production wires these to the real phase,
    /// paste tail, retry-state, unauthorized handling, and telemetry;
    /// `DropBatchRecoveryTests`
    /// wires recorders.
    struct DropBatchRecoverySink {
        /// Move the on-screen Drop phase (`.finishing`, `.idle`, `.deliveryFailed`).
        var setPhase: (AppPhase) -> Void
        /// Deliver through the mode's processing + paste tail. False means the
        /// processing owner retained the transcript and displayed a retryable
        /// failure; recovery must not clear it or substitute a raw partial.
        var deliver: (String) async -> Bool
        /// Retain the captured PCM for a manual Retry (total-offline only).
        var retainForRetry: (Data) -> Void
        /// Clear any armed retry (on a successful delivery).
        var clearPendingRetry: () -> Void
        /// Close the turn's diagnostics with a failure reason.
        var failTelemetry: (String) -> Void
        /// Paste a RAW transcript (the realtime partial) directly, bypassing
        /// cleanup — used only on the salvage rung. Async because the paste
        /// tail awaits AutoPaste.
        /// Returns whether the paste landed: a `false` lets `salvageOrFail` fall
        /// through to `.deliveryFailed` (retain for retry) instead of silently
        /// losing the dictation.
        var pasteRaw: (String) async -> Bool = { _ in true }
        /// A Smart take must process recovered partials before delivering them.
        var requiresProcessingForPartial: Bool = false
    }

    /// Pure-ish state machine for degraded-Drop batch recovery (Task 7). Given
    /// the retained `pcm`, whether a batch transcriber is available, and an
    /// injected `transcribe` closure, it drives the `DropBatchRecoverySink`
    /// through the contractual arms:
    ///
    ///  - no audio / no transcriber → idle + `degraded_no_audio`, no paste, NO
    ///    retry (nothing to recover);
    ///  - empty transcript → idle + `degraded_empty`, no paste, NO retry;
    ///  - success → `.finishing` then `deliver` exactly once, then idle, and
    ///    clear any pending retry;
    ///  - any other throw → keep the audio for retry + flip to
    ///    `.deliveryFailed` + `degraded_batch_failed`, and NEVER paste.
    ///
    /// Static + closure-driven so it is fully covered by `DropBatchRecoveryTests`
    /// without an `AppDelegate` instance; `recoverViaBatch` is the thin
    /// production wrapper that binds the real side effects.
    static func runBatchRecovery(
        pcm: Data,
        hasBatchTranscriber: Bool,
        deadline: BatchRecoveryDeadline = .production,
        transcribe: @escaping (Data) async throws -> String,
        sink: DropBatchRecoverySink
    ) async {
        guard shouldAttemptBatchRecovery(
            hasAudio: !pcm.isEmpty,
            hasBatchTranscriber: hasBatchTranscriber
        ) else {
            // Nothing to recover — fail to idle WITHOUT pasting or arming retry.
            sink.failTelemetry("degraded_no_audio")
            sink.setPhase(.idle)
            return
        }
        sink.setPhase(.finishing)
        do {
            let raw = try await withBatchRecoveryDeadline(deadline) {
                try await transcribe(pcm)
            }
            if streamingTranscriptIsEmpty(raw) {
                // Empty recovered transcript: nothing to deliver and nothing
                // worth retrying — fail to idle WITHOUT pasting or arming retry.
                sink.failTelemetry("degraded_empty")
                sink.setPhase(.idle)
                return
            }
            guard await sink.deliver(raw) else { return }
            // Delivery owns the phase tail (it ends at .idle); a successful
            // (re)delivery clears any armed retry from a prior failed attempt.
            sink.clearPendingRetry()
        } catch {
            // Keep the audio so the user can retry, surface the non-alarming
            // .deliveryFailed state, and NEVER paste an empty/partial result.
            // A deadline-cut hang reports its own reason so a stuck decode can
            // be told from an error.
            sink.retainForRetry(pcm)
            sink.failTelemetry(
                error is BatchRecoveryTimeout ? "degraded_batch_timeout" : "degraded_batch_failed"
            )
            sink.setPhase(.deliveryFailed)
        }
    }

    /// Thrown by `withBatchRecoveryDeadline` when the batch-recovery transcribe
    /// exceeds its deadline. Typed so telemetry can distinguish a hang
    /// (`degraded_batch_timeout`) from an ordinary failure, and so external
    /// cancellation is never misreported as a timeout.
    struct BatchRecoveryTimeout: Error {}

    /// Deadline policy for the batch-recovery transcribe (rung 2 + manual
    /// Retry). A stuck decode used to wedge the island on "finishing…" —
    /// Drop hotkey `.noop`, Retry seemingly dead. 30 s end-to-end: generous
    /// for a legitimate multi-minute buffer, decisive for a hung one. `sleep`
    /// is injectable so tests can expire (or never expire) the deadline
    /// without wall-clock waits.
    /// WHY: docs/decisions/2026-07-22-hub-token-join-and-batch-recovery-deadline.md
    /// (closes the "app-level timeout" tail deferred in
    /// docs/decisions/2026-06-24-deliveryfailed-escapable-and-retry-robust.md).
    struct BatchRecoveryDeadline: Sendable {
        var seconds: TimeInterval
        var sleep: @Sendable (TimeInterval) async throws -> Void

        static let production = BatchRecoveryDeadline(seconds: 30) {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    }

    /// Race `operation` against the deadline. The losing arm is cancelled.
    /// The operation's own errors — including `CancellationError` from an
    /// EXTERNAL cancel — surface untouched; only the deadline arm throws
    /// `BatchRecoveryTimeout`.
    static func withBatchRecoveryDeadline(
        _ deadline: BatchRecoveryDeadline,
        operation: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in try await operation() }
            group.addTask { @MainActor [sleep = deadline.sleep, seconds = deadline.seconds] in
                try await sleep(seconds)
                throw BatchRecoveryTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BatchRecoveryTimeout() }
            return first
        }
    }

    /// Unified Drop delivery ladder. Every non-cancelled turn outcome routes here;
    /// delivers the best available result and never loses dictation silently.
    /// Pure + closure-driven for `DropDeliveryResolverTests` (no AppDelegate).
    /// WHY: docs/superpowers/specs/2026-06-21-drop-delivery-resolver-design.md
    static func resolveDelivery(
        result: StreamingSessionResult,
        stopRequested: Bool = true,
        capturedPCM: Data,
        lastPartial: String,
        startedAt: Date = Date(),
        hasBatchTranscriber: Bool,
        deadline: BatchRecoveryDeadline = .production,
        transcribe: @escaping (Data) async throws -> String,
        sink: DropBatchRecoverySink
    ) async {
        switch result {
        case .transcript(let text), .endpointDetected(let text):
            // A `.transcript` that resolved WITHOUT the user releasing
            // (stopRequested == false) is an abnormal/premature finish: the
            // upstream/provider closed the stream mid-hold (e.g. ElevenLabs'
            // keepalive cutting a long dictation at ~40 s), so `text` is a
            // truncated fragment — or empty — of a longer utterance whose full
            // audio is in `capturedPCM`. Recover the full audio via batch instead
            // of pasting the fragment / silence-guarding it away; the realtime
            // text is carried as the salvage fallback (the longer of it and the UI
            // partial) so we never deliver LESS than the live stream produced.
            // `.endpointDetected` (provider VAD end-of-speech) is a legitimate
            // auto-finish and is exempt — it always delivers its realtime text.
            // WHY: docs/decisions/2026-06-22-longhold-upstream-close-truncation.md
            if case .transcript = result, !stopRequested {
                await recoverOrSalvage(
                    pcm: capturedPCM,
                    lastPartial: text.count >= lastPartial.count ? text : lastPartial,
                    hasBatchTranscriber: hasBatchTranscriber,
                    deadline: deadline,
                    transcribe: transcribe, sink: sink)
                return
            }
            if streamingTranscriptIsEmpty(text) {
                sink.failTelemetry("silence_guard"); sink.setPhase(.idle); return
            }
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            os_log(
                "streaming transcribe ok chars=%{public}d latency_ms=%{public}d",
                log: log, type: .info,
                text.count, latencyMs
            )
            guard await sink.deliver(text) else { return }             // rung 1
            // A successful realtime delivery clears any retry armed by a PRIOR
            // failed take (parity with the batch rung), so stale PCM never
            // lingers across turns.
            sink.clearPendingRetry()
        case .cancelled:
            sink.failTelemetry("cancelled"); sink.setPhase(.idle)
        case .failed, .degraded:
            await recoverOrSalvage(
                pcm: capturedPCM, lastPartial: lastPartial,
                hasBatchTranscriber: hasBatchTranscriber,
                deadline: deadline,
                transcribe: transcribe, sink: sink)
        }
    }

    /// Rungs 2–4: full batch → raw partial → deliveryFailed/idle.
    private static func recoverOrSalvage(
        pcm: Data, lastPartial: String, hasBatchTranscriber: Bool,
        deadline: BatchRecoveryDeadline = .production,
        transcribe: @escaping (Data) async throws -> String, sink: DropBatchRecoverySink
    ) async {
        /// `armRetry: false` means the batch rung already SUCCEEDED and returned
        /// an empty transcript — the audio reached the provider and it heard no
        /// speech. Retry re-runs that same batch, so it can only come back empty
        /// again; arming it would park "Couldn't deliver — offline" on what is
        /// really silence. Such turns idle quietly (rung 1 does the same via
        /// `silence_guard`) and report `batchFailureReason` verbatim.
        /// WHY: docs/decisions/2026-07-26-empty-batch-is-silence-not-offline.md
        func salvageOrFail(
            batchFailureReason: String = "degraded_batch_failed",
            armRetry: Bool = true
        ) async {
            // The manual Retry armed by `retainForRetry` (.deliveryFailed →
            // `recoverViaBatch`) re-transcribes the retained PCM in batch.
            if !streamingTranscriptIsEmpty(lastPartial) {
                if sink.requiresProcessingForPartial {
                    if await sink.deliver(lastPartial) { sink.clearPendingRetry() }
                    return
                }
                let pasted = await sink.pasteRaw(lastPartial)          // rung 3
                if pasted {
                    sink.failTelemetry("salvaged_partial")
                } else if !pcm.isEmpty && armRetry {
                    // The raw-partial paste itself failed (pasteboard write /
                    // modifier timeout). Don't silently lose the dictation —
                    // retain the audio and surface .deliveryFailed for a retry.
                    sink.retainForRetry(pcm)
                    sink.failTelemetry("salvaged_partial_paste_failed")
                    sink.setPhase(.deliveryFailed)
                } else {
                    // Paste failed and nothing to retain — idle is the only
                    // honest outcome, but flag it distinctly from a clean
                    // salvage.
                    sink.failTelemetry("salvaged_partial_paste_failed")
                    sink.setPhase(.idle)
                }
            } else if !pcm.isEmpty && armRetry {
                sink.retainForRetry(pcm)
                sink.failTelemetry(batchFailureReason)
                sink.setPhase(.deliveryFailed)                         // rung 4
            } else {
                // No retryable audio (empty PCM), or a batch that
                // succeeded-but-empty — the latter carries its own reason.
                sink.failTelemetry(armRetry ? "degraded_no_audio" : batchFailureReason)
                sink.setPhase(.idle)
            }
        }
        guard shouldAttemptBatchRecovery(
            hasAudio: !pcm.isEmpty,
            hasBatchTranscriber: hasBatchTranscriber
        ) else {
            await salvageOrFail(); return
        }
        sink.setPhase(.finishing)
        do {
            let raw = try await withBatchRecoveryDeadline(deadline) {  // rung 2
                try await transcribe(pcm)
            }
            if streamingTranscriptIsEmpty(raw) {
                // Batch SUCCEEDED with an empty transcript = no speech in the
                // audio, not a delivery failure. Salvage a partial if there is
                // one, otherwise idle — never arm a Retry that re-uploads the
                // same silence.
                await salvageOrFail(batchFailureReason: "degraded_empty", armRetry: false)
                return
            }
            guard await sink.deliver(raw) else { return }
            sink.clearPendingRetry()
        } catch is BatchRecoveryTimeout {
            // Stuck decode cut by the deadline: same salvage ladder, but the
            // reason distinguishes the hang from an ordinary batch error.
            await salvageOrFail(batchFailureReason: "degraded_batch_timeout")
        } catch {
            await salvageOrFail()
        }
    }

    // MARK: - Meeting Notes coordinator

    /// Instantiates the Stage 1a wiring shell and publishes a weak ref
    /// through `AppState.meetingsCoordinator` so the rest of the app
    /// (status menu, future Stage 4 hotkey guard) can read coordinator
    /// state without reaching into the app delegate.
    ///
    /// `start()` is intentionally NOT called here. `startReady()` invokes it
    /// so it only runs after permissions match the rest of the ready-state
    /// subsystems. When `MeetingsConfig.isEnabled` is `false` `start()` is a
    /// logged no-op.
    private func installMeetingsCoordinator() {
        let config = MeetingsConfig()
        // PoC switch: use process-level meeting-context probe instead of
        // device-level mic probe. Teams keeps `com.microsoft.teams2.modulehost`
        // claiming the input device after the user leaves a call (for
        // quick rejoin / huddle), so device-level "mic in use" stays
        // true → detector never sees a session boundary, recorder never
        // auto-finalizes. Process-level "is a meeting-context bundle
        // recording" releases promptly on leave. Drop-in: conforms to
        // the same `MicInUseProbing` protocol downstream relies on.
        let micProbe: MicInUseProbing = MeetingContextActiveProbe()
        let vadAdapter = SileroVADAdapter()
        let systemAudioSource = CoreAudioSystemAudioSource()
        let vadProbe = SystemAudioVADProbe(
            vad: vadAdapter,
            audioSource: systemAudioSource
        )
        let detector = MeetingDetector(
            micProbe: micProbe,
            vadProbe: vadProbe,
            config: config,
            frontmostDetector: FrontmostAppDetector()
        )
        // Stage 3: pill + prerecord buffer wiring. Both are constructed
        // unconditionally so the AppDelegate launch path stays simple;
        // the coordinator gates on `MeetingsConfig.isEnabled` before
        // any of them does observable work. When the feature flag is
        // off the pill panel never orders front (its `applyState`
        // observer sees `.hidden` only) and the buffer never receives
        // an `append` call.
        let buffer = PrerecordBuffer(
            sampleRate: 16_000,
            capacitySeconds: MeetingsConfig.prerecordBufferCapacitySeconds
        )
        let pill = MeetingPillController(buffer: buffer)
        let pillPanel = MeetingPillPanel(controller: pill)
        // Recorder factory. Builds a real `MeetingRecorder` wired to
        // audio-only mic capture and the CoreAudio system-audio fan-out.
        // The staging directory lives under Application Support so chunks
        // survive app restarts (launch recovery picks them back up from
        // disk).
        let stagingRoot = Self.meetingsStagingRoot()
        let recorderFactory: MeetingsCoordinator.RecorderFactory = { meetingId in
            MeetingRecorder(
                micSource: MicCaptureSource(),
                systemSource: vadProbe,
                micInUseProbe: micProbe,
                stagingRoot: stagingRoot,
                testCapture: MeetingLiveTestSettings.makeIfEnabled()
            )
        }
        // Local store + coordinator wire. Store init can throw on
        // filesystem failure (cannot create Application Support dir, SQLite
        // open fails) — degrade gracefully: log and proceed without a store.
        let store: MeetingsStore?
        do {
            store = try MeetingsStore(
                rootDirectory: MeetingsStore.defaultRootDirectory()
            )
        } catch {
            os_log(
                "MeetingsStore init failed (%{public}@) — running in degraded mode",
                log: Self.log, type: .error,
                String(describing: error)
            )
            store = nil
        }
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            recorderFactory: recorderFactory,
            stagingRoot: { stagingRoot },
            meetingsStore: store,
            directProcessor: MeetingBYOKProcessor(),
            meetingsEnabled: { UserPreferencesCache.shared.currentMeetingsEnabled },
            enableMeetingsCapability: { UserPreferencesCache.shared.setMeetingsEnabled(true) }
        )
        self.meetingsCoordinator = coordinator
        self.meetingsStore = store
        self.meetingPillController = pill
        self.meetingPillPanel = pillPanel
        self.meetingPrerecordBuffer = buffer
        AppState.shared.meetingsCoordinator = coordinator

        // Start draining coordinator events so a freshly transcribed
        // meeting refreshes the open Meetings window without polling
        // the store.
        installMeetingsEventConsumer(coordinator: coordinator)

        // Recover anything left in the staging dir by a previous run that
        // crashed or quit (a fully recorded meeting whose processing never
        // finished). Idempotent: noop once the staging dir is fully drained.
        coordinator.resumePendingProcessingOnLaunch()
    }

    /// Build the Now Playing coordinator + controller and mirror the
    /// coordinator weakly on `AppState`. Constructed unconditionally so the
    /// launch path stays simple; the coordinator gates on
    /// `NowPlayingConfig.isEnabled` before any polling runs. `start()` is
    /// invoked from `startReady()` beside the meetings coordinator so it
    /// only begins after auth + permissions match the rest of the ready
    /// subsystems. When the flag is off, `start()` is a logged no-op.
    /// Starts the Case broker socket. Only a packaged app serves it (tests
    /// and `swift run` never do); the helper is trusted by the cdhash of
    /// `Contents/Helpers/whytap` in this same bundle. Approve requests show the
    /// island prompt (`CaseApprovalController`).
    private func installCaseBroker() {
        guard caseBrokerServer == nil, Bundle.main.bundleURL.pathExtension == "app",
              let bundleID = Bundle.main.bundleIdentifier
        else { return }
        let inspector = CaseSystemProcessInspector()
        let controls = AppControlController()
        appControlController = controls
        let approvals = CaseApprovalController()
        caseApprovalController = approvals
        caseApprovalPanel = CaseApprovalPanel(controller: approvals)
        caseApprovalCancellable = approvals.$current
            .map { $0 != nil }
            .removeDuplicates()
            .sink { active in AppState.shared.caseApprovalActive = active }
        let broker = CaseBroker(
            service: CaseVaultService.shared,
            resolver: CaseSystemCallerResolver(
                inspector: inspector,
                builtInOpenCodePIDs: { CaseBuiltInAgentProcesses.shared.pids }),
            approvals: approvals,
            authenticator: LocalCaseAuthenticator(),
            appControl: { [controls] request in await controls.handle(request) })
        let server = CaseBrokerServer(
            socketURL: CaseBrokerPaths.socketURL(bundleID: bundleID),
            broker: broker,
            inspector: inspector,
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whytap"))
        do {
            try server.start()
            caseBrokerServer = server
        } catch {
            os_log("case_broker start_failed", log: Self.lifecycleLog, type: .error)
        }
    }

    private func installNowPlayingCoordinator() {
        let config = NowPlayingConfig()
        // Pick the data source once per session: the prompt-free MediaRemote
        // adapter when healthy, else the AppleScript fallback. The MediaRemote
        // source starts its own streaming process inside the factory.
        let selection = NowPlayingSourceFactory.makeSelection()
        let controller = NowPlayingController(source: selection.source)
        let coordinator = NowPlayingCoordinator(config: config, controller: controller)
        self.nowPlayingController = controller
        self.nowPlayingCoordinator = coordinator
        AppState.shared.nowPlayingCoordinator = coordinator
        AppState.shared.nowPlayingSourceKind = selection.kind

        installVolumeDuck()
    }

    /// Builds the volume-duck controller (+ CoreAudio volume reader and fader)
    /// and subscribes it to recording state. The controller reads
    /// `VolumeDuckConfig.isEnabled` fresh on every transition (live Settings
    /// toggle, no relaunch). Volume is moved through CoreAudio's device scalar —
    /// no audio capture, no TCC grant. It restores only if WE lowered it (see
    /// `VolumeDuckController`).
    private func installVolumeDuck() {
        let config = VolumeDuckConfig()
        let volume = SystemOutputVolume()
        let fader = VolumeFader(write: { value, device in volume.setVolume(value, device: device) })
        let controller = VolumeDuckController(
            toggleEnabled: { config.isEnabled },
            readOutput: { volume.currentOutput() },
            fade: { from, to, duration, device in
                fader.fade(from: from, to: to, duration: duration, on: device)
            },
            activeFade: { fader.active },
            cancelFade: { fader.cancel() }
        )
        self.systemOutputVolume = volume
        self.volumeFader = fader
        self.volumeDuckController = controller

        installVolumeDuckObserver()
    }

    /// Drives `VolumeDuckController.update(recording:)` from recording state.
    /// Both the Drop flow (`$phase == .recording`) and the agent voice flow
    /// (`$agentPhase == .voiceRecording`) lower the volume. A short trailing
    /// debounce absorbs the rapid toggles a Drop hold-release produces.
    private func installVolumeDuckObserver() {
        let appState = AppState.shared
        // Merge both phase publishers into a single "something changed" signal;
        // the closure re-reads recording state fresh, so the merged value is
        // irrelevant (mapped to Void). The initial emission (phase == .idle)
        // computes `recording == false`, an idempotent no-op while not ducked —
        // so no `dropFirst()` is needed.
        let phaseChanges = appState.$phase.map { _ in () }
        let agentPhaseChanges = appState.$agentPhase.map { _ in () }
        phaseChanges
            .merge(with: agentPhaseChanges)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let state = AppState.shared
                let recording = state.phase == .recording
                    || state.agentPhase == .voiceRecording
                self.volumeDuckController?.update(recording: recording)
            }
            .store(in: &volumeDuckCancellables)
    }

    /// Drains `coordinator.events` and refreshes the open Meetings
    /// window whenever a meeting lands. Detached `Task` because the loop
    /// runs for the lifetime of the app; cancelled on terminate.
    private func installMeetingsEventConsumer(coordinator: MeetingsCoordinator) {
        meetingsEventConsumer?.cancel()
        meetingsEventConsumer = Task { [weak self] in
            for await event in coordinator.events {
                guard !Task.isCancelled else { return }
                self?.handleMeetingsCoordinatorEvent(event)
                await MeetingReadyNotifications.shared.receive(event)
            }
        }
    }

    private func handleMeetingsCoordinatorEvent(_ event: MeetingsCoordinatorEvent) {
        switch event {
        case .newMeetingAvailable, .meetingFailed:
            // Refresh the open Meetings window so a new row appears in
            // the sidebar without forcing the user to close and reopen.
            // Reading the private storage on the coordinator avoids
            // constructing the window lazily — we only want to refresh
            // if it has already been opened once.
            meetingsCoordinator?.refreshOpenWindowIfNeeded()
        }
    }

    /// Application Support root for staging chunks. Spec / plan:
    /// `~/Library/Application Support/Sidekey/meetings-staging/`.
    private static func meetingsStagingRoot() -> URL {
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportRoot
            .appendingPathComponent("Sidekey", isDirectory: true)
            .appendingPathComponent("meetings-staging", isDirectory: true)
    }

    /// Subscribes to `DisplayPreferences.hideHelpers` so the floating
    /// `KeybindingsHintPanel` is closed when the user enables "Hide
    /// Helpers" and reopened (when the orb is on-screen) when the
    /// toggle flips back off. The three SwiftUI-hosted helper chips
    /// (`OrbActionsView`, `AgentResponsePanel`'s close row,
    /// `UsefulLinksBlockView`'s rolling chip) observe the preference
    /// directly through `@ObservedObject` and don't need a sink here.
    ///
    /// `dropFirst()` skips the initial value emission so toggling the
    /// menu item is the only event that flows through this sink — the
    /// startup state is already handled by `showFloatingPanelIfNeeded`
    /// reading `DisplayPreferences.shared.hideHelpers` synchronously.
    private func installDisplayPreferenceObserver() {
        DisplayPreferences.shared.$hideHelpers
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in
                guard let self else { return }
                if hidden {
                    self.keybindingsHintPanel?.close()
                    self.keybindingsHintPanel = nil
                } else if self.panel != nil {
                    // Only reopen if the orb is currently visible —
                    // otherwise we'd resurrect the hint before the
                    // floating panel ecosystem exists (e.g. before
                    // launch finishes).
                    self.showKeybindingsHintIfNeeded()
                }
            }
            .store(in: &cancellables)
    }

    /// Stand up the Dynamic Island idle-hide controller and its bridges, once.
    /// Idempotent — called after `IslandPanel.shared.show()` from both the ready
    /// startup and wake paths, but only the first call installs.
    ///
    /// Three bridges (spec §7.2 / §7.3):
    ///   * controller.$visibility → `AppState.idleVisibility` (drives the fade +
    ///     the panel's hit-rect collapse).
    ///   * AppState blockers + agent flow → `controller.updateBusy` (holds
    ///     `.active` while any blocker is up).
    ///   * panel mouse-activity / hover → `controller.registerActivity` /
    ///     `setHovered` (wake + B10 hover blocker). No event payload crosses —
    ///     invariant #2.
    private func installIslandIdleControllerIfNeeded() {
        guard islandIdleController == nil else { return }
        let controller = IslandIdleController(
            isEnabled: { [weak self] in self?.islandIdlePreferences.isEnabled ?? true }
        )
        islandIdleController = controller
        islandIdleCancellables.removeAll()

        // React to the Settings auto-hide toggle: a disable must un-hide the
        // island at once (not wait for the next hover/hotkey), an enable starts
        // a fresh idle window. The preference setter posts this only on a real
        // change (no spurious pokes).
        NotificationCenter.default.publisher(
            for: IslandIdlePreferences.didChangeNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak controller] _ in controller?.settingsDidChange() }
        .store(in: &islandIdleCancellables)

        // Publish visibility into AppState for the view + panel. SYNCHRONOUS
        // delivery on purpose: the controller is @MainActor, so the value is
        // already published on main — a `.receive(on: RunLoop.main)` hop here
        // deferred the WAKE by a runloop turn (and RunLoop-scheduled delivery
        // stalls in tracking modes), which read as visible lag when hovering
        // to the notch (founder feedback 2026-07-06).
        controller.$visibility
            .removeDuplicates()
            .sink { visibility in
                AppState.shared.setIdleVisibility(visibility)
            }
            .store(in: &islandIdleCancellables)

        // Recompute the blocker disjunction whenever AppState or the agent flow
        // store changes. `objectWillChange` fires BEFORE the value mutates, so
        // hop a runloop tick to read the settled state (mirrors the panel's
        // `subscribeToAgentFlow`).
        let recomputeBusy: () -> Void = { [weak self, weak controller] in
            guard let self, let controller else { return }
            controller.updateBusy(self.currentIslandIdleBlockers().isBusy)
        }
        AppState.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in DispatchQueue.main.async(execute: recomputeBusy) }
            .store(in: &islandIdleCancellables)
        IslandPanel.shared.agentFlow.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in DispatchQueue.main.async(execute: recomputeBusy) }
            .store(in: &islandIdleCancellables)
        LocalNotificationHub.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in DispatchQueue.main.async(execute: recomputeBusy) }
            .store(in: &islandIdleCancellables)
        // Push the initial blocker state so a launch that is already busy
        // (e.g. an update pill already up) starts held.
        recomputeBusy()

        // Wake + hover blocker from the panel's mouse routing.
        IslandPanel.shared.onIslandMouseActivity = { [weak controller] in
            controller?.registerActivity()
        }
        IslandPanel.shared.onIslandHoverChange = { [weak controller] hovered in
            controller?.setHovered(hovered)
        }
    }

    /// A brightness key changed the island display: show the Display strip briefly, without
    /// keyboard focus. While the island cannot expand the level still changes, without the strip.
    private func showBrightnessGlance() {
        registerIslandHotkeyActivity()
        let appState = AppState.shared
        guard IslandHoverPolicy.allowsExpansion(
            meetingSuggestionActive: appState.meetingSuggestionActive,
            meetingRecordingActive: appState.meetingRecordingActive,
            agentFlowActive: IslandPanel.shared.agentFlow.isActive,
            caseApprovalActive: appState.caseApprovalActive
        ) else { return }
        appState.programmaticHoverExpansion = true
        hoverPanelRequestToken += 1
        appState.programmaticHoverPanelRequest = HoverPanelRequest(
            panel: .brightness, token: hoverPanelRequestToken, isGlance: true
        )
    }

    /// Register a hotkey activation as island activity (spec §4.2): resets the
    /// idle timer and wakes a hidden island instantly. Called from each hotkey
    /// handler. Blocker-flipping hotkeys (Drop / Agent / Meeting / Hover) also
    /// wake via the busy bridge, but this covers non-blocker hotkeys (Help /
    /// History) and keeps the pill alive for the full timeout while the user
    /// interacts. Carries NO keystroke content — invariant #2.
    private func registerIslandHotkeyActivity() {
        islandIdleController?.registerActivity()
    }

    /// Snapshot the AppState-sourced idle blockers (spec §3). B10 (mouse-over)
    /// is fed separately via the panel, so it is not read here.
    private func currentIslandIdleBlockers() -> IslandIdleBlockers {
        let appState = AppState.shared
        return IslandIdleBlockers(
            dropFlowActive: appState.phase != .idle,
            agentPhaseActive: appState.agentPhase != .idle,
            agentPanelVisible: IslandPanel.shared.agentFlow.isActive,
            meetingSuggestionActive: appState.meetingSuggestionActive,
            meetingRecordingActive: appState.meetingRecordingActive,
            updateAvailable: appState.updateAvailable != nil,
            justUpdatedVisible: appState.justUpdatedVersion != nil,
            nowPlayingActive: appState.nowPlaying != nil,
            rightModifierHeld: appState.rightCommandHeld || appState.rightOptionHeld,
            programmaticHoverExpansion: appState.programmaticHoverExpansion,
            notificationActive: LocalNotificationHub.shared.current != nil,
            caseApprovalActive: appState.caseApprovalActive
        )
    }

    // MARK: - Boot output

    private func printBanner() {
        print("Whytap v0.1")
        print("Hotkey: \(HotkeyPreferences.shared.dropVoiceShortcut.title)")
    }

    private func reportPermissions() {
        // Drop hotkey: Carbon `RegisterEventHotKey` (`CarbonHotkeyMonitor`),
        // gated by Accessibility. Agent gesture: `NSEvent` global monitor,
        // also Accessibility. Synth Cmd+V paste: `CGEvent.post` on
        // `.cghidEventTap`. On Tahoe consumer macOS there is no separate
        // "Post Event" pane in System Settings — Accessibility is the
        // actual gate, and `CGPreflightPostEventAccess` returns false on
        // adhoc-signed dev builds even when the post works. The
        // Post-Event print line is kept as advisory diagnostics; the
        // engine no longer guards on it.
        let axGranted = PermissionsHelper.accessibilityGranted(prompt: false)
        let postEventStatus = PermissionsHelper.postEventAccessGranted(prompt: false)
        let micStatus = PermissionsHelper.microphoneStatus()

        print("Permissions:")
        print("  [\(axGranted ? "ok" : "missing")] Accessibility")
        print("  [\(postEventStatus ? "ok" : "preflight-false")] Post Event (advisory)")
        let micLabel: String
        switch micStatus {
        case .authorized: micLabel = "ok"
        case .denied: micLabel = "denied"
        case .restricted: micLabel = "restricted"
        case .notDetermined: micLabel = "will-prompt"
        @unknown default: micLabel = "unknown"
        }
        print("  [\(micLabel)] Microphone")

    }
}
