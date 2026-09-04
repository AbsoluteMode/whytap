import Foundation
import os.log

// MARK: - Public surface

/// Events emitted by `MeetingDetector` onto its `events` stream.
enum MeetingDetectorEvent: Sendable, Equatable {
    /// Detector decided a meeting is likely happening. The UUID is the
    /// candidate `meetingId` that the pill / recorder / processor all
    /// thread through the rest of the pipeline.
    case triggered(meetingId: UUID)
    /// The meeting context ended after a trigger. The coordinator uses this
    /// to clear an unanswered suggestion without treating it as Skip.
    case contextEnded
}

/// Test seam for the wall clock the detector uses for cooldown / session
/// boundary math. Production uses `SystemClock`; tests inject a virtual
/// clock that advances by direct method call (no `Task.sleep` involved).
protocol MeetingDetectorClocking: Sendable {
    func now() -> Date
}

/// Production clock — thin shim over `Date()`. Lives in this file because
/// detector is the only consumer today.
struct SystemClock: MeetingDetectorClocking {
    func now() -> Date { Date() }
}

// MARK: - Detector

/// Stage 2 detector that turns `MicInUseProbe` + `SystemAudioVADProbe`
/// streams into a single `.triggered(meetingId:)` event whenever the spec
/// heuristic is satisfied:
///
/// > mic-in-use **AND** ≥ `MeetingsConfig.detectorMinSpeechSeconds` (5s) of
/// > voice activity in the system audio within the last
/// > `MeetingsConfig.detectorWindowSeconds` (10s) rolling window.
///
/// Once triggered the detector goes silent for the rest of the current
/// mic-session (no repeated fire on a 30-minute Zoom). The pill / coordinator
/// is then expected to call `engageCooldown()` when the user dismisses the
/// suggestion, which extends the silence by `cooldownAfterDismissMinutes`
/// (30 min) — still scoped to the same mic-session. A new mic-session
/// (mic released for ≥ `autoEndMicReleasedSeconds`, 10s, then re-acquired)
/// clears both the cooldown and the "already fired" latch so the next
/// meeting is detectable.
///
/// The detector is **not** an actor: subscription wiring runs on the
/// MainActor (matching the rest of the meetings module), while the heavy
/// work happens inside `Task.detached` consumers that read mic / VAD
/// streams concurrently.
@MainActor
final class MeetingDetector: MeetingDetectorEventEmitting {

    /// os_log surface — spec / plan call out `detector` category.
    private static let log = OSLog(
        subsystem: "com.sidekey.meetings",
        category: "detector"
    )

    // MARK: - Injected deps

    private let micProbe: MicInUseProbing
    private let vadProbe: SystemAudioVADProbing
    private let config: MeetingsConfig
    private let clock: MeetingDetectorClocking
    /// Duration each VAD chunk represents in seconds. Production uses
    /// `Double(VadManager.chunkSize) / Double(VadManager.sampleRate)` =
    /// 4096/16000 = 0.256 s. Tests inject 0.25 s to keep math round.
    private let chunkDurationSeconds: TimeInterval

    // MARK: - State (touched only on MainActor)

    /// AsyncStream the wider system listens on.
    let events: AsyncStream<MeetingDetectorEvent>
    private let eventsContinuation: AsyncStream<MeetingDetectorEvent>.Continuation

    /// True after `subscribe()` runs. Second `subscribe()` is a no-op.
    private var didSubscribe = false

    /// Tasks consuming the mic + VAD streams. Held so `stop()` can cancel.
    private var micConsumer: Task<Void, Never>?
    private var vadConsumer: Task<Void, Never>?

