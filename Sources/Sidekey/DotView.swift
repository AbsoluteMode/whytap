import SwiftUI

/// SwiftUI view rendering the floating orb. Reacts to `AppState.phase`
/// and `AppState.agentPhase` to pick an orb mode; reads
/// `BackgroundLuminanceObserver.isDarkBackground` to pick a palette for
/// the drop flow (white-on-dark vs black-on-light). The agent flow
/// always renders the fixed pink-violet palette regardless of background.
///
/// Renders a single `VoiceOrbView` instance for every mode (idle and
/// active). VoiceOrbView's internal composition switch picks the right
/// surface (idle ring, gradient ring, or active BlobShape stack) and the
/// idle branch keeps `TimelineView` paused so there is zero per-frame
/// work at rest.
///
/// **Why one instance, not an if/else swap.** A previous design swapped
/// between a local idle ring and `VoiceOrbView` via `if orbMode == .idle`
/// with `.transition(.opacity)`. On the active→idle transition SwiftUI
/// kept the outgoing `VoiceOrbView` in the view graph until the opacity
/// transition finished — that retained copy still held the pre-transition
/// `mode` (e.g. `.agentVoice`), so the `paused: mode == .idle` guard
/// inside VoiceOrbView's TimelineView evaluated to `false` and the
/// BlobShape stack kept ticking at 60fps while invisible. Rendering a
/// single VoiceOrbView whose `mode` flips to `.idle` makes the pause
/// take effect immediately — no zombie copy lingering in the graph.
///
/// **Shared luminance source.** `VoiceOrbView` reads `isDarkBackground`
/// from this view's `BackgroundLuminanceObserver`, so the idle ring and
/// the active drop orb pick from the same single source of truth — the
/// idle→drop transition cannot show two different palettes for the same
/// wallpaper.
struct DotView: View {
    @ObservedObject var state: AppState
    @ObservedObject var luminance: BackgroundLuminanceObserver

    private let containerSize: CGFloat = VoiceOrbView.canvasSize

    /// `state` defaults to the shared `AppState`; `luminance` defaults
    /// to the shared `BackgroundLuminanceObserver`. The defaults are
    /// computed inside the initializer body (instead of in the parameter
    /// list) so SwiftUI's struct synthesis doesn't choke on the
    /// MainActor-isolated singleton references — that's the Swift 6
    /// strict-concurrency-friendly pattern.
    @MainActor
    init(
        state: AppState? = nil,
        luminance: BackgroundLuminanceObserver? = nil
    ) {
        self.state = state ?? .shared
        self.luminance = luminance ?? .shared
    }

    var body: some View {
        VoiceOrbView(
            mode: orbMode,
            levels: state.audioLevels,
            isDarkBackground: luminance.isDarkBackground
        )
        .frame(width: containerSize, height: containerSize)
        .animation(.easeInOut(duration: 0.20), value: state.phase)
        .animation(.easeInOut(duration: 0.20), value: state.agentPhase)
        .animation(.easeInOut(duration: 0.30), value: luminance.isDarkBackground)
    }

    private var orbMode: VoiceOrbMode {
        if state.agentPhase != .idle {
            switch state.agentPhase {
            case .idle:
                return .idle
            case .textInputActive:
                return .agentTextInputActive
            case .voiceRecording:
                return .agentVoice
            case .transcribing, .executing:
                return .agentProcessing
            }
        }

        switch state.phase {
        case .idle:
            return .idle
        case .recording:
            return .dropVoice
        case .transcribing, .verifying, .inserting:
            return .dropProcessing
        case .finishing:
            // Resilient-Drop batch recovery in flight (Task 7): a calm
            // "working" orb, identical to the normal processing state — NOT an
            // error. The "дочитываю…" copy lives on the Dynamic Island wing.
            return .dropProcessing
        case .deliveryFailed:
            // Total-offline terminal state (Task 7): the work is paused awaiting
            // a manual Retry. There is no error orb palette, and the Dynamic
            // Island carries the non-alarming failure message + Retry; the
            // floating orb simply rests so it never shows a stuck spinner.
            return .idle
        }
    }
}
