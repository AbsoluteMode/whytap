import Foundation

enum AppPhase: Equatable {
    case idle
    case recording
    case transcribing
    case verifying
    case inserting
    /// Degraded resilient-Drop recovery: the live stream broke mid-turn but
    /// the audio was retained locally and is being batch-transcribed. A calm
    /// "working" state ("дочитываю…"), NOT an error — only reached on the
    /// `.degraded` path (resilient-delivery flag on).
    case finishing
    /// Total-offline resilient-Drop outcome: batch recovery also failed, so the
    /// captured audio is kept and a manual Retry is offered. A non-alarming
    /// error state; only reached on the `.degraded` path (flag on).
    case deliveryFailed
}

enum AgentPhase: Equatable {
    case idle
    /// User tapped R-Cmd, the text-input panel is on screen. No request
    /// has been dispatched yet; UI surfaces this with the gradient-ring orb.
    case textInputActive
    case voiceRecording
    case transcribing
    case executing
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: AppPhase = .idle
    @Published var agentPhase: AgentPhase = .idle

    /// Dynamic Island idle-hide visibility, mirrored from `IslandIdleController`
    /// by `AppDelegate` (controller-owns-logic / AppState-mirrors-for-view).
    /// `IslandView` reads this to fade the
    /// compact content to the bare notch after the idle timeout; `IslandPanel`
    /// reads it to gate the compact hit-rect. Default `.active` so the island is
    /// visible on launch and before the controller is installed.
    @Published private(set) var idleVisibility: IdleVisibility = .active

    /// Setter for `AppDelegate`'s controller→AppState mirror. Kept a method (not
    /// a public setter) so only the wiring layer publishes it.
    func setIdleVisibility(_ visibility: IdleVisibility) {
        guard idleVisibility != visibility else { return }
        idleVisibility = visibility
    }

    @Published private(set) var audioLevels: [Float] = []
    @Published var hotkeyFlash: Bool = false
    @Published var rightCommandHeld: Bool = false
    @Published var rightOptionHeld: Bool = false
    @Published var toolsExpanded: Bool = false
    @Published var meetingSuggestionActive: Bool = false
    @Published var meetingSuggestionDeadline: Date?

    @Published private(set) var meetingRecordingActive: Bool = false
    @Published private(set) var meetingRecordingPaused: Bool = false
    @Published private(set) var meetingRecordingDuration: TimeInterval = 0
    @Published private(set) var meetingRecordingLevels: [Double] = []

    /// Current track from Apple Music / Spotify, owned by
    /// `NowPlayingController` and published here for the Dynamic Island
    /// music surfaces (Stages 2–3). Non-nil while a track is active
    /// (playing OR paused); cleared (debounced) when nothing is active.
    /// Stays nil when the feature flag is off (no polling runs).
    @Published private(set) var nowPlaying: NowPlayingSnapshot?

    /// Which transport button the cursor is over, resolved geometrically by
    /// `IslandPanel` (SwiftUI `.onHover` flickers in the non-activating panel).
    /// Drives the music strip's hover highlight.
    @Published var hoveredMusicTransport: MusicTransportButton?

    /// Active scheduled-update prompt, owned by `UpdateController`. The
    /// Dynamic Island right band (Stage 2 of ROO-186) observes this via
    /// `@ObservedObject` and renders `IslandUpdateAvailablePill` when
    /// non-nil. Set on gentle-reminders discovery, cleared on Update click
    /// (resume) or Skip click (dismiss until process restart). Default is
    /// nil so the UI is no-op for installations without an active discovery.
    @Published var updateAvailable: PendingUpdate?

    /// Display version of an update that JUST applied on the previous launch,
    /// surfaced as a transient "Updated vX.Y" island indicator (variant A —
    /// shown post-relaunch in the new binary, so the one-button auto-install +
    /// relaunch flow is preserved). Set on launch by `JustUpdatedIndicator`
    /// when the persisted install marker matches the running `CFBundleVersion`;
    /// self-clears after ~5 s or on tap. Default nil → no-op indicator.
    /// Distinct from `updateAvailable` (an in-flight Sparkle update): this is a
    /// post-hoc confirmation with no download/skip/dismiss lifecycle.
    @Published var justUpdatedVersion: String?

    /// Held weak — `AppDelegate` owns the controller. Stage 2 click handlers
    /// in `IslandUpdateAvailablePill` will call into this without reaching
    /// back into `AppDelegate`, mirroring `meetingsCoordinator` ownership.
    weak var updateController: UpdateController?

    /// True while the mouse cursor is inside the floating orb area
    /// (orb panel frame, optionally unioned with the keybindings-hint
    /// panel frame). Drives the orb→actions visual swap: both
    /// `FloatingDotPanel` and `KeybindingsHintPanel` subscribe and
    /// fade their normal contents out / fade the action icons in.
    /// Owned at the singleton level because two separate `NSPanel`s
    /// need to react to the same hover signal.
    @Published var orbHovered: Bool = false

    /// True once `CarbonHotkeyMonitor.start()` has thrown
    /// `VEError.hotkeyFailed`. Surfaces the failure to UI so a future
    /// status-bar badge / alert can prompt the user. Always reset to `false`
    /// on a subsequent successful registration.
    @Published var hotkeyRegistrationFailed: Bool = false

