import AppKit
import Combine
import Foundation
import os.log

enum AgentControllerState: Equatable {
    case idle
    case textInput
    case voiceRecording
    case executing
}

/// Batch transcription seam for the agent's record-then-transcribe voice
/// path (used when realtime streaming is unavailable). Production runs the
/// on-device Parakeet model; tests inject a fake.
protocol AgentAudioTranscribing {
    /// `language` is the ISO 639-1 code selected by the user (e.g. "ru"),
    /// or `nil` for automatic detection.
    func transcribe(audioData: Data, language: String?) async throws -> String
}

/// On-device batch transcription of a captured WAV via Parakeet.
struct LocalAgentAudioTranscriber: AgentAudioTranscribing {
    private let batch: any BatchTranscribing

    init(batch: any BatchTranscribing = LocalBatchTranscriber()) {
        self.batch = batch
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await batch.transcribe(audio: audioData, language: language)
    }
}

@MainActor
final class AgentController: ObservableObject {
    @Published private(set) var state: AgentControllerState = .idle
    private(set) var currentSnapshot: FocusSnapshot?
    let responseStore: AskResponseStore

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "agent")

    private let gestureMonitor: RightCmdGestureMonitoring
    private let snapshotProvider: () -> FocusSnapshot?
    private let resolveProvider: @MainActor () -> (any CLIProvider)?
    private let resolveRunOptions: @MainActor (CLIProviderID) -> AgentRunOptions
    /// The provider that drove the most-recently-started turn. Set at the
    /// top of `continueSubmit`; nil between turns.
    private var activeTurnProvider: (any CLIProvider)?
    /// Durable per-provider CLI session ids. Keeping Codex and Claude separate
    /// lets each CLI use its own native resume / auto-compact state without
    /// leaking one provider's thread id into the other.
    private let agentSessionStore: any AgentSessionStoring
    private let audioTranscriber: any AgentAudioTranscribing
    private let voiceSessionFactory: @MainActor () -> any AgentVoiceSessioning
    private let chatStackStore: ChatStackStore?
    private let privacyPreferences: PrivacyPreferences
    private let selectionFallbackInvoker: SelectionFallbackInvoker
    /// Capability gate: returns true when the Agent capability is enabled.
    /// Injected so tests can control the flag without touching the singleton.
    private let agentEnabled: @MainActor () -> Bool
    /// A gesture arrived while Agent is disabled or no CLI provider is
    /// connected. Production opens Settings > Agents immediately; the no-op
    /// default keeps standalone tests and previews independent from AppDelegate.
    private let onAgentSetupRequired: @MainActor () -> Void
    /// When `true`, R-Cmd hold may drive realtime streaming transcription via
    /// `AgentRealtimeVoiceSessioning` instead of the batch record-then-send
    /// path. Production keeps this on; the batch path stays as the fallback
    /// when no realtime session can be built.
    private let streamingVoiceEnabled: Bool
    private let realtimeVoiceEnabled: @MainActor () -> Bool
    /// Factory injected by tests (or AppDelegate) to create the realtime voice
    /// session. `nil` when `streamingVoiceEnabled` is `false`. Returns `nil`
    /// when the session cannot be built (e.g. a missing BYOK key); in that
    /// case `handleHoldStart` calls `handleStreamResult(.failed(.transportFailed))`.
    private let agentVoiceStreamFactory: (@MainActor () async -> (any AgentRealtimeVoiceSessioning)?)?
    private let snapshotStore = AgentControllerSnapshotStore()
    /// Presentation store for the Dynamic Island agent surfaces (wing +
    /// answer panel). Optional so the legacy panel tests build a controller
    /// without it; every routing call site goes through `?.` so a nil flow
    /// is a no-op. Production injects the same instance the island panel
    /// renders from (`IslandPanel.installAgentFlow`).
    private let islandAgentFlow: IslandAgentFlowStore?
    /// Shared useful-links selection chip state. THE SAME instance the
    /// island answer panel renders from (`IslandPanel.agentLinksSelection`)
    /// so the hotkey controller's index moves the on-screen chip. Nil in
    /// legacy-panel tests (no island), where the links hotkeys are inert.
    private let islandLinksSelection: UsefulLinksSelectionState?
    private let closeHotkeyFactory: @MainActor () -> AgentResponseCloseHotkeyControlling
    private let escapeCloseHotkeyFactory: @MainActor () -> AgentResponseCloseHotkeyControlling
    private let usefulLinksHotkeyFactory: @MainActor () -> UsefulLinksHotkeyController
    private let hotkeyPreferences: HotkeyPreferences
    /// Owns the ⌥Q close hotkey while the island answer panel is visible.
    /// Registered/torn down by a Combine subscription on the flow store's
    /// `answerPanelVisible`. Reuses the same Carbon adapter the legacy panel
    /// built. Nil until first needed.
    private var responseCloseHotkey: AgentResponseCloseHotkeyControlling?
    private var responseCloseHotkeyActive = false
    private var answerPanelVisibleCancellable: AnyCancellable?
    private var answerCloseHotkeyPreferencesCancellable: AnyCancellable?
    /// Owns the fixed bare-Escape close monitor (passive NSEvent observer,
    /// NOT a Carbon grab). Registered only while the answer panel is visible:
    /// the acting/recording/composing wings have their own Escape semantics
    /// (gesture cancel, key-window `.onExitCommand`), and a monitor observing
    /// during those phases would double-handle the key.
    /// WHY: docs/decisions/2026-07-02-escape-close-passive-monitor.md
    private var escapeCloseHotkey: AgentResponseCloseHotkeyControlling?
    private var escapeCloseHotkeyActive = false
    private var escapeCloseLifecycleCancellable: AnyCancellable?
    /// Drives the useful-links hotkey family (⌥←/→/↑/↓) while the island
    /// answer panel shows a links block. Lifecycle mirrors the legacy
    /// panel's `startUsefulLinksObserver` but is now owned here so the
    /// island answer panel needs no NSPanel host.
    private var usefulLinksHotkey: UsefulLinksHotkeyController?
    private var usefulLinksBlocksCancellable: AnyCancellable?
    private var usefulLinksHotkeyPreferencesCancellable: AnyCancellable?
    /// `true` once the text-input flow is active (the composing wing is on
    /// screen via the island flow store). Replaces the old `textInputPanel
    /// != nil` presence check the legacy NSPanel provided — a second R-Cmd
    /// tap while composing toggles back to idle.
    private var textInputActive = false
    /// Called by `handleTextSubmit` instead of the agent path when the
    /// island flow's `activeSourceIsGoogle` flag is set. Injected by
    /// AppDelegate (Task 8); no-op default so the controller remains
    /// standalone for existing tests.
    private var onGoogleTextSubmit: (String) -> Void = { _ in }
    private var consumeTask: Task<Void, Never>?
    private var voiceSession: (any AgentVoiceSessioning)?
    /// The in-flight realtime voice session, set once the session factory
    /// resolves. `handleHoldEnd` calls `stop()` on it (finalize → transcript);
    /// `stop()`/`handleCancel()`/a re-entrant `handleHoldStart` tear it down
    /// via `teardownRealtimeVoiceSession()` (cancel). Stays `nil` while the
    /// factory is still suspended on a JWT refresh — teardown during that
    /// window cancels the run Task, whose post-factory `Task.isCancelled`
    /// check then closes the session before `run()` starts.
    private var realtimeVoiceSession: (any AgentRealtimeVoiceSessioning)?
    /// Task owning the `session.run()` await. Cancelling it alone does NOT
    /// resolve the session's checked continuation — teardown must
    /// also call `session.cancel()` (see `teardownRealtimeVoiceSession()`).
    private var realtimeRunTask: Task<Void, Never>?
    private var hotkeyPreferencesCancellable: AnyCancellable?

    /// `id` of the chat row owned by the in-flight turn. Set in
    /// `submitQuery`, cleared at the start of the next submit. Nil between
    /// turns and when `chatStackStore` is absent (feature gate off or
    /// in tests).
    private var activeRowId: Int64?

    /// Guard against double-finalisation when SSE delivers both `error` and
    /// trailing `done` for the same turn. ChatStackStore writes are
    /// idempotent on the row, but flipping `.error` back to `.done` would
    /// erase the user-visible failure marker.
    private var didFinalizeActiveRow = false

    /// Stage 0b: provider-issued `turn_id` for the in-flight turn. Set to
    /// `"pending"` at `voice_turn_started` emit time (before the CLI is
    /// spawned) and overwritten when the `started` event lands.
    /// Cleared on the next submit. Lets `voice_turn_completed` /
    /// `voice_turn_failed` carry the real id when the provider produced one,
    /// or `"pending"` when the turn died before the stream opened.
    private var activeTurnId: String?

    /// Stage 0b: mode tag for the in-flight turn. Persists across `submitQuery`
    /// so completed/failed emissions carry the same `mode` as `started`.
    private var activeTurnMode: String?

    /// Stage 0b: dedupes `voice_turn_completed` / `_failed`. The
    /// `markActiveRowError` + trailing `done` pairing already trips
    /// `didFinalizeActiveRow`, but telemetry has its own lifetime — emit-once
    /// guard so completed never lands after failed (and vice-versa).
    private var didEmitTurnTerminator = false

    /// Stage 0b: dedupes `voice_turn_started`. The voice path emits at
    /// `handleHoldStart`, then submits via `submitQuery` after transcription —
    /// this flag prevents a second emission inside `continueSubmit`.
    private var didEmitTurnStarted = false

    /// Behavioural system prompt prepended to the FIRST turn of a fresh agent
    /// session (when `resumeSessionID == nil`). On resume the CLI already has
    /// it in history, so it is not resent. The agent does NOT edit this — it is
    /// our control over behaviour, kept out of the `AGENTS.md` memory file so
    /// the two layers (behaviour here, facts there) never duplicate. English by
    /// design: system prompts are more reliable in English; the agent still
    /// replies to the user in the user's language per the instruction below.
    private static let sharedMemoryPromptPreamble = """
    You are Whytap — the user's assistant, one keystroke away on their Mac.
    They summon you mid-task, so respect their attention: be fast and brief.
    Reply in the user's language.

    ANSWERING
    - Lead with the answer in your first sentence. No preamble, no restating the
      question, no "Sure"/"Based on…", and never praise the question.
    - 1–2 sentences for simple asks; longer only when truly needed. Your answer
      shows in a small window and is often read aloud: plain sentences, no
      headings, tables, or lists (use a list only if asked).
    - On a question, be decisive: if it's ambiguous, make the most reasonable
      assumption and answer — don't bounce a question back.
    - On a task, when you're missing what you need (e.g. "reply to Katya" — who,
      where), find it yourself first: check your memory, the user's connected
      tools, the web. Only if you still can't, ask the user one short question.
      Never guess at an irreversible action.
    - Don't hedge, moralize, or pad ("It's important to…", "As an AI…"). If you
      don't know or a tool finds nothing, say so in one line. No trailing summary,
      "related topics", or closing question.

    TOOLS
    - Answer timeless or well-known things from your own knowledge — don't search.
      Use the web only when the answer depends on recent, real-time, or external
      facts (news, prices, weather, people, events) or on something specific to
      this Mac. Default to one search; never more than two for the same thing.
    - "Who painted Guernica?" → answer directly. "Weather in Yerevan?" → search.

    MEMORY
    - AGENTS.md in your working directory is your memory — yours to maintain, not
      just read. Read it at the start.
    - Record what's durable so you don't ask twice: facts about the user and their
      preferences; who the people they mention are; what a recurring task needs and
      how they like it done. When you ask the user for something missing, write the
      answer down.
    - Refresh stale entries; when a newer fact contradicts an old one, replace it;
      drop duplicates. Keep it concise — it loads every session.
    - Store only what changes how you act for this user. Never store secrets,
      tokens, or personal data — the file is plaintext.

    When your answer contains something the user can act on — a file path, a
    command or snippet to paste, or an external link — also surface it as one
    final JSON code fence so they can insert or open it in one keystroke. Keep it
    in your text too; the fence is in addition, not instead. Fence: kind
    "useful.actions", schemaVersion 1, items each {type, description} where type is
    "link" (with url), "path" (with path), or "copy" (with text).
    """

    /// Read-only test seam for the behavioural preamble. The constant itself is
    /// private (it is our behaviour contract, not API); this exposes its text
    /// to a guard test that pins the load-bearing markers so a future edit
    /// can't silently drop a section.
    static var systemPromptPreambleForTesting: String { sharedMemoryPromptPreamble }

    static let maximumSelectionCharacters = 24_000
    static let selectionTruncationMarker = "\n\n[Selection shortened by Whytap]\n\n"
    private static let perTurnLanguageInstruction =
        "Reply in the language of the user's latest request. Do not switch languages because of tool output or earlier turns."

    init(
        gestureMonitor: RightCmdGestureMonitoring = RightCmdGestureMonitor(),
        snapshotProvider: @escaping () -> FocusSnapshot? = FocusSnapshot.capture,
        resolveProvider: @escaping @MainActor () -> (any CLIProvider)? = { ClaudeCodeProvider() },
        resolveRunOptions: @escaping @MainActor (CLIProviderID) -> AgentRunOptions = { AgentSettingsStore.shared.options(for: $0) },
        agentSessionStore: (any AgentSessionStoring)? = nil,
        audioTranscriber: (any AgentAudioTranscribing)? = nil,
        voiceSessionFactory: (@MainActor () -> any AgentVoiceSessioning)? = nil,
        responseStore: AskResponseStore? = nil,
        chatStackStore: ChatStackStore? = nil,
        privacyPreferences: PrivacyPreferences = .shared,
        selectionFallbackInvoker: SelectionFallbackInvoker = SelectionFallbackInvoker.live,
        agentEnabled: @escaping @MainActor () -> Bool = { UserPreferencesCache.shared.currentAgentEnabled },
        onAgentSetupRequired: @escaping @MainActor () -> Void = {},
        streamingVoiceEnabled: Bool = false,
        realtimeVoiceEnabled: (@MainActor () -> Bool)? = nil,
        agentVoiceStreamFactory: (@MainActor () async -> (any AgentRealtimeVoiceSessioning)?)? = nil,
        islandAgentFlow: IslandAgentFlowStore? = nil,
        agentLinksSelection: UsefulLinksSelectionState? = nil,
        closeHotkeyFactory: (@MainActor () -> AgentResponseCloseHotkeyControlling)? = nil,
        escapeCloseHotkeyFactory: (@MainActor () -> AgentResponseCloseHotkeyControlling)? = nil,
        usefulLinksHotkeyFactory: (@MainActor () -> UsefulLinksHotkeyController)? = nil
    ) {
        let resolvedResponseStore = responseStore ?? AskResponseStore()
        self.gestureMonitor = gestureMonitor
        self.snapshotProvider = snapshotProvider
        self.resolveProvider = resolveProvider
        self.resolveRunOptions = resolveRunOptions
        self.agentSessionStore = agentSessionStore ?? AgentSessionStore.shared
        self.audioTranscriber = audioTranscriber ?? LocalAgentAudioTranscriber()
        self.voiceSessionFactory = voiceSessionFactory ?? {
            AgentVoiceSession(recorder: AudioRecorder())
        }
        self.responseStore = resolvedResponseStore
        self.chatStackStore = chatStackStore
        self.privacyPreferences = privacyPreferences
        self.selectionFallbackInvoker = selectionFallbackInvoker
        self.agentEnabled = agentEnabled
        self.onAgentSetupRequired = onAgentSetupRequired
        self.streamingVoiceEnabled = streamingVoiceEnabled
        self.realtimeVoiceEnabled = realtimeVoiceEnabled ?? { streamingVoiceEnabled }
        self.agentVoiceStreamFactory = agentVoiceStreamFactory
        self.islandAgentFlow = islandAgentFlow
        self.islandLinksSelection = agentLinksSelection
        let resolvedHotkeyPreferences = HotkeyPreferences.shared
        self.hotkeyPreferences = resolvedHotkeyPreferences
        self.closeHotkeyFactory = closeHotkeyFactory ?? {
            CarbonResponseCloseHotkey(hotkeyPreferences: resolvedHotkeyPreferences)
        }
        self.escapeCloseHotkeyFactory = escapeCloseHotkeyFactory ?? {
            EscapeCloseEventMonitor()
        }
        self.usefulLinksHotkeyFactory = usefulLinksHotkeyFactory ?? {
            UsefulLinksHotkeyController(configurationProvider: {
                resolvedHotkeyPreferences.configuration
            })
        }

        // Wire the permission-decision sink ONCE so user Allow/Deny choices
        // in the pill are forwarded to the live process via the active turn
        // provider's respondToPermission (Codex: no-op; Claude Code: stdin write).
        // Capture via [weak self] so the store closure does not retain the
        // controller (which owns the store) creating a retain cycle.
        resolvedResponseStore.onPermissionDecision = { [weak self] requestId, decision in
            self?.activeTurnProvider?.respondToPermission(requestId: requestId, decision: decision)
        }

        // Island routing: the answer-panel hotkeys (⌥Q close, useful-links
        // family) used to be owned by the legacy `AgentResponsePanel`'s
        // show/close lifecycle. With the panel gone from the live path, the
        // controller owns them, keyed off the flow store's
        // `answerPanelVisible`. No-op when no island flow is wired.
        bindAnswerPanelHotkeyLifecycle()
    }

    /// Callbacks for the R-Option Google-search gesture. Passed to `start()`
    /// by AppDelegate (Task 8); all default to no-ops so existing tests that
    /// call `start()` with no arguments are unaffected.
    struct GoogleCallbacks {
        var onTextTap: () -> Void = {}
        var onVoiceTap: () -> Void = {}
        var onHoldStart: () -> Void = {}
        var onHoldEnd: () -> Void = {}
        var onCancel: () -> Void = {}
        var onTextSubmit: (String) -> Void = { _ in }

        static let noOp = GoogleCallbacks()
    }

    func start(googleCallbacks: GoogleCallbacks = .noOp) {
        onGoogleTextSubmit = googleCallbacks.onTextSubmit
        bindHotkeyPreferencesIfSupported()
        if let configurableMonitor = gestureMonitor as? RightCmdGestureMonitor {
            configurableMonitor.start(
                onSnapshot: { [weak self] snapshot in
                    self?.snapshotStore.snapshot = snapshot
                    Task { @MainActor in
                        self?.currentSnapshot = snapshot
                    }
                },
                onTextTap: { [weak self] in
                    Task { @MainActor in
                        self?.handleTap()
                    }
                },
                onVoiceTap: { [weak self] in
                    Task { @MainActor in
                        await self?.handleVoiceTap()
                    }
                },
                onVoiceHoldStart: { [weak self] in
                    Task { @MainActor in
                        self?.handleHoldStart()
                    }
                },
                onVoiceHoldEnd: { [weak self] in
                    Task { @MainActor in
                        await self?.handleHoldEnd()
                    }
                },
                onCancel: { [weak self] in
                    Task { @MainActor in
                        self?.handleCancel()
                    }
                },
                onGoogleTextTap: googleCallbacks.onTextTap,
                onGoogleVoiceTap: googleCallbacks.onVoiceTap,
                onGoogleHoldStart: googleCallbacks.onHoldStart,
                onGoogleHoldEnd: googleCallbacks.onHoldEnd,
                onGoogleCancel: googleCallbacks.onCancel
            )
            return
        }
        gestureMonitor.start(
            onSnapshot: { [weak self] snapshot in
                self?.snapshotStore.snapshot = snapshot
                Task { @MainActor in
                    self?.currentSnapshot = snapshot
                }
            },
            onTap: { [weak self] in
                Task { @MainActor in
                    self?.handleTap()
                }
            },
            onHoldStart: { [weak self] in
                Task { @MainActor in
                    self?.handleHoldStart()
                }
            },
            onHoldEnd: { [weak self] in
                Task { @MainActor in
                    await self?.handleHoldEnd()
                }
            },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.handleCancel()
                }
            }
        )
    }

    func stop() {
        hotkeyPreferencesCancellable?.cancel()
        hotkeyPreferencesCancellable = nil
        gestureMonitor.stop()
        consumeTask?.cancel()
        consumeTask = nil
        voiceSession?.cancel()
        voiceSession = nil
        teardownRealtimeVoiceSession()
        // Tear down the island answer-panel hotkey lifecycle (⌥Q + bare Esc +
        // useful links). Cancels the flow-store subscriptions and any live
        // registrations.
        answerPanelVisibleCancellable?.cancel()
        answerPanelVisibleCancellable = nil
        escapeCloseLifecycleCancellable?.cancel()
        escapeCloseLifecycleCancellable = nil
        stopResponseCloseHotkey()
        stopEscapeCloseHotkey()
        stopUsefulLinksObserver()
        // Stage 0b: shutdown closes any in-flight turn with a failure
        // emission (mirrors handleCancel). No-op when no turn is in flight.
        emitTurnFailedTelemetry(reason: "controller_stopped")
        textInputActive = false
        currentSnapshot = nil
        snapshotStore.snapshot = nil
        responseStore.reset()
        // Stage 3b: shutdown ends the current chat-stack lifetime. The
        // next session at startup gets a fresh Langfuse-session id.
        setAgentPhase(.idle)
        state = .idle
    }

    private func bindHotkeyPreferencesIfSupported() {
        guard let configurableMonitor = gestureMonitor as? RightCmdGestureMonitor else {
            return
        }
        hotkeyPreferencesCancellable?.cancel()
        configurableMonitor.setConfiguration(HotkeyPreferences.shared.configuration)
        hotkeyPreferencesCancellable = Publishers.CombineLatest3(
            HotkeyPreferences.shared.$agentTextShortcut,
            HotkeyPreferences.shared.$agentVoiceShortcut,
            HotkeyPreferences.shared.$agentVoiceGesture
        )
            .dropFirst()
            .sink { [weak configurableMonitor] _, _, _ in
                configurableMonitor?.setConfiguration(HotkeyPreferences.shared.configuration)
            }
    }

    // MARK: - Island answer-panel hotkey lifecycle (Task 10)

    /// Mirrors the flow store's `answerPanelVisible` into the answer-panel
    /// hotkeys (⌥Q close + useful-links family). Registered when the panel
    /// appears, torn down when it goes away — exactly the show/close
    /// lifecycle `AgentResponsePanel` ran, but keyed off the store so the
    /// island answer view needs no NSPanel host. No-op without an island flow.
    private func bindAnswerPanelHotkeyLifecycle() {
        guard let islandAgentFlow else { return }
        answerPanelVisibleCancellable = islandAgentFlow.$answerPanelVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.startResponseCloseHotkey()
                    self.startUsefulLinksObserver()
                } else {
                    self.stopResponseCloseHotkey()
                    self.stopUsefulLinksObserver()
                }
            }

        // Guaranteed-Escape close: observe bare Esc for the whole lifetime of
        // a visible answer — no app-active gate. whytap is an accessory app
        // and the island answer panel is non-activating, so the app is
        // virtually never frontmost while the user reads an answer; gating on
        // frontmost (#458) turned Esc-close off entirely. Holding the monitor
        // is safe only because it is PASSIVE (NSEvent monitors, not a Carbon
        // grab): Escape still reaches the app the user is working in, which is
        // what the removed gate existed to protect.
        // WHY: docs/decisions/2026-07-02-escape-close-passive-monitor.md
        escapeCloseLifecycleCancellable = islandAgentFlow.$answerPanelVisible
            .removeDuplicates()
            .sink { [weak self] answerPanelVisible in
                guard let self else { return }
                if answerPanelVisible {
                    self.startEscapeCloseHotkey()
                } else {
                    self.stopEscapeCloseHotkey()
                }
            }
    }

    /// Brings the ⌥Q close hotkey online for the visible answer panel.
    /// Reuses the same Carbon adapter the legacy panel built; `start()` is
    /// idempotent, and `responseCloseHotkeyActive` guards against piling up
    /// registrations on repeated `true` emissions.
    private func startResponseCloseHotkey() {
        if responseCloseHotkeyActive { return }
        let hotkey = responseCloseHotkey ?? makeResponseCloseHotkey()
        responseCloseHotkey = hotkey
        do {
            try hotkey.start()
            responseCloseHotkeyActive = true
            bindResponseCloseHotkeyPreferences()
        } catch {
            // Soft-fail (same contract as the legacy panel): another app may
            // own ⌥Q. The crest (✕) dismiss and Esc paths still work.
            os_log(
                "island close hotkey start failed: %{public}@",
                log: Self.log, type: .error,
                String(describing: error)
            )
        }
    }

    private func stopResponseCloseHotkey() {
        guard responseCloseHotkeyActive else { return }
        responseCloseHotkey?.stop()
        responseCloseHotkeyActive = false
        answerCloseHotkeyPreferencesCancellable?.cancel()
        answerCloseHotkeyPreferencesCancellable = nil
    }

    private func makeResponseCloseHotkey() -> AgentResponseCloseHotkeyControlling {
        let hotkey = closeHotkeyFactory()
        hotkey.setOnHotkey { [weak self] in
            // Funnel through the same cancel path the wing/answer dismiss
            // affordances use so panel close is a single source of truth.
            self?.handleCancel()
        }
        return hotkey
    }

    /// Brings the fixed bare-Escape close monitor online. `escapeCloseHotkeyActive`
    /// guards against piling up registrations on repeated `true` emissions
    /// (the subscription already de-dupes, but the guard is cheap and keeps
    /// the start path idempotent). Esc is not user-configurable, so unlike
    /// `startResponseCloseHotkey` there is no preference-rebind subscription.
    private func startEscapeCloseHotkey() {
        if escapeCloseHotkeyActive { return }
        let hotkey = escapeCloseHotkey ?? makeEscapeCloseHotkey()
        escapeCloseHotkey = hotkey
        do {
            try hotkey.start()
            escapeCloseHotkeyActive = true
            // Diagnostic for the "Escape close broken" bug family: record WHEN
            // the monitor comes online and which app was frontmost. Level
            // .default (not .info) so it persists in `log show` — the #458
            // recurrence was invisible post-factum because .info is memory-only.
            // Privacy: bundle id only, no key contents.
            os_log(
                "escape_close_registered frontmost=%{public}@",
                log: Self.log, type: .default,
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            )
        } catch {
            // Soft-fail (same contract as ⌥Q + useful-links): log and move
            // on — ⌥Q and the close button still dismiss the panel. (The
            // passive monitor's start does not actually throw; this arm is
            // the protocol's contract for the Carbon-backed ⌥Q sibling.)
            os_log(
                "island escape close hotkey start failed: %{public}@",
                log: Self.log, type: .error,
                String(describing: error)
            )
        }
    }

    private func stopEscapeCloseHotkey() {
        guard escapeCloseHotkeyActive else { return }
        escapeCloseHotkey?.stop()
        escapeCloseHotkeyActive = false
        // Pairs with `escape_close_registered`: the monitor's lifetime should
        // exactly track answer-panel visibility, so an unpaired register (or a
        // long gap) means the lifecycle leaked.
        // WHY: docs/decisions/2026-07-02-escape-close-passive-monitor.md
        os_log("escape_close_unregistered", log: Self.log, type: .default)
    }

    private func makeEscapeCloseHotkey() -> AgentResponseCloseHotkeyControlling {
        let hotkey = escapeCloseHotkeyFactory()
        hotkey.setOnHotkey { [weak self] in
            // Same single dismiss path as ⌥Q / the close button.
            self?.handleCancel()
        }
        return hotkey
    }

    private func bindResponseCloseHotkeyPreferences() {
        guard answerCloseHotkeyPreferencesCancellable == nil else { return }
        answerCloseHotkeyPreferencesCancellable = hotkeyPreferences
            .$agentCloseShortcut
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.responseCloseHotkeyActive else { return }
                self.stopResponseCloseHotkey()
                self.responseCloseHotkey = nil
                self.startResponseCloseHotkey()
            }
    }

    /// Brings the useful-links hotkey family online and starts the Combine
    /// subscription on `responseStore.blocks` that resynchronises the shared
    /// selection state + hotkey registration whenever a links block lands or
    /// vanishes. Mirrors the legacy panel's `startUsefulLinksObserver`.
    private func startUsefulLinksObserver() {
        guard usefulLinksBlocksCancellable == nil else { return }
        let hotkey = usefulLinksHotkey ?? makeUsefulLinksHotkey()
        usefulLinksHotkey = hotkey
        usefulLinksBlocksCancellable = responseStore
            .$blocks
            .receive(on: RunLoop.main)
            .sink { [weak self] blocks in
                self?.syncUsefulLinks(from: blocks)
            }
        bindUsefulLinksHotkeyPreferences()
    }

    private func stopUsefulLinksObserver() {
        usefulLinksBlocksCancellable?.cancel()
        usefulLinksBlocksCancellable = nil
        usefulLinksHotkeyPreferencesCancellable?.cancel()
        usefulLinksHotkeyPreferencesCancellable = nil
        usefulLinksHotkey?.stop()
        islandLinksSelection?.apply(items: [])
    }

    /// Pulls the active actions block out of the rendered set (the LAST one
    /// wins — see `IslandAgentAnswerPanelView.latestUsefulActions`) and drives
    /// the shared selection state + hotkey registration off its items. The live
    /// agent path emits `.usefulActions`; for robustness a legacy `.usefulLinks`
    /// block (any surface still emitting it) folds into `.link` items as a
    /// fallback when no `.usefulActions` block is present.
    private func syncUsefulLinks(from blocks: [UIBlock]) {
        let activeItems: [ActionItem]
        if let actions = IslandAgentAnswerPanelView.latestUsefulActions(in: blocks) {
            activeItems = actions.items
        } else if let links = IslandAgentAnswerPanelView.latestUsefulLinks(in: blocks) {
            activeItems = links.links.map {
                .link(url: $0.url, description: $0.description, provider: $0.provider)
            }
        } else {
            activeItems = []
        }
        islandLinksSelection?.apply(items: activeItems)
        reregisterUsefulLinksHotkey()
    }

    /// Re-registers the hotkey family from the current selection state. Called
    /// on block change, selection move, and prefs change. The Open hotkey
    /// follows the *selected* item's type — a copy item omits it — so this must
    /// run whenever the selection index moves, not only when the block changes.
    private func reregisterUsefulLinksHotkey() {
        usefulLinksHotkey?.start(
            itemCount: islandLinksSelection?.items.count ?? 0,
            openAvailable: islandLinksSelection?.selectedItemSupportsOpen ?? false
        )
    }

    private func bindUsefulLinksHotkeyPreferences() {
        guard usefulLinksHotkeyPreferencesCancellable == nil else { return }
        // Re-register on prefs changes (new combos) AND on selection moves so
        // the Open hotkey tracks the selected item's open-availability.
        let prefs = hotkeyPreferences.objectWillChange.map { _ in () }
        let selection = islandLinksSelection?.$currentIndex
            .map { _ in () }
            .eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
        usefulLinksHotkeyPreferencesCancellable = Publishers.Merge(prefs, selection)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.reregisterUsefulLinksHotkey()
                }
            }
    }

    /// Builds the useful-links hotkey controller and wires its four action
    /// handlers — Insert, Open, Next, Previous — to the same effect paths the
    /// legacy panel used (Insert pastes via `InsertExecutor`; Open launches
    /// the URL; Next/Previous move the shared selection chip).
    private func makeUsefulLinksHotkey() -> UsefulLinksHotkeyController {
        let controller = usefulLinksHotkeyFactory()
        controller.onInsert = { [weak self] in
            self?.handleUsefulLinksInsert()
        }
        controller.onOpen = { [weak self] in
            self?.handleUsefulLinksOpen()
        }
        controller.onNext = { [weak self] in
            self?.islandLinksSelection?.selectNext()
        }
        controller.onPrevious = { [weak self] in
            self?.islandLinksSelection?.selectPrevious()
        }
        // A chip click runs the same insert/open path as the hotkeys (we own
        // the focus snapshot + executor). Open for a path opens the file in its
        // default app — never an auto-run.
        islandLinksSelection?.onInsertItem = { [weak self] item in
            self?.handleActionInsert(item)
        }
        islandLinksSelection?.onOpenItem = { [weak self] item in
            self?.handleActionOpen(item)
        }
        return controller
    }

    /// Insert hotkey: paste the selected action item's `insertText` (URL string
    /// for a link, raw path for a path, text for a copy) into the previously-
    /// focused app via the current focus snapshot. The panel stays open after
    /// the paste — canonical dismissal is ✕ / ⌥Q / next turn.
    private func handleUsefulLinksInsert() {
        guard let item = islandLinksSelection?.selectedItem else { return }
        handleActionInsert(item)
    }

    /// Open hotkey: hand the selected item to the system. Link → default
    /// browser, path → default app for that file (Finder-style open, never an
    /// auto-run), copy → no-op (its hotkey is never registered). Leaves the
    /// answer panel open for sequential opens.
    private func handleUsefulLinksOpen() {
        guard let item = islandLinksSelection?.selectedItem else { return }
        handleActionOpen(item)
    }

    /// Pastes an action item's `insertText` into the focus-snapshot target.
    /// Split out from the hotkey entry point so the per-type dispatch is
    /// independent of the selection-state plumbing.
    private func handleActionInsert(_ item: ActionItem) {
        guard let snapshot = currentSnapshot else { return }
        let executor = makeInsertExecutor()
        let variant = InsertVariant(
            id: "useful_action_insert",
            label: "Insert",
            text: item.insertText,
            actionType: .paste
        )
        Task { @MainActor in
            _ = try? await executor.execute(variant, snapshot: snapshot)
        }
    }

    /// Opens an action item's `openTarget` via `NSWorkspace`. `nil` target
    /// (copy items) is a no-op — the open hotkey is not registered for copy,
    /// this is belt-and-braces. A path target is a `file://` URL, so the system
    /// opens the file in its default app exactly like a Finder double-click; it
    /// never runs the path's contents as a command.
    private func handleActionOpen(_ item: ActionItem) {
        guard let target = item.openTarget else { return }
        NSWorkspace.shared.open(target)
    }

    /// Single writer for `AppState.agentPhase`. Every controller transition
    /// flows through here so the island flow store (`IslandAgentFlowStore`)
    /// receives the exact same phase the orb-era UI consumed via
    /// `AppState.agentPhase`. Keeps the orb-state UI and the island in lock
    /// step from one place instead of mirroring at 14 call sites.
    private func setAgentPhase(_ phase: AgentPhase) {
        AppState.shared.agentPhase = phase
        islandAgentFlow?.agentPhaseChanged(phase)
    }

    func submitTextQuery(_ text: String, snapshot: FocusSnapshot) {
        submitQuery(text, snapshot: snapshot, mode: .text)
    }

    // MARK: - Google search UI helpers (Task 8)

    /// Open the composing wing in Google mode (placeholder driven by
    /// `activeSourceIsGoogle`). Does NOT run the agent; the island routes
    /// a Return press to `onGoogleTextSubmit` instead. Called by the
    /// AppDelegate google-text-tap callback so the shared island surface
    /// (composer wing + orb) shows Google colours.
    func startGoogleTextInputUI() {
        textInputActive = true
        setAgentPhase(.textInputActive)
        // Parity with `handleTap` (line ~981): set the state machine so the
        // open composer is detectable (`isTextComposerOpen`) and a second
        // R-Option tap can toggle it closed instead of re-opening.
        state = .textInput
    }

    /// True when a text composer is open on the shared island surface
    /// (`state == .textInput && textInputActive`) — exactly the condition the
    /// agent `handleTap` toggle keys on. Generic across composer sources
    /// (agent OR Google): this predicate cannot tell them apart. Exposed so the
    /// AppDelegate Google callback can detect an already-open composer and
    /// toggle it closed on a second R-Option tap, without reaching into private
    /// controller state. The caller pairs it with the flow store's
    /// `activeSourceIsGoogle` to confirm the open composer is the Google one.
    var isTextComposerOpen: Bool {
        state == .textInput && textInputActive
    }

    /// Show the island recording wing in Google mode. Called by the
    /// AppDelegate google-hold-start callback before handing audio to
    /// `GoogleSearchController`. Does NOT start an agent session.
    ///
    /// Parity with the agent voice hold-start's UI-state setup
    /// (`handleHoldStart`): the orb only re-renders into the recording state
    /// when the response store is marked `.recording` (the flow store's
    /// response-store sink drives the recording surface off it) — phase alone
    /// is not enough. We copy ONLY the UI-state calls
    /// (`reset` + `markLocalStatus` + phase + state), NOT the agent
    /// telemetry / snapshot / voice-session concerns, which the Google flow
    /// (driven by `GoogleSearchController`) must never touch.
    func startGoogleRecordingUI() {
        responseStore.reset()
        responseStore.markLocalStatus(.recording)
        setAgentPhase(.voiceRecording)
        state = .voiceRecording
    }

    /// Return the island to idle from a google end/cancel. Called by
    /// the AppDelegate google-hold-end / google-cancel callbacks after
    /// `GoogleSearchController` has resolved (or discarded) the session.
    ///
    /// Resets `state` to `.idle` too: `startGoogleRecordingUI()` drives the
    /// state machine to `.voiceRecording` (orb parity), so the teardown must
    /// clear it or a stale `.voiceRecording` would route the next agent voice
    /// tap to `.stopVoiceCapture` instead of starting a capture.
    func endGoogleUI() {
        textInputActive = false
        setAgentPhase(.idle)
        state = .idle
    }

    /// External trigger for the text-input flow normally driven by the
    /// Right Cmd tap gesture. Routes through `handleTap()` so the
    /// existing toggle / snapshot / telemetry path runs unchanged.
    /// Wired by the Dynamic Island toolbar's text-agent slot.
    func triggerTextAgent() {
        handleTap()
    }

    /// External trigger for the voice flow normally driven by the
    /// Right Cmd hold gesture. Routes through `handleHoldStart()` so
    /// snapshot capture, voice-session start, telemetry and AppState
    /// transitions run identically to a real hold. Since a click is
    /// point-in-time (no key-up event to bracket the recording), the
    /// turn closes via `AgentVoiceSession.onAutoStop` at max duration —
    /// same path the Carbon hold uses when the user keeps the key
    /// down past the cap. Wired by the Dynamic Island toolbar's
    /// voice-agent slot.
    func triggerVoiceAgent() {
        handleHoldStart()
    }

    /// External trigger for the voice-flow termination normally driven
    /// by the Right Cmd hold release. Routes through `handleHoldEnd()`
    /// so the stop -> transcribe -> agent path runs identically to
    /// a real hold release. Lets the Dynamic Island agent mini-orb act
    /// as a toggle: first click starts the session via
    /// `triggerVoiceAgent()`, second click ends + submits via this
    /// method (without waiting for `AgentVoiceSession.onAutoStop`'s
    /// max-duration cap).
    func triggerVoiceAgentEnd() {
        Task { @MainActor in
            await handleHoldEnd()
        }
    }

    /// Submit the composing wing's text as an agent prompt. Wired to the
    /// island's `submitAgentText` callback. Routes through the same
    /// `handleTextSubmit` path the legacy text-input panel used, so snapshot
    /// validation, the connection gate, and the SSE consume loop run
    /// identically.
    func submitIslandText(_ text: String) {
        handleTextSubmit(text)
    }

    /// Cancel the active agent flow from an island affordance (Esc in the
    /// composing wing, the answer panel's dismiss button). Routes through the
    /// existing `handleCancel` teardown so focus restore, telemetry close,
    /// and the store reset run exactly as a gesture-driven cancel.
    func cancelAgentFlowFromIsland() {
        handleCancel()
    }

    private func submitQuery(_ text: String, snapshot: FocusSnapshot, mode: HistoryQueryMode) {
        // Cmd+C fallback for Electron / Chromium apps where AX returned
        // no selection. The fallback runs via DispatchQueue.main.async
        // (out of any NSEvent monitor closure) so synthetic Cmd+C events
        // do not re-enter the gesture state machine. v1 (#103) and v2
        // (#106) both broke Right Cmd by posting the events inside the
        // flagsChanged handler — v3 moves the dance to submit time,
        // after the gesture has fully resolved.
        // Gate the turn on an active connection. After a full Disconnect
        // (AgentProviderStore.activeProvider == nil) the production
        // resolveProvider yields nil; refuse with a "connect first" message
        // instead of silently running a CLI. Runs BEFORE the Cmd+C fallback so
        // a disconnected gesture never synthesises a copy.
        guard let provider = resolveProvider() else {
            showNotConnected()
            return
        }
        guard Self.shouldRunSelectionFallback(snapshot: snapshot) else {
            continueSubmit(text, snapshot: snapshot, mode: mode, provider: provider)
            return
        }
        selectionFallbackInvoker.invoke(snapshot.targetPID) { [weak self] captured in
            guard let self else { return }
            let updated = snapshot.withSelectionText(captured)
            self.currentSnapshot = updated
            self.snapshotStore.snapshot = updated
            self.continueSubmit(text, snapshot: updated, mode: mode, provider: provider)
        }
    }

    /// Returns true when the snapshot has no usable AX selection — the
    /// Cmd+C fallback should be attempted before submission. Reading
    /// secure text fields (`isEditable == false`) is intentionally NOT a
    /// reason to skip — empty selection in a non-editable app (Cursor
    /// status bar, a code-editor file tab) is still worth probing.
    static func shouldRunSelectionFallback(snapshot: FocusSnapshot) -> Bool {
        guard let text = snapshot.selectionText else { return true }
        return text.isEmpty
    }

    /// Assembles the prompt sent to the CLI. The behavioural preamble is
    /// prepended only when `includePreamble` is true — the first turn of a
    /// fresh session. On resume it is already in the CLI's history, so callers
    /// pass `false` and the prompt is just the optional selection plus query.
    private func buildPrompt(query: String, snapshot: FocusSnapshot, includePreamble: Bool) -> String {
        var parts: [String] = []
        if includePreamble {
            parts.append(Self.sharedMemoryPromptPreamble)
        }
        if let selection = snapshot.selectionText, !selection.isEmpty {
            parts.append("Selected text:\n\(Self.selectionForPrompt(selection))")
        }
        // The first-turn preamble is not resent when a native CLI session is
        // resumed. Repeat this one small language rule every turn so tool
        // output or older conversation context cannot make the answer drift.
        parts.append(Self.perTurnLanguageInstruction)
        parts.append(query)
        return parts.joined(separator: "\n\n")
    }

    static func selectionForPrompt(_ text: String) -> String {
        guard text.count > maximumSelectionCharacters else { return text }
        let available = maximumSelectionCharacters - selectionTruncationMarker.count
        let prefixCount = available / 2
        let suffixCount = available - prefixCount
        return String(text.prefix(prefixCount))
            + selectionTruncationMarker
            + String(text.suffix(suffixCount))
    }

    private func continueSubmit(_ text: String, snapshot: FocusSnapshot, mode: HistoryQueryMode, provider: any CLIProvider) {
        beginSubmit(snapshot: snapshot)
        startActiveRow(queryText: text, mode: mode)
        // Stage 0b: emit `voice_turn_started` EAGERLY (before the CLI spawn)
        // with `turn_id="pending"`. The real `turn_id` is captured from the
        // `started` SSE event and used for the matching `_completed` / `_failed`
        // emission. `startTurnTelemetry` is idempotent: voice flows call it
        // earlier in `handleHoldStart`, so the post-transcribe `submitQuery`
        // call does NOT double-emit. Text flows arrive here with no prior emit.
        startTurnTelemetry(mode: mode, flow: .agent)
        responseStore.markLocalStatus(.thinking)
        // Pill 1 shows the user's own query (their "drop") for this turn rather
        // than a generic "Thinking" — provider-agnostic, works for both claude
        // and codex (which name sessions differently / not at all locally).
        responseStore.showTitle(text)
        // Island routing: echo the dispatched query into the flow store so the
        // answer panel's query row shows it. The answer panel itself opens off
        // store content / permission via `IslandAgentFlowStore`; the controller
        // no longer drives a panel show here.
        islandAgentFlow?.querySubmitted(text)

        activeTurnProvider = provider
        let options = resolveRunOptions(provider.id)
        // Resume id drives both the CLI resume AND whether to send the
        // behavioural preamble: nil means a fresh session (first turn) that has
        // never seen it, so prepend; non-nil means the preamble is already in
        // the CLI's history and must not be repeated. Computed before
        // buildPrompt so the two stay in lock step.
        let resumeSessionID = agentSessionStore.sessionID(for: provider.id)
        let prompt = buildPrompt(
            query: text,
            snapshot: snapshot,
            includePreamble: resumeSessionID == nil
        )
        consume(provider.run(prompt: prompt, resumeSessionID: resumeSessionID, options: options))
    }

    /// Surface a "connect a provider first" message instead of silently
    /// running a CLI when nothing is connected (activeProvider == nil after a
    /// full Disconnect). Mirrors showTranscriptionError's panel + idle reset.
    private func showNotConnected() {
        responseStore.markErrorBlock(StateErrorBlock(
            title: "No agent connected",
            subtitle: "Connect in Settings",
            message: "Connect Claude Code or Codex in Settings to use the agent.",
            code: "not_connected",
            retryable: false
        ))
        // Island routing: surface the "connect first" prompt as a transient
        // wing notice. The turn never dispatched, so there is no answer body
        // to open. No-op when no island flow is wired (island is the only
        // answer surface).
        islandAgentFlow?.sttFailed(message: "Connect an agent in Settings")
        // M9: the "connect an agent" prompt is now visible — fire-and-forget
        // a PII-free user_error classified as a not-connected error (not STT).
        currentSnapshot = nil
        snapshotStore.snapshot = nil
        setAgentPhase(.idle)
        state = .idle
    }

    private func handleTap() {
        // WHY: docs/superpowers/specs/2026-06-27-capability-opt-in-gating-design.md
        guard agentEnabled() else {
            onAgentSetupRequired()
            return
        }
        guard resolveProvider() != nil else {
            onAgentSetupRequired()
            return
        }
        // Toggle: if the composing wing is already on screen, a second R-Cmd
        // tap closes it (mirroring Esc), restoring focus to the captured
        // snapshot and returning to idle. Only the text-input state qualifies;
        // voice and executing states keep their own dismissal paths.
        if state == .textInput, textInputActive {
            handleCancel()
            return
        }
        // No agent telemetry: nothing about a turn leaves the machine — only
        // audio goes through the user's STT path.
        ensureSnapshot()
        // Island routing: the composing wing (driven by `agentPhase ==
        // .textInputActive` through the flow store) owns the text input. The
        // live path only transitions phase — the island is the only input
        // surface.
        textInputActive = true
        setAgentPhase(.textInputActive)
        state = .textInput
    }

    private func handleTextSubmit(_ text: String) {
        // When the composing wing belongs to the Google gesture, route the
        // text to the Google controller instead of the agent. The UI teardown
        // (phase → idle, flag reset) is the caller's responsibility via the
        // injected closure; the agent path (snapshot gate, SSE submit) must
        // NOT run for a Google submit.
        if islandAgentFlow?.activeSourceIsGoogle == true {
            textInputActive = false
            onGoogleTextSubmit(text)
            return
        }
        guard let snapshot = currentSnapshot else {
            handleCancel()
            return
        }
        textInputActive = false
        submitTextQuery(text, snapshot: snapshot)
    }

    private func handleHoldStart(triggerGesture: String = "hold") {
        // WHY: docs/superpowers/specs/2026-06-27-capability-opt-in-gating-design.md
        guard agentEnabled() else {
            onAgentSetupRequired()
            return
        }
        guard resolveProvider() != nil else {
            onAgentSetupRequired()
            return
        }
        // No hotkey/turn events ever leave the machine for the agent path; the
        // local turn state machine (startTurnTelemetry) only feeds os_log.
        startTurnTelemetry(mode: .voice, flow: .agent)
        ensureSnapshot()
        responseStore.reset()

        if streamingVoiceEnabled, realtimeVoiceEnabled(), let agentVoiceStreamFactory {
            responseStore.markLocalStatus(.recording)
            setAgentPhase(.voiceRecording)
            state = .voiceRecording
            // Re-entrant hold-start: fully tear down any prior session
            // (cancel task AND resolve its continuation) before spawning a
            // new one — a bare task cancel would orphan a live WS session.
            teardownRealtimeVoiceSession()
            realtimeRunTask = Task { @MainActor [weak self] in
                guard let self else { return }
                guard let session = await agentVoiceStreamFactory() else {
                    await self.handleStreamResult(.failed(.transportFailed))
                    return
                }
                // The factory suspends on a JWT refresh; if teardown
                // (stop / cancel / hold-end) cancelled this task during that
                // window, `realtimeVoiceSession` was still nil so teardown
                // could not close the session. Close the freshly-built one
                // here — cancel() resolves its continuation and tears down the
                // WS + mic tap — and never call run(), which would otherwise
                // start an orphaned, un-stoppable recording.
                if Task.isCancelled {
                    await session.cancel()
                    return
                }
                // Surface live partials in the island recording wing as words
                // land. Every streaming session drives this sink; the protocol
                // requirement lets us wire it without a concrete down-cast.
                // No-op when no island flow is present.
                session.onTranscriptUpdate = { [weak self] text in
                    self?.islandAgentFlow?.transcriptUpdated(text)
                }
                self.realtimeVoiceSession = session
                let result = await session.run()
                await self.handleStreamResult(result)
            }
            return
        }

        voiceSession?.cancel()
        let session = voiceSessionFactory()
        session.onAutoStop = { [weak self] in
            Task { @MainActor in
                await self?.handleHoldEnd()
            }
        }
        voiceSession = session
        session.start()

        responseStore.markLocalStatus(.recording)
        setAgentPhase(.voiceRecording)
        state = .voiceRecording
    }

    /// Tears down an in-flight realtime voice session: cancels the run task
    /// AND calls the session's own cancel() (Swift task cancellation alone
    /// does not resolve the session's checked continuation).
    private func teardownRealtimeVoiceSession() {
        realtimeRunTask?.cancel()
        realtimeRunTask = nil
        if let session = realtimeVoiceSession {
            realtimeVoiceSession = nil
            Task { await session.cancel() }
        }
    }

    private func handleStreamResult(_ result: StreamingSessionResult) async {
        realtimeRunTask = nil
        realtimeVoiceSession = nil
        switch result {
        case .transcript(let text), .endpointDetected(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                closeVoiceWithoutSubmit()
                return
            }
            guard let snapshot = currentSnapshot else {
                closeVoiceWithoutSubmit()
                return
            }
            // Match the batch path's ordering (state before agentPhase) so
            // there is no window where agentPhase == .executing while state
            // is still .voiceRecording.
            state = .executing
            setAgentPhase(.executing)
            submitQuery(text, snapshot: snapshot, mode: .voice)
        case .failed(let err):
            await handleStreamFailure(err)
        case .cancelled, .degraded:
            // `.degraded` (Drop resilient-delivery) has no batch-recovery path
            // for agent voice — there is no retained-audio fallback wired here
            // and no transcript to submit — so reset to idle like `.cancelled`.
            closeVoiceWithoutSubmit()
        }
    }

    private func handleStreamFailure(_ error: StreamingSessionError) async {
        os_log(
            "agent realtime voice failed: %{public}@",
            log: Self.log,
            type: .error,
            String(describing: error)
        )
        // Mirror the batch path: surface the same transcription-error UI
        // and emit voice_turn_failed telemetry via showTranscriptionError.
        showTranscriptionError(error)
    }

    // MARK: - Voice-tap toggle routing

    /// Route for a voice-tap gesture (Toggle mode).  Pure function so the
    /// toggle logic can be pinned by `AgentVoiceTapToggleTests` without
    /// standing up the full controller.
    enum AgentVoiceTapRoute: Equatable {
        /// Start a new voice capture (first tap, or tap from idle).
        case startVoiceCapture
        /// Stop the active voice capture (second tap = toggle stop).
        case stopVoiceCapture
        /// No action — tap arrives in a state where starting or stopping
        /// would race with an active session.
        case noop
    }

    static func agentVoiceTapRoute(state: AgentControllerState) -> AgentVoiceTapRoute {
        switch state {
        case .voiceRecording: return .stopVoiceCapture
        case .idle:           return .startVoiceCapture
        case .textInput:      return .noop
        case .executing:      return .noop
        }
    }

    private func handleVoiceTap() async {
        switch Self.agentVoiceTapRoute(state: state) {
        case .startVoiceCapture:
            handleHoldStart(triggerGesture: "tap")
        case .stopVoiceCapture:
            await handleHoldEnd()
        case .noop:
            break
        }
    }

    private func handleHoldEnd() async {
        guard state == .voiceRecording else {
            return
        }

        if streamingVoiceEnabled {
            if let realtime = realtimeVoiceSession {
                // stop() resolves the suspended run() → handleStreamResult
                // fires on the run Task with the final transcript.
                await realtime.stop()
            } else if realtimeRunTask != nil {
                // The session factory is still in flight (JWT refresh) so no
                // session exists to stop. Cancel the run Task; its post-factory
                // `Task.isCancelled` check closes the freshly-built session
                // before run() can start an orphaned recording.
                teardownRealtimeVoiceSession()
                closeVoiceWithoutSubmit()
            }
            return
        }

        // Snapshot duration + peak from the session BEFORE clearing it —
        // both are frozen at `stop()` time, but the session reference is
        // about to be released.
        let session = voiceSession
        let audio = await session?.stop()
        let durationSeconds = session?.elapsedSeconds ?? 0
        let peakEnergy = session?.peakEnergy ?? 0
        voiceSession = nil

        guard let audio, !audio.isEmpty, let snapshot = currentSnapshot else {
            closeVoiceWithoutSubmit()
            return
        }

        // Pre-flight silence guard: a fast tap-and-release of Right Cmd
        // produces a tiny WAV that's non-empty in bytes (header + a few
        // PCM frames of background noise) but contains no speech. Running
        // the transcriber on it would surface an alarming "Transcription
        // failed" pill for what was really a finger-twitch. Drop it here
        // instead: log, close the UI silently, leave the user with the same
        // outcome they'd have if they hadn't triggered the gesture at all.
        let detector = AudioSilenceDetector()
        switch detector.decide(durationSeconds: durationSeconds, peakEnergy: peakEnergy) {
        case .drop(let reason):
            os_log(
                "voice gesture dropped pre-transcribe reason=%{public}@ duration_ms=%{public}d peak_energy=%{public}.3f",
                log: Self.log,
                type: .info,
                reason.rawValue,
                Int(durationSeconds * 1000),
                Double(peakEnergy)
            )
            closeVoiceWithoutSubmit()
            return
        case .proceed:
            break
        }

        state = .executing
        // Voice always goes through STT -> text -> the local agent CLI.
        responseStore.markLocalStatus(.transcribing)
        setAgentPhase(.transcribing)

        do {
            let languageCode = privacyPreferences.selectedLanguage?.code
            let text = try await audioTranscriber.transcribe(
                audioData: audio,
                language: languageCode
            )
            // A sub-second voice gesture transcribes to an empty/whitespace
            // string — a gesture misfire, not an error. Skip the agent
            // dispatch silently; the UI returns to idle as if the gesture
            // never happened.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                os_log(
                    "voice transcript empty; skipping agent dispatch",
                    log: Self.log,
                    type: .debug
                )
                closeVoiceWithoutSubmit()
                return
            }
            setAgentPhase(.executing)
            submitQuery(text, snapshot: snapshot, mode: .voice)
        } catch {
            showTranscriptionError(error)
        }
    }

    private func handleCancel() {
        consumeTask?.cancel()
        consumeTask = nil
        voiceSession?.cancel()
        voiceSession = nil
        teardownRealtimeVoiceSession()
        // Stage 0b: cancel terminates an in-flight turn — emit
        // `voice_turn_failed` so the funnel from voice_turn_started closes.
        // No-op when no telemetry started (text-input-only path with no
        // submit yet, or already finalised turn).
        emitTurnFailedTelemetry(reason: "cancelled")
        textInputActive = false
        // No focus restore on cancel. The composer is a non-activating panel,
        // so the agent never stole focus from the user's app — there is nothing
        // to "return". Restoring the captured target here only yanked the user
        // back (often a Space switch) when they had moved to another window
        // while the agent ran — bad UX on dismiss. Drop's paste-target restore
        // is a SEPARATE path (AutoPasteEngine) and is unaffected.
        currentSnapshot = nil
        snapshotStore.snapshot = nil
        responseStore.reset()
        setAgentPhase(.idle)
        state = .idle
    }

    private func closeVoiceWithoutSubmit() {
        // Stage 0b: silence-guard / empty-transcript paths emit
        // `voice_turn_failed` so the started→terminator funnel closes.
        // Reason classifies into a distinct bucket so "user fumbled the
        // gesture" stays separate from real transcription / provider
        // failures.
        emitTurnFailedTelemetry(reason: "voice_gesture_aborted")
        currentSnapshot = nil
        snapshotStore.snapshot = nil
        responseStore.reset()
        setAgentPhase(.idle)
        state = .idle
    }

    private func finishWithoutResponse() {
        currentSnapshot = nil
        snapshotStore.snapshot = nil
        setAgentPhase(.idle)
        state = .idle
    }

    private func ensureSnapshot() {
        if currentSnapshot == nil {
            currentSnapshot = snapshotStore.snapshot ?? snapshotProvider()
        }
    }

    private func beginSubmit(snapshot: FocusSnapshot) {
        consumeTask?.cancel()
        currentSnapshot = snapshot
        snapshotStore.snapshot = snapshot
        responseStore.reset()
        setAgentPhase(.executing)
        state = .executing
    }

    private func consume(_ stream: AsyncStream<AgentSSEEvent>) {
        consumeTask?.cancel()
        consumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await responseStore.consume(
                stream,
                onFirstBlock: {
                    // No-op: the island answer panel opens off the flow
                    // store's content / status, so block arrival needs no
                    // explicit surface call from the controller.
                },
                onErrorEvent: {
                    // The error block written to the store surfaces in the
                    // island answer panel (the flow store opens it on
                    // error content). The controller only records the row.
                    let message = self.responseStore.errorMessage ?? ""
                    self.markActiveRowError(message: message)
                    // M9: an agent error is now visible in the answer panel.
                    // The `message` text (which may carry CLI detail) stays in
                    // the panel and the history row — it never leaves the app.
                },
                onCompletionEvent: {
                    if AppState.shared.agentPhase == .executing {
                        self.setAgentPhase(.idle)
                    }
                    // Persist the CLI session id for native resume / auto-compact
                    // continuity on the next turn. Nil means "keep the previous
                    // known id" because some error paths do not restate it.
                    if let provider = self.activeTurnProvider,
                       let sessionID = provider.lastSessionID {
                        self.agentSessionStore.setSessionID(sessionID, for: provider.id)
                    }
                    self.finalizeActiveRow()
                },
                onToolEvent: { tool in
                    self.recordActiveRowTool(tool)
                },
                onVoiceTranscript: { text in
                    self.updateActiveRowQueryText(text)
                },
                onStartedEvent: { turnId in
                    // Stage 0b: capture the provider-issued turn_id so the
                    // matching `voice_turn_completed` / `_failed` carries the
                    // real id (instead of the placeholder `"pending"` from
                    // eager start).
                    self.activeTurnId = turnId
                }
            )
        }
    }

    private func showTranscriptionError(_ error: Error) {
        // Island routing: STT failures surface as a short transient notice in
        // the recording wing rather than a full error answer panel — the turn
        // never reached the agent, so there is nothing to render. The error
        // block is intentionally NOT written to the store so the answer panel
        // does not open on its `errorMessage` content. No-op when no island
        // flow is wired (island is the only answer surface).
        islandAgentFlow?.sttFailed(message: "Didn't catch that — try again")
        // M9: the STT failure notice is now visible — fire-and-forget a
        // PII-free user_error (the raw `error` text is never forwarded).
        // Stage 0b: voice path failed at transcription, before the agent
        // ever opened. Emit `voice_turn_failed` so the funnel from
        // `voice_turn_started` (fired at handleHoldStart) closes properly.
        emitTurnFailedTelemetry(
            reason: transcriptionErrorMessage(for: error)
        )
        currentSnapshot = nil
        snapshotStore.snapshot = nil
        setAgentPhase(.idle)
        state = .idle
    }

    private func makeInsertExecutor() -> InsertExecutor {
        InsertExecutor(
            formatter: ClientInsertFormatter(),
            textInserter: TextInserter(),
            snapshot: currentSnapshot
        )
    }

    // MARK: - Voice turn telemetry (Stage 0b)

    /// Origin of a voice/agent turn — admin dashboards split metrics by
    /// `flow=drop` (Option+/) vs. `flow=agent` (R-Cmd). Internal helper so
    /// call sites stay readable.
    private enum TurnFlow: String {
        case drop
        case agent
    }

    /// Emits `voice_turn_started` once per turn and seeds `activeTurnId`
    /// with the placeholder `"pending"`. The real id replaces it when the
    /// SSE `started` event lands. Idempotent: voice flows call this from
    /// `handleHoldStart`, but the same turn flows through `submitQuery`
    /// post-transcribe — the second call must not double-emit.
    private func startTurnTelemetry(mode: HistoryQueryMode, flow: TurnFlow) {
        guard !didEmitTurnStarted else { return }
        didEmitTurnStarted = true
        activeTurnId = "pending"
        activeTurnMode = mode.rawValue
        didEmitTurnTerminator = false
        // Local bookkeeping only — nothing is emitted anywhere.
        _ = flow
    }

    /// Resets all turn-telemetry bookkeeping. Called between turns so the
    /// next `startTurnTelemetry` fires fresh.
    private func resetTurnTelemetryState() {
        didEmitTurnStarted = false
        didEmitTurnTerminator = false
        activeTurnId = nil
        activeTurnMode = nil
    }

    /// Emits `voice_turn_completed` for the active turn. Idempotent —
    /// `didEmitTurnTerminator` ensures completion + failure cannot both fire.
    /// Only emits when a matching `voice_turn_started` was already sent
    /// (avoids zombie `completed` events for paths that bypassed the start).
    /// Resets telemetry state so the next turn starts fresh.
    private func emitTurnCompletedTelemetry() {
        guard didEmitTurnStarted, !didEmitTurnTerminator else { return }
        didEmitTurnTerminator = true
        // Local bookkeeping only — nothing is emitted anywhere.
        resetTurnTelemetryState()
    }

    /// Emits `voice_turn_failed` for the active turn. `reason` names the
    /// failure bucket (network vs. provider vs. transcribe vs. payload) for
    /// local bookkeeping only — it is not recorded anywhere.
    /// Idempotent via `didEmitTurnTerminator`. Only emits when a matching
    /// `voice_turn_started` was already sent. Resets telemetry state.
    private func emitTurnFailedTelemetry(reason: String) {
        guard didEmitTurnStarted, !didEmitTurnTerminator else { return }
        didEmitTurnTerminator = true
        // Local bookkeeping only — `reason` is not recorded anywhere.
        _ = reason
        resetTurnTelemetryState()
    }

    // MARK: - Chat stack row lifecycle (Stage 4a)

    /// Opens a fresh `pending` chat row for the in-flight turn. Captures
    /// the rowId so subsequent SSE handlers can update the same row.
    private func startActiveRow(queryText: String, mode: HistoryQueryMode) {
        didFinalizeActiveRow = false
        guard let chatStackStore else {
            activeRowId = nil
            return
        }
        let rowId = chatStackStore.startChat(queryText: queryText, mode: mode)
        activeRowId = rowId == 0 ? nil : rowId
        os_log(
            "chat_row_started rowId=%{public}lld",
            log: Self.log, type: .debug,
            activeRowId ?? 0
        )
    }

    /// Pushes the STT provider's final voice transcript into the active
    /// voice row so completed turns become eligible for `historyMessages()`.
    private func updateActiveRowQueryText(_ text: String) {
        guard let chatStackStore, let rowId = activeRowId else { return }
        chatStackStore.updateQueryText(rowId: rowId, text: text)
    }

    /// Appends a tool name to the active row's `tool_names`. Dedupe lives
    /// inside `ChatStackStore.recordTool`.
    private func recordActiveRowTool(_ tool: String) {
        guard let chatStackStore, let rowId = activeRowId else { return }
        chatStackStore.recordTool(rowId: rowId, tool: tool)
    }

    /// Marks the active row as done with the rendered blocks + a markdown
    /// rollup (the downgrade-safe column). Idempotent via
    /// `didFinalizeActiveRow` — after an error fires `markChatError`, a
    /// trailing `done` event must not flip the status back.
    ///
    /// Stage 0b: also emits `voice_turn_completed` once per turn. The
    /// telemetry termination is guarded separately from `didFinalizeActiveRow`
    /// so a controller built without a chat-stack store (tests, feature gate
    /// off) still emits the analytics event.
    private func finalizeActiveRow() {
        let shouldEmitTelemetry = !didEmitTurnTerminator
        if !didFinalizeActiveRow {
            if let chatStackStore, let rowId = activeRowId {
                chatStackStore.finalizeChat(
                    rowId: rowId,
                    blocks: responseStore.blocks,
                    markdown: composeResponseMarkdown()
                )
                os_log(
                    "chat_row_finalized rowId=%{public}lld",
                    log: Self.log, type: .debug,
                    rowId
                )
            }
            didFinalizeActiveRow = true
        }
        if shouldEmitTelemetry {
            emitTurnCompletedTelemetry()
        }
    }

    /// Marks the active row as `.error`. Empty/missing `message` is
    /// substituted with a placeholder by `ChatStackStore` so the
    /// downgrade-safe `response_markdown` column is never empty.
    ///
    /// Stage 0b: also emits `voice_turn_failed` once per turn with the
    /// rendered error message and the active `turn_id` (real or `"pending"`).
    private func markActiveRowError(message: String) {
        let shouldEmitTelemetry = !didEmitTurnTerminator
        if !didFinalizeActiveRow {
            if let chatStackStore, let rowId = activeRowId {
                chatStackStore.markChatError(rowId: rowId, message: message)
                os_log(
                    "chat_row_errored rowId=%{public}lld",
                    log: Self.log, type: .debug,
                    rowId
                )
            }
            didFinalizeActiveRow = true
        }
        if shouldEmitTelemetry {
            emitTurnFailedTelemetry(reason: message)
        }
    }

    private func composeResponseMarkdown() -> String {
        // Concatenate the body text of every block plus any remaining
        // streaming summary text. Falls back to the error message when the
        // turn failed before producing a block.
        var segments: [String] = []
        for block in responseStore.blocks {
            switch block {
            case .textAnswer(let b):
                segments.append(b.body)
            case .entityCard(let b):
                segments.append(b.description ?? b.name)
            case .entityList(let b):
                let items = b.items.map { "- \($0.title)" + (($0.subtitle).map { ": \($0)" } ?? "") }
                segments.append(items.joined(separator: "\n"))
            case .metricCard(let b):
                segments.append("\(b.label): \(b.value)\(b.unit.map { " \($0)" } ?? "")")
            case .searchResults(let b):
                let items = b.results.map { "- \($0.title)" + (($0.snippet).map { ": \($0)" } ?? "") }
                segments.append(items.joined(separator: "\n"))
            case .stateEmpty(let b):
                segments.append(b.message)
            case .stateError(let b):
                segments.append(b.message)
            case .statePermission(let b):
                segments.append(b.message ?? b.provider)
            case .usefulLinks(let b):
                // Render each link as a "- description (url)" line so the
                // composed markdown carries the same information the chip
                // row would have shown — history and the canonical answer
                // both stay readable without the chips.
                let lines = b.links.map { link in
                    "- \(link.description) (\(link.url.absoluteString))"
                }
                segments.append(lines.joined(separator: "\n"))
            case .usefulActions(let b):
                // Mirror the useful.links rendering for the generalised block:
                // "- description (insertText)" when the item carries a
                // description, otherwise just "- insertText". Keeps the
                // composed answer readable without the actionable chips.
                let lines = b.items.map { item -> String in
                    if let description = item.description, !description.isEmpty {
                        return "- \(description) (\(item.insertText))"
                    }
                    return "- \(item.insertText)"
                }
                segments.append(lines.joined(separator: "\n"))
            }
        }
        if !responseStore.summary.isEmpty, segments.isEmpty {
            segments.append(responseStore.summary)
        }
        if segments.isEmpty, let errorMessage = responseStore.errorMessage {
            segments.append(errorMessage)
        }
        return segments.joined(separator: "\n\n")
    }

    private func transcriptionErrorBlock(for error: Error) -> StateErrorBlock {
        StateErrorBlock(
            title: "Agent error",
            subtitle: "Transcription failed",
            message: transcriptionErrorMessage(for: error),
            code: "transcription_failed",
            retryable: isTranscriptionErrorRetryable(error)
        )
    }

    private func transcriptionErrorMessage(for error: Error) -> String {
        if let agentError = error as? AgentClientError {
            return agentError.description
        }
        if let localError = error as? LocalTranscriptionModelError {
            return localError.errorDescription ?? "Could not transcribe audio."
        }
        return "Could not transcribe audio."
    }

    private func isTranscriptionErrorRetryable(_ error: Error) -> Bool {
        if let agentError = error as? AgentClientError {
            return agentError.retryable
        }
        if error is LocalTranscriptionModelError {
            return false
        }
        return true
    }
}

private final class AgentControllerSnapshotStore {
    var snapshot: FocusSnapshot?
}
