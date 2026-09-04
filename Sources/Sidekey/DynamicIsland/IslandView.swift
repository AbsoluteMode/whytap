import AppKit
import SwiftUI

/// Derived state shown by the Dynamic Island. Computed from
/// `AppState.phase` (drop flow) and `AppState.agentPhase` (agent flow)
/// via `IslandState.from(phase:agentPhase:)`. The island is a pure
/// view-of-state — no demo cycler, no interactive cycle.
///
/// Cases match the visual vocabulary the orb already speaks:
/// - `.idle` — silent ring
/// - `.listening` — active blob (voice flavour: drop or agent)
/// - `.thinking` — processing composition (drop or agent flavour)
/// - `.textInput` — agent gradient ring (text panel open, no request yet)
enum IslandState: Equatable {
    case idle
    case listening
    case thinking
    case textInput

    /// Pure mapping function. Drop flow has priority when both flows are
    /// somehow active simultaneously (shouldn't happen — the hotkey
    /// monitors suppress each other — but defensively we prefer the
    /// drop flow because it owns the primary user-facing surface).
    static func from(phase: AppPhase, agentPhase: AgentPhase) -> IslandState {
        // Drop flow first — wins on contention.
        switch phase {
        case .recording:
            return .listening
        case .transcribing, .verifying, .inserting, .finishing:
            // `.finishing` is degraded batch recovery in flight (Task 7) — a
            // calm working state, same orb as the other processing phases.
            return .thinking
        case .deliveryFailed:
            // Total-offline terminal (Task 7): the orb rests; the Dynamic Island
            // wing carries the non-alarming failure + Retry.
            return .idle
        case .idle:
            break
        }

        switch agentPhase {
        case .idle:
            return .idle
        case .voiceRecording:
            return .listening
        case .transcribing, .executing:
            return .thinking
        case .textInputActive:
            return .textInput
        }
    }

    /// Maps an `IslandState` + the originating flow to a `VoiceOrbMode`.
    /// The flow is needed because `.listening` / `.thinking` have two
    /// flavours: drop (white-on-dark / black-on-light blobs) vs agent
    /// (pink-violet blobs). We re-read `phase` / `agentPhase` rather
    /// than carrying a "which flow" tag on the state itself — keeps
    /// `IslandState` flat and the mapping side-effect-free.
    ///
    /// `activeSourceIsGoogle` is true when the R-Option Google gesture is
    /// driving the agent phase. Google phases resolve to their own orb
    /// modes (`.googleVoice` / `.googleTextInputActive`) so the orb glows
    /// Google colors instead of the default pink-violet agent palette.
    func orbMode(
        phase: AppPhase,
        agentPhase: AgentPhase,
        activeSourceIsGoogle: Bool = false
    ) -> VoiceOrbMode {
        // Google branch: intercept agent phases before the generic mapping.
        // Safe to run before the `.listening` drop-vs-agent split: Drop (hold
        // Space) and the Google gesture (R-Option) are mutually exclusive at
        // the flow-store level (one gesture machine at a time), so
        // `activeSourceIsGoogle` is never true during a live drop and this can
        // never mask the `phase == .recording -> .dropVoice` outcome.
        if activeSourceIsGoogle {
            switch agentPhase {
            case .voiceRecording:
                return .googleVoice
            case .textInputActive:
                return .googleTextInputActive
            default:
                break
            }
        }

        switch self {
        case .idle:
            return .idle
        case .textInput:
            return .agentTextInputActive
        case .listening:
            // Drop flow wins (matches `from(...)`'s priority).
            if phase == .recording {
                return .dropVoice
            }
            return .agentVoice
        case .thinking:
            switch phase {
            case .transcribing, .verifying, .inserting, .finishing:
                // `.finishing` reaches here as a drop-flow working state (Task 7).
                return .dropProcessing
            case .idle, .recording, .deliveryFailed:
                // `.deliveryFailed` never maps to `.thinking` (it resolves to
                // `.idle` in `from(...)`); listed for exhaustiveness.
                return .agentProcessing
            }
        }
    }
}

/// SwiftUI root for the Dynamic Island. The pill literally wraps the
/// macOS notch — orb on the LEFT of the notch, trigger area on the
/// RIGHT, hardware cutout in the middle (rendered as a spacer so the
/// black pill background appears continuous with the physical notch).
///
/// **State**:
/// - `isHovering` — hover-driven. The passive state shows rotating
///   two-line hints in the right band; hover reveals the two trigger
///   orbs and opens the lower Drop Mode control.
/// - Orb composition derives from `AppState.phase` + `AppState.agentPhase`
///   via `IslandState.from(...)`. No interactive cycle — the pill is a
///   view-of-state surface.
///
/// **Layout dimensions** are forwarded from `IslandPanel` (which reads
/// them off the selected screen — `IslandScreenResolver.currentDescriptor()`):
/// - `compactHeight` — pill height in compact state (= notch height,
///   clamped to `[24, 44]`).
/// - `compactWidth` — `leftSideWidth + notchWidth + rightSideWidth`.
/// - `notchWidth` — real notch cutout width or synthetic placeholder
///   on non-notched screens.
struct IslandView: View {

    /// Compact pill height (= clamped live menu-bar / notch height).
    let compactHeight: CGFloat

    /// Compact pill width on this screen.
    let compactWidth: CGFloat

    /// Width of the gap between the left and right panels — the literal
    /// notch cutout on notched screens, synthetic placeholder elsewhere.
    let notchWidth: CGFloat

    /// Production action closures fired when the trigger orbs are
    /// clicked. Defaults to `.noOp` so previews and tests render
    /// without dragging in `AppDelegate`.
    let actions: IslandActions

    /// Called whenever the hover-expanded lower panel opens/closes so
    /// `IslandPanel` can widen the hit-test rect to include it.
    let onHoverChange: (Bool) -> Void

    /// Called while the language picker is open. The panel normally
    /// stays non-key so clicks do not steal focus; the search field is
    /// the one hover state that needs keyboard input.
    let onKeyboardFocusRequest: (Bool) -> Void

    /// Reports the hover band height for the current panel mode so
    /// `IslandPanel` can grow its hit-test band when a tall inline panel
    /// (History) is on screen — and shrink it back on `.controls`.
    let onHoverPanelBandHeightChange: (CGFloat) -> Void

    /// Reports the rendered answer card height so `IslandPanel` can size the
    /// answer hit-zone to the visible card (not a fixed reservation that would
    /// eat clicks for windows under the island below a short answer).
    let onAgentAnswerHeightChange: (CGFloat) -> Void

    /// Presentation state for the agent surfaces (wing + answer panel).
    /// Derived from `AgentController` by the routing task; here it just
    /// drives the wing slot / answer column and the agent-aware priority
    /// gating.
    @ObservedObject private var agentFlow: IslandAgentFlowStore

    /// Selection chip state for the answer panel's useful-links block.
    @ObservedObject private var agentLinksSelection: UsefulLinksSelectionState

    /// Submits the composing wing's text as an agent prompt. Wired to
    /// `AgentController` by the routing task; defaults to a no-op so
    /// previews / tests render without it.
    /// Cancels the active agent flow (Esc in the composing wing, the
    /// answer panel's dismiss button). Wired by the routing task.
    let cancelAgentFlow: () -> Void

    /// Reports composing-field focus changes outward so `IslandPanel` can
    /// flip `agentKeyboardEnabled` (same route as `onKeyboardFocusRequest`
    /// for the language picker).
    let onAgentKeyboardFocusChange: (Bool) -> Void

    @MainActor
    init(
        compactHeight: CGFloat = IslandFrameLayout.defaultCompactHeight,
        compactWidth: CGFloat = IslandFrameLayout.leftSideWidth
            + IslandFrameLayout.syntheticNotchWidth
            + IslandFrameLayout.rightSideWidth,
        notchWidth: CGFloat = IslandFrameLayout.syntheticNotchWidth,
        appState: AppState? = nil,
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        onKeyboardFocusRequest: @escaping (Bool) -> Void = { _ in },
        onHoverPanelBandHeightChange: @escaping (CGFloat) -> Void = { _ in },
        onAgentAnswerHeightChange: @escaping (CGFloat) -> Void = { _ in },
        actions: IslandActions? = nil,
        agentFlow: IslandAgentFlowStore? = nil,
        agentLinksSelection: UsefulLinksSelectionState? = nil,
        cancelAgentFlow: @escaping () -> Void = {},
        onAgentKeyboardFocusChange: @escaping (Bool) -> Void = { _ in },
        displayPreferences: DisplayPreferences? = nil,
        vocabulary: (() -> VocabularyCache)? = nil
    ) {
        let resolvedActions = actions ?? .noOp
        self.compactHeight = compactHeight
        self.compactWidth = compactWidth
        self.notchWidth = notchWidth
        self.actions = resolvedActions
        self.onHoverChange = onHoverChange
        self.onKeyboardFocusRequest = onKeyboardFocusRequest
        self.onHoverPanelBandHeightChange = onHoverPanelBandHeightChange
        self.onAgentAnswerHeightChange = onAgentAnswerHeightChange
        self.cancelAgentFlow = cancelAgentFlow
        self.onAgentKeyboardFocusChange = onAgentKeyboardFocusChange
        self._agentFlow = ObservedObject(
            wrappedValue: agentFlow ?? IslandAgentFlowStore(responseStore: AskResponseStore())
        )
        self._agentLinksSelection = ObservedObject(
            wrappedValue: agentLinksSelection ?? UsefulLinksSelectionState()
        )
        self._appState = ObservedObject(wrappedValue: appState ?? .shared)
        self._displayPreferences = ObservedObject(wrappedValue: displayPreferences ?? .shared)
        self._dropMode = State(initialValue: resolvedActions.currentDropMode())
        self._selectedLanguage = State(initialValue: resolvedActions.currentLanguage())
        self._targetLanguage = State(initialValue: resolvedActions.currentTargetLanguage())
        let vocabularyStore = vocabulary?() ?? resolvedActions.vocabulary()
        self._vocabularyViewModel = StateObject(
            wrappedValue: IslandVocabularyViewModel(vocabulary: vocabularyStore)
        )
        self._fillerViewModel = StateObject(
            wrappedValue: IslandFillerViewModel()
        )
        self._caseViewModel = StateObject(
            wrappedValue: CaseViewModel()
        )
    }

    @ObservedObject private var appState: AppState
    @ObservedObject private var displayPreferences: DisplayPreferences
    /// Hover over the compact pill rectangle (top portion of the host frame).
    /// Tracks the cursor inside `compactWidth × compactHeight` only — the
    /// area below the pill no longer participates in expansion gating.
    /// Sequences the wing entrance: form grows empty → content fades in.
    @StateObject private var wingReveal = IslandWingRevealCoordinator()

    @State private var pillHovering = false
    /// Hover over the rendered hover panel (Row-1 + Row-2 tile grid). Only
    /// meaningful once expansion has already happened; lets the cursor
    /// travel from the pill down into the panel without dismissing.
    @State private var panelHovering = false
    /// Gated mouse-hover state (the latch `isHovering` reflects). Resolved by
    /// `IslandHoverGate` from `pillHovering` / `panelHovering` and its own
    /// prior value: the OPEN edge requires the visible pill, the STAY-open edge
    /// honours either region. Keeping the prior value here is what lets the gate
    /// distinguish "opening" from "staying open" so the drawer's fading hover
    /// band can never re-trigger an open before the cursor reaches the pill
    /// (ROO-259 bug B).
    @State private var mouseExpanded = false
    @State private var dropMode: TranscriptionMode
    @State private var dropModeStatus: TranscriptionMode?
    @State private var dropModeStatusGeneration = 0
    @State private var hoverPanelMode: IslandHoverPanelMode = .controls
    /// Invalidation token for the programmatic-expansion auto-collapse timer:
    /// each change to `programmaticHoverExpansion` AND each ⌥N panel request
    /// bumps it (`armProgrammaticExpansionCollapse`), so a stale deferred
    /// collapse (from an earlier ⌥N) can't fire against a newer expansion —
    /// a repeat press extends the window instead of inheriting the old timer.
    @State private var programmaticExpansionCollapseGeneration = 0
    @State private var selectedLanguage: AppLanguage?

    /// Hover band height for a panel mode. History renders ~267pt of
    /// content (mode row + 5 visible rows + hint) — far taller than the
    /// default 145pt band — so the band grows with the mode. When a track is
    /// active the hover-gated player strip sits at the top of the band
    /// (between the island and the hover panel), so the band grows by the
    /// strip's height too (same precedent as History's tall band — see
    /// `historyHoverPanelHeight` / `onHoverPanelBandHeightChange`).
    static func hoverPanelHeight(
        for mode: IslandHoverPanelMode,
        musicActive: Bool
    ) -> CGFloat {
        let base = mode == .history
            ? IslandDropModeControl.historyHoverPanelHeight
            : IslandDropModeControl.hoverPanelHeight
        return base + (musicActive
            ? IslandDropModeControl.musicStripHeight + IslandDropModeControl.musicStripBottomGap
            : 0)
    }

    /// `true` while the hover-gated player strip is shown — a track is active
    /// AND the island is hover-expanded. Drives the band growth and the
    /// strip insertion at the top of the hover drawer.
    private var showsHoverMusicStrip: Bool {
        isHoverExpanded && hoverNowPlaying != nil
    }

    private var activeHoverPanelHeight: CGFloat {
        Self.hoverPanelHeight(
            for: hoverPanelMode,
            musicActive: hoverNowPlaying != nil
        )
    }

    /// Playback for the COMPACT right-band wing — eye-INDEPENDENT. The wing is
    /// an always-on "a track is playing" indicator, so the "Hide Hover and
    /// Music" eye must not remove it (only the hover player widget is hidden).
    private var compactNowPlaying: NowPlayingSnapshot? {
        IslandMusicRouting.compactWingNowPlaying(
            appState.nowPlaying,
            hoverWidgetsHidden: displayPreferences.hideIslandHoverWidgets
        )
    }

    /// Playback for the HOVER player widget (the card between the island and the
    /// hover drawer) — gated by the "Hide Hover and Music" eye.
    private var hoverNowPlaying: NowPlayingSnapshot? {
        IslandMusicRouting.hoverWidgetNowPlaying(
            appState.nowPlaying,
            hoverWidgetsHidden: displayPreferences.hideIslandHoverWidgets
        )
    }

    /// Coordinate space the History rows report their frames in; the
    /// preview bubble overlay is anchored in the same space.
    static let hoverZoneSpace = HistoryHoverView.hoverZoneSpaceName

    /// Hovered History row whose content earned a preview bubble.
    @State private var historyPreviewAnchor: HistoryHoverPreviewAnchor?
    @State private var targetLanguage: AppLanguage?
    @StateObject private var vocabularyViewModel: IslandVocabularyViewModel
    @StateObject private var fillerViewModel: IslandFillerViewModel
    @StateObject private var caseViewModel: CaseViewModel

    /// Combined hover state — `true` whenever the cursor is over either the
    /// compact pill OR (once already expanded) the hover panel below it.
    /// Used everywhere the old single `isHovering` flag was consulted so
    /// the rest of the view tree (background, camera chrome, hover-callback)
    /// still sees a single "is the island lit up" boolean.
    ///
    /// Reads the `mouseExpanded` latch rather than `pillHovering ||
    /// panelHovering` directly: the latch is gated by `IslandHoverGate` so the
    /// drawer's lingering hover band cannot re-open a closed drawer during its
    /// fade-out (ROO-259 bug B). `recomputeMouseExpanded()` keeps the latch in
    /// sync on every raw-hover change.
    private var isHovering: Bool { mouseExpanded }

