import Foundation
import OSLog

/// Drives the audio engine directly into a BYOK provider adapter and resolves
/// to the same `StreamingSessionResult` the on-device session produces, so
/// `AppDelegate.handleStreamingResult` handles both uniformly.
@MainActor
final class DirectProviderStreamingSession: StreamingSessionRunning {
    /// Live-transcript sink (`AgentRealtimeVoiceSessioning`). Fed the latest
    /// display snapshot while the user is still speaking. Provider adapters
    /// emit committed `.final` segments separately from the current
    /// non-final `.partial` tail; this session combines them before calling
    /// the wing so the UI never blinks through a committed-only prefix.
    var onTranscriptUpdate: ((String) -> Void)?

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-stream-session")

    /// Post-stop wait bound for the provider's terminal `.done`. A half-open
    /// upstream never delivers it; without this bound `run()` hangs on its
    /// `for await ev in session.events` forever and the orb is stuck in
    /// `.transcribing`. Default 10 s; tests inject a tiny value.
    static let defaultStopWatchdog: Duration = .seconds(10)

    /// How long audio may flow OUT with no partial coming back before the live
    /// stream is treated as silently stalled (half-open socket / upstream hang
    /// that emits no error). Conservative on purpose — a merely-slow network can
    /// legitimately go several seconds between partials, so a low value would
    /// degrade healthy turns. Tests shrink it.
    static let defaultStallSeconds: Double = 6

    /// No-progress HARD resolve threshold (resilient only). When no partial
    /// has arrived for this many seconds AND the user has NOT called `stop()` AND
    /// the session is unresolved, the stall task stops the engine, closes the
    /// upstream, and `run()` returns `.degraded` via the after-loop degraded path.
    /// Conservative — well above p99 finalize latency. Injectable for tests.
    static let defaultNoProgressResolveSeconds: Double = 12.0

    private let audioEngine: any StreamingAudioSourcing
    private let adapter: BYOKTranscriptionAdapter
    private let language: String?
    private let terms: [String]
    private let stopWatchdog: Duration
    private let noProgressResolveSeconds: Double

    /// Whether resilient delivery is enabled for this session. Captured once at
    /// init (default `AgentFeatureGate.resilientDropDeliveryEnabled`). When
    /// `false`, EVERY degrade decision below is skipped — a transport-class
    /// error tears the capture + upstream down and resolves `.failed`, so the
    /// session is bit-for-bit the pre-B1 behavior. When `true`, a broken live
    /// upstream keeps capturing and resolves `.degraded` so
    /// `AppDelegate.recoverViaBatch` can batch-transcribe the retained PCM.
    private let resilient: Bool

    private var upstream: BYOKUpstreamSession?
    private var audioTask: Task<Void, Never>?
    private var failureWatchTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// Periodically polls `progress.isStalled()` to catch a silent stall —
    /// audio flowing out with no partial coming back (half-open socket /
    /// upstream hang that emits no error). Only spawned when `resilient` is on.
    private var stallCheckTask: Task<Void, Never>?
    private var stopped = false
    /// Set (from the audio task, one main hop) when the forward loop finishes
    /// on its own — the chunk stream ended and `endInput()` returned. Lets the
    /// degraded resolve distinguish "drain completed" from "drain wedged on a
    /// dead upstream" WITHOUT awaiting the task itself: a non-throwing
    /// `Task<Void, Never>.value` await cannot be abandoned on a deadline, so
    /// racing it in a group would re-introduce the very hang we bound here.
    private var audioTaskCompleted = false
    /// Set when `cancel()` ran. `run()` re-checks this AFTER `adapter.open()`
    /// returns so a cancel landing during open closes the fresh upstream and
    /// returns `.cancelled` (instead of leaving a live upstream that later
    /// resolves `.transcript`/`.failed`).
    private var cancelled = false
    /// Set when a transport-class `.error` (or a silent stall) tore down only
    /// the upstream mid-turn: the audio engine keeps capturing so the retained
    /// PCM can be batch-recovered on `stop()`. Drives the `.degraded` resolution
    /// instead of `.failed`. Only ever set when `resilient` is true.
    private var degraded = false
    /// Set when the stop watchdog (`.watchdogTimeout`) or the engine-failure
    /// watcher (`.audioEngineFailed`) fires. Makes `run()` return `.failed`
    /// with the matching cause when its event loop falls through, instead of
    /// the `.cancelled` it returns for a clean upstream close. Typed (not a
    /// Bool) so telemetry can aggregate the two root causes separately.
    private var failureReason: StreamingSessionError?