    /// Set by a Hover-slot hotkey (⌥N) to expand the Hover drawer WITHOUT a
    /// mouse hover (D4). `IslandView.isHoverExpanded` unions this with the
    /// mouse-hover signal but still gates the result on
    /// `IslandHoverPolicy.allowsExpansion`, so ⌥N never forces the drawer open
    /// during a meeting suggestion / agent flow. Reset to `false` when the
    /// cursor leaves the island (the next mouse-exit collapses it) so it never
    /// stays latched.
    @Published var programmaticHoverExpansion: Bool = false

    /// One-shot request from a Hover-slot hotkey to open a specific inline
    /// sub-panel (for `.inlinePanel` tools). `IslandView` observes this, maps it
    /// onto its private panel-mode state, then the request is cleared. `nil`
    /// means "no pending panel request" (action/navigate tools don't set it).
    /// Bumped through a monotonic token so two consecutive requests for the same
    /// panel still register as distinct events.
    @Published var programmaticHoverPanelRequest: HoverPanelRequest?

    /// One-shot "Drop mode was toggled by its hover-slot hotkey" event.
    /// `IslandView` observes it to sync its local `dropMode` state and to show
    /// the same transient `ON Smart`/`ON Fast` right-band status the tile click
    /// shows. The monotonic `token` makes two consecutive toggles to the same
    /// mode distinct `@Published` events (mirrors `HoverPanelRequest`).
    @Published var dropModeHotkeyToggle: DropModeHotkeyToggle?

    private var dropModeHotkeyToggleToken = 0

    func publishDropModeHotkeyToggle(_ mode: TranscriptionMode) {
        dropModeHotkeyToggleToken += 1
        dropModeHotkeyToggle = DropModeHotkeyToggle(
            mode: mode,
            token: dropModeHotkeyToggleToken
        )
    }

    /// Singleton-level handle on the Meeting Notes coordinator. Owned
    /// strongly by `AppDelegate`; held here as a weak ref so any caller
    /// (status menu rebuild, hotkey guard introduced in Stage 4) can ask
    /// "is a meeting recording right now?" without reaching back into the
    /// app delegate. Stage 1a wires the property; Stages 2-9 add real
    /// behaviour the rest of the app needs to read.
    weak var meetingsCoordinator: MeetingsCoordinator?

    /// Singleton-level handle on the Now Playing coordinator. Owned
    /// strongly by `AppDelegate`; held weakly here so the Stage 3 strip's
    /// transport buttons can drive the active player without reaching back
    /// into the app delegate. Mirrors `meetingsCoordinator` ownership. Nil
    /// when the feature flag is off (coordinator inert).
    weak var nowPlayingCoordinator: NowPlayingCoordinator?

    /// Which now-playing data source was selected for this session
    /// (MediaRemote adapter vs AppleScript fallback). Read by the Settings
    /// view to decide whether the Automation permission row is meaningful —
    /// the adapter needs no permission, so its row is informational. `nil`
    /// until the coordinator is installed.
    var nowPlayingSourceKind: NowPlayingSourceFactory.Kind?

    /// Stage 4 convenience: read-only "is a meeting recorder live right
    /// now?" used by `CarbonHotkeyMonitor`'s suppression gate so Option+/
    /// is silently no-op'd while the meeting mic owns the input. Returns
    /// `false` if no coordinator is wired (Stage 1a/2/3 deployment with
    /// feature flag off — same outcome as no recording active).
    var isMeetingRecording: Bool {
        meetingsCoordinator?.isRecording ?? false
    }

    /// Push a new normalized [0..1] level. Keeps the buffer bounded.
    /// Also feeds the global `NoiseFloorEstimator` so the orb's voice
    /// gate adapts to the user's ambient room tone.
    func pushAudioLevel(_ level: Float) {
        audioLevels.append(level)
        if audioLevels.count > AudioMeter.bufferSize {
            audioLevels.removeFirst()
        }
        NoiseFloorEstimator.shared.record(level)
    }

    func clearAudioLevels() {
        audioLevels = []
    }

    func updateMeetingRecordingState(
        audioLevel: Double,
        duration: TimeInterval,
        paused: Bool
    ) {
        meetingRecordingActive = true
        meetingRecordingPaused = paused
        meetingRecordingDuration = max(0, duration)
        meetingRecordingLevels = IslandMeetingRecordingSlot.appendingLevel(
            to: meetingRecordingLevels,
            level: paused ? 0 : audioLevel
        )
    }

    func clearMeetingRecordingState() {
        meetingRecordingActive = false
        meetingRecordingPaused = false
        meetingRecordingDuration = 0
        meetingRecordingLevels = []
    }

    /// Publish the latest Now Playing snapshot. Idempotent-friendly: a
    /// value equal to the current one is a no-op so SwiftUI does not
    /// re-render on identical ~1 s polls.
    func updateNowPlaying(_ snapshot: NowPlayingSnapshot) {
        guard nowPlaying != snapshot else { return }
        nowPlaying = snapshot
    }

    /// Clear the Now Playing snapshot (no active player). No-op when
    /// already nil.
    func clearNowPlaying() {
        guard nowPlaying != nil else { return }
        nowPlaying = nil
    }

    private init() {}

    func setHotkeyModifierKey(_ key: HotkeyModifierKey, held: Bool) {
        switch key {
        case .rightCommand:
            rightCommandHeld = held
            if held {
                rightOptionHeld = false
            }
        case .rightOption:
            rightOptionHeld = held
            if held {
                rightCommandHeld = false
            }
        }
    }
}

/// Payload of `AppState.dropModeHotkeyToggle`.
struct DropModeHotkeyToggle: Equatable {
    let mode: TranscriptionMode
    let token: Int
}