    /// Re-resolve the `mouseExpanded` latch from the raw `.onHover` signals via
    /// `IslandHoverGate`. Called whenever `pillHovering` / `panelHovering`
    /// change. The gate consults the latch's PRIOR value, so the open vs
    /// stay-open distinction is preserved.
    private func recomputeMouseExpanded() {
        let next = IslandHoverGate.mouseExpanded(
            pillHovering: pillHovering,
            panelHovering: panelHovering,
            wasExpanded: mouseExpanded
        )
        if mouseExpanded != next {
            mouseExpanded = next
        }
    }

    /// A small local reveal for the right-side hover controls and lower
    /// Drop Mode panel.
    private static let hoverMotion = Animation.spring(response: 0.24, dampingFraction: 0.82)
    private static let widthGrowth = Animation.spring(response: 0.32, dampingFraction: 0.9)

    /// How long a programmatic (⌥N) Hover expansion stays open with no mouse
    /// hover before auto-collapsing. Long enough to read the surfaced panel,
    /// short enough that a keyboard-opened drawer never feels stuck.
    private static let programmaticExpansionTimeout: TimeInterval = 4

    /// Maps a Hover-slot inline-panel request (from a ⌥N hotkey) onto the
    /// private panel-mode state. `outputLanguagePicker` only opens in Smart mode
    /// — in Fast mode the picker is meaningless (no translation target), so the
    /// request is ignored (stays on `.controls`), mirroring the tile click's
    /// fast-mode gate (`IslandOutputLanguageControl.tap`).
    private static func panelMode(
        for panel: HoverInlinePanel,
        mode: TranscriptionMode
    ) -> IslandHoverPanelMode {
        switch panel {
        case .history:
            return .history
        case .vocabularyEditor:
            return .vocabularyEditor
        case .caseVault:
            return .caseVault
        case .fillerEditor:
            return .fillerEditor
        case .inputLanguagePicker:
            return .languagePicker
        case .outputLanguagePicker:
            switch IslandOutputLanguageControl.tap(for: mode) {
            case .openPicker:
                return .outputLanguagePicker
            case .showSmartOnlyNotice:
                return .controls
            }
        }
    }

    /// Animation for the passive-hint priority gate. Hiding is INSTANT
    /// (`nil`): the agent recording face inserts with `.transition(.identity)`
    /// in the same band, so an animated hint fade would overlap the already
    /// visible "listening…" — and that fade advances on the main thread,
    /// which dictation start keeps busy, stretching the half-faded overlap to
    /// hundreds of ms. Revealing the hints back animates normally.
    static func passiveHintGateAnimation(hasPriorityRightState: Bool) -> Animation? {
        hasPriorityRightState ? nil : hoverMotion
    }

    /// Animation for the hover drawer's expand/collapse and panel-mode swap.
    /// The mouse path animates with the standard `hoverMotion`; a hotkey-driven
    /// (programmatic) expansion renders instantly — replaying the hover-in
    /// motion for a keyboard action reads as a stray flicker.
    static func hoverExpansionAnimation(programmatic: Bool) -> Animation? {
        programmatic ? nil : hoverMotion
    }

    /// `true` while the compact pill should be faded to the bare notch after
    /// the idle timeout (`AppState.idleVisibility == .hiddenIdle`, spec §1). The
    /// engine only reaches this with every blocker clear, so no agent / meeting
    /// / notification / update surface is ever mid-fade.
    private var isIdleHidden: Bool {
        appState.idleVisibility == .hiddenIdle
    }

    /// Direction-aware fade for the idle collapse (spec §5): a slightly slower
    /// "settling" fade-out (220 ms) and a snappier wake (160 ms). `.easeOut`
    /// both ways; only the SwiftUI content animates — the window never moves.
    private var idleFadeAnimation: Animation {
        .easeOut(
            duration: isIdleHidden
                ? IslandIdleConfig.sleepAnimationDuration
                : IslandIdleConfig.wakeAnimationDuration
        )
    }

    /// Live-derived island state — recomputed every body pass from the
    /// observed `AppState`. Recomputation is cheap (a `switch` over two
    /// enums) and avoids holding a stale snapshot.
    private var islandState: IslandState {
        IslandState.from(phase: appState.phase, agentPhase: appState.agentPhase)
    }

    private var orbMode: VoiceOrbMode {
        islandState.orbMode(
            phase: appState.phase,
            agentPhase: appState.agentPhase,
            activeSourceIsGoogle: agentFlow.activeSourceIsGoogle
        )
    }

    /// Drop flow uses the live audio meter buffer; everything else
    /// shows a quiet orb (`[]` means `audioEnergy = 0` inside
    /// `VoiceOrbView`).
    private var orbLevels: [Float] {
        islandState == .listening ? appState.audioLevels : []
    }

    private var isHoverExpanded: Bool {
        // Union the mouse-hover signal with programmatic expansion (a Hover-slot
        // ⌥N press — D4), then gate the result on the policy so neither path
        // forces the drawer open during a meeting suggestion / agent flow.
        !displayPreferences.hideIslandHoverWidgets
            && (isHovering || appState.programmaticHoverExpansion)
            && IslandHoverPolicy.allowsExpansion(
                meetingSuggestionActive: appState.meetingSuggestionActive,
                meetingRecordingActive: appState.meetingRecordingActive,
                agentFlowActive: agentFlow.isActive
            )
    }

    private var meetingRecordingSnapshot: IslandMeetingRecordingSnapshot? {
        guard appState.meetingRecordingActive, !appState.meetingSuggestionActive else {
            return nil
        }
        return IslandMeetingRecordingSnapshot(
            duration: appState.meetingRecordingDuration,
            levels: appState.meetingRecordingLevels,
            isPaused: appState.meetingRecordingPaused
        )
    }

    /// Total width the island occupies including the left morph slot. The
    /// slot is reserved PERMANENTLY (`+ leftNotificationWidth`), whether or
    /// not a notification is on screen, so the island content never resizes
    /// when the pill appears/disappears — only the pill's own `.transition`
    /// plays. The empty slot is transparent and the reserved width sits to
    /// the LEFT; the island content stays trailing-aligned (pinned to the
    /// notch), so the island visually stays put. Reserving the width here
    /// (and permanently in `IslandPanel`'s window frame) is what kills the
    /// curve-mismatch jitter that used to come from animating two frames on
    /// different curves.
    private var outerWidth: CGFloat {
        compactWidth + IslandFrameLayout.leftNotificationWidth
            + (agentFlow.isActive ? IslandFrameLayout.rightAgentZoneWidth : 0)
    }

    /// Full SwiftUI content height. Matches the host window: the expanded
    /// (hover-panel) height plus, while the agent flow is active, the
    /// downward answer-panel zone (`agentWingGap + agentAnswerZoneHeight`).
    /// Growing in lockstep with the window keeps the content top-pinned —
    /// a shorter content frame would let SwiftUI center it vertically and
    /// drop the island below the menu bar.
    private var outerHeight: CGFloat {
        compactHeight + IslandDropModeControl.hoverPanelHeight
            + (agentFlow.isActive
                ? IslandFrameLayout.agentWingGap + IslandFrameLayout.agentAnswerZoneHeight
                : 0)
            // The player strip is no longer an always-on structural row; it
            // is hover-gated, living at the top of the hover drawer between
            // the island and the hover panel. The drawer's own
            // `activeHoverPanelHeight` (which grows by `musicStripHeight`
            // while a track is active) drives the islandStack frame, so no
            // unconditional growth is needed here. The permanent host window
            // frame reserves ample downward room (agent answer zone), so the
            // taller expanded band never clips.
    }

    /// Coarse identity of the current wing face — ignores the live
    /// transcript string so the body's layout animation fires on face
    /// transitions (hidden ↔ recording ↔ composing ↔ acting ↔ failed) but
    /// NOT on every recording delta.
    private var wingFaceID: Int {
        switch agentFlow.wing {
        case .hidden: return 0
        case .recording: return 1
        case .composing: return 2
        case .acting: return 3
        case .failed: return 4
        case .answerControls: return 5
        case .deliveryFailed: return 6
        }
    }

    /// Intrinsic width of the current wing face's CONTENT — `0` when no wing
    /// is shown. The face is laid out at this width by `IslandAgentWingView`;
    /// the first `agentWingInCapsuleWidth` of it is hosted inside the compact
    /// capsule's right band and the rest overflows into the form extension
    /// (`activeWingExtension`). Recording transcript partials only change this
    /// when they set a new rendered-width peak; shorter/narrower live updates
    /// keep the prior width, so the ticker stays live without repeated shrink
    /// springs (the body's `wingFaceID` spring keys off the coarse face, not the
    /// string).
    private var activeWingFaceWidth: CGFloat {
        switch agentFlow.wing {
        case .hidden: return 0
        case .recording:
            // Size to the turn's WIDEST rendered transcript (monotonic), NOT the
            // live one: the width grows then holds, so a transient provider
            // re-segment (a shorter/narrower partial) never shrinks/jumps the
            // wing — while the displayed text stays live. The store resets the
            // hint per turn.
            return IslandAgentWingView.recordingFaceWidth(
                text: agentFlow.recordingFaceWidthHint,
                providerMarkVisible: agentFlow.recordingProviderBrand != nil
            )
        case .composing:
            // Grows with the typed text from the placeholder floor up to the
            // composing cap, then the composer field scrolls. Single source of
            // truth shared with the hit zone + field rect in `IslandPanel`.
            return IslandAgentWingView.composingFaceWidth(text: agentFlow.composingText)
        case .acting:
            // Content-size the acting slot like recording/composing: hug the
            // status mark + label so short labels ("Editing") leave no dead
            // space to the right, while long tool labels cap at
            // agentWingActingWidth and truncate with an ellipsis (the face's own
            // .truncationMode(.tail)).
            return IslandAgentWingView.actingFaceWidth(
                label: agentFlow.activityLabel,
                providerMarkVisible: agentFlow.recordingProviderBrand != nil
            )
        case .answerControls: return IslandFrameLayout.agentWingAnswerControlsWidth
        case .failed: return IslandFrameLayout.agentWingFailedWidth
        case .deliveryFailed: return IslandFrameLayout.agentWingDeliveryFailedWidth
        }
    }

    /// How far the single island surface stretches RIGHTWARD for the current
    /// face — only the face's overflow past the right band
    /// (`agentWingExtension(faceWidth:)`), `0` when no wing is shown or the
    /// face fits inside the band. Mirrors `IslandPanel`'s wing-extension
    /// mapping (the hit-test side) so the rendered black surface and the hit
    /// zones stay in lockstep. The growth animates via the body's
    /// `wingFaceID` spring.
    private var activeWingExtension: CGFloat {
        IslandFrameLayout.agentWingExtension(faceWidth: activeWingFaceWidth)
    }

    /// `true` while the acting slot is showing. The acting label is the live
    /// progress narration, which changes rapidly; springing the wing width on
    /// every label swap makes the wing shake, so the width snaps instantly
    /// while acting (the label cross-fades in place) instead of springing.
    private var wingIsActing: Bool {
        if case .acting = agentFlow.wing { return true }
        return false
    }

    /// Snap (don't spring) the wing width when content drives rapid width
    /// changes the spring would lag behind: the acting label (live narration),
    /// and the composer once text is being typed. The composer's content lives
    /// in a separate, instantly-resized panel (`IslandAgentComposerPanel`), so a
    /// springing black capsule would trail the typed text and briefly leak it
    /// past the capsule edge onto the desktop. An empty composer still springs
    /// OPEN to the placeholder floor — only the per-keystroke grow snaps.
    private var wingSnapsWidth: Bool {
        if wingIsActing { return true }
        if case .composing = agentFlow.wing { return !agentFlow.composingText.isEmpty }
        return false
    }

    var body: some View {
        // Top-trailing ZStack so the island row stays pinned to the notch
        // while the agent answer column hangs below it. When the agent flow
        // is inactive this is a single child (`islandRow`) at the exact
        // prior size — bit-for-bit the previous trailing-aligned layout.
        ZStack(alignment: .topTrailing) {
            islandRow

            if agentFlow.answerPanelVisible {
                agentAnswerLayer
            }
        }
        .frame(width: outerWidth, height: outerHeight, alignment: .topTrailing)
        // Animate the wing's APPEARANCE and FACE changes (recording ->
        // acting -> …), not every transcript partial. `wingFaceID` collapses
        // `.recording(transcript:)` to a single token so the live ticker
        // doesn't re-trigger the layout spring on each delta.
        .animation(Self.hoverMotion, value: wingFaceID)
        // Acting label and per-keystroke composer growth change width too fast
        // for a spring (it shakes / trails the typed text, leaking it past the
        // capsule). Snap those; keep the spring for the recording grow and the
        // composer's OPEN, where the width moves monotonically as one smooth
        // stretch. See `wingSnapsWidth`.
        .animation(wingSnapsWidth ? nil : Self.widthGrowth, value: activeWingFaceWidth)
        .animation(Self.hoverMotion, value: agentFlow.answerPanelVisible)
        // Strip slides in / out with the same reveal spring as the rest of
        // the island when a track starts / stops (height + transition).
        .animation(Self.hoverMotion, value: appState.nowPlaying != nil)
        // Form-then-content sequencing: flag the coarse hidden↔visible edge
        // (NOT transcript partials — wingFaceID collapses those) so the
        // reveal coordinator can hold the face at opacity 0 while the form
        // grows, then fade it in (see `IslandWingRevealCoordinator`).
        .onChange(of: wingFaceID != 0) { _, visible in
            wingReveal.wingVisibilityChanged(visible)
        }
        // Pin the (smaller-than-window) content box to the window's
        // top-leading corner. The window is PERMANENTLY agent-sized and owns
        // its frame (`host.sizingOptions = []` — the hosting view no longer
        // shrink-wraps the window to the content). Without an explicit
        // anchor the hosting view would CENTER a fixed-size root in the
        // larger bounds, drifting the island off the notch. Top-leading is
        // the stable corner: the window's left edge is the notification
        // zone's left edge and its top is the screen top, in every state —
        // so the capsule cannot move when `outerWidth`/`outerHeight` grow
        // for the agent (the box grows rightward/downward only).
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        // Critical: without `.ignoresSafeArea()` the NSHostingView
        // applies the screen's safeAreaInsets to its SwiftUI content,
        // pushing the pill BELOW the notch (we want it AT the notch).
        // `NSPrefersDisplaySafeAreaCompatibilityMode = false` in
        // Info.plist enables modern safe-area semantics; this modifier
        // is the per-view opt-out for those semantics.
        .ignoresSafeArea()
    }

    /// The island row: left notification morph slot, the island capsule
    /// stack, and — while the agent flow is active — the right-side wing
    /// zone. The wing zone is a FIXED `rightAgentZoneWidth` reservation so
    /// the island capsule's right edge stays put as the wing changes width
    /// (recording adaptive up to 260 / composing 300 / acting 120). The wing is
    /// left-aligned inside the zone (gap, then wing) so its left edge sits
    /// at `windowRight - rightAgentZoneWidth + agentWingGap` — matching
    /// `IslandAgentHitZones.wingRect`.
    private var islandRow: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left morph slot: PERMANENTLY reserved at `leftNotificationWidth`
            // whether or not a notification is present, so nothing resizes on
            // show/hide — only the pill's own `.transition` plays. The empty
            // slot renders nothing visible (transparent) and its hit-testing
            // is gated in `IslandPanel` via `leftZoneWidth` (click-through
            // when empty, hittable when a pill is present). Trailing-aligned
            // so the pill hugs the island's left edge; the 8pt gap is kept
            // only when a pill is shown (empty slot needs no gap).
            notificationSlot
                .frame(
                    width: IslandFrameLayout.leftNotificationWidth,
                    height: compactHeight,
                    alignment: .trailing
                )
                .padding(.trailing, 0)

