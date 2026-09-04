import Foundation

/// Closures the Dynamic Island can fire from its hover controls. Each
/// closure mirrors the hotkey action the control represents.
///
/// Wiring: `AppDelegate` constructs a production `IslandActions` with
/// real handlers (drop hotkey, agent gesture, history strip, meetings window)
/// and assigns it to `IslandPanel.shared.actions` before calling `show()`.
/// The view receives the struct through its init and invokes the closures
/// on click.
///
/// The defaults in `noOp` are silent — keeps SwiftUI previews and unit
/// tests rendering without dragging in `AppDelegate`. Production code
/// MUST overwrite every closure; a silent click in production would
/// look like a UI bug.
@MainActor
struct IslandActions {
    /// `⌥/` — start/stop the dictate (drop) voice flow. Matches the
    /// existing Carbon hotkey at `AppDelegate.onHotkey()`.
    var startDictate: () -> Void
    /// `right ⌘ hold` — agent voice flow start. Mirrors
    /// `AgentController.handleHoldStart()`. Auto-stops at max duration
    /// (no separate "stop" action on the start control — same UX departure
    /// as a regular hotkey hold where the key release ends the turn,
    /// but a click is point-in-time so the session's own auto-stop
    /// closes it).
    var startVoiceAgent: () -> Void
    /// `right ⌘ hold release` — agent voice flow end + submit. Mirrors
    /// `AgentController.handleHoldEnd()`. Used by the Dynamic Island
    /// agent mini-orb to toggle: while a voice session is in progress
    /// (`agentPhase == .voiceRecording`), a second click ends the
    /// recording and submits to the agent — same code path the real
    /// hotkey release uses, no waiting for the max-duration auto-stop.
    var stopVoiceAgent: () -> Void
    /// `right ⌘ tap` — agent text input toggle. Mirrors
    /// `AgentController.handleTap()`.
    var openTextAgent: () -> Void
    /// Toolbar entry point for the unified history strip's Clipboard
    /// filter. Mirrors `HistoryStripController.toggle(.clipboard)` —
    /// post-ROO-208 the strip exposes filter selection via an in-strip
    /// sidebar, so the toolbar button pre-selects Clipboard but the
    /// user can pivot to Drop / Agent without re-opening.
    var openClipboard: () -> Void
    /// Hover History entry point. Captures the paste target while the
    /// user's app is still frontmost and returns the mode to show first.
    var openHistory: () -> HistoryStripMode = { .clipboard }
    /// Reads history rows for the active hover History mode.
    var historyCards: (HistoryStripMode) async -> [HistoryStripCard] = { _ in [] }
    /// Persists the user's last selected hover History mode.
    var selectHistoryMode: (HistoryStripMode) -> Void = { _ in }
    /// User clicked a hover History row body.
    var copyHistoryCard: (HistoryStripCard) -> Void = { _ in }
    /// Root of the clipboard image sidecar store — the hover preview
    /// bubble resolves full-size images from it (thumbnail fallback).
    var historyAssetsDirectory: () -> URL? = { nil }
    /// User pressed Enter on a hovered hover History row.
    var pasteHistoryCard: (HistoryStripCard) -> Void = { _ in }
    /// Current validated paste target name captured before History opened.
    var historyPasteTargetName: () -> String? = { nil }
    /// Useful Links nav hotkey — surface Useful Links in the agent response panel.
    /// **No clean re-usable entry point exists outside the response
    /// panel** — the `UsefulLinksHotkeyController` only registers this
    /// action when a response panel is on screen with a `usefulLinks` block.
    /// In production this closure is a logged no-op; see report
    /// concerns for the trade-off.
    var openUsefulLinks: () -> Void
    /// Open Settings with the Notes tab selected. There is no dedicated
    /// hotkey today.
    var openMeetings: () -> Void
    /// Open Settings on its default tab.
    var openSettings: () -> Void
    /// Open the Help / Hotkeys window
    /// (`HelpWindowController` — same surface the `⌥?` hotkey opens).
    /// Wired from the hover panel's `Hotkeys` tile so users without
    /// the hotkey can still reach the cheatsheet.
    var openHelp: () -> Void
    /// Open Settings with the Hotkeys tab selected.
    var openHotkeys: () -> Void
    /// Quit the app completely. Mirrors the status menu's Quit item.
    var quitApplication: () -> Void
    /// Stop the active Meeting Notes recorder. Mirrors the recording
    /// pill's Stop button so the Dynamic Island right-side recorder
    /// slot does not create a second stop path.
    var stopMeetingRecording: () -> Void
    /// Toggle a MANUAL Meeting Notes recording — start when idle (bypassing
    /// the detector nudge), stop when one is running. The hover "Record"
    /// tile / ⌥M hotkey path; mirrors
    /// `MeetingsCoordinator.toggleManualRecording()`. Defaults to a silent
    /// no-op for previews / tests.
    var toggleMeetingRecord: () -> Void = {}
    /// Retry a total-offline Drop delivery (Task 7). Fired by the
    /// `.deliveryFailed` wing's Retry pill; mirrors
    /// `AppDelegate.retryPendingDelivery()`, which re-runs batch recovery from
    /// the audio retained when delivery last failed. No-op when nothing is
    /// pending. Defaults to a silent no-op for previews / tests.
    var retryDelivery: () -> Void = {}
    /// Skip to the previous track in the active media player. Wired by
    /// `AppDelegate` to `NowPlayingCoordinator.previous()`; the Stage 3
    /// player strip's ⏮ button fires this.
    var musicPrevious: () -> Void = {}
    /// Toggle play/pause on the active media player (discrete play vs
    /// pause chosen by the controller from the last known state). Wired to
    /// `NowPlayingCoordinator.playPause()`; the strip's ⏯ button fires it.
    var musicPlayPause: () -> Void = {}
    /// Skip to the next track in the active media player. Wired to
    /// `NowPlayingCoordinator.next()`; the strip's ⏭ button fires it.
    var musicNext: () -> Void = {}
    /// Current transcription / agent response language. `nil` means
    /// Auto detection.
    var currentLanguage: () -> AppLanguage?
    /// Persist a new transcription / agent response language. Passing
    /// `nil` restores Auto detection.
    var setLanguage: (AppLanguage?) -> Void
    /// Current Output (target) language for Smart-mode translation. `nil`
    /// means off (no translation — same as the input language).
    var currentTargetLanguage: () -> AppLanguage?
    /// Persist a new Output (target) language. `nil` turns translation off.
    var setTargetLanguage: (AppLanguage?) -> Void
    /// Current Drop transcription mode (`fast` / `smart`). The hover
    /// Drop Mode control reads this so the island reflects the same
    /// setting the `⌥/` hotkey route uses.
    var currentDropMode: () -> TranscriptionMode
    /// Toggle Drop transcription mode and return the mode now in effect.
    /// Production updates `UserPreferencesCache` immediately so the next
    /// `⌥/` uses the selected route, then syncs preferences in the
    /// background.
    var toggleDropMode: () -> TranscriptionMode
    /// Local vocabulary store behind the inline hover Vocab editor.
    var vocabulary: () -> VocabularyCache = { .shared }

    /// Default factory used by SwiftUI previews and unit tests so the
    /// view renders without a wired `AppDelegate`. All closures are
    /// silent no-ops.
    static let noOp = IslandActions(
        startDictate: {},
        startVoiceAgent: {},
        stopVoiceAgent: {},
        openTextAgent: {},
        openClipboard: {},
        openUsefulLinks: {},
        openMeetings: {},
        openSettings: {},
        openHelp: {},
        openHotkeys: {},
        quitApplication: {},
        stopMeetingRecording: {},
        currentLanguage: { nil },
        setLanguage: { _ in },
        currentTargetLanguage: { nil },
        setTargetLanguage: { _ in },
        currentDropMode: { .fast },
        toggleDropMode: { .fast }
    )
}
