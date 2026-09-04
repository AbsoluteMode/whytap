import Combine
import Foundation

/// Presentation state for the island agent surfaces (wing / acting slot /
/// answer panel). Pure derivation from `AppState.agentPhase`,
/// live STT transcript, and `AskResponseStore` — it does NOT own the
/// agent lifecycle (that stays in `AgentController`).
@MainActor
final class IslandAgentFlowStore: ObservableObject {
    enum Wing: Equatable {
        case hidden
        case recording(transcript: String)
        case composing
        case acting
        /// Close controls ([Esc] [✕]) shown in the right wing while the answer
        /// panel is up. The wing is otherwise empty in that phase, so the
        /// dismiss affordance lives there instead of over the centred card.
        case answerControls
        /// Transient STT failure notice; auto-collapses to idle.
        case failed(message: String)
        /// Persistent total-offline Drop-delivery failure (Task 7,
        /// `AppPhase.deliveryFailed`). Unlike `.failed` this does NOT
        /// auto-collapse: the captured audio is retained and the wing offers a
        /// manual Retry. It is still ESCAPABLE — a fresh Drop press abandons the
        /// failed take and starts a new turn (`.discardFailedTakeAndStart`),
        /// driving the phase off `.deliveryFailed` and clearing the wing; a
        /// successful Retry clears it the same way. So it is never a roach-motel.
        case deliveryFailed(message: String)
    }

    @Published private(set) var wing: Wing = .hidden
    @Published private(set) var answerPanelVisible = false
    /// True only while the `.acting` wing belongs to an AGENT execution
    /// (`phase != .idle`), never a Drop's `.finishing`/`.verifying`/`.inserting`
    /// `.acting` (those run with the agent `phase == .idle`). Drop and agent
    /// share one wing, so consumers that care about ownership must not key off
    /// `wing == .acting` alone.
    @Published private(set) var agentActing = false
    @Published private(set) var activityLabel: String = ""
    private(set) var recordingProviderBrand: TranscriptionProviderBrand?

    /// When true, the island never opens its own answer panel. Set while the
    /// onboarding Try-Agent step owns the answer surface (`OnboardingAgentLiveAnswer`
    /// renders the agent's reply in the onboarding card instead) so the island
    /// up top does not duplicate the same answer. Toggling it on closes any
    /// panel already on screen.
    var answerPanelSuppressed = false {
        didSet {
            guard answerPanelSuppressed, answerPanelVisible else { return }
            answerPanelVisible = false
            queryText = ""
            recompute()
        }
    }

    /// The submitted query text shown in the answer panel's query row.
    @Published private(set) var queryText: String = ""

    /// Live text being typed into the composer, mirrored from
    /// `IslandAgentComposerPanel` on each keystroke. Drives the composing
    /// capsule's width (`IslandAgentWingView.composingFaceWidth`) so the black
    /// surface and the composer field grow together with what is typed. Empty
    /// whenever the composer is closed.
    @Published private(set) var composingText: String = ""

    /// True while the on-screen surface (composer OR voice) belongs to the
    /// Google-search gesture (R-Option) rather than the agent (R-Command).
    /// Drives the composer placeholder (Task 6) and the orb palette (Task 7).
    /// Reset whenever the wing hides / the flow resets.
    @Published private(set) var activeSourceIsGoogle = false

    // Set by the Google gesture wiring (Task 8). The Google flow flips this
    // AFTER the `.voiceRecording`/`.textInputActive` phase change (so the agent
    // composer leak-guard in `agentPhaseChanged` cannot clear it first), and
    // never fires `recompute()` itself. Re-running `recompute()` here lets the
    // breathing provider logo re-resolve to the Google brand once the flag is
    // set — mirroring how the orb (which reads this `@Published` flag live)
    // re-renders Google colours on the same signal.
    func setActiveSourceIsGoogle(_ isGoogle: Bool) {
        activeSourceIsGoogle = isGoogle
        recompute()
    }

    /// True while any agent surface is on screen — drives hover gating
    /// and right-band priority.
    var isActive: Bool { wing != .hidden || answerPanelVisible }

    /// The response store the island views render from. Exposed read-only
    /// for view construction; the store itself stays private.
    var responseStoreForViews: AskResponseStore { responseStore }

    private let responseStore: AskResponseStore
    private let dropProviderBrand: @MainActor () -> TranscriptionProviderBrand?
    private let dropCleanupBrand: @MainActor () -> TranscriptionProviderBrand?
    /// Brand for the user's active agent CLI (Codex / Claude Code), shown in the
    /// breathing provider logo during AGENT voice (Right Cmd hold). Injected so
    /// tests can supply a fake active provider; the default reads the shared
    /// `AgentProviderStore`. Returns nil when no CLI is connected.
    private let agentProviderBrand: @MainActor () -> TranscriptionProviderBrand?
    private var phase: AgentPhase = .idle
    private var transcript: String = ""