            // `islandStack` already self-sizes to `compactWidth ×
            // (compactHeight + hoverPanelHeight)` via its own inner `.frame`.
            //
            // Idle auto-hide (spec §1/§5): fade the whole compact pill — orb
            // strip, passive hints, right band AND the black camera surface — to
            // the bare notch after the idle timeout. `.opacity(0)` keeps the
            // layout/frame intact, so the window never moves (§1.2); the pill
            // simply becomes invisible + click-through (the panel drops its
            // compact hit-rect in `.hiddenIdle`). Direction-aware timing: slower
            // settle out, snappier wake in. The engine only reaches `.hiddenIdle`
            // with every blocker clear, so no meeting / update / agent surface is
            // ever mid-fade.
            islandStack
                .opacity(isIdleHidden ? 0 : 1)
                .animation(idleFadeAnimation, value: isIdleHidden)

            if agentFlow.isActive {
                agentWingZone
            }
        }
        .frame(
            width: outerWidth,
            height: compactHeight + IslandDropModeControl.hoverPanelHeight,
            // .topTrailing, NOT .top: when no notification pill is present
            // the left morph slot's `if let` branch is empty, so its
            // `.frame(width: leftNotificationWidth)` never materializes and
            // the HStack does NOT fill `outerWidth`. A plain `.top` then
            // CENTERS the underfilled row and drags the island ~150pt left
            // of the notch; trailing pins the capsule (and the agent wing
            // zone, which the hit zones expect right-anchored) to the
            // window's right edge regardless of slot materialization.
            alignment: .topTrailing
        )
        // ROO-221: dedicated transaction so the notification pill's `.transition`
        // plays deterministically even while the island rebuilds during Drop.
        // Deleted in 5521636 (hover redesign); without it the pill is lost when
        // a notification arrives mid-dictation. Do not remove.
        // Critical: without `.ignoresSafeArea()` the NSHostingView
        // applies the screen's safeAreaInsets to its SwiftUI content,
        // pushing the pill BELOW the notch (we want it AT the notch).
        // `NSPrefersDisplaySafeAreaCompatibilityMode = false` in
        // Info.plist enables modern safe-area semantics; this modifier
        // is the per-view opt-out for those semantics.
        .ignoresSafeArea()
    }

    /// Fixed-width transparent spacer reserving `rightAgentZoneWidth` to the
    /// right of the capsule while the agent flow is active. The agent phase
    /// content itself no longer lives here — it is drawn INSIDE the island's
    /// stretched single surface (see `islandStack`'s `.overlay`), so the
    /// island reads as one continuous shape rather than a separate component
    /// beside it. This spacer exists only to keep the row's trailing-aligned
    /// width math (`outerWidth`) and the hit zones unchanged: it pins the
    /// capsule's right edge at `windowRight - rightAgentZoneWidth`, matching
    /// `IslandAgentHitZones.wingRect`'s origin.
    private var agentWingZone: some View {
        Color.clear
            .frame(
                width: IslandFrameLayout.rightAgentZoneWidth,
                height: compactHeight
            )
            .allowsHitTesting(false)
    }

    /// The agent answer column, hung below the capsule row. Its right edge
    /// aligns with the RECORDING wing's right edge (capsule right + gap +
    /// `agentWingRecordingWidth`) — product feedback asked for the panel
    /// to sit further right than the collapsed acting slot it originally
    /// aligned to.
    ///
    /// Built as: intrinsic-width (336pt) panel, pushed DOWN by the capsule
    /// row + the vertical gap and RIGHT-anchored via a trailing pad equal to
    /// the gap between the recording-FORM right edge and the window right
    /// edge. The agent content now begins in the right band; the island form
    /// grows only by each face's EXTENSION, so the recording-form right edge
    /// sits at `windowRight - rightAgentZoneWidth + agentWingRecordingExtension`,
    /// leaving a trailing pad of `rightAgentZoneWidth -
    /// agentWingRecordingExtension`. The surrounding `.frame(alignment:
    /// .topTrailing)` pins the padded box to the window's top-right. This
    /// reproduces `IslandAgentHitZones`' `answerRect` exactly (both key off
    /// `agentWingRecordingExtension`) so the rendered panel and the hit zone
    /// coincide — clicks land.
    private var agentAnswerLayer: some View {
        IslandAgentAnswerPanelView(
            responseStore: agentFlow.responseStoreForViews,
            linksSelection: agentLinksSelection,
            panelWidth: compactWidth
        )
        // Measure the rendered card height (before the layout paddings) and
        // report it so the answer hit-zone tracks the visible card — a fixed
        // reservation left a tall click-eating band below short answers.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onAgentAnswerHeightChange(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in
                        onAgentAnswerHeightChange(height)
                    }
            }
        )
        .padding(.top, compactHeight + IslandFrameLayout.agentWingGap)
        // Trailing pad = the full wing zone, so the card's right edge lands on
        // the pill's right edge. With the card sized to the pill width, that
        // centres it under the notch — matching `IslandAgentHitZones.answerRect`.
        .padding(.trailing, IslandFrameLayout.rightAgentZoneWidth)
        .frame(
            width: outerWidth,
            height: outerHeight,
            alignment: .topTrailing
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        ))
    }

    /// The left morph slot is reserved but empty: keeping the width constant
    /// is what stops the island content from re-laying-out when the window
    /// frame changes (see `outerWidth`).
    @ViewBuilder
    private var notificationSlot: some View {
        EmptyView()
    }

    /// The island proper (camera body + compact row + hover panel). Extracted
    /// from `body` so the left morph slot can sit beside it in an `HStack`.
    private var islandStack: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                IslandCompactRow(
                    compactHeight: compactHeight,
                    notchWidth: notchWidth,
                    orbMode: orbMode,
                    orbLevels: orbLevels,
                    agentPhase: appState.agentPhase,
                    showsTriggerOrbs: isHoverExpanded,
                    meetingSuggestionDeadline: appState.meetingSuggestionActive
                        ? appState.meetingSuggestionDeadline
                        : nil,
                    meetingRecording: meetingRecordingSnapshot,
                    updateAvailable: appState.updateAvailable,
                    justUpdatedVersion: appState.justUpdatedVersion,
                    onJustUpdatedDismiss: {
                        appState.updateController?.dismissJustInstalledIndicator()
                    },
                    dropModeStatus: dropModeStatus,
                    agentFlowActive: agentFlow.isActive,
                    nowPlaying: compactNowPlaying,
                    showsHideButton: isHovering,
                    islandHoverWidgetsHidden: displayPreferences.hideIslandHoverWidgets,
                    onToggleIslandHoverWidgets: {
                        displayPreferences.hideIslandHoverWidgets.toggle()
                    },
                    actions: actions
                )
                .frame(width: compactWidth, height: compactHeight, alignment: .top)
                // Pill body: a SINGLE flat-black surface, merging with the
                // hardware notch without an extra rim. Top corners are square
                // (flush with the screen edge); the bottom corners round
                // slightly, like a camera cutout. Drawn as a `.background`
                // (not a ZStack child) so it can stretch RIGHTWARD past the
                // compact frame when the agent is active WITHOUT widening the
                // compact row's layout — `alignment: .leading` pins it to the
                // capsule's left edge, so the camera never moves; only the
                // right edge and its rounded bottom-trailing corner travel as
                // the island grows. The agent phase content is laid over the
                // extension below, so there is no separate wing background and
                // no hairline seam: the island reads as one shape growing.
                // (The hover panel remains a separate detached drawer below —
                // see the `isHoverExpanded` block.)
                .background(alignment: .leading) {
                    // Static host frame at the WIDEST form — only the
                    // CAShapeLayer's path inside morphs, so width growth is
                    // pure render-server work (see `IslandCameraSurface`).
                    IslandCameraSurface(
                        compactWidth: compactWidth,
                        compactHeight: compactHeight,
                        meetingSuggestionActive: appState.meetingSuggestionActive,
                        trailingExtension: activeWingExtension,
                        // Snap the surface for acting and per-keystroke composer
                        // growth (see `wingSnapsWidth`) so the black wing never
                        // lags behind the text and leaks it past the capsule.
                        animatesWidthChange: !wingSnapsWidth
                    )
                    .frame(
                        width: IslandFrameLayout.mergedCapsuleWidth(
                            compactWidth: compactWidth,
                            extension: IslandFrameLayout.agentWingExtension(
                                faceWidth: IslandFrameLayout.agentWingComposingWidth
                            )
                        ),
                        height: compactHeight,
                        alignment: .leading
                    )
                }
                // Hover trigger zone = compact pill rectangle ONLY. The
                // bottom area (where the hover panel renders once expanded)
                // is intentionally excluded — see `panelHovering` attached
                // to the panel itself below. `contentShape(Rectangle())`
                // forces the hit region to be the rectangular frame instead
                // of leaking out through the rendered child views' tracking
                // areas (NSTrackingArea is window-driven, bypassing the
                // outer NSHostingView's `hitTest:` filter).
                .contentShape(Rectangle())
                .onHover { hovering in
                    let next = hovering && IslandHoverPolicy.allowsExpansion(
                        meetingSuggestionActive: appState.meetingSuggestionActive,
                        meetingRecordingActive: appState.meetingRecordingActive
                    )
                    if next {
                        dropMode = actions.currentDropMode()
                        selectedLanguage = actions.currentLanguage()
                        targetLanguage = actions.currentTargetLanguage()
                    }
                    pillHovering = next
                }
                // Agent phase content (waveform / ticker / pulse / text field)
                // drawn INSIDE the stretched surface. It BEGINS in the right
                // band (where the passive hints begin — just past the notch
                // gap) and runs into the rightward extension, so the dead
                // black gap between the notch and the content is gone.
                // Applied AFTER the compact pill's `contentShape`/`onHover` so
                // the wing's own interactivity (composing TextField clicks,
                // routed via the AppKit `IslandAgentHitZones.wingRect`) stays
                // fully independent of the pill's rectangular hover shape —
                // exactly as when the wing was a separate sibling.
                //
                // Right-aligned to the STRETCHED form's right edge: the
                // leading-anchored face (laid out at `activeWingFaceWidth`) is
                // offset by `compactWidth + extension - faceWidth`. For every
                // face ≥ the band width this resolves to `compactWidth -
                // agentWingInCapsuleWidth` = band-left, so the content's left
                // edge sits exactly at the end of the notch gap (never under
                // the notch) and its right edge meets the form's right edge.
                // The short `.opacity` fade reads as the island filling in;
                // the width pop rides the body's `wingFaceID` spring.
                .overlay(alignment: .leading) {
                    // The clip container lives UNCONDITIONALLY (even with no
                    // wing) so its width is always an animatable change on an
                    // EXISTING view — riding the same springs as the black
                    // surface. With the clip inside the `if`, the freshly
                    // inserted face arrived at its FINAL width in frame one
                    // while the surface was still springing wider:
                    // "listening…" floated over the wallpaper past the
                    // island's edge, then the field caught up.
                    ZStack(alignment: .topLeading) {
                        if agentFlow.wing != .hidden {
                            IslandAgentWingView(
                                wing: agentFlow.wing,
                                faceWidth: activeWingFaceWidth,
                                activityLabel: agentFlow.activityLabel,
                                recordingProviderBrand: agentFlow.recordingProviderBrand,
                                height: compactHeight,
                                onComposingFocusChange: onAgentKeyboardFocusChange,
                                isGoogle: agentFlow.activeSourceIsGoogle
                            )
                            .frame(height: compactHeight, alignment: .top)
                            .offset(x: compactWidth + activeWingExtension - activeWingFaceWidth)
                            // The surface LEADS, the content FOLLOWS: the
                            // form grows EMPTY, then the face fades in
                            // (`IslandWingRevealCoordinator`). Explicit state
                            // — not a `.transition` — so no transaction can
                            // re-time it into a half-clipped "listenin|"
                            // frame; the first ~70pt of every face sit inside
                            // the COMPACT capsule where the travelling clip
                            // edge can never hide them anyway.
                            .opacity(wingReveal.revealed ? 1 : 0)
                            .transition(.identity)
                        }
                    }
                    // Clip the face to the SAME shape the black surface
                    // (`IslandCameraSurface`) is drawing this frame — same
                    // width formula, same radii, same transaction — so face
                    // content can never paint past the island's edge, no
                    // matter how the insertion and the width springs
                    // interleave (or stall on a busy main thread).
                    .frame(
                        width: IslandFrameLayout.mergedCapsuleWidth(
                            compactWidth: compactWidth,
                            extension: activeWingExtension
                        ),
                        height: compactHeight,
                        alignment: .topLeading
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: IslandFrameLayout.cameraTopCornerRadius,
                            bottomLeadingRadius: IslandFrameLayout.cameraBottomCornerRadius(
                                compactHeight: compactHeight,
                                meetingSuggestionActive: appState.meetingSuggestionActive
                            ),
                            bottomTrailingRadius: IslandFrameLayout.cameraBottomCornerRadius(
                                compactHeight: compactHeight,
                                meetingSuggestionActive: appState.meetingSuggestionActive
                            ),
                            topTrailingRadius: IslandFrameLayout.cameraTopCornerRadius,
                            style: .continuous
                        )
                    )
                    .allowsHitTesting(agentFlow.wing != .hidden)
                }

                if isHoverExpanded {
                    VStack(spacing: 0) {
                        // Transparent gap between the island and the detached
                        // drawer. Kept INSIDE the panel's hover/hit zone so the
                        // cursor can travel island -> gap -> tiles without the
                        // expansion collapsing mid-traverse. When the music
                        // strip is shown it uses a smaller `musicStripTopGap`
                        // so the strip sits tighter under the island; the
                        // hover panel below absorbs the reclaimed pixels (its
                        // frame subtracts the same gap), so the total drawer
                        // height stays `activeHoverPanelHeight`.
                        Color.clear
                            .frame(height: showsHoverMusicStrip
                                ? IslandDropModeControl.musicStripTopGap
                                : IslandDropModeControl.detachedPanelGap)

                        // Hover-gated Now Playing player strip. Lives in the
                        // gap region BETWEEN the compact island and the hover
                        // panel — at the top of the drawer, above the panel.
                        // Present ONLY while hover-expanded AND a track is
                        // active. Its transport buttons are hit-testable
                        // through the existing hover band-height plumbing
                        // (the band grows by `musicStripHeight` while a track
                        // is active — see `hoverPanelHeight(for:musicActive:)`),
                        // so no dedicated always-on hit zone is needed.
                        if let nowPlaying = hoverNowPlaying {
                            IslandMusicStripView(
                                snapshot: nowPlaying,
                                width: compactWidth,
                                hovered: appState.hoveredMusicTransport,
                                onPrevious: actions.musicPrevious,
                                onPlayPause: actions.musicPlayPause,
                                onNext: actions.musicNext
                            )
                            .frame(
                                width: compactWidth,
                                height: IslandDropModeControl.musicStripHeight,
                                alignment: .top
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))

                            // Gap separating the player card from the controls
                            // panel below so they read as two distinct floating
                            // cards (they used to sit flush, rounded corners
                            // colliding). The band height accounts for this gap
                            // (`hoverPanelHeight(for:musicActive:)`), so the panel
                            // keeps its full size — only the drawer grows.
                            Color.clear
                                .frame(height: IslandDropModeControl.musicStripBottomGap)
                        }

                        IslandDropModeHoverPanel(
                            mode: dropMode,
                            selectedLanguage: selectedLanguage,
                            targetLanguage: targetLanguage,
                            panelMode: $hoverPanelMode,
                            hoverStore: HoverLayoutStore.shared,
                            hotkeys: HotkeyPreferences.shared,
                            vocabularyViewModel: vocabularyViewModel,
                            fillerViewModel: fillerViewModel,
                            caseViewModel: caseViewModel,
                            onToggle: {
                                dropMode = actions.toggleDropMode()
                                showDropModeStatus(dropMode)
                            },
                            onOpenSettings: actions.openSettings,
                            onOpenHotkeys: actions.openHotkeys,
                            onOpenHistory: actions.openHistory,
                            historyCards: actions.historyCards,
                            onSelectHistoryMode: actions.selectHistoryMode,
                            onCopyHistoryCard: actions.copyHistoryCard,
                            onHistoryPreviewAnchorChange: { card, frame in
                                if let frame {
                                    historyPreviewAnchor = HistoryHoverPreviewAnchor(
                                        card: card, rowFrame: frame
                                    )
                                } else if historyPreviewAnchor?.card == card {
                                    historyPreviewAnchor = nil
                                }
                            },
                            onPasteHistoryCard: actions.pasteHistoryCard,
                            historyPasteTargetName: actions.historyPasteTargetName,
                            onOpenNotes: actions.openMeetings,
                            onOpenHelp: actions.openHelp,
                            onQuit: actions.quitApplication,
                            onToggleMeetingRecord: actions.toggleMeetingRecord,
                            onSelectLanguage: { language in
                                selectedLanguage = language
                                actions.setLanguage(language)
                                hoverPanelMode = .controls
                            },
                            onSelectOutputLanguage: { language in
                                targetLanguage = language
                                actions.setTargetLanguage(language)
                                hoverPanelMode = .controls
                            }
                        )
                        .frame(
                            width: compactWidth,
                            height: activeHoverPanelHeight
                                // Subtract the ACTUAL top gap used above (the
                                // music-strip case uses the smaller
                                // `musicStripTopGap`), so the panel reclaims
                                // those pixels and the VStack still sums to
                                // `activeHoverPanelHeight`.
                                - (showsHoverMusicStrip
                                    ? IslandDropModeControl.musicStripTopGap
                                    : IslandDropModeControl.detachedPanelGap)
                                // Strip + the gap below it that separates the
                                // player card from this panel (both counted into
                                // the band height), so the panel keeps full size.
                                - (showsHoverMusicStrip
                                    ? IslandDropModeControl.musicStripHeight
                                        + IslandDropModeControl.musicStripBottomGap
                                    : 0)
                        )
                        // Own detached glass background with uniform rounding —
                        // the panel is its own floating surface now, not merged
                        // into the island.
                        .background {
                            if hoverPanelMode == .history {
                                Color.clear
                            } else {
                                IslandDetachedHoverPanelBackground()
                            }
                        }
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: IslandDropModeControl.detachedPanelCornerRadius,
                                style: .continuous
                            )
                        )
                    }
                    .frame(width: compactWidth, height: activeHoverPanelHeight)
                    // Hover trigger zone for the lower panel (gap + drawer as
                    // one hit zone) — only present once expansion has already
                    // happened. Keeps the expanded state alive while the cursor
                    // travels from the compact pill down through the gap into
                    // the tile grid (and to its children: Row-1 PDF orbs,
                    // Row-2 visual tiles).
                    .contentShape(Rectangle())
                    .onHover { panelHovering = $0 }
                    // Asymmetric transition so the panel feels natural in
                    // both directions:
                    //   - insertion: rises from below — `move(edge: .bottom)`
                    //     means the panel's bottom edge is anchored, so it
                    //     appears underneath the compact island and slides
                    //     up into its final docked position. Reads like a
                    //     drawer pulling out from beneath the pill.
                    //   - removal: fades + shrinks in place toward the
                    //     compact island silhouette. The previous symmetric
                    //     `.move(edge: .top)` on removal made the panel
                    //     slide upward through / over the island, which
                    //     looked like a visual collision before it
                    //     disappeared.
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        )
                    )
                }
            }
        }
        .frame(
            width: compactWidth,
            height: compactHeight + activeHoverPanelHeight,
            alignment: .top
        )
        .coordinateSpace(name: Self.hoverZoneSpace)
        // Preview bubble for the hovered History row. Lives OUTSIDE the
        // clipped drawer (which would cut anything beyond its bounds) and
        // renders leftward into the window's permanently reserved left
        // notification zone (300pt ≥ bubble 280 + 8 gap). Purely visual:
        // hit-testing stays off so the window's mouse routing is untouched.
        .overlay(alignment: .topLeading) {
            if let anchor = historyPreviewAnchor,
               isHoverExpanded, hoverPanelMode == .history {
                HistoryHoverPreviewBubble(
                    card: anchor.card,
                    assetsDirectory: actions.historyAssetsDirectory()
                )
                .offset(
                    x: -(HistoryHoverPreviewPolicy.bubbleWidth + 8),
                    y: anchor.rowFrame.minY
                )
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: historyPreviewAnchor)
        .animation(
            Self.hoverExpansionAnimation(programmatic: appState.programmaticHoverExpansion),
            value: isHoverExpanded
        )
        .animation(
            Self.hoverExpansionAnimation(programmatic: appState.programmaticHoverExpansion),
            value: hoverPanelMode
        )
        // Re-resolve the gated `mouseExpanded` latch on every raw-hover edge.
        // The gate (ROO-259 bug B) requires the visible pill to OPEN but either
        // region to STAY open, so the drawer's fading hover band can't re-open a
        // closed drawer before the cursor reaches the pill.
        .onChange(of: pillHovering) { _, _ in recomputeMouseExpanded() }
        .onChange(of: panelHovering) { _, _ in recomputeMouseExpanded() }
        .onChange(of: isHovering) { _, newValue in
            onHoverChange(newValue && !displayPreferences.hideIslandHoverWidgets)
            if newValue {
                // Mouse takes over the drawer: drop the programmatic latch in both
                // directions. On exit it collapses the keyboard-opened drawer (D4);
                // on enter it hands animation control back to the hover path.
                appState.programmaticHoverExpansion = false
            } else {
                hoverPanelMode = .controls
                onKeyboardFocusRequest(false)
                // The mouse left the island: drop any programmatic (⌥N)
                // expansion so a keyboard-opened drawer collapses on mouse-exit
                // like a normal hover and never stays latched (D4).
                appState.programmaticHoverExpansion = false
            }
        }
        .onChange(of: hoverPanelMode) { _, newValue in
            onHoverPanelBandHeightChange(
                Self.hoverPanelHeight(
                    for: newValue,
                    musicActive: hoverNowPlaying != nil
                )
            )
            onKeyboardFocusRequest(isHoverExpanded && newValue.needsKeyboardFocus)
            if newValue != .history {
                historyPreviewAnchor = nil
            }
        }
        // A track starting / stopping while the island is hover-expanded
        // inserts / removes the player strip at the top of the drawer, so the
        // hover band must grow / shrink by the strip's height — report it the
        // same way History's tall band is reported (`onHoverPanelBandHeightChange`)
        // so the AppKit panel's hit-test band covers the strip's transport
        // buttons.
        .onChange(of: appState.nowPlaying != nil) { _, _ in
            onHoverPanelBandHeightChange(
                Self.hoverPanelHeight(
                    for: hoverPanelMode,
                    musicActive: hoverNowPlaying != nil
                )
            )
        }
        .onChange(of: displayPreferences.hideIslandHoverWidgets) { _, hidden in
            if hidden {
                hoverPanelMode = .controls
                onKeyboardFocusRequest(false)
                appState.programmaticHoverExpansion = false
                appState.hoveredMusicTransport = nil
            }
            onHoverChange(isHovering && !hidden)
            onHoverPanelBandHeightChange(
                Self.hoverPanelHeight(
                    for: hoverPanelMode,
                    musicActive: hoverNowPlaying != nil
                )
            )
        }
        .onChange(of: isHoverExpanded) { _, expanded in
            if !expanded {
                hoverPanelMode = .controls
                onKeyboardFocusRequest(false)
            }
            // Re-report the band height on every expand/collapse: a track may
            // already be active when the user first hovers (neither
            // `hoverPanelMode` nor `nowPlaying` changes then), so the strip's
            // band growth would otherwise never be reported and the panel's
            // hit band would be too short to cover the strip + the panel below
            // it.
            onHoverPanelBandHeightChange(
                Self.hoverPanelHeight(
                    for: hoverPanelMode,
                    musicActive: hoverNowPlaying != nil
                )
            )
        }
        // A Hover-slot ⌥N for an inline-panel tool lands here (D1). Honour it
        // only while expansion is allowed (D4) and the drawer is open; otherwise
        // the inline-panel action is ignored (`.inlinePanel` tiles need the
        // drawer). Action/navigate tools never set a request — they fire their
        // IslandActions closure directly in `AppDelegate`.
        .onChange(of: appState.programmaticHoverPanelRequest) { _, request in
            guard let request, isHoverExpanded else { return }
            hoverPanelMode = Self.panelMode(for: request.panel, mode: dropMode)
            // A repeat ⌥N while the drawer is already open leaves
            // `programmaticHoverExpansion` at true (true -> true is not a
            // change event), so the expansion onChange never re-fires and the
            // FIRST press's collapse timer would still govern — ⌥3 pressed
            // 3.5s after ⌥2 would collapse the just-opened History 0.5s in.
            // The request's monotonic token fires THIS handler on every press:
            // extend the window here. Gated on the programmatic flag — a
            // mouse-held drawer doesn't run the timer.
            if appState.programmaticHoverExpansion {
                armProgrammaticExpansionCollapse()
            }
        }
        // Programmatic (⌥N) expansion with no mouse hover: auto-collapse after a
        // short window so a keyboard-opened drawer never latches open when the
        // cursor is elsewhere. If the mouse enters meanwhile, `isHovering` keeps
        // it open and clearing this flag is harmless (the mouse governs).
        .onChange(of: appState.programmaticHoverExpansion) { _, isOn in
            guard isOn else {
                // Turning off: invalidate the pending deferred collapse so a
                // stale timer can't fire against a future expansion.
                programmaticExpansionCollapseGeneration += 1
                return
            }
            armProgrammaticExpansionCollapse()
        }
        // ⌥N Drop-Mode toggle: sync the tile's local state and show the same
        // transient right-band ON Smart/Fast status the tile click shows. The
        // monotonic token makes repeated toggles to the same mode re-fire.
        .onChange(of: appState.dropModeHotkeyToggle) { _, toggle in
            guard let toggle else { return }
            dropMode = toggle.mode
            showDropModeStatus(toggle.mode)
        }
        .onChange(of: appState.meetingSuggestionActive) { _, isActive in
            if isActive {
                pillHovering = false
                panelHovering = false
                hoverPanelMode = .controls
                onKeyboardFocusRequest(false)
                appState.programmaticHoverExpansion = false
            }
        }
        // No `.onChange(meetingRecordingActive)` reset here on purpose:
        // the user wants hover / drop / agent to keep working during
        // a meeting. Forcibly collapsing pillHovering + panelHovering
        // on recording start used to cascade into IslandPanel's
        // `acceptsExpandedHitTesting = false` (mouse events ignored
        // outside the compact band) which is exactly the symptom we
        // need to avoid. The meeting recording slot still owns its
        // visible area via `.contentShape(Capsule())` on the slot view,
        // and `meetingSuggestionActive` (the short pre-accept window)
        // keeps the existing reset so the suggestion pill is not
        // visually overrun.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Whytap Dynamic Island — \(accessibilityLabel)")
        // Critical: without `.ignoresSafeArea()` the NSHostingView
        // applies the screen's safeAreaInsets to its SwiftUI content,
        // pushing the pill BELOW the notch (we want it AT the notch).
        // `NSPrefersDisplaySafeAreaCompatibilityMode = false` in
        // Info.plist enables modern safe-area semantics; this modifier
        // is the per-view opt-out for those semantics.
        .ignoresSafeArea()
    }

    private var accessibilityLabel: String {
        if appState.meetingRecordingActive {
            return appState.meetingRecordingPaused
                ? "meeting recording paused"
                : "meeting recording"
        }
        if appState.meetingSuggestionActive {
            return "meeting suggestion"
        }

        switch islandState {
        case .idle:      return "idle"
        case .listening: return "listening"
        case .thinking:  return "thinking"
        case .textInput: return "text input"
        }
    }

    private func showDropModeStatus(_ mode: TranscriptionMode) {
        dropModeStatus = mode
        dropModeStatusGeneration += 1
        let generation = dropModeStatusGeneration

        DispatchQueue.main.asyncAfter(
            deadline: .now() + IslandDropModeControl.statusDisplaySeconds
        ) {
            guard dropModeStatusGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                dropModeStatus = nil
            }
        }
    }

    /// Arms (or re-arms) the programmatic-expansion auto-collapse window:
    /// bumps the generation so any pending deferred collapse goes stale, then
    /// schedules a fresh one. Shared by the expansion onChange (first ⌥N) and
    /// the panel-request onChange (every subsequent ⌥N), so switching panels
    /// extends the window instead of inheriting the first press's timer. The
    /// deferred block collapses only if the mouse never arrived.
    private func armProgrammaticExpansionCollapse() {
        programmaticExpansionCollapseGeneration += 1
        let generation = programmaticExpansionCollapseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.programmaticExpansionTimeout) {
            guard programmaticExpansionCollapseGeneration == generation else { return }
            if !isHovering {
                appState.programmaticHoverExpansion = false
            }
        }
    }
}