    /// Tracks audio-out vs partial-in timing to detect a silent stall. Uses a
    /// MONOTONIC clock (`systemUptime`) so an NTP wall-clock jump can't make a
    /// healthy stream look stalled. Mutated only on the main actor (`noteAudioSent`
    /// via a single hop from the audio task, `notePartial` in the `.partial`
    /// case, read in the stall-check tick). Mirrors the on-device session.
    private var progress: StreamingProgressMonitor

    /// PCM16 retained locally for the current turn, delegated to the audio
    /// source (overrides the `StreamingSessionRunning` default which returns
    /// empty). `AppDelegate.recoverViaBatch` batch-transcribes this when the
    /// session resolves `.degraded`.
    func capturedAudioPCM16() -> Data { audioEngine.capturedPCM16() }

    init(
        audioEngine: any StreamingAudioSourcing,
        adapter: BYOKTranscriptionAdapter,
        language: String?,
        terms: [String],
        stopWatchdog: Duration = DirectProviderStreamingSession.defaultStopWatchdog,
        stallSeconds: Double = DirectProviderStreamingSession.defaultStallSeconds,
        noProgressResolveSeconds: Double = DirectProviderStreamingSession.defaultNoProgressResolveSeconds,
        resilient: Bool = AgentFeatureGate.resilientDropDeliveryEnabled
    ) {
        self.audioEngine = audioEngine
        self.adapter = adapter
        self.language = language
        self.terms = terms
        self.stopWatchdog = stopWatchdog
        self.noProgressResolveSeconds = noProgressResolveSeconds
        self.resilient = resilient
        self.progress = StreamingProgressMonitor(
            stallSeconds: stallSeconds,
            now: { ProcessInfo.processInfo.systemUptime }
        )
    }