    /// Drop flow (hold-Space dictation) phase + live transcript. The island
    /// wing mirrors the agent's recording→thinking arc for drop too, but only
    /// while the agent flow itself is idle — agent surfaces take priority.
    /// Drop writes `AppState.phase`; the agent writes `AppState.agentPhase`,
    /// so the two never contend for the wing.
    private var dropPhase: AppPhase = .idle
    private var dropTranscript: String = ""

    /// Widest transcript seen in the current recording turn — drives the
    /// recording wing's WIDTH only (so it grows, then HOLDS, never shrinking on
    /// a transient provider re-segment), while the displayed transcript stays
    /// the latest (live) value so the ticker never freezes. Reset to "" wherever
    /// the turn's transcript resets. Read by `IslandView.activeWingFaceWidth`.
    ///
    /// Empty means the initial "listening…" placeholder is still the width peak.
    /// Width is measured in rendered points, not `String.count`: a longer
    /// partial can be visually narrower and must not shrink the wing.
    private(set) var recordingFaceWidthHint: String = ""

    private var cancellables: Set<AnyCancellable> = []

    init(
        responseStore: AskResponseStore,
        dropProviderBrand: @escaping @MainActor () -> TranscriptionProviderBrand? = {
            TranscriptionProviderBrand.currentDrop()
        },
        dropCleanupBrand: @escaping @MainActor () -> TranscriptionProviderBrand? = {
            TranscriptionProviderBrand.currentDropCleanup()
        },
        agentProviderBrand: @escaping @MainActor () -> TranscriptionProviderBrand? = {
            AgentProviderStore.shared.activeProvider.map(TranscriptionProviderBrand.agent)
        }
    ) {
        self.responseStore = responseStore
        self.dropProviderBrand = dropProviderBrand
        self.dropCleanupBrand = dropCleanupBrand
        self.agentProviderBrand = agentProviderBrand
        responseStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFromResponseStore() }
            .store(in: &cancellables)
        // Mirror the live drop phase so the island shows the dictation
        // listening frame + a Smart post-process "thinking…" slot — the same
        // wing surfaces the agent voice flow uses.
        //
        // WHY DispatchQueue.main (NOT RunLoop.main): the accessory app is
        // backgrounded right after a Drop paste (focus moves to the target
        // app). RunLoop.main only delivers Combine values while the main
        // RunLoop runs in `.default` mode, so a backgrounded app never receives
        // the trailing `.idle` — the island stays stuck on "thinking…" after a
        // short phrase (reproduced only on prod / in the background, never in a
        // foreground dev session or a unit test where the RunLoop is active).
        // DispatchQueue.main delivers regardless of activation.
        // WHY: docs/decisions/2026-06-16-island-drop-thinking-stuck.md
        AppState.shared.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.dropPhaseChanged(phase) }
            .store(in: &cancellables)
    }

    func agentPhaseChanged(_ newPhase: AgentPhase) {
        if case .failed = wing, newPhase != .idle {
            // Starting a new cycle dismisses the transient failure notice
            // early; a trailing `.idle` (e.g. the tail of the cancel path)
            // must not — the notice owns its ~2s on screen.
            wing = .hidden
        }
        if newPhase != .textInputActive {
            // Composer closed (or never open) — collapse the capsule back to its
            // placeholder floor so the next compose opens snug.
            composingText = ""
        }
        if newPhase == .voiceRecording || newPhase == .textInputActive {
            transcript = ""
            recordingFaceWidthHint = ""
            // A fresh recording / composing phase begins a NEW turn — the
            // prior turn's answer panel must close so the input/recording wing
            // can take over. The orb-era controller force-closed the response
            // panel here; with the panel gone the flow store owns the reset.
            // (The normal lifecycle also clears this via the `.idle` tail, but
            // interrupting an in-flight turn with a new gesture never passes
            // through idle.)
            answerPanelVisible = false
            queryText = ""
            // Agent-composer / agent-voice leak-guard: clear a prior Google
            // turn's source flag at the START of every new agent turn. The
            // Google gesture re-sets the flag AFTER this phase change (see
            // `AppDelegate.makeGoogleCallbacks`), so a Google turn keeps it; a
            // plain agent turn never sets it again and stays the agent palette.
            // This reset lived in `recompute()`'s `.voiceRecording`/
            // `.textInputActive` branches, but `recompute()` runs repeatedly
            // (response-store refreshes, the Google-flag setter) and must NOT
            // clobber a flag the Google flow just set — so it moved here, where
            // it fires once per turn.
            activeSourceIsGoogle = false
        }
        if newPhase == .idle {
            transcript = ""
            recordingFaceWidthHint = ""
            // A turn that finished with answer content (success or a
            // dispatched-turn error) drives the controller to `.idle`, but its
            // result must stay on screen until the next turn or an explicit
            // dismiss — matching the orb-era panel, which stayed open after
            // `done`. Only force the panel closed when there is nothing left to
            // show (e.g. cancel/silence paths reset the store before idle).
            if !hasAnswerContent {
                answerPanelVisible = false
                queryText = ""
            }
        }
        phase = newPhase
        recompute()
    }

    func transcriptUpdated(_ text: String) {
        // Same transient-empty latch as the drop wing (display-only — the agent
        // query uses the session's resolved result). Non-empty always shown so
        // the ticker stays LIVE; do NOT length-gate (it froze the drop wing on
        // long dictations). `transcript` resets to "" at turn start/idle.
        guard !text.isEmpty else { return }
        transcript = text
        promoteRecordingFaceWidthHint(text)
        recompute()
    }

    /// Live drop (hold-Space) phase changed. Drives the wing through the same
    /// recording→thinking arc as the agent: the listening frame while
    /// `.recording`/`.transcribing` (the latter brackets recording — session
    /// setup + the brief stop moment), then a "thinking…" slot through the
    /// LLM post-process (on-device or BYOK) + paste (`.verifying`/
    /// `.inserting`). Cleared on `.idle`. Wired in production from
    /// `AppState.$phase`; exposed for direct driving in tests.
    func dropPhaseChanged(_ newPhase: AppPhase) {
        dropPhase = newPhase
        if newPhase == .idle {
            dropTranscript = ""
            recordingFaceWidthHint = ""
        }
        recompute()
    }

    /// Live STT partial for the drop recording wing — wired from the drop
    /// streaming session's `onTranscriptUpdate` (the same sink the agent voice
    /// flow uses, inherited via `StreamingSessionRunning`).
    func dropTranscriptUpdated(_ text: String) {
        // Latch through a transient EMPTY partial only. ElevenLabs commits a
        // segment on a speech pause and briefly emits "" before the next
        // utterance; without this the wing collapses to "listening…" mid-turn.
        // Everything non-empty is shown so the ticker stays LIVE.
        //
        // NB: do NOT gate by length (a prior attempt used `count > current`).
        // On a long dictation (~20-30s) the provider re-segments and revises
        // the tail, so the snapshot stops strictly growing — a length gate then
        // FREEZES the wing on the peak line while the user keeps talking. The
        // visual jump it tried to fix is a width-spring concern, not a
        // text-value one. Display-only (paste uses the resolved result); `.idle`
        // (dropPhaseChanged) clears it for the next turn.
        guard !text.isEmpty else { return }
        dropTranscript = text
        promoteRecordingFaceWidthHint(text)
        recompute()
    }

    /// Records the prompt the user just submitted so the answer panel can
    /// echo it in its query row. Cleared when the cycle returns to idle.
    func querySubmitted(_ text: String) {
        queryText = text
    }

    /// Live composer text changed — mirror it so the composing capsule width
    /// tracks what is typed. No `recompute()`: the wing stays `.composing`; only
    /// the derived face width (read off `composingText`) changes, and the
    /// `@Published` mutation already nudges the surfaces + view to re-read it.
    func composingTextChanged(_ text: String) {
        composingText = text
    }

    /// STT failed or produced no speech: show a short notice in the wing,
    /// then auto-collapse. `autoDismissDelay` is injectable for tests.
    func sttFailed(message: String, autoDismissDelay: Duration = .seconds(2)) {
        phase = .idle
        answerPanelVisible = false
        recordingProviderBrand = nil
        wing = .failed(message: message)
        Task { [weak self] in
            try? await Task.sleep(for: autoDismissDelay)
            guard let self, case .failed = self.wing else { return }
            self.activeSourceIsGoogle = false
            self.wing = .hidden
        }
    }

    /// True when the response store carries something the answer panel should
    /// render: streamed text, blocks, or a terminal error message.
    private var hasAnswerContent: Bool {
        !responseStore.streamingText.isEmpty
            || !responseStore.blocks.isEmpty
            || responseStore.errorMessage != nil
    }

    /// Re-reads the response store (also wired to objectWillChange).
    func refreshFromResponseStore() {
        if !answerPanelSuppressed, responseStore.pendingPermission != nil || hasAnswerContent {
            // Answer panel opens once and stays until the cycle ends. A
            // turn-terminating event (`done` / `error`) drives the controller
            // to `.idle` synchronously, so the deferred refresh that carries
            // the final content runs with `phase == .idle`; still open the
            // panel then so a completed turn's answer (or error) is visible.
            answerPanelVisible = true
        }
        activityLabel = AgentActivityCategorizer.label(
            toolLabel: responseStore.currentToolLabel,
            status: responseStore.status
        )
        recompute()
    }

    private func recompute() {
        if case .failed = wing {
            // The transient failure notice is cleared only by its own
            // timer or by an explicit new cycle in `agentPhaseChanged` —
            // background response-store refreshes must not blink it away.
            recordingProviderBrand = nil
            if agentActing { agentActing = false }
            return
        }
        if answerPanelVisible {
            recordingProviderBrand = nil
            // The wing hosts the close controls ([Esc] [✕]) while the answer
            // is up — it would otherwise sit empty next to the centred card.
            wing = .answerControls
            // Escape is already covered by `answerPanelVisible` itself.
            if agentActing { agentActing = false }
            return
        }
        switch phase {
        case .voiceRecording:
            // Breathing provider logo resolves by recording SOURCE: Google
            // search (R-Option hold) shows the Google mark; otherwise the
            // active agent CLI (Codex / Claude Code, R-Cmd hold). The Google
            // flag is set AFTER the phase change and re-runs `recompute()` via
            // `setActiveSourceIsGoogle`, so this branch re-resolves to `.google`
            // once the flag flips. `agentProviderBrand()` is nil when no CLI is
            // connected (no logo, same as drop's local mode).
            recordingProviderBrand = activeSourceIsGoogle
                ? TranscriptionProviderBrand.google
                : agentProviderBrand()
            wing = .recording(transcript: transcript)
        case .textInputActive:
            recordingProviderBrand = nil
            wing = .composing
        case .transcribing, .executing:
            recordingProviderBrand = nil
            wing = .acting
        case .idle:
            // Agent idle → the drop flow may own the wing. Live words while
            // dictating (`.recording`/`.transcribing`), then a "thinking…"
            // slot through the LLM post-process + paste
            // (`.verifying`/`.inserting`). Fast mode only flashes the slot
            // (no LLM pass); Smart holds it for the real cleanup. Mapping `.transcribing` to the listening frame (not the
            // slot) keeps the pre-roll setup + early partials as "listening…",
            // never a premature "thinking…".
            switch dropPhase {
            case .recording, .transcribing:
                recordingProviderBrand = dropProviderBrand()
                wing = .recording(transcript: dropTranscript)
            case .verifying, .inserting:
                recordingProviderBrand = dropCleanupBrand()
                activityLabel = AgentActivityCategorizer.label(toolLabel: nil, status: .thinking)
                wing = .acting
            case .finishing:
                // Degraded resilient-Drop recovery: the live stream broke but the
                // audio was retained and is being batch-transcribed. Reuse the
                // calm "thinking" slot — a working state, NOT an error — with a
                // distinct label so it reads as "finishing the dictation".
                recordingProviderBrand = nil
                activityLabel = Self.finishingLabel
                wing = .acting
            case .deliveryFailed:
                // Total offline: batch recovery also failed. Surface a persistent,
                // non-alarming failure with a manual Retry; the audio is retained
                // (`AppDelegate.pendingRetryPCM`) until the user retries or starts
                // a new turn.
                recordingProviderBrand = nil
                wing = .deliveryFailed(message: Self.deliveryFailedMessage)
            case .idle:
                recordingProviderBrand = nil
                activeSourceIsGoogle = false
                wing = .hidden
            }
        }
        // Ownership marker: ONLY an agent execution `.acting` (agent phase
        // still live). A Drop's `.acting` runs with `phase == .idle`, so this
        // stays false for Drop. Guard the assignment so an unchanged value
        // emits no extra `objectWillChange` — keeps the wing+brand publication
        // atomic.
        let nextAgentActing = (wing == .acting && phase != .idle)
        if agentActing != nextAgentActing { agentActing = nextAgentActing }
    }

    /// Working-state label shown in the `.acting` slot while a degraded Drop is
    /// being batch-recovered (`AppPhase.finishing`).
    static let finishingLabel = "finishing…"

    /// Non-alarming copy for the persistent total-offline Drop-delivery failure
    /// wing (`AppPhase.deliveryFailed`). The Retry affordance sits beside it.
    static let deliveryFailedMessage = "Couldn't deliver — offline"

    private func promoteRecordingFaceWidthHint(_ text: String) {
        let candidateWidth = IslandAgentWingView.recordingMeasuredContentWidth(text: text)
        let currentWidth = IslandAgentWingView.recordingMeasuredContentWidth(
            text: recordingFaceWidthHint
        )
        if candidateWidth > currentWidth {
            recordingFaceWidthHint = text
        }
    }
}