// MARK: - Right-band priority helper

/// Pure-function helper extracted from `IslandWrapRow` so its right-band
/// priority logic is unit-testable without instantiating SwiftUI views.
///
/// Priorities (top first):
///   - PA — agent flow (wing capsule + answer column) — preempts EVERYTHING
///   - P0 — meeting suggestion countdown / meeting recording slot
///   - P1 — update available pill (ROO-186 Stage 2)
///   - P2 — passive hints / trigger orbs (default state)
///
/// The agent flow sits above P0: while a wing or answer panel is on
/// screen the right band and the rightward window extension belong to the
/// agent, so the meeting recording slot, update pill, Drop Mode status,
/// passive hints, and trigger orbs all yield. (The meeting RECORDING
/// keeps running — only its right-band slot is hidden.)
///
/// `IslandWrapRow.hasPriorityRightState` / `showsUpdateAvailable`
/// delegate to these static functions so the view layer stays a thin
/// pass-through and the rules can be exhaustively covered in
/// `IslandWrapRowPriorityTests`.
enum IslandRightBandPriority {

    /// `true` iff at least one priority right-band slot (PA / P0 / P1 /
    /// Drop Mode status) is active — the trigger orbs / passive hints must
    /// yield to it. An active agent flow is itself a priority state even
    /// when every other slot is clear (the passive hints sit under the
    /// agent answer column and must stay hidden).
    static func hasPriorityRightState(
        showsMeetingCountdown: Bool,
        showsMeetingRecording: Bool,
        showsUpdateAvailable: Bool,
        showsDropModeStatus: Bool,
        agentFlowActive: Bool = false,
        showsMusic: Bool = false
    ) -> Bool {
        agentFlowActive
            || showsMeetingCountdown
            || showsMeetingRecording
            || showsUpdateAvailable
            || showsDropModeStatus
            || showsMusic
    }