    func run() async -> StreamingSessionResult {
        // Start capture FIRST (so the voice orb reacts immediately) so the voice orb reacts
        // immediately and the start of speech isn't clipped while the provider
        // WebSocket connects.
        do { try audioEngine.start() } catch { return .failed(.transportFailed) }

        // A cancel could already have landed during `audioEngine.start()`.
        if cancelled {
            audioEngine.stop()
            return .cancelled
        }

        let session: BYOKUpstreamSession
        do {
            session = try await adapter.open(language: language, terms: terms)
        } catch {
            audioEngine.stop()
            return .failed(.transportFailed)
        }

        // v2 cancel-race guard: a `cancel()` (sleep / app-quit) can land WHILE
        // `adapter.open()` was suspended above. Before this guard, `run()` did
        // not re-check, so it wired up a live upstream that the now-cancelled
        // session would later resolve `.transcript(...)` (pasting pre-sleep
        // speech onto whatever has focus on wake) or `.failed` (spuriously
        // re-arming the recorder). Close the fresh upstream and bail.
        if cancelled {
            await session.close()
            audioEngine.stop()
            return .cancelled
        }
        upstream = session

        audioTask = Task { [weak self] in
            guard let self else { return }
            // Marks the first send so the stall monitor knows audio started
            // flowing. Local flag + single main-actor hop (not per-chunk) avoids
            // an actor crossing on every frame. Mirrors the on-device session.
            var marked = false
            for await chunk in self.audioEngine.chunks {
                await session.sendAudio(chunk)
                if !marked {
                    marked = true
                    await MainActor.run { [weak self] in self?.progress.noteAudioSent() }
                }
            }
            os_log(
                "byok stream: audio drained; sending endInput",
                log: Self.log, type: .info
            )
            await session.endInput()
            // Signal a CLEAN completion so the degraded resolve can tell a
            // finished drain from one wedged on a dead upstream (see
            // `awaitDegradedDrainBounded`). A single main hop at end-of-turn —
            // never per chunk.
            await MainActor.run { [weak self] in self?.audioTaskCompleted = true }
        }

        // Watch the engine for a fatal failure (bad format / route-change
        // restart exhausted). Default stub stream finishes immediately, so
        // this is a no-op when the engine never fails. `.audioEngineFailed`
        // (not transport): the socket is healthy, the mic is dead — the
        // caller uses the distinction to skip the recorder fallback.
        failureWatchTask = Task { [weak self] in
            for await _ in audioEngine.failures {
                guard let self else { break }
                os_log(
                    "byok stream: audio engine fatal failure",
                    log: Self.log, type: .error
                )
                self.failureReason = .audioEngineFailed
                await session.close()  // unblock the event loop below
                break
            }
        }

        // Silent-stall detector (resilient only). Audio can keep flowing OUT on
        // a half-open socket / upstream hang that emits NO error, so neither the
        // audio task nor an `.error` event ever fires — the turn would sit
        // unresolved until the user releases and the stop watchdog reaps it.
        // Poll once a second; if audio is flowing but no partial has come back
        // for `stallSeconds`, degrade the SAME way as a transport error: mark
        // `degraded`, close ONLY the upstream (which finishes the events stream
        // → the loop ends → the after-loop returns `.degraded`), keep the engine
        // capturing so the retained PCM is batch-recovered on `stop()`. Spawned
        // only when resilient is on, so the flag-off session is bit-for-bit the
        // old behavior (no extra task, no stall detection). Mirrors
        // the stall wiring (Task 6).
        if resilient {
            stallCheckTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }

                    // --- soft stall degrade (unchanged) ---
                    // Marks `degraded` but does NOT resolve — waits for stop().
                    let didSoftDegrade: Bool = await MainActor.run { [weak self] in
                        guard let self else { return false }
                        // Re-check every guard on the main actor: the turn may
                        // have stopped or already degraded (transport path)
                        // between ticks.
                        guard self.resilient,
                              !self.stopped,
                              !self.degraded,
                              self.progress.isStalled()
                        else { return false }
                        self.degraded = true
                        os_log(
                            "byok stream: degraded (stall); keeping capture",
                            log: Self.log, type: .error
                        )
                        return true
                    }
                    if didSoftDegrade {
                        // Close ONLY the upstream (the close is async, so do it
                        // off the main-actor hop above). Finishing the events
                        // stream ends the loop; the after-loop then waits on
                        // `await audioTask?.value` for the user's stop to resolve
                        // `.degraded`. Do NOT return — keep polling so the hard
                        // no-progress resolve below stays reachable. If the user
                        // never stops (the mid-record hang this task exists for),
                        // that wait would block forever; the hard resolve is the
                        // safety net that stops the engine and forces `.degraded`.
                        // The soft-degrade guard's `!degraded` prevents re-firing.
                        await self?.upstream?.close()
                    }

                    // --- hard no-progress resolve (Task 4) ---
                    // WHY: docs/decisions/2026-06-22-byok-noprogress-deadlock.md
                    // When audio has been flowing but no partial has arrived for
                    // `noProgressResolveSeconds` AND the user has not stopped,
                    // resolve immediately so `run()` returns. Mirrors
                    // the hard-resolve rule, adapted to the
                    // event-loop model: set `degraded`, stop the engine (so the
                    // audio task drains and finishes quickly), then close the
                    // upstream (ends the event stream → `run()`'s for-await
                    // falls through → `if degraded` path → teardown → `.degraded`).
                    let shouldHardResolve: Bool = await MainActor.run { [weak self] in
                        // NB: intentionally does NOT guard on `!degraded` (unlike
                        // the soft-degrade guard above, and matching
                        // the hard-resolve rule). A soft degrade
                        // (stall) or a transport degrade may already have set
                        // `degraded` and closed the upstream while leaving the
                        // engine capturing for the user's stop. If that stop never
                        // comes, this hard resolve must still fire to stop the
                        // engine and unblock the after-loop's `await audioTask`.
                        guard let self,
                              self.resilient,
                              !self.stopped,
                              !self.cancelled,
                              let elapsed = self.progress.secondsSinceLastProgress(),
                              elapsed >= self.noProgressResolveSeconds
                        else { return false }
                        self.degraded = true
                        os_log(
                            "byok stream: no-progress hard resolve; stopping capture",
                            log: Self.log, type: .error
                        )
                        // Stop the engine here (on main actor) so the audio task's
                        // `for await chunk in audioEngine.chunks` finishes and
                        // `await audioTask?.value` in the after-loop doesn't hang.
                        self.audioEngine.stop()
                        return true
                    }
                    if shouldHardResolve {
                        // Close the upstream (ends the event stream → the for-await
                        // in run() exits) AFTER stopping the engine above. Any
                        // chunks the audio task drains in the engine's stop window
                        // therefore go to an already-closed upstream (sendAudio
                        // swallows the error), never to a live one.
                        await self?.upstream?.close()
                        return
                    }
                }
            }
        }

        var committedLiveTranscript = ""
        var lastEmittedLiveTranscript = ""
        let liveJoin = session.finalsJoin
        func emitLiveTranscript(_ text: String) {
            guard text != lastEmittedLiveTranscript else { return }
            lastEmittedLiveTranscript = text
            onTranscriptUpdate?(text)
        }

        for await ev in session.events {
            switch ev {
            case .partial(let text):
                // A partial came back → the live stream is making progress;
                // reset the stall clock. (No effect when resilient is off — the
                // stall-check task isn't running to read it.)
                progress.notePartial()
                emitLiveTranscript(Self.liveTranscript(
                    committed: committedLiveTranscript,
                    partial: text,
                    join: liveJoin
                ))
                continue
            case .final(let text):
                committedLiveTranscript = Self.appendingLiveTranscriptSegment(
                    text,
                    to: committedLiveTranscript,
                    join: liveJoin
                )
                continue
            case .done(let text):
                await teardown(session)
                return .transcript(text)
            case .error(let code):
                if resilient, !stopped, Self.isTransportClass(code) {
                    // Resilient delivery on: the live upstream broke
                    // mid-recording. Do NOT tear down the capture — the audio
                    // engine keeps running and the tee keeps filling the turn
                    // buffer, so the turn can be recovered by batch-transcribing
                    // the retained PCM on `stop()`. Close only the upstream and
                    // break the loop; the after-loop sees `degraded` and waits
                    // for the user's release before resolving `.degraded`.
                    degraded = true
                    os_log(
                        "byok stream: degraded (transport); keeping capture",
                        log: Self.log, type: .error
                    )
                    await session.close()
                    break
                }
                // OLD path (flag off, post-stop, or non-transport error): tear
                // the capture + upstream down and resolve `.failed`, as before.
                await teardown(session)
                if code == BYOKStreamErrorCode.endOfStreamSendFailed {
                    return .failed(.endOfStreamSendFailed)
                }
                return .failed(.unknown)
            }
        }
        // Degraded mid-turn (transport `.error` broke the loop, or the stall
        // task closed the upstream). Wait for the user to release the hotkey,
        // THEN tear down and resolve `.degraded` so `AppDelegate.recoverViaBatch`
        // batch-transcribes the retained PCM.
        //
        // Wait mechanism: `awaitDegradedDrainBounded()`. The old code awaited
        // `audioTask.value` directly, on the assumption that sends to the
        // already-closed upstream "return promptly". They do NOT on a half-open
        // socket (Wi-Fi/VPN dropout — exactly what degrades the turn): a
        // `URLSessionWebSocketTask.send` can stall until the TCP timeout, so the
        // resolve hung for tens of seconds with NO watchdog armed on this path
        // (prod turn EE2A, 2026-07-08: 37.6 s between stop and resolving). The
        // bounded wait fixes that — see its doc.
        //
        // Cancel (Escape) WINS over a prior degrade: the user explicitly asked
        // not to deliver, so we must NOT batch-recover and paste the retained
        // audio. Checked before the `degraded` branch — and re-checked after the
        // bounded wait, because `cancel()` can fire while we wait on it.
        // Soniox gets this for free via its exactly-once continuation resolve;
        // the event-loop model resolves by whichever after-loop branch wins, so
        // the ordering is explicit here.
        // WHY: docs/decisions/2026-06-22-byok-noprogress-deadlock.md
        //      docs/decisions/2026-07-09-degraded-drain-bounded.md
        if cancelled {
            await teardown(session)
            return .cancelled
        }
        if degraded {
            await awaitDegradedDrainBounded()
            if cancelled {
                await teardown(session)
                return .cancelled
            }
            await teardown(session)
            return .degraded
        }
        await teardown(session)
        // The events stream finished without a terminal event. Distinguish
        // *why*: a watchdog (`.watchdogTimeout`) / engine-failure
        // (`.audioEngineFailed`) close is a failure with its own cause; a
        // user-cancel close is `.cancelled`.
        if let failureReason {
            return .failed(failureReason)
        }
        return .cancelled
    }

    /// Whether `code` is a transport/network-class failure — a broken live
    /// upstream whose turn is still recoverable by batch-transcribing the
    /// locally-captured audio.
    ///
    /// Deliberate allow-list (the BYOK `.error` payload is an open `String`):
    /// only the two codes emitted on genuine socket breakage with audio intact
    /// are transport-class —
    ///   • `"transport"`            — `receive()` failed (Wi-Fi drop / provider close)
    ///   • `endOfStreamSendFailed`  — the EOF send broke the socket; audio captured
    /// Everything else is NOT transport-class and fails immediately:
    ///   • `"provider"` / `"error"` / any other code — the provider rejected the
    ///     content (bad key, quota, unsupported); on the BYOK direct path a batch
    ///     to the SAME provider key would fail identically, so don't degrade.
    static func isTransportClass(_ code: String) -> Bool {
        switch code {
        case "transport", BYOKStreamErrorCode.endOfStreamSendFailed:
            return true
        default:
            return false
        }
    }

    private static func liveTranscript(
        committed: String, partial: String, join: BYOKTranscriptJoin
    ) -> String {
        appendingLiveTranscriptSegment(partial, to: committed, join: join)
    }

    private static func appendingLiveTranscriptSegment(
        _ segment: String, to base: String, join: BYOKTranscriptJoin
    ) -> String {
        guard !segment.isEmpty else { return base }
        guard !base.isEmpty else { return segment }
        switch join {
        case .verbatim:
            // Soniox-shaped upstreams: tokens carry their own leading spaces
            // (word boundaries only). Inserting a separator here split words
            // into syllables — the raw-salvage "Фи чи по фа кту" bug.
            return base + segment
        case .wordBoundary:
            if base.last?.isWhitespace == true || segment.first?.isWhitespace == true {
                return base + segment
            }
            return base + " " + segment
        }
    }

    /// Bound the post-degrade wait so a dead upstream can't wedge the resolve.
    ///
    /// A mid-turn transport degrade closes the upstream but keeps the mic
    /// capturing, so `run()` must wait for the user to RELEASE before resolving
    /// `.degraded` (resolving earlier would truncate the utterance). The retained
    /// PCM the batch recovery needs is teed at CAPTURE time — complete
    /// independent of the send loop — so once the user releases there is nothing
    /// left for the drain to contribute.
    ///
    /// Two phases:
    ///   1. Release wait — unbounded. The engine keeps capturing after a
    ///      transport/soft-stall degrade, so we must not resolve until it has
    ///      stopped producing. That happens on `stop()` (user release,
    ///      `stopped`), `cancel()` (`cancelled`), or the no-progress hard resolve
    ///      (`audioEngine.stop()` with neither flag set — observed via the
    ///      forward loop finishing, `audioTaskCompleted`). The hold length is the
    ///      user's to decide, so this wait has no ceiling.
    ///   2. Residual drain — bounded by `stopWatchdog`. `audioTaskCompleted`
    ///      flips when the forward loop finishes cleanly (fast path: sends to a
    ///      closed socket fail promptly). If it wedges instead, the deadline wins
    ///      and we proceed anyway; `teardown` cancels the orphaned task.
    ///
    /// Polling (not `await audioTask.value`) is deliberate: a `Task<Void,
    /// Never>.value` await can't be abandoned on a deadline, so it would just
    /// reintroduce the hang. Every flag is `@MainActor` state on this
    /// `@MainActor` class, so the reads are free.
    private func awaitDegradedDrainBounded() async {
        while !stopped && !cancelled && !audioTaskCompleted {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let deadline = ContinuousClock.now + stopWatchdog
        while !audioTaskCompleted && !cancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Called by the caller (drop hotkey release) to finalize input. Stopping
    /// the audio engine ends the forward loop, which calls `endInput()` on the
    /// upstream session — the provider then commits and emits the terminal
    /// transcript, resolving `run()` via the `.done` event.
    ///
    /// Arms a watchdog so a provider that never commits (half-open socket)
    /// can't wedge `run()` forever: on expiry we record `.watchdogTimeout`
    /// and close the upstream, which finishes the event stream and lets
    /// `run()` return `.failed(.watchdogTimeout)`.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        // Graceful: capture the post-release word tail (silence-gated,
        // max-bounded inside the engine), THEN the chunk stream finishes
        // and audioTask sends endInput() after the last chunk. cancel()
        // keeps the immediate stop().
        audioEngine.finish()
        // Already degraded mid-recording (transport died / stall): the upstream
        // is closed and there is nothing to finalize. Skip the watchdog and
        // finish the chunk stream NOW (`finish()` above keeps it open for the
        // tail; `stop()` closes it immediately) so the audio task drains its
        // last chunk + `endInput()` and completes — that completion is exactly
        // what the after-loop `await audioTask?.value` is waiting on to resolve
        // `.degraded`. `degraded` is only ever set when `resilient` is true, but
        // keep the guard explicit so the OFF path can never reach this branch.
        if resilient, degraded {
            audioEngine.stop()
            return
        }
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self, stopWatchdog] in
            try? await Task.sleep(for: stopWatchdog)
            if Task.isCancelled { return }
            guard let self, !self.cancelled else { return }
            os_log(
                "byok stream: stop watchdog fired; provider never finished",
                log: Self.log, type: .error
            )
            // Don't overwrite an earlier, more specific cause (the engine
            // failure watcher may have fired first and already closed the
            // upstream).
            if self.failureReason == nil {
                self.failureReason = .watchdogTimeout
            }
            await self.upstream?.close()
        }
    }

    /// User / lifecycle cancellation (app termination, sleep). Tears down
    /// without waiting for the provider: closing the upstream session finishes
    /// its `events` stream, so the `run()` loop falls through to `.cancelled`.
    func cancel() async {
        cancelled = true
        stopped = true
        watchdogTask?.cancel()
        stallCheckTask?.cancel()
        audioTask?.cancel()
        audioEngine.stop()
        await upstream?.close()
    }

    private func teardown(_ session: BYOKUpstreamSession) async {
        audioTask?.cancel()
        failureWatchTask?.cancel()
        watchdogTask?.cancel()
        stallCheckTask?.cancel()
        audioEngine.stop()
        await session.close()
    }
}