    /// Most recent mic-in-use state observed.
    private var micIsOn = false
    /// When mic last went `false`. Used to detect a new session when mic
    /// stays released for ≥ `autoEndMicReleasedSeconds` and then comes
    /// back. Nil while mic is currently on or has never been on.
    private var micReleasedAt: Date?
    /// True once a `.triggered` event has been emitted in the current
    /// mic-session. Reset on session boundary.
    private var firedInCurrentSession = false
    /// If non-nil, no new triggers may fire until this date. Reset on
    /// session boundary. Cleared when `Date >= cooldownUntil`.
    private var cooldownUntil: Date?
    /// Set when the current meeting context should be considered closed
    /// on the next false→true edge. This covers both explicit user
    /// dismiss/timeout and the meeting-context false edge after a trigger.
    private var shouldResetOnNextContextStart = false

    /// FIFO of "speech chunk arrived at time T" timestamps. Used to keep
    /// a rolling sum of speech-seconds within the last
    /// `detectorWindowSeconds`. We only store positive chunks (silence is
    /// implied by the gap between timestamps); evicting the head is enough.
    private var speechChunkTimestamps: [Date] = []

    // MARK: - Init

    /// - Parameters:
    ///   - micProbe: mic-in-use seam (Stage 2: real `MicInUseProbe` in app,
    ///     scripted stream in tests).
    ///   - vadProbe: speech-in-system-audio seam.
    ///   - config: `MeetingsConfig` for the named timings.
    ///   - clock: virtual clock seam — production passes `SystemClock()`,
    ///     tests pass a `VirtualClock` so cooldown math runs without
    ///     waiting wall time.
    ///   - chunkDurationSeconds: how many seconds one VAD `true` chunk
    ///     represents. Production: ~0.256s (FluidAudio Silero @ 16 kHz);
    ///     tests usually pass 0.25 to keep arithmetic round.
    init(
        micProbe: MicInUseProbing,
        vadProbe: SystemAudioVADProbing,
        config: MeetingsConfig,
        clock: MeetingDetectorClocking = SystemClock(),
        chunkDurationSeconds: TimeInterval = Double(4096) / Double(16000),
        frontmostDetector: FrontmostAppDetecting? = nil
    ) {
        self.micProbe = micProbe
        self.vadProbe = vadProbe
        self.config = config
        self.clock = clock
        self.chunkDurationSeconds = chunkDurationSeconds
        self.frontmostDetector = frontmostDetector

        let (stream, continuation) = AsyncStream<MeetingDetectorEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    // MARK: - MeetingDetectorProtocol

    /// Idempotent. First call subscribes to both probes and starts the
    /// background consumers; subsequent calls are no-ops (Stage 1a contract
    /// is "called exactly once when the feature flag is on").
    func subscribe() {
        guard !didSubscribe else { return }
        didSubscribe = true

        let micStream = micProbe.subscribe()
        // NOTE: `vadProbe.subscribe()` deliberately no longer starts the
        // CoreAudio tap. This detector subscribes once at launch and is never
        // stopped, so a tap started here would keep the macOS "System Audio
        // Recording" indicator lit for the whole session even when nothing is
        // being recorded. With no tap running no samples flow, so `vadStream`
        // stays empty and `handleVAD` is dormant in production — the trigger
        // fires off `handleMic` (frontmost-app + mic) instead. The VAD path is
        // kept wired but inert pending a decision on whether VAD detection
        // returns. WHY: docs/decisions/2026-06-16-system-audio-tap-on-record-only.md
        let vadStream = vadProbe.subscribe()

        micConsumer = Task { [weak self] in
            for await value in micStream {
                guard let self else { break }
                await self.handleMic(value)
            }
        }
        vadConsumer = Task { [weak self] in
            for await value in vadStream {
                guard let self else { break }
                await self.handleVAD(speechPresent: value)
            }
        }
    }

    /// Tears down both consumer tasks and terminates the `events` stream.
    /// Called by the coordinator at shutdown / feature-flag flip.
    func stop() async {
        micConsumer?.cancel()
        vadConsumer?.cancel()
        micOnlyTriggerTask?.cancel()
        micConsumer = nil
        vadConsumer = nil
        micOnlyTriggerTask = nil
        micProbe.stop()
        await vadProbe.stop()
        eventsContinuation.finish()
    }

    /// Engaged by the pill / coordinator when the user dismisses the
    /// suggestion (Stage 3). Locks new triggers in the **current**
    /// mic-session for `cooldownAfterDismissMinutes` minutes. The clock
    /// here is the injected one so tests can fast-forward.
    func engageCooldown() {
        let minutes = TimeInterval(MeetingsConfig.cooldownAfterDismissMinutes)
        let until = clock.now().addingTimeInterval(minutes * 60)
        cooldownUntil = until
        shouldResetOnNextContextStart = true
        os_log(
            "detector cooldown engaged (minutes: %{public}d)",
            log: Self.log, type: .info,
            MeetingsConfig.cooldownAfterDismissMinutes
        )
    }

    // MARK: - PoC mic-only trigger

    /// Path A: if the frontmost app is a recognized meeting app (or a
    /// browser with a meeting URL open), fire immediately — no need to
    /// wait the 30s fallback. Returns true if we fired.
    /// Path B (caller): otherwise schedule the mic-duration fallback.
    private func tryFireFromFrontmost() async -> Bool {
        guard let detector = frontmostDetector else { return false }
        guard await detector.isInMeetingContext() else { return false }
        let nowStillEligible: Bool = {
            guard micIsOn else { return false }
            guard !firedInCurrentSession else { return false }
            if let cooldownUntil, clock.now() < cooldownUntil { return false }
            return true
        }()
        guard nowStillEligible else { return false }
        firedInCurrentSession = true
        let meetingId = UUID()
        eventsContinuation.yield(.triggered(meetingId: meetingId))
        os_log(
            "detector triggered via frontmost-app path (meetingId: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString
        )
        return true
    }

    /// Polls frontmost-app every 2s while mic is active. Fires path A
    /// trigger as soon as frontmost matches whitelist / browser URL.
    /// Exits cleanly when mic released, trigger fires, or task cancelled.
    /// Replaces the previous 30s "fallback" path which caused false
    /// positives on voice messages and dictation. No fallback means apps
    /// outside the whitelist (Loom, in-person etc.) don't trigger — by
    /// design for PoC; revisit per spec if coverage gap matters.
    private func scheduleMicOnlyTrigger() {
        micOnlyTriggerTask?.cancel()
        os_log(
            "frontmost-app watcher started (poll every 2s while mic active)",
            log: Self.log, type: .info
        )
        micOnlyTriggerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.tryFireFromFrontmost() {
                    return  // fired via path A
                }
                if await self.shouldStopFrontmostWatcher() {
                    return  // mic released, already fired, or cooldown
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func shouldStopFrontmostWatcher() -> Bool {
        if !micIsOn { return true }
        if firedInCurrentSession { return true }
        if let cooldownUntil, clock.now() < cooldownUntil { return true }
        return false
    }

    /// Legacy fallback fire — kept compiling but no longer scheduled.
    /// Removed in PoC because 30s mic-only fired on voice messages /
    /// dictation. Whitelist + browser URL is the only trigger path now.
    private func fireMicOnlyTriggerIfStillEligible() async {
        // intentional no-op
    }

    // MARK: - State machine

    /// PoC override: hybrid trigger.
    /// (1) Frontmost app in meeting whitelist OR browser w/ meeting URL → fire immediately.
    /// (2) Fallback: sustained mic-active for `micOnlyTriggerSeconds` → fire (for apps
    ///     outside whitelist e.g. Loom-style recordings, in-person meetings).
    /// Original VAD path (system-audio Silero) silently classified real Zoom/Slack
    /// audio as silence in production; bypassed pending separate investigation.
    private static let micOnlyTriggerSeconds: TimeInterval = 30
    private var micOnlyTriggerTask: Task<Void, Never>?
    /// Frontmost-app detector. Injected via init; defaults to production
    /// `FrontmostAppDetector` when AppDelegate constructs the detector.
    /// Optional so existing tests (Stage 2-9) keep working unchanged —
    /// nil = legacy mic-only fallback path only.
    private let frontmostDetector: FrontmostAppDetecting?

    private func handleMic(_ isOn: Bool) async {
        let now = clock.now()

        // Detect new mic-session: mic was released for ≥
        // `autoEndMicReleasedSeconds` and is now back on.
        if isOn && !micIsOn {
            if let releasedAt = micReleasedAt {
                let gap = now.timeIntervalSince(releasedAt)
                if shouldResetOnNextContextStart || gap >= MeetingsConfig.autoEndMicReleasedSeconds {
                    resetSessionState()
                }
            }
            // Even if this is the very first mic-on we ever see, clear
            // any stale per-session state from construction.
            if !firedInCurrentSession && cooldownUntil == nil {
                speechChunkTimestamps.removeAll(keepingCapacity: true)
            }
            micReleasedAt = nil
            // Path A: immediate fire when frontmost is a meeting app /
            // browser with meeting URL. If it fires, skip scheduling
            // the slower mic-duration fallback (single trigger per session).
            let firedImmediately = await tryFireFromFrontmost()
            if !firedImmediately {
                scheduleMicOnlyTrigger()
            }
        } else if !isOn && micIsOn {
            micReleasedAt = now
            if firedInCurrentSession {
                let shouldNotifyContextEnded = !shouldResetOnNextContextStart
                shouldResetOnNextContextStart = true
                if shouldNotifyContextEnded {
                    eventsContinuation.yield(.contextEnded)
                    os_log(
                        "detector context ended",
                        log: Self.log, type: .info
                    )
                }
            }
            micOnlyTriggerTask?.cancel()
            micOnlyTriggerTask = nil
        } else if !isOn && !micIsOn {
            // Repeated "still off" tick: if enough time has passed since
            // the last mic-released stamp (and we are not currently in a
            // mic session anyway), proactively clear session state so a
            // future mic-on is recognised as a fresh session even if the
            // probe deduped intermediate transitions.
            if let releasedAt = micReleasedAt {
                let gap = now.timeIntervalSince(releasedAt)
                if gap >= MeetingsConfig.autoEndMicReleasedSeconds {
                    resetSessionState()
                }
            }
        }
        micIsOn = isOn
    }

    private func handleVAD(speechPresent: Bool) async {
        let now = clock.now()
        // Evict any timestamps older than the rolling window.
        let windowStart = now.addingTimeInterval(-MeetingsConfig.detectorWindowSeconds)
        while let head = speechChunkTimestamps.first, head < windowStart {
            speechChunkTimestamps.removeFirst()
        }

        guard speechPresent else { return }
        speechChunkTimestamps.append(now)

        evaluateTrigger(at: now)
    }

    private func evaluateTrigger(at now: Date) {
        guard micIsOn else { return }
        guard !firedInCurrentSession else { return }
        if let cooldownUntil, now < cooldownUntil { return }

        let speechSeconds = Double(speechChunkTimestamps.count) * chunkDurationSeconds
        guard speechSeconds >= MeetingsConfig.detectorMinSpeechSeconds else {
            return
        }

        firedInCurrentSession = true
        let meetingId = UUID()
        eventsContinuation.yield(.triggered(meetingId: meetingId))
        os_log(
            "detector triggered (meetingId: %{public}@, speech_s: %{public}.2f)",
            log: Self.log, type: .info,
            meetingId.uuidString, speechSeconds
        )
    }

    private func resetSessionState() {
        firedInCurrentSession = false
        cooldownUntil = nil
        shouldResetOnNextContextStart = false
        speechChunkTimestamps.removeAll(keepingCapacity: true)
        micReleasedAt = nil
        micOnlyTriggerTask?.cancel()
        micOnlyTriggerTask = nil
    }
}