    /// `true` iff the music wing should occupy the right band, replacing
    /// the passive hints. It sits just above the hints and below every
    /// other right-band slot: the agent flow (PA), the meeting countdown /
    /// recording (P0), the update pill (P1), and the transient Drop Mode
    /// status all preempt it. A track stays "active" while paused, so the
    /// wing persists across pause — only `musicActive` gates it, not play
    /// state.
    static func showsMusic(
        musicActive: Bool,
        showsMeetingCountdown: Bool,
        showsMeetingRecording: Bool,
        showsUpdateAvailable: Bool,
        showsDropModeStatus: Bool,
        agentFlowActive: Bool = false
    ) -> Bool {
        musicActive
            && !agentFlowActive
            && !showsMeetingCountdown
            && !showsMeetingRecording
            && !showsUpdateAvailable
            && !showsDropModeStatus
    }

    /// `true` iff the meeting recording slot should render in the right
    /// band. An active agent flow preempts it — the recording itself keeps
    /// running, only the slot is hidden so it does not collide with the
    /// agent surfaces.
    static func showsMeetingRecording(
        meetingRecordingNonNil: Bool,
        agentFlowActive: Bool = false
    ) -> Bool {
        meetingRecordingNonNil && !agentFlowActive
    }

    /// `true` iff the update pill itself should render. The agent flow
    /// (PA) and P0 meeting layers preempt the pill (`updateAvailable`
    /// value stays set on `AppState` but the pill is hidden); the pill
    /// re-appears once those clear, provided the user has not Skipped the
    /// version.
    static func showsUpdateAvailable(
        updateAvailableNonNil: Bool,
        showsMeetingCountdown: Bool,
        showsMeetingRecording: Bool,
        agentFlowActive: Bool = false
    ) -> Bool {
        updateAvailableNonNil
            && !agentFlowActive
            && !showsMeetingCountdown
            && !showsMeetingRecording
    }

    /// `true` iff the transient Drop Mode status should occupy the
    /// right-band notification slot. The agent flow, meeting state, and
    /// update notification all win because they own the band / are
    /// actionable; otherwise a recent Fast/Smart toggle briefly replaces
    /// passive hints / trigger orbs.
    static func showsDropModeStatus(
        dropModeStatusNonNil: Bool,
        showsMeetingCountdown: Bool,
        showsMeetingRecording: Bool,
        showsUpdateAvailable: Bool,
        agentFlowActive: Bool = false
    ) -> Bool {
        dropModeStatusNonNil
            && !agentFlowActive
            && !showsMeetingCountdown
            && !showsMeetingRecording
            && !showsUpdateAvailable
    }

    /// Hover trigger orbs are visible during the regular expanded hover
    /// state, but yield to every higher-priority right-band slot — the
    /// agent flow (PA), the meeting suggestion countdown (P0), an active
    /// meeting recording slot (P0), the update available pill (P1), and
    /// the transient Drop Mode status pill. The user can still hover the
    /// island to reach the lower drop-mode panel during a meeting; the
    /// orbs themselves just stay hidden so they do not visually collide
    /// with the meeting recording slot in the right band. (Agent flow
    /// additionally blocks expansion entirely — see
    /// `IslandHoverPolicy.allowsExpansion` — so `hoverExpanded` is already
    /// `false` then; the guard here is belt-and-suspenders.)
    static func showsHoverTriggerOrbs(
        hoverExpanded: Bool,
        showsMeetingCountdown: Bool = false,
        showsMeetingRecording: Bool = false,
        showsUpdateAvailable: Bool,
        showsDropModeStatus: Bool,
        agentFlowActive: Bool = false
    ) -> Bool {
        hoverExpanded
            && !agentFlowActive
            && !showsMeetingCountdown
            && !showsMeetingRecording
            && !showsUpdateAvailable
            && !showsDropModeStatus
    }

    /// `true` iff the update pill should render its two actionable icons.
    /// The reveal follows the island's hover-expanded state, not a tiny
    /// tracking area on the update pill itself, so hovering anywhere on the
    /// Dynamic Island opens the same actionable update surface.
    ///
    /// Actions are gated additionally on `isActionable`: while Sparkle
    /// is still downloading there is nothing to act on, so the pill stays
    /// compact even with the island hover panel open. Actionable stages
    /// are `.available` (download affordance) and `.readyToInstall`
    /// (restart affordance).
    static func showsUpdateActions(
        hoverExpanded: Bool,
        showsUpdateAvailable: Bool,
        isReadyToInstall: Bool,
        isAvailableToDownload: Bool = false
    ) -> Bool {
        hoverExpanded && showsUpdateAvailable && (isReadyToInstall || isAvailableToDownload)
    }
}

// MARK: - Shared top row (orb · notch gap · right band)

/// The "wrap-around-notch" row used as the entire compact pill content.
/// Three sections:
///
/// ```
/// [ orb (leftSideWidth) ][ notch gap (notchWidth) ][ right band (rightSideWidth) ]
/// ```
///
/// The middle gap is a `Spacer` of fixed `notchWidth` — leaves visual
/// room for the physical notch cutout while the surrounding pill
/// background continues across it (pill ZStack fills the full width).
///
/// The right side shows the passive hint at all times, yielding only to
/// genuine priority states (update pill, drop-mode status, meeting).
private struct IslandWrapRow: View {
    let compactHeight: CGFloat
    let notchWidth: CGFloat
    let orbMode: VoiceOrbMode
    let orbLevels: [Float]
    let agentPhase: AgentPhase
    let showsTriggerOrbs: Bool
    let meetingSuggestionDeadline: Date?
    let meetingRecording: IslandMeetingRecordingSnapshot?
    let updateAvailable: PendingUpdate?
    /// Display version of an update that just applied on the previous launch
    /// (variant A). When non-nil the transient "Updated" pill occupies the same
    /// P1 slot as `updateAvailable` (the two are mutually exclusive — one shows
    /// before restart, the other after). Mirrors `AppState.justUpdatedVersion`.
    let justUpdatedVersion: String?
    /// Dismisses the transient "Updated" pill on tap. Wiring calls
    /// `UpdateController.dismissJustInstalledIndicator()`.
    let onJustUpdatedDismiss: () -> Void
    let dropModeStatus: TranscriptionMode?
    /// `true` while the agent flow owns the right band + the rightward
    /// window extension — every right-band slot and the passive hints
    /// yield to it.
    let agentFlowActive: Bool
    /// Current track (playing or paused), or `nil` when nothing is active.
    /// Drives the music wing, which replaces the passive hints just above
    /// them in priority. Stage 1 publishes this on `AppState.nowPlaying`.
    let nowPlaying: NowPlayingSnapshot?
    /// Shows the eye toggle in the left side while the cursor is over the
    /// island. The button replaces the decorative orb only for hover.
    let showsHideButton: Bool
    /// Current state of the Dynamic Island eye toggle.
    let islandHoverWidgetsHidden: Bool
    /// Toggles the eye. Wired to `DisplayPreferences.hideIslandHoverWidgets`.
    let onToggleIslandHoverWidgets: () -> Void
    let actions: IslandActions

    private var showsMeetingCountdown: Bool {
        meetingSuggestionDeadline != nil && !agentFlowActive
    }

    private var showsMeetingRecording: Bool {
        IslandRightBandPriority.showsMeetingRecording(
            meetingRecordingNonNil: meetingRecording != nil,
            agentFlowActive: agentFlowActive
        )
    }

    /// Update pill visibility — the agent flow and P0 meeting layers
    /// preempt P1 update, per `IslandRightBandPriority`. The
    /// `AppState.updateAvailable` value stays set; the pill simply hides
    /// and re-appears once the higher-priority layer clears.
    private var showsUpdateAvailable: Bool {
        IslandRightBandPriority.showsUpdateAvailable(
            updateAvailableNonNil: updateAvailable != nil,
            showsMeetingCountdown: showsMeetingCountdown,
            showsMeetingRecording: showsMeetingRecording,
            agentFlowActive: agentFlowActive
        )
    }

    /// Transient post-relaunch "Updated" pill visibility (variant A). Shares the
    /// P1 update slot: it yields to the agent flow and the P0 meeting layers,
    /// exactly like `showsUpdateAvailable`. `updateAvailable` and
    /// `justUpdatedVersion` are mutually exclusive in practice (before vs after
    /// restart), so no tie-break between the two is needed.
    private var showsJustUpdated: Bool {
        IslandRightBandPriority.showsUpdateAvailable(
            updateAvailableNonNil: justUpdatedVersion != nil,
            showsMeetingCountdown: showsMeetingCountdown,
            showsMeetingRecording: showsMeetingRecording,
            agentFlowActive: agentFlowActive
        )
    }

    /// The P1 update slot is occupied by EITHER the in-flight update pill or the
    /// post-relaunch "Updated" pill. Lower-priority slots (music, drop-mode,
    /// free-tier, passive hints) yield to whichever is showing.
    private var updateSlotOccupied: Bool {
        showsUpdateAvailable || showsJustUpdated
    }

    private var showsDropModeStatus: Bool {
        IslandRightBandPriority.showsDropModeStatus(
            dropModeStatusNonNil: dropModeStatus != nil,
            showsMeetingCountdown: showsMeetingCountdown,
            showsMeetingRecording: showsMeetingRecording,
            showsUpdateAvailable: updateSlotOccupied,
            agentFlowActive: agentFlowActive
        )
    }

    /// The music wing replaces the passive hints when a track is active
    /// and no higher-priority slot owns the band. It sits just above the
    /// hints, below every other slot.
    private var showsMusic: Bool {
        IslandRightBandPriority.showsMusic(
            musicActive: nowPlaying != nil,
            showsMeetingCountdown: showsMeetingCountdown,
            showsMeetingRecording: showsMeetingRecording,
            showsUpdateAvailable: updateSlotOccupied,
            showsDropModeStatus: showsDropModeStatus,
            agentFlowActive: agentFlowActive
        )
    }

    private var hasPriorityRightState: Bool {
        IslandRightBandPriority.hasPriorityRightState(
            showsMeetingCountdown: showsMeetingCountdown,
            showsMeetingRecording: showsMeetingRecording,
            showsUpdateAvailable: updateSlotOccupied,
            showsDropModeStatus: showsDropModeStatus,
            agentFlowActive: agentFlowActive,
            showsMusic: showsMusic
        )
    }

    private var showsUpdateActions: Bool {
        IslandRightBandPriority.showsUpdateActions(
            hoverExpanded: showsTriggerOrbs,
            showsUpdateAvailable: showsUpdateAvailable,
            isReadyToInstall: isUpdateReadyToInstall,
            isAvailableToDownload: isUpdateAvailableToDownload
        )
    }

    private var isUpdateReadyToInstall: Bool {
        guard let stage = updateAvailable?.stage else { return false }
        if case .readyToInstall = stage { return true }
        return false
    }

    private var isUpdateAvailableToDownload: Bool {
        guard let stage = updateAvailable?.stage else { return false }
        if case .available = stage { return true }
        return false
    }

