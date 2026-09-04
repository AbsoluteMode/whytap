import Combine
import Foundation
import os.log

@MainActor
final class AskResponseStore: ObservableObject {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "agent.sse")

    @Published private(set) var status: AgentLocalStatus = .ready
    @Published private(set) var summary: String = ""
    @Published private(set) var streamingText: String = ""
    @Published private(set) var blocks: [UIBlock] = []
    @Published private(set) var sources: [Source] = []
    @Published private(set) var currentToolLabel: String?
    // Dormant seam: the chat.title namer was removed (pivot); a future change repopulates this with the user's prompt.
    @Published private(set) var chatTitle: String?
    @Published private(set) var errorCode: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isErrorRetryable: Bool = false
    @Published private(set) var streamCompleted: Bool = false

    /// The permission ask currently shown in the pill — always the HEAD of
    /// `permissionQueue`. Published so the UI re-renders when the head changes.
    /// Settable for backward compatibility, but writes should go through the
    /// queue mutators below; the UI only reads it.
    @Published var pendingPermission: PermissionPrompt?

    /// FIFO of un-answered `can_use_tool` asks. Claude batches parallel
    /// control_requests in ONE turn (e.g. several Bash calls), each with its
    /// own request_id, all awaiting a `control_response` on stdin. The old
    /// single-slot `pendingPermission` was overwritten by each new ask, so
    /// every request but the last was silently dropped — never answered — and
    /// claude blocked on stdin forever waiting for the missing responses.
    /// The queue surfaces them one at a time (head -> `pendingPermission`),
    /// answers in arrival order, and `reset()` / `denyAllPending()` write a
    /// deny `control_response` for EVERY queued id so the CLI is never wedged.
    private var permissionQueue: [PermissionPrompt] = []

    var onPermissionDecision: ((String, PermissionDecision) -> Void)?

    /// Answer buffers for the CLI event stream. A turn that streams its
    /// answer via `summaryDelta`/`blockComplete` leaves both empty and drives
    /// `streamingText` directly.
    /// `narrationBuffer` accumulates `.narrationDelta` (hidden fallback);
    /// `pendingFinalAnswer` holds the canonical `.finalAnswer`. Whichever is
    /// set is revealed into `streamingText` at `done` (final wins).
    private var narrationBuffer = ""
    private var pendingFinalAnswer = ""

    // Typewriter streams smooth out Pill 2 tool action labels: those arrive
    // as single short bursts and would otherwise flash on screen in one frame.
    // The agent's streaming answer text is NOT typewriter-smoothed — it's
    // piped directly from `summary.delta` events into `streamingText` at
    // whatever pace the CLI emits them. Removing per-tick typewriter drain
    // cuts the MarkdownBlockParser re-parse rate from 80-160/sec down to the
    // CLI's own delta rate, which is the dominant perf cost during a streaming
    // answer with a long markdown body.
    //
    // Both typewriters are created lazily so unit tests that drive the store
    // via the `markLocalStatus` / `consume` API don't need to wire timers
    // manually, and so the real Task-based drain never starts in a
    // non-MainActor test runner.
    private lazy var toolLabelTypewriter = TypewriterStream { [weak self] text in
        self?.currentToolLabel = text.isEmpty ? nil : text
    }
    private lazy var chatTitleTypewriter = TypewriterStream { [weak self] text in
        self?.chatTitle = text.isEmpty ? nil : text
    }

    /// Populates Pill 1 (the title pill) with the user's prompt for the
    /// in-flight turn — the provider-agnostic replacement for the removed
    /// chat.title namer. Set DIRECTLY (not via the typewriter) so it shows on
    /// the very first frame; truncated to keep the pill compact (the user's
    /// own query, not a generated title).
    func showTitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        chatTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    func consume(
        _ stream: AsyncStream<AgentSSEEvent>,
        onFirstBlock: @escaping () -> Void = {},
        onErrorEvent: @escaping () -> Void = {},
        onCompletionEvent: @escaping () -> Void = {},
        onToolEvent: @escaping (String) -> Void = { _ in },
        onVoiceTranscript: @escaping (String) -> Void = { _ in },
        /// Stage 0b: receives the provider-issued `turn_id` from the first
        /// event (`started`) so the controller can correlate its per-turn
        /// bookkeeping and log lines. Fires exactly once per stream when the
        /// provider honours its contract; absent if the stream errors before
        /// the first event lands.
        onStartedEvent: @escaping (_ turnId: String) -> Void = { _ in },
        onPermissionRequest: ((PermissionPrompt) -> Void)? = nil
    ) async {
        var didCallFirstBlock = false
        // Error is terminal — once it fires, a trailing `done` must not wipe
        // the visible error state. Backends emit error+done as a paired
        // terminator; without this flag the user sees the streaming preview
        // disappear after a flicker of "thinking..." with no failure surfaced.
        var didFireError = false
        for await event in stream {
            switch event {
            case .toolExecuting(let tool, let label):
                os_log(
                    "sse tool.executing tool=%{public}@ label_chars=%{public}d",
                    log: Self.log, type: .info,
                    tool, label.count
                )
                toolLabelTypewriter.replace(label)
                status = .thinking
                onToolEvent(tool)
            case .summaryDelta(let text):
                status = .thinking
                summary += text
                streamingText += text
            case .narrationDelta(let text):
                // Hidden during the turn so the pill stays on tool-step labels.
                // Only surfaced at `done` as a fallback if no finalAnswer landed.
                status = .thinking
                narrationBuffer += text
            case .finalAnswer(let text):
                // Canonical final answer; replaces any prior candidate. Stays
                // hidden until `done` reveals it (steps now, clean final at end).
                status = .thinking
                pendingFinalAnswer = text
            case .blockComplete(let block):
                status = .thinking
                if case .textAnswer(let answer) = block {
                    // Backfill the visible stream with the canonical body
                    // — guards against the rare case where deltas dropped
                    // or arrived out of order so the user still sees the
                    // full answer once the block lands. The block ALSO
                    // stays in `blocks` for history persistence; the
                    // response panel filters textAnswer out of the
                    // on-screen block list and renders Pill 2 from
                    // `streamingText`.
                    if streamingText.count < answer.body.count {
                        streamingText = answer.body
                    }
                } else if case .usefulLinks = block {
                    // The model emits useful_links as a trailing ```json
                    // fenced block at the end of its prose. By the time
                    // we see block.complete(useful_links), the event mapper
                    // has already extracted the JSON, but our locally
                    // accumulated `streamingText` still carries the
                    // fence. Strip it so Pill 2 reads as clean prose.
                    // If a textAnswer block lands later it'll backfill
                    // to the canonical body anyway, so this strip is
                    // best-effort and idempotent.
                    streamingText = Self.strippingTrailingJSONFence(from: streamingText)
                }
                // All other non-textAnswer blocks (entityCard, metricCard,
                // searchResults, entityList, state.*) leave streamingText
                // alone. Earlier we cleared it on every non-textAnswer
                // block, which deleted Sonnet's accumulated prose
                // whenever a sibling block landed first — visible as an
                // empty Pill 2 next to chips / cards when Sonnet didn't
                // emit a follow-up textAnswer.
                // Dedup back-to-back identical blocks. Some backends emit
                // a `block.complete` twice for the same payload during
                // fast turns (parse retry, stream restart, etc.) and the
                // user sees the same text twice on screen. Drop the
                // duplicate when it's adjacent to its twin — non-adjacent
                // repeats are still appended because a user could legit
                // ask "say it again" mid-turn.
                if blocks.last != block {
                    blocks.append(block)
                }
                if !didCallFirstBlock {
                    didCallFirstBlock = true
                    onFirstBlock()
                }
            case .done(let sources):
                self.sources = sources
                toolLabelTypewriter.clear()
                if !didFireError {
                    // Reveal the captured final answer (or the narration
                    // fallback) into the pill now. A turn that streamed its
                    // answer via summaryDelta leaves both buffers empty and
                    // owns streamingText itself, so this never clobbers a
                    // streamed answer.
                    let localFinal = !pendingFinalAnswer.isEmpty ? pendingFinalAnswer
                        : (!narrationBuffer.isEmpty ? narrationBuffer : nil)
                    if let localFinal {
                        streamingText = localFinal
                        summary = localFinal
                    }
                    errorCode = nil
                    errorMessage = nil
                    isErrorRetryable = false
                    status = .ready
                }
                streamCompleted = true
                onCompletionEvent()
            case .error(let code, let message, let retryable):
                didFireError = true
                toolLabelTypewriter.clear()
                errorCode = code
                errorMessage = message
                isErrorRetryable = retryable
                streamingText = ""
                streamCompleted = true
                status = .failed
                onErrorEvent()
                onCompletionEvent()
            case .voiceTranscript(let text):
                os_log(
                    "sse voice.transcript chars=%{public}d",
                    log: Self.log,
                    type: .info,
                    text.count
                )
                onVoiceTranscript(text)
            case .started(let turnId, _, _):
                // Stage 0b: metadata-only event. No store mutation — the
                // controller owns `turn_id` for per-turn correlation. Logs
                // turn_id at info level (PII-free random hex) so log lines
                // from the same turn can be matched up when the user
                // forwards a diagnostic.
                os_log(
                    "sse started turn_id=%{public}@",
                    log: Self.log, type: .info,
                    turnId
                )
                onStartedEvent(turnId)
            case .permissionRequest(let id, let toolName, let summary, let inputJSON):
                let prompt = PermissionPrompt(id: id, toolName: toolName, summary: summary, inputJSON: inputJSON)
                // Enqueue; head surfaces in the pill. A parallel batch lands as
                // several events back-to-back — all but the head wait their turn
                // instead of clobbering each other.
                permissionQueue.append(prompt)
                syncPendingPermissionHead()
                onPermissionRequest?(prompt)
            case .statusNarration(let text):
                os_log(
                    "sse status.narration label_chars=%{public}d",
                    log: Self.log, type: .info, text.count
                )
                toolLabelTypewriter.replace(text)
                status = .thinking
            }
        }
    }

    /// Answers the head ask, dequeues it, and surfaces the next (if any).
    /// Writing the decision back through `onPermissionDecision` is what frees
    /// the CLI: it forwards to the active provider's `respondToPermission`,
    /// which writes the `control_response` line to the child's stdin.
    func decide(_ decision: PermissionDecision) {
        guard !permissionQueue.isEmpty else { return }
        let head = permissionQueue.removeFirst()
        syncPendingPermissionHead()
        onPermissionDecision?(head.id, decision)
    }

    /// Denies EVERY queued ask (head + backlog) and clears the queue. Used by
    /// `reset()` and by the controller's dismiss / cancel handlers: a turn torn
    /// down with un-answered permissions would leave the CLI blocked on stdin
    /// forever, so each pending id gets an explicit deny `control_response`.
    /// Idempotent — a no-op when the queue is already empty.
    func denyAllPending() {
        guard !permissionQueue.isEmpty else { return }
        let pending = permissionQueue
        permissionQueue.removeAll()
        syncPendingPermissionHead()
        for prompt in pending {
            onPermissionDecision?(prompt.id, .deny(message: "User declined in Whytap"))
        }
    }

    /// Mirrors the queue head into the published `pendingPermission` so the
    /// pill always shows exactly one ask (or none).
    private func syncPendingPermissionHead() {
        pendingPermission = permissionQueue.first
    }

    func reset() {
        // Deny any un-answered permission asks before tearing down so the CLI
        // is never left blocked on stdin (the single-slot version never
        // cleared pendingPermission here at all). denyAllPending() also clears
        // the published head.
        denyAllPending()
        status = .ready
        summary = ""
        streamingText = ""
        narrationBuffer = ""
        pendingFinalAnswer = ""
        blocks = []
        sources = []
        toolLabelTypewriter.clear()
        chatTitleTypewriter.clear()
        errorCode = nil
        errorMessage = nil
        isErrorRetryable = false
        streamCompleted = false
    }

    func markLocalStatus(_ status: AgentLocalStatus) {
        guard status != .ready && status != .failed else {
            self.status = status
            return
        }
        self.status = status
        streamingText = ""
        // Do not seed Pill 2 here. Pill 1 already shows the "Thinking"
        // shimmer placeholder while the request is in flight; Pill 2 must
        // stay hidden until Nano's first `tool.executing` (action label) or
        // Sonnet's first `block.complete` actually arrives. Seeding made
        // Pill 2 surface synchronously with Pill 1 and then flicker on the
        // real `tool.executing` swap.
        toolLabelTypewriter.clear()
        errorCode = nil
        errorMessage = nil
        isErrorRetryable = false
        streamCompleted = false
    }

    func markError(_ error: AgentClientError, code: String? = nil) {
        status = .failed
        streamingText = ""
        toolLabelTypewriter.clear()
        errorCode = code ?? error.code
        errorMessage = error.description
        isErrorRetryable = error.retryable
    }

    func markErrorBlock(_ block: StateErrorBlock) {
        status = .failed
        summary = ""
        streamingText = ""
        blocks = [.stateError(block)]
        sources = []
        toolLabelTypewriter.clear()
        errorCode = block.code
        errorMessage = block.message
        isErrorRetryable = block.retryable
        streamCompleted = true
    }

    /// Test hook — flips `streamCompleted` and `.ready` status so unit tests
    /// can simulate the "agent finished" state without driving a full
    /// `AsyncStream`. Equivalent to a `done` event with no sources.
    func markStreamCompletedForTesting() {
        status = .ready
        streamCompleted = true
    }

    /// Synchronously snap the Nano-driven typewriters to their target so
    /// unit tests can assert `currentToolLabel` / `chatTitle` immediately
    /// after `consume(_:)` returns without waiting for the drain ticks.
    /// `streamingText` no longer needs flushing — it mutates directly from
    /// `summary.delta` events at the CLI's own pace.
    func flushTypewritersForTesting() {
        toolLabelTypewriter.flush()
        chatTitleTypewriter.flush()
    }

    /// Strips a trailing fenced JSON code block (`​```json …`​) from `text`,
    /// returning the prose that precedes it. Used when `block.complete`
    /// for `useful_links` lands — the event mapper has already extracted the
    /// JSON payload, but our locally accumulated `streamingText` still has
    /// the fence the model emitted in its answer.
    ///
    /// Match is best-effort by prefix: any of `​```json`, `​```\n{`, `​```{`
    /// starting somewhere in `text` is treated as the boundary. If no
    /// fence is found the input is returned unchanged.
    ///
    /// `internal` (not `private`) so the unit tests can pin the exact
    /// stripping behaviour without driving a full `consume(_:)` round.
    static func strippingTrailingJSONFence(from text: String) -> String {
        let patterns = ["```json", "```\n{", "```{"]
        for pattern in patterns {
            if let range = text.range(of: pattern) {
                return String(text[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