    /// Stage tag forwarded to the pill. The full `PendingUpdate.Stage`
    /// carries closures on `.available` and `.readyToInstall`, which is
    /// awkward for view equality; the pill consumes a closure-free enum
    /// instead.
    private var pillStage: IslandUpdateAvailablePillStage {
        guard let stage = updateAvailable?.stage else { return .downloading }
        switch stage {
        case .available: return .available
        case .downloading: return .downloading
        case .readyToInstall: return .readyToInstall
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if showsHideButton {
                    IslandHideButton(
                        compactHeight: compactHeight,
                        isHidden: islandHoverWidgetsHidden,
                        action: onToggleIslandHoverWidgets
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    IslandOrbSlot(
                        compactHeight: compactHeight,
                        orbMode: orbMode,
                        orbLevels: orbLevels
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(width: IslandFrameLayout.leftSideWidth)

            Spacer()
                .frame(width: notchWidth)

            ZStack {
                IslandPassiveHintsRolling(compactHeight: compactHeight)
                    .opacity(hasPriorityRightState ? 0 : 1)
                    .scaleEffect(hasPriorityRightState ? 0.96 : 1)
                    // Pin the gate's own animation so the hide is not driven
                    // by the body's `wingFaceID` spring (see
                    // `passiveHintGateAnimation`).
                    .animation(
                        IslandView.passiveHintGateAnimation(hasPriorityRightState: hasPriorityRightState),
                        value: hasPriorityRightState
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(hasPriorityRightState)

                if showsMeetingCountdown, let meetingSuggestionDeadline {
                    IslandMeetingCountdownView(
                        deadline: meetingSuggestionDeadline,
                        duration: MeetingsConfig.pillDecisionTimeoutSeconds,
                        compactHeight: compactHeight
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if showsMeetingRecording, meetingSuggestionDeadline == nil, let meetingRecording {
                    IslandMeetingRecordingSlotView(
                        snapshot: meetingRecording,
                        onStop: actions.stopMeetingRecording
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    // Clip the slot's hit region to its visible capsule
                    // shape so it owns clicks only on the timer + Stop
                    // button area, not the transparent padding around it
                    // that SwiftUI's default frame-based hit-test would
                    // otherwise claim. Without this, the slot's frame
                    // swallows hover events in the right band and the
                    // parent pill row's `.onHover` never fires — drop /
                    // agent hover-helper and the island's expansion to
                    // the hover panel both go silent for the entire
                    // duration of the meeting. Mirrors the pattern used
                    // by `IslandUpdateAvailablePill` (also right-band).
                    .contentShape(Capsule())
                }

                if showsUpdateAvailable, let updateAvailable {
                    IslandUpdateAvailablePill(
                        displayVersion: updateAvailable.displayVersion,
                        stage: pillStage,
                        hoverExpanded: showsUpdateActions,
                        onDownload: { updateAvailable.startDownload() },
                        onSkip: { updateAvailable.skip() }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if showsJustUpdated, let justUpdatedVersion {
                    IslandJustUpdatedPill(
                        displayVersion: justUpdatedVersion,
                        onDismiss: onJustUpdatedDismiss
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if showsDropModeStatus, let dropModeStatus {
                    IslandDropModeStatusView(mode: dropModeStatus)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                if showsMusic, let nowPlaying {
                    IslandMusicWingView(snapshot: nowPlaying)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .contentShape(Capsule())
                }
            }
            .frame(width: IslandFrameLayout.rightSideWidth, alignment: .center)
        }
    }
}

// MARK: - Compact row

private struct IslandCompactRow: View {
    let compactHeight: CGFloat
    let notchWidth: CGFloat
    let orbMode: VoiceOrbMode
    let orbLevels: [Float]
    let agentPhase: AgentPhase
    let showsTriggerOrbs: Bool
    let meetingSuggestionDeadline: Date?
    let meetingRecording: IslandMeetingRecordingSnapshot?
    let updateAvailable: PendingUpdate?
    let justUpdatedVersion: String?
    let onJustUpdatedDismiss: () -> Void
    let dropModeStatus: TranscriptionMode?
    let agentFlowActive: Bool
    let nowPlaying: NowPlayingSnapshot?
    let showsHideButton: Bool
    let islandHoverWidgetsHidden: Bool
    let onToggleIslandHoverWidgets: () -> Void
    let actions: IslandActions

    var body: some View {
        IslandWrapRow(
            compactHeight: compactHeight,
            notchWidth: notchWidth,
            orbMode: orbMode,
            orbLevels: orbLevels,
            agentPhase: agentPhase,
            showsTriggerOrbs: showsTriggerOrbs,
            meetingSuggestionDeadline: meetingSuggestionDeadline,
            meetingRecording: meetingRecording,
            updateAvailable: updateAvailable,
            justUpdatedVersion: justUpdatedVersion,
            onJustUpdatedDismiss: onJustUpdatedDismiss,
            dropModeStatus: dropModeStatus,
            agentFlowActive: agentFlowActive,
            nowPlaying: nowPlaying,
            showsHideButton: showsHideButton,
            islandHoverWidgetsHidden: islandHoverWidgetsHidden,
            onToggleIslandHoverWidgets: onToggleIslandHoverWidgets,
            actions: actions
        )
    }
}

// MARK: - Meeting countdown

private struct IslandMeetingCountdownView: View {
    let deadline: Date
    let duration: TimeInterval
    let compactHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 10.0)) { context in
            let size = IslandMeetingCountdown.circleSize(forCompactHeight: compactHeight)
            let remaining = IslandMeetingCountdown.remainingSeconds(
                now: context.date,
                deadline: deadline
            )
            let progress = IslandMeetingCountdown.progress(
                now: context.date,
                deadline: deadline,
                duration: duration
            )

            ZStack {
                Circle()
                    .stroke(
                        Color.white.opacity(IslandMeetingCountdown.backgroundRingOpacity),
                        lineWidth: IslandMeetingCountdown.ringLineWidth
                    )

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.white.opacity(IslandMeetingCountdown.foregroundRingOpacity),
                        style: StrokeStyle(
                            lineWidth: IslandMeetingCountdown.ringLineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))

                Text("\(remaining)")
                    .font(.system(
                        size: IslandMeetingCountdown.textFontSize,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: size, height: size)
            .offset(y: IslandMeetingCountdown.verticalOffset)
            .accessibilityLabel("Meeting suggestion expires in \(remaining) seconds")
        }
    }
}

// MARK: - Drop mode status

private struct IslandDropModeStatusView: View {
    let mode: TranscriptionMode

    var body: some View {
        HStack(spacing: 4) {
            IslandDropModeStatusActiveBadge()

            Text(IslandDropModeControl.statusModeLabel(for: mode))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop mode \(IslandDropModeControl.statusAccessibilityLabel(for: mode))")
    }
}

private struct IslandDropModeStatusActiveBadge: View {
    private var activeColor: Color {
        Color(
            red: IslandDropModeStatusStyle.activeRed,
            green: IslandDropModeStatusStyle.activeGreen,
            blue: IslandDropModeStatusStyle.activeBlue
        )
        .opacity(IslandDropModeStatusStyle.activeOpacity)
    }

    var body: some View {
        Text(IslandDropModeControl.statusActiveLabel)
            .font(.system(size: 7.4, weight: .bold, design: .rounded))
            .foregroundStyle(activeColor)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(
                width: IslandDropModeStatusStyle.activeRingSize,
                height: IslandDropModeStatusStyle.activeRingSize
            )
            .overlay {
                Circle()
                    .stroke(
                        activeColor.opacity(0.68),
                        lineWidth: IslandDropModeStatusStyle.activeRingLineWidth
                    )
            }
    }
}

// MARK: - Meeting recording slot

private struct IslandMeetingRecordingSlotView: View {
    let snapshot: IslandMeetingRecordingSnapshot
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMeetingRecordingSlot.verticalSpacing) {
            HStack(spacing: 0) {
                Text(IslandMeetingRecordingSlot.formattedElapsed(snapshot.duration))
                    .font(.system(
                        size: IslandMeetingRecordingSlot.timerFontSize,
                        weight: .semibold,
                        design: .monospaced
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(snapshot.isPaused ? 0.56 : 0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 4)

                IslandMeetingRecordingStopButton(action: onStop)
            }
            .frame(
                width: IslandMeetingRecordingSlot.width,
                height: IslandMeetingRecordingSlot.topHeight
            )

            IslandMeetingRecordingWaveform(
                levels: snapshot.levels,
                isPaused: snapshot.isPaused
            )
            .frame(
                width: IslandMeetingRecordingSlot.width,
                height: IslandMeetingRecordingSlot.waveHeight
            )
        }
        .frame(
            width: IslandMeetingRecordingSlot.width,
            height: IslandMeetingRecordingSlot.totalHeight,
            alignment: .leading
        )
        .offset(y: IslandMeetingRecordingSlot.verticalOffset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            snapshot.isPaused
                ? "Meeting recording paused, \(IslandMeetingRecordingSlot.formattedElapsed(snapshot.duration))"
                : "Meeting recording, \(IslandMeetingRecordingSlot.formattedElapsed(snapshot.duration))"
        )
    }
}

private struct IslandMeetingRecordingStopButton: View {
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button {
            // M4: user stopped the meeting recording.
            action()
        } label: {
            RoundedRectangle(
                cornerRadius: IslandMeetingRecordingSlot.stopCornerRadius,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.37, blue: 0.32),
                        Color(red: 1.0, green: 0.27, blue: 0.23),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: IslandMeetingRecordingSlot.stopCornerRadius,
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .frame(
                width: IslandMeetingRecordingSlot.stopButtonSize,
                height: IslandMeetingRecordingSlot.stopButtonSize
            )
            .shadow(
                color: Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.45),
                radius: 3,
                x: 0,
                y: 1
            )
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .help("Stop meeting recording")
        .accessibilityLabel("Stop meeting recording")
    }
}

struct IslandMeetingRecordingWaveform: View {
    let levels: [Double]
    let isPaused: Bool

    var body: some View {
        Canvas { context, size in
            let displayLevels = IslandMeetingRecordingSlot.displayLevels(levels)
            let count = displayLevels.count
            guard count > 0 else { return }
            let barWidth = IslandMeetingRecordingSlot.barWidth
            let gap = count > 1
                ? max(1, (size.width - barWidth * CGFloat(count)) / CGFloat(count - 1))
                : 0

            for index in 0..<count {
                let rawLevel = displayLevels[index]
                let level = IslandMeetingRecordingSlot.normalizedLevel(rawLevel)
                let height = max(barWidth, CGFloat(level) * size.height)
                let x = CGFloat(index) * (barWidth + gap)
                let y = (size.height - height) / 2

                let center = CGFloat(count - 1) / 2
                let distance = center == 0 ? 0 : abs(CGFloat(index) - center) / center
                let alpha = (isPaused ? 0.3 : 0.52) + (1 - distance) * (isPaused ? 0.18 : 0.4)
                let color = level > 0.82
                    ? Color(red: 1.0, green: 0.42, blue: 0.37)
                    : Color.white

                context.fill(
                    Path(roundedRect: CGRect(
                        x: x,
                        y: y,
                        width: barWidth,
                        height: height
                    ), cornerRadius: barWidth / 2),
                    with: .color(color.opacity(alpha))
                )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Passive hints

private struct IslandPassiveHintsRolling: View {
    let compactHeight: CGFloat
    // Observe the live hotkey config so a rebound shortcut (or the
    // Drop hold-Space gesture) flows into the passive hint rather than a
    // hardcoded glyph. Same singleton-resolving pattern as the floating
    // `KeybindingsHintView` / `ShortcutChips`.
    @ObservedObject private var hotkeys: HotkeyPreferences = .shared

    var body: some View {
        let hints = IslandPassiveHints.hints(for: hotkeys.configuration)
        TimelineView(.periodic(from: .now, by: IslandPassiveHints.cycleIntervalSeconds)) { context in
            let index = IslandPassiveHints.activeHintIndex(
                at: context.date.timeIntervalSinceReferenceDate,
                count: hints.count,
                interval: IslandPassiveHints.cycleIntervalSeconds
            )

            IslandPassiveHintView(
                hint: hints[index],
                compactHeight: compactHeight
            )
            .id(index)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .move(edge: .top))
                )
            )
            .animation(.easeInOut(duration: 0.24), value: index)
        }
    }
}

private struct IslandPassiveHintView: View {
    let hint: IslandPassiveHint
    let compactHeight: CGFloat

    private var fitScale: CGFloat {
        min(1, max(0.78, compactHeight / 33))
    }

    var body: some View {
        let keycapLayoutSize = hint.keycapLayoutSize(baseSize: KeycapView.compactSize)
        let shortcutRowHeight = hint.keycapLayoutHeight(baseSize: KeycapView.compactSize)

        VStack(spacing: 1) {
            Text(hint.title)
                .font(.system(size: IslandPassiveHints.titleFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            HStack(spacing: 3) {
                if let actionLabel = hint.actionLabel {
                    Text(actionLabel)
                        .font(.system(
                            size: IslandPassiveHints.secondaryTextFontSize,
                            weight: IslandPassiveHints.secondaryTextWeight.swiftUIFontWeight
                        ))
                        .foregroundStyle(.white.opacity(IslandPassiveHints.secondaryTextOpacity))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                switch hint.shortcutStyle {
                case .keycaps:
                    ForEach(Array(hint.keyContents.enumerated()), id: \.offset) { _, content in
                        let layoutWidth = hint.keycapLayoutWidth(
                            for: content,
                            baseSize: KeycapView.compactSize
                        )
                        KeycapView(content: content, compact: true)
                            .scaleEffect(hint.keyScale)
                            .frame(width: layoutWidth, height: keycapLayoutSize)
                    }

                case .inlineText:
                    IslandInlineShortcut(contents: hint.keyContents)
                }
            }
            .frame(height: max(10, shortcutRowHeight))
        }
        .frame(
            width: IslandFrameLayout.rightSideWidth,
            height: compactHeight,
            alignment: .center
        )
        .scaleEffect(fitScale)
        .offset(y: IslandPassiveHints.verticalOffset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [hint.title]
        if let actionLabel = hint.actionLabel {
            parts.append(actionLabel)
        }
        parts.append(contentsOf: hint.keyContents.map(\.spokenName))
        return parts.joined(separator: ", ")
    }
}

private struct IslandInlineShortcut: View {
    let contents: [KeycapContent]

    var body: some View {
        Text(contents.map(\.islandInlineShortcutText).joined(separator: " "))
            .font(.system(
                size: IslandPassiveHints.inlineShortcutFontSize,
                weight: IslandPassiveHints.inlineShortcutTextWeight.swiftUIFontWeight
            ))
            .foregroundStyle(.white.opacity(IslandPassiveHints.inlineShortcutTextOpacity))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

enum IslandHoverPanelMode: Equatable {
    case controls
    case languagePicker
    case outputLanguagePicker
    case history
    case vocabularyEditor
    case fillerEditor
    case caseVault

    var needsKeyboardFocus: Bool {
        switch self {
        case .languagePicker, .outputLanguagePicker, .history, .vocabularyEditor, .fillerEditor, .caseVault:
            return true
        case .controls:
            return false
        }
    }
}

private struct IslandDropModeHoverPanel: View {
    let mode: TranscriptionMode
    let selectedLanguage: AppLanguage?
    let targetLanguage: AppLanguage?
    @Binding var panelMode: IslandHoverPanelMode
    @ObservedObject var hoverStore: HoverLayoutStore
    /// Live hotkey config so the per-tile keycap hints render the CURRENT
    /// positional shortcut (⌥1..⌥5 by default) and update after a Save in
    /// Settings — `HotkeyPreferences` is an `ObservableObject` whose
    /// `@Published configuration` drives the redraw.
    @ObservedObject var hotkeys: HotkeyPreferences
    @ObservedObject var vocabularyViewModel: IslandVocabularyViewModel
    @ObservedObject var fillerViewModel: IslandFillerViewModel
    @ObservedObject var caseViewModel: CaseViewModel
    let onToggle: () -> Void
    let onOpenSettings: () -> Void
    let onOpenHotkeys: () -> Void
    let onOpenHistory: () -> HistoryStripMode
    let historyCards: (HistoryStripMode) async -> [HistoryStripCard]
    let onSelectHistoryMode: (HistoryStripMode) -> Void
    let onCopyHistoryCard: (HistoryStripCard) -> Void
    let onHistoryPreviewAnchorChange: (HistoryStripCard, CGRect?) -> Void
    let onPasteHistoryCard: (HistoryStripCard) -> Void
    let historyPasteTargetName: () -> String?
    let onOpenNotes: () -> Void
    let onOpenHelp: () -> Void
    let onQuit: () -> Void
    /// Manual meeting-record toggle (the "Record" tile). Defaults to a
    /// no-op so previews/tests don't need to wire it.
    var onToggleMeetingRecord: () -> Void = {}
    let onSelectLanguage: (AppLanguage?) -> Void
    let onSelectOutputLanguage: (AppLanguage?) -> Void

    /// Tile gap inside one row. 2pt keeps six 48pt tiles + 5 gaps = 298pt,
    /// matching the production 6-column hover grid under the compact pill.
    private static let tileSpacing: CGFloat = 2
    /// Inter-row gap. 6pt keeps the panel under `hoverPanelHeight`
    /// while leaving each row room for title + orb + label.
    private static let rowSpacing: CGFloat = 6

    /// Controls the staged fade-in of the inner controls so the panel
    /// container reads as "drawer slides up first, then its contents
    /// populate" instead of buttons riding the slide-in motion of the
    /// panel itself. Flipped to `true` from `.onAppear` so it fires on
    /// every fresh hover (the view is recreated each time the outer
    /// `if isHoverExpanded` flips). The delayed opacity animation is
    /// what produces the perceived two-stage entrance.
    @State private var contentsVisible = false
    @State private var outputFastNoticeVisible = false
    @State private var outputFastNoticeGeneration = 0
    /// Currently-hovered tile in the icons row; `nil` when nothing is hovered.
    @State private var hoveredTool: HoverTool? = nil
    @State private var historyMode: HistoryStripMode = .clipboard
    @State private var historyTargetAppName: String?
    /// Cards for the open History panel. Loaded OFF the main thread (the
    /// fetch is a synchronous SQLite read) and cached here so the SwiftUI
    /// `body` never blocks on disk I/O during the island's per-frame
    /// re-render. WHY: docs/decisions/2026-06-24-island-history-off-main.md
    @State private var historyCardsCache: [HistoryStripCard] = []

    var body: some View {
        ZStack {
            if panelMode == .languagePicker {
                IslandLanguagePickerPanel(
                    selectedLanguage: selectedLanguage,
                    onSelectLanguage: onSelectLanguage
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if panelMode == .outputLanguagePicker {
                IslandLanguagePickerPanel(
                    selectedLanguage: targetLanguage,
                    leadingOption: IslandLanguageControl.offOption(),
                    onSelectLanguage: onSelectOutputLanguage
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if panelMode == .history {
                HistoryHoverView(
                    mode: $historyMode,
                    cards: historyCardsCache,
                    targetAppName: historyTargetAppName,
                    onSelectMode: onSelectHistoryMode,
                    onCopy: onCopyHistoryCard,
                    onPreviewAnchorChange: onHistoryPreviewAnchorChange,
                    onPaste: { card in
                        onPasteHistoryCard(card)
                        panelMode = .controls  // release key before synth Cmd+V
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if panelMode == .vocabularyEditor {
                IslandVocabularyEditorPanel(
                    viewModel: vocabularyViewModel
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if panelMode == .fillerEditor {
                IslandFillerEditorPanel(
                    viewModel: fillerViewModel
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if panelMode == .caseVault {
                IslandCaseVaultPanel(
                    viewModel: caseViewModel
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                controls
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if outputFastNoticeVisible {
                Text(IslandOutputLanguageControl.smartOnlyNotice)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.16)))
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: panelMode)
        .onChange(of: panelMode) { _, newMode in
            if newMode == .outputLanguagePicker {
                outputFastNoticeGeneration += 1   // invalidate the pending auto-clear
                outputFastNoticeVisible = false
            }
            // History entry runs from the panelMode transition so BOTH the tile
            // click and the ⌥N Hover-slot hotkey (D1) capture the paste target
            // identically. The hotkey path only flips `panelMode = .history`
            // (via the parent's programmatic request) and never runs the tile's
            // click closure — without this the hotkey would open History with a
            // nil target and Enter-to-paste would silently no-op.
            if newMode == .history {
                historyMode = onOpenHistory()
                historyTargetAppName = historyPasteTargetName()
            }
        }
        // Two-stage hover entrance: the panel container's own
        // .transition(.move(edge: .bottom)) on the parent slides the
        // drawer up first; then the contents fade in over ~0.18s after
        // a small delay so the buttons appear to "fill in" inside the
        // settled drawer. Without the delay buttons rode the slide-in
        // motion of the panel and the eye read it as a single chunky
        // animation — Maxim asked for the staged feel.
        .opacity(contentsVisible ? 1 : 0)
        .animation(
            .easeOut(duration: 0.18).delay(0.16),
            value: contentsVisible
        )
        .onAppear { contentsVisible = true }
        // Load History cards off-main whenever the panel enters History or the
        // user switches the History tab. Keyed on the mode (nil when not in
        // History) so `.task` re-runs on every relevant change and cancels the
        // stale load. The body only ever reads `historyCardsCache`, so the
        // per-frame re-render never touches SQLite.
        .task(id: panelMode == .history ? historyMode : nil) {
            guard panelMode == .history else { return }
            historyCardsCache = await historyCards(historyMode)
        }
    }

    private func showOutputFastNotice() {
        withAnimation(.easeIn(duration: 0.14)) {
            outputFastNoticeVisible = true
        }
        outputFastNoticeGeneration += 1
        let generation = outputFastNoticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard outputFastNoticeGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                outputFastNoticeVisible = false
            }
        }
    }

    /// Split layout: icons-only row (top) + thin divider + hovered label strip (bottom).
    private var controls: some View {
        let circleSize: CGFloat = 70
        return VStack(spacing: 0) {
            // Tiles with labels — fills space above divider. The positional
            // ⌥N hint sits ABOVE the tile, gated by hover: opacity(1) only for
            // the tile under the cursor, opacity(0) for all others. Hidden via
            // opacity — NOT conditional removal — so the layout slot above every
            // tile stays reserved and tiles never jump vertically when the cursor
            // moves between them. The fade uses the same hoveredTool value and
            // easeInOut(0.15s) that drives the description strip below.
            HStack(spacing: 0) {
                ForEach(Array(hoverStore.slots.enumerated()), id: \.offset) { offset, tool in
                    Spacer(minLength: 0)
                    VStack(spacing: 1) {
                        hoverSlotHint(for: offset)
                            .opacity(hoveredTool == tool ? 1 : 0)
                            .animation(.easeInOut(duration: 0.15), value: hoveredTool)
                        tileView(for: tool, circleSize: circleSize)
                    }
                    .onHover { isHovering in
                        if isHovering { hoveredTool = tool }
                        else if hoveredTool == tool { hoveredTool = nil }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            // Description strip
            HStack(spacing: 0) {
                Text(hoveredTool.map { tool in
                    HoverToolRegistry.description(
                        for: tool,
                        mode: mode,
                        inputLanguage: selectedLanguage,
                        outputLanguage: targetLanguage
                    )
                } ?? "")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.15), value: hoveredTool)
                    .animation(.easeInOut(duration: 0.15), value: mode)
                    .animation(.easeInOut(duration: 0.15), value: selectedLanguage?.code)
                    .animation(.easeInOut(duration: 0.15), value: targetLanguage?.code)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                Spacer()
            }
            .frame(height: 32)
        }
    }

    /// Bare positional keycap overline for the Hover-slot shortcut at `offset`
    /// (0-based), sitting ABOVE the tile. Visible only when the cursor hovers
    /// over this tile — the callsite gates visibility via `opacity(hoveredTool
    /// == tool ? 1 : 0)` with `easeInOut(0.15s)`, matching the description
    /// strip animation. Hidden via opacity (not conditional removal) so the
    /// layout slot stays reserved and tiles never jump vertically on hover.
    /// Sourced from the LIVE `hotkeys.configuration` so it shows the current
    /// binding (default ⌥1..⌥5) and updates after a Save (D1, динамика).
    /// Built through the shared `HotkeyHintView` per `docs/hotkey.md` (glyphs
    /// from `HotkeyGlyph`, каждый keycap side-by-side, no "+"); `.keycaps`
    /// style gives each glyph its own mini rounded chip without an outer pill,
    /// so the hint reads as `[⌥][N]` — two distinct keys — rather than loose
    /// glyphs. `.tiny` size keeps the chips at ~half the compact cap height so
    /// they sit as a light positional mark above the tile.
    @ViewBuilder
    private func hoverSlotHint(for offset: Int) -> some View {
        let shortcuts = hotkeys.configuration.hoverSlotShortcuts
        if offset < shortcuts.count {
            HotkeyHintView(
                contents: shortcuts[offset].contents,
                style: .keycaps,
                size: .tiny
            )
        }
    }

    @ViewBuilder
    private func tileView(for tool: HoverTool, circleSize: CGFloat) -> some View {
        switch tool {
        case .dropMode:
            IslandHoverPanelControl(
                title: IslandDropModeControl.title,
                systemImage: IslandDropModeControl.systemImage(for: mode),
                pdfResource: nil,
                label: IslandDropModeControl.hoverTileLabel(for: mode),
                circleSize: circleSize,
                accessibilityLabel: [IslandDropModeControl.title, IslandDropModeControl.label(for: mode)].joined(separator: ", "),
                action: onToggle
            )
        case .clipboard:
            IslandHoverPanelControl(
                title: "History",
                systemImage: "clock.arrow.circlepath",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "History",
                centersIcon: true,
                // The paste-target + remembered-mode capture lives on the
                // panelMode -> .history transition (see onChange below) so the
                // click and the ⌥N hotkey enter History through one path (D1).
                action: {
                    panelMode = .history
                }
            )
        case .vocab:
            IslandHoverPanelControl(
                title: "Vocab",
                systemImage: "book",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Vocab",
                centersIcon: true,
                action: { panelMode = .vocabularyEditor }
            )
        case .caseVault:
            IslandHoverPanelControl(
                title: "Case",
                systemImage: "key.horizontal",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Case",
                centersIcon: true,
                action: { panelMode = .caseVault }
            )
        case .filler:
            IslandHoverPanelControl(
                title: "Filler",
                systemImage: "scissors",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Filler",
                centersIcon: true,
                action: { panelMode = .fillerEditor }
            )
        case .inputLang:
            IslandHoverPanelControl(
                title: IslandLanguageControl.title,
                systemImage: IslandLanguageControl.systemImage,
                pdfResource: nil,
                iconPresentation: IslandLanguageControl.hoverIconPresentation(for: selectedLanguage),
                label: IslandLanguageControl.hoverTileLabel(for: selectedLanguage),
                circleSize: circleSize,
                accessibilityLabel: "Choose input language",
                action: { panelMode = .languagePicker }
            )
        case .outputLang:
            IslandHoverPanelControl(
                title: IslandOutputLanguageControl.title,
                systemImage: IslandLanguageControl.systemImage,
                pdfResource: nil,
                iconPresentation: IslandLanguageControl.hoverIconPresentation(for: targetLanguage),
                label: IslandLanguageControl.hoverTileLabel(for: targetLanguage),
                circleSize: circleSize,
                accessibilityLabel: "Choose output language",
                isDimmed: mode == .fast,
                action: {
                    switch IslandOutputLanguageControl.tap(for: mode) {
                    case .openPicker:
                        panelMode = .outputLanguagePicker
                    case .showSmartOnlyNotice:
                        showOutputFastNotice()
                    }
                }
            )
        case .hotkeys:
            IslandHoverPanelControl(
                title: "Hotkeys",
                systemImage: "keyboard",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Open hotkeys settings",
                centersIcon: true,
                action: {
                    onOpenHotkeys()
                }
            )
        case .notes:
            IslandHoverPanelControl(
                title: "Notes",
                systemImage: "note.text",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Open meeting notes",
                centersIcon: true,
                action: {
                    onOpenNotes()
                }
            )
        case .meetingRecord:
            IslandHoverPanelControl(
                title: "Record",
                systemImage: "record.circle",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Start or stop meeting recording",
                centersIcon: true,
                action: {
                    onToggleMeetingRecord()
                }
            )
        case .quit:
            IslandHoverPanelControl(
                title: "Quit",
                systemImage: "rectangle.portrait.and.arrow.right",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Quit Whytap",
                centersIcon: true,
                action: {
                    onQuit()
                }
            )
        case .settings:
            IslandHoverPanelControl(
                title: "Settings",
                systemImage: "slider.horizontal.3",
                pdfResource: nil,
                label: nil,
                circleSize: circleSize,
                accessibilityLabel: "Settings",
                centersIcon: true,
                action: {
                    onOpenSettings()
                }
            )
        }
    }
}

struct IslandLanguagePickerPanel: View {
    let selectedLanguage: AppLanguage?
    var leadingOption: IslandLanguageOption = IslandLanguageControl.autoOption()
    let onSelectLanguage: (AppLanguage?) -> Void

    @State private var query = ""
    @State private var placeholderStartDate = Date()
    @State private var searchFocused = false
    @State private var expandedLanguageGroup: IslandLanguageOption?

    private var options: [IslandLanguageOption] {
        if isFiltering {
            return IslandLanguageControl.filteredOptions(query: query, leading: leadingOption)
        }

        if let expandedLanguageGroup {
            return IslandLanguageControl.variantOptions(for: expandedLanguageGroup)
        }

        return IslandLanguageControl.pickerOptions(
            selectedLanguage: selectedLanguage,
            leading: leadingOption
        )
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isChoosingLanguageVariant: Bool {
        expandedLanguageGroup != nil && !isFiltering
    }

    var body: some View {
        GeometryReader { proxy in
            let panelSize = proxy.size
            let inputFrame = IslandLanguagePickerLayout.inputFrame(
                panelSize: panelSize,
                optionCount: options.count,
                anchorsToFullGrid: !isFiltering
            )

            ZStack {
                IslandLanguageFlagCloud(
                    options: options,
                    selectedLanguage: selectedLanguage,
                    leadingOptionID: leadingOption.id,
                    panelSize: panelSize,
                    isFiltering: isFiltering,
                    isChoosingLanguageVariant: isChoosingLanguageVariant,
                    onActivateOption: activateOption
                )

                ZStack {
                    if query.isEmpty {
                        IslandLanguagePlaceholder(startDate: placeholderStartDate)
                    }

                    IslandLanguageSearchField(
                        text: $query,
                        isFocused: searchFocused
                    )
                }
                .padding(.horizontal, 8)
                .frame(width: inputFrame.width, height: inputFrame.height)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.18), lineWidth: 0.8)
                )
                .position(x: inputFrame.midX, y: inputFrame.midY)
                .accessibilityLabel("Search language")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            placeholderStartDate = Date()
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onChange(of: query) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                expandedLanguageGroup = nil
            }
        }
    }

    private func activateOption(_ option: IslandLanguageOption) {
        guard !isFiltering, option.hasLanguageVariants else {
            expandedLanguageGroup = nil
            onSelectLanguage(option.language)
            return
        }

        expandedLanguageGroup = option
    }
}

@MainActor
private struct IslandLanguageSearchField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool

    func makeNSView(context: Context) -> IslandLanguageSearchTextView {
        let textView = IslandLanguageSearchTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.shouldAutoFocusOnWindowAttach = isFocused
        Self.configure(textView)
        return textView
    }

    func updateNSView(_ textView: IslandLanguageSearchTextView, context: Context) {
        context.coordinator.parent = self
        textView.delegate = context.coordinator
        textView.shouldAutoFocusOnWindowAttach = isFocused
        Self.configure(textView)

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let location = min(selectedRange.location, text.utf16.count)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func configure(_ textView: IslandLanguageSearchTextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = textView.languageCursorColor
        textView.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        textView.alignment = .center
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: textView.font as Any,
            .foregroundColor: textView.textColor as Any,
            .paragraphStyle: paragraphStyle,
        ]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IslandLanguageSearchField

        init(parent: IslandLanguageSearchField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string.replacingOccurrences(of: "\n", with: "")
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commandSelector == #selector(NSResponder.insertNewline(_:))
        }
    }
}

@MainActor
private final class IslandLanguageSearchTextView: NSTextView {
    var shouldAutoFocusOnWindowAttach = false

    var languageCursorColor: NSColor {
        NSColor(
            white: IslandLanguageInputStyle.cursorWhiteComponent,
            alpha: IslandLanguageInputStyle.cursorAlpha
        )
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shouldAutoFocusOnWindowAttach, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        guard flag else { return }
        var cursorRect = rect
        cursorRect.size.width = IslandLanguageInputStyle.cursorWidth
        cursorRect.origin.x = rect.midX - cursorRect.width / 2
        languageCursorColor.setFill()
        cursorRect.fill()
    }
}

private struct IslandLanguagePlaceholder: View {
    let startDate: Date

    var body: some View {
        TimelineView(
            .periodic(
                from: startDate,
                by: IslandLanguageControl.placeholderIntervalSeconds / 10
            )
        ) { context in
            Text(
                IslandLanguageControl.placeholder(
                    at: context.date.timeIntervalSince(startDate)
                )
            )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

private struct IslandLanguageFlagCloud: View {
    let options: [IslandLanguageOption]
    let selectedLanguage: AppLanguage?
    /// The id of the leading (neutral) option — "auto" for the input picker,
    /// "off" for the output picker. When `selectedLanguage` is nil, this
    /// option gets the selected highlight instead of always using "auto".
    let leadingOptionID: String
    let panelSize: CGSize
    let isFiltering: Bool
    let isChoosingLanguageVariant: Bool
    let onActivateOption: (IslandLanguageOption) -> Void

    var body: some View {
        let frames = isChoosingLanguageVariant
            ? IslandLanguagePickerLayout.variantFrames(panelSize: panelSize, count: options.count)
            : IslandLanguagePickerLayout.flagFrames(
                panelSize: panelSize,
                count: options.count,
                anchorsToFullGrid: !isFiltering
            )
        ZStack {
            ForEach(Array(options.prefix(frames.count).enumerated()), id: \.element.id) { index, option in
                IslandLanguageFlagChip(
                    option: option,
                    selected: isSelected(option),
                    enlarged: isFiltering,
                    showsLanguageLabel: isChoosingLanguageVariant,
                    action: {
                        onActivateOption(option)
                    }
                )
                .frame(width: frames[index].width, height: frames[index].height)
                .position(x: frames[index].midX, y: frames[index].midY)
            }
        }
    }

    private func isSelected(_ option: IslandLanguageOption) -> Bool {
        guard let selectedLanguage else {
            return option.id == leadingOptionID
        }
        return option.language?.code == selectedLanguage.code
    }
}

private struct IslandLanguageFlagChip: View {
    let option: IslandLanguageOption
    let selected: Bool
    let enlarged: Bool
    let showsLanguageLabel: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let usesCapsuleChrome = showsLanguageLabel
            || IslandLanguageFlagChipStyle.usesCapsuleChrome(for: option)

        chipContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Group {
                    if usesCapsuleChrome {
                        Capsule()
                            .fill(backgroundOpacity)
                    }
                }
            )
            .overlay(
                Group {
                    if usesCapsuleChrome {
                        Capsule()
                            .stroke(.white.opacity(selected ? 0.34 : 0.08), lineWidth: 0.7)
                    }
                }
            )
            .scaleEffect(hovering ? IslandLanguageFlagChipStyle.hoverScale(for: option) : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { action() }
            .animation(.easeOut(duration: 0.10), value: hovering)
            .accessibilityLabel(option.label)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var chipContent: some View {
        if showsLanguageLabel {
            Text(option.label)
                .font(.system(
                    size: IslandLanguageFlagChipStyle.variantLanguageFontSize,
                    weight: .medium
                ))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        } else {
            // Emoji flags everywhere — uniform across the ~99-language
            // set (the bundled PNG flags only covered ~44 countries).
            Text(option.flag)
                .font(.system(
                    size: IslandLanguageFlagChipStyle.fontSize(for: option, enlarged: enlarged),
                    weight: .semibold
                ))
                .foregroundStyle(.white.opacity(option.language == nil ? 0.82 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
    }

    private var backgroundOpacity: Color {
        if selected {
            return Color.white.opacity(0.22)
        }
        return Color.white.opacity(hovering ? 0.16 : 0.08)
    }
}

@MainActor
private enum IslandLanguageFlagAsset {
    private static let subdirectory = "LanguageFlags"
    private static var cache: [String: NSImage] = [:]

    static func image(for option: IslandLanguageOption) -> NSImage? {
        guard option.language != nil, let countryCode = option.countryCode else {
            return nil
        }

        let resourceName = IslandLanguageControl.flagAssetResourceName(
            forCountryCode: countryCode
        )
        if let cached = cache[resourceName] {
            return cached
        }

        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: subdirectory
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = false
        cache[resourceName] = image
        return image
    }
}

/// Single graphite tile inside the hover panel. It keeps the surrounding
/// layout fixed, while the squircle itself follows the cursor a few points
/// with a springy magnetic pull.
struct IslandHoverPanelControl: View {
    let title: String
    let systemImage: String
    /// Optional bundled-PDF resource name (without `.pdf` extension).
    /// When present, the tile renders the PDF orb directly and ignores
    /// `systemImage`; the white background circle is suppressed.
    let pdfResource: String?
    /// Optional dynamic icon body. Used by Language so the same control
    /// can show a planet in Auto mode and a selected-language flag
    /// inside the same orb footprint.
    var iconPresentation: IslandHoverIconPresentation? = nil
    /// Optional bottom label under the orb. Shown only for tiles whose
    /// current value differs from the column header (Drop Mode → Fast/Smart,
    /// Language → current language). For tiles where the title already
    /// describes the tile, pass `nil` so the label slot stays blank — the
    /// fixed-height frame keeps icons vertically aligned across the row.
    let label: String?
    let circleSize: CGFloat
    let accessibilityLabel: String
    /// When `true`, the icon is vertically centered in the area below the
    /// title and no bottom label slot is reserved — used for tiles whose
    /// title fully describes them (no value-label underneath). When
    /// `false` (default), layout is unchanged: title, icon, optional
    /// label stacked top-aligned with the original spacing.
    var centersIcon: Bool = false
    /// Renders the tile faded + non-emphasised. Used by Output Language in
    /// Fast mode, where the tile is inactive (tap shows a notice).
    var isDimmed: Bool = false
    /// When `true`, a small red unread dot sits on the tile's top-trailing
    /// edge. Used by the "Notifs" tile to flag unread notifications.
    var showsDot: Bool = false
    /// When `false`, the bottom label `Text` is omitted entirely and its
    /// reserved height collapses. Used by the no-label icons row in the
    /// split hover panel layout.
    var showsLabel: Bool = true
    let action: () -> Void

    /// Layout knobs sized so the 5-slot hover row fits inside the compact
    /// pill width while letting the visible circles read larger than the
    /// original compact controls.
    static let tileWidth: CGFloat = 55
    static let tileHeight: CGFloat = 72
    /// Fixed label slot so one-line and two-line tiles keep their orbs at the
    /// same vertical position: tile 44 + spacing 5 + label 19 = 68. Without a
    /// reserved slot a taller two-line label recenters the VStack and the orb
    /// drifts up ~5pt versus one-line tiles in the same row.
    static let labelHeight: CGFloat = 19

    /// Tile label text. Multi-word titles break one word per line
    /// ("Input Language" → "INPUT\nLANGUAGE"); single words stay on one line.
    static func displayTitle(_ title: String) -> String {
        title.uppercased().replacingOccurrences(of: " ", with: "\n")
    }

    @State private var hovering = false
    @State private var pull: CGSize = .zero
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.plain)
            .frame(width: Self.tileWidth, height: Self.tileHeight, alignment: .center)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovering = true
                    pull = IslandGraphiteHoverControlStyle.magneticPull(
                        location: location,
                        bounds: CGSize(width: Self.tileWidth, height: Self.tileHeight),
                        presentation: resolvedIconPresentation
                    )
                case .ended:
                    hovering = false
                    pull = .zero
                }
            }
            .modifier(IslandHoverPressEventsModifier(
                onPress: { pressed = true },
                onRelease: { pressed = false }
            ))
            .animation(.spring(response: 0.34, dampingFraction: 0.74), value: pull)
            .animation(.spring(response: 0.22, dampingFraction: 0.70), value: pressed)
            .animation(.easeOut(duration: 0.22), value: hovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 5) {
            graphiteTile
                .frame(
                    width: IslandGraphiteHoverControlStyle.tileSize,
                    height: IslandGraphiteHoverControlStyle.tileSize
                )
                .offset(pull)
                .scaleEffect(pressed ? 0.94 : 1)

            if showsLabel {
                Text(Self.displayTitle(title))
                    .font(.system(
                        size: IslandGraphiteHoverControlStyle.labelFontSize,
                        weight: .medium,
                        design: .monospaced
                    ))
                    .tracking(IslandGraphiteHoverControlStyle.labelTracking)
                    .foregroundStyle(hovering ? Color.white.opacity(0.94) : Color.white.opacity(0.50))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.54)
                    .frame(width: Self.tileWidth, height: Self.labelHeight, alignment: .top)
            }
        }
        .frame(width: Self.tileWidth, height: Self.tileHeight, alignment: .center)
        .opacity(isDimmed ? 0.4 : 1)
    }

    private var graphiteTile: some View {
        ZStack {
            Circle()
                .fill(tileFill)
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.40 : 0.22), lineWidth: 0.75))
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(colors: [.white.opacity(0.45), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 0.75
                        )
                        .blur(radius: 0.5)
                )
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.22),
                        radius: hovering ? 8 : 4, x: 0, y: hovering ? 4 : 2)

            iconView.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            if showsDot {
                Circle()
                    .fill(Color(red: 1.0, green: 0.27, blue: 0.23))   // iOS red (#ff453a)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1.5))
                    .offset(x: 1, y: -1)
            }
        }
    }

    private var tileFill: LinearGradient {
        return LinearGradient(
            colors: hovering
                ? [Color.white.opacity(0.22), Color.white.opacity(0.10)]
                : [Color.white.opacity(0.12), Color.white.opacity(0.045)],
            startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var iconView: some View {
        switch resolvedIconPresentation {
        case .pdfResource(let pdfResource):
            if let nsImage = IslandControlIcon.image(named: pdfResource) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackSystemIcon
            }

        case .systemImage(let systemImage):
            Image(systemName: systemImage)
                .font(.system(size: IslandGraphiteHoverControlStyle.iconFontSize, weight: .regular))
                .foregroundStyle(hovering ? Color.white : Color.white.opacity(0.78))
                .symbolRenderingMode(.monochrome)

        case .flag(let flag):
            Text(flag)
                .font(.system(size: IslandHoverPanelIconStyle.dynamicFlagFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.74)

        case .text(let text):
            Text(text)
                .font(.system(
                    size: IslandGraphiteHoverControlStyle.textIconFontSize,
                    weight: .semibold,
                    design: .monospaced
                ))
                .tracking(0.8)
                .foregroundStyle(hovering ? Color.white : Color.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(
                    width: IslandGraphiteHoverControlStyle.textIconFrameSize.width,
                    height: IslandGraphiteHoverControlStyle.textIconFrameSize.height
                )
                .offset(y: IslandGraphiteHoverControlStyle.textIconOpticalYOffset)
                .drawingGroup(opaque: false, colorMode: .linear)

        case .pdfRingedSystemImage(let ringResource, let systemImage):
            pdfRingedIcon(ringResource: ringResource) {
                Image(systemName: systemImage)
                    .font(.system(size: IslandHoverPanelIconStyle.ringSystemFontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }

        case .pdfRingedFlag(let ringResource, let flag):
            pdfRingedIcon(ringResource: ringResource) {
                Text(flag)
                    .font(.system(size: IslandHoverPanelIconStyle.ringFlagFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

        case .none:
            fallbackSystemIcon
        }
    }

    private var resolvedIconPresentation: IslandHoverIconPresentation? {
        iconPresentation ?? pdfResource.map(IslandHoverIconPresentation.pdfResource)
    }

    @ViewBuilder
    private func pdfRingedIcon<Content: View>(
        ringResource: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            if let nsImage = IslandControlIcon.image(named: ringResource) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
            }

            content()
                .frame(
                    width: circleSize * IslandHoverPanelIconStyle.ringContentScale,
                    height: circleSize * IslandHoverPanelIconStyle.ringContentScale
                )
        }
    }

    @ViewBuilder
    private func dynamicLanguageIcon<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(hovering ? 0.15 : 0.10))
            Circle()
                .stroke(
                    Color.white.opacity(hovering ? 0.32 : 0.18),
                    lineWidth: 0.8
                )
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var fallbackSystemIcon: some View {
        Image(systemName: systemImage)
            .font(.system(size: IslandHoverPanelIconStyle.fallbackSystemFontSize, weight: .regular))
            .foregroundStyle(hovering ? Color.white : Color.white.opacity(0.78))
            .symbolRenderingMode(.monochrome)
    }
}

private struct IslandHoverPressEventsModifier: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded { _ in onRelease() }
        )
    }
}

struct IslandDetachedHoverPanelBackground: View {
    /// Hand-crafted liquid glass — see `IslandDetachedHoverPanelGlassStyle`
    /// for why the system `NSGlassEffectView` is not used here. Layer order:
    /// frosted behind-window blur -> depth wash -> top specular -> edge
    /// lens -> crisp rim. One code path for every macOS version keeps the
    /// panel pixel-identical across machines.
    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: IslandDropModeControl.detachedPanelCornerRadius,
            style: .continuous
        )
        glassBase(in: shape)
            .overlay(depthWash(in: shape))
            .overlay(alignment: .top) { topSpecular }
            .overlay(edgeLens(in: shape))
            .overlay(crispRim(in: shape))
            .clipShape(shape)
    }

    /// Base material. Consistent dark glass: `.ultraThinMaterial` plus a fixed
    /// dark wash, so the slab reads identically regardless of wallpaper or the
    /// surface's size/position on screen.
    ///
    /// macOS 26's `.glassEffect(.regular)` was dropped here: as an *adaptive*
    /// effect it tinted each surface from its own backdrop, so the player strip
    /// and the controls panel — two separate instances of this view — rendered
    /// visibly different colours (light strip over a bright editor, dark panel
    /// below). A fixed wash over `.ultraThinMaterial` keeps both surfaces matched
    /// on any background — the same call `DarkGlassCard` settled on (which also
    /// sidesteps the Tahoe-only symbol that fails to compile on CI's Xcode).
    /// Dark in light mode stays enforced by the window-level `darkAqua` pin on
    /// `IslandPanel`.
    // WHY: docs/decisions/2026-06-16-island-music-progress-and-gap.md
    private func glassBase(in shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(.black.opacity(0.25)))
    }

    /// Vertical darkening: the slab reads thicker toward the bottom.
    private func depthWash(in shape: RoundedRectangle) -> some View {
        shape.fill(
            LinearGradient(
                colors: [
                    Color.black.opacity(
                        IslandDetachedHoverPanelGlassStyle.depthWashTopOpacity
                    ),
                    Color.black.opacity(
                        IslandDetachedHoverPanelGlassStyle.depthWashBottomOpacity
                    ),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Soft ceiling-light reflection hugging the top edge. Wider than the
    /// panel and mostly clipped away, so only a gentle dome of light shows.
    private var topSpecular: some View {
        Ellipse()
            .fill(
                Color.white.opacity(
                    IslandDetachedHoverPanelGlassStyle.specularOpacity
                )
            )
            .frame(height: IslandDetachedHoverPanelGlassStyle.specularHeight)
            .scaleEffect(x: 1.25)
            .blur(radius: IslandDetachedHoverPanelGlassStyle.specularBlurRadius)
            .offset(y: -IslandDetachedHoverPanelGlassStyle.specularHeight * 0.62)
    }

    /// Wide blurred inner stroke — the bent-light band of a real glass edge.
    private func edgeLens(in shape: RoundedRectangle) -> some View {
        shape
            .inset(by: IslandDetachedHoverPanelGlassStyle.lensStrokeWidth / 2)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(
                            IslandDetachedHoverPanelGlassStyle.lensStrokeTopOpacity
                        ),
                        Color.white.opacity(
                            IslandDetachedHoverPanelGlassStyle.lensStrokeBottomOpacity
                        ),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: IslandDetachedHoverPanelGlassStyle.lensStrokeWidth
            )
            .blur(radius: IslandDetachedHoverPanelGlassStyle.lensBlurRadius)
    }

    /// Crisp sub-pixel rim on the very edge — the facet cut.
    private func crispRim(in shape: RoundedRectangle) -> some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [
                    Color.white.opacity(
                        IslandDetachedHoverPanelGlassStyle.rimTopOpacity
                    ),
                    Color.white.opacity(
                        IslandDetachedHoverPanelGlassStyle.rimBottomOpacity
                    ),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: IslandDetachedHoverPanelGlassStyle.rimWidth
        )
    }
}

private extension IslandPassiveTextWeight {
    var swiftUIFontWeight: Font.Weight {
        switch self {
        case .medium:
            return .medium
        }
    }
}

private extension KeycapContent {
    var islandInlineShortcutText: String {
        switch self {
        case .text(let value):
            return value
        case .symbol(let name, _):
            return name
        case .prefixedGlyph(let prefix, let glyph, _):
            return "\(prefix) \(glyph)"
        }
    }
}


// MARK: - Orb slot

private struct IslandOrbSlot: View {
    let compactHeight: CGFloat
    let orbMode: VoiceOrbMode
    let orbLevels: [Float]

    /// Visual canvas size for the orb inside the compact pill. Sized so
    /// the orb almost touches the top and bottom of the pill — `compactHeight
    /// - 4` leaves ~2pt breathing room on each side at the default 38pt
    /// notch height (≈ 34pt orb). Scales naturally with the pill height
    /// so the "slightly inside the edge" feel holds on any screen.
    private var orbCanvas: CGFloat { max(0, compactHeight - 4) }

    private var orbScale: CGFloat {
        guard VoiceOrbView.canvasSize > 0 else { return 1 }
        return orbCanvas / VoiceOrbView.canvasSize
    }

    var body: some View {
        VoiceOrbView(
            mode: orbMode,
            levels: orbLevels,
            isDarkBackground: true
        )
        .frame(
            width: VoiceOrbView.canvasSize,
            height: VoiceOrbView.canvasSize
        )
        .scaleEffect(orbScale)
        .frame(width: orbCanvas, height: orbCanvas)
        // Smooth the mode swap. VoiceOrbView already animates its
        // internal composition transitions, but the parent-level
        // spring keeps surrounding layout coherent with the orb's
        // own crossfade.
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: orbMode)
    }
}

private struct IslandHideButton: View {
    let compactHeight: CGFloat
    let isHidden: Bool
    let action: () -> Void

    private var orbCanvas: CGFloat { max(0, compactHeight - 4) }
    private var iconSize: CGFloat { max(12, orbCanvas * 0.5) }

    var body: some View {
        Button(action: action) {
            Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(isHidden ? 0.62 : 0.92))
                .frame(width: orbCanvas, height: orbCanvas)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isHidden ? "Show Hover and Music" : "Hide Hover and Music")
        .accessibilityLabel(isHidden ? "Show Hover and Music" : "Hide Hover and Music")
    }
}

// MARK: - Trigger orbs (right side of the pill)
