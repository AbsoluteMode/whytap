import AppKit
import Combine
import Foundation
import SwiftUI
import os.log

// MARK: - Public state / event surfaces

/// State machine for `MeetingPillController`. Stage 3 implements
/// `.hidden` and `.suggesting`; `.recording` and `.paused` are
/// placeholders Stage 4 / Stage 9 fill in (the cases live here so the
/// controller can keep the same `state` property as it grows).
@MainActor
enum MeetingPillState: Equatable {
    /// No pill on screen.
    case hidden
    /// "Take notes / Skip" suggestion. `deadline` is the absolute wall-clock
    /// time at which the controller auto-dismisses with reason `.timeout`.
    case suggesting(meetingId: UUID, deadline: Date)
    /// A detector trigger arrived during the previous recording's grace window.
    case suggestingReconnect(
        meetingId: UUID,
        previousMeetingId: UUID,
        gapSeconds: TimeInterval,
        deadline: Date
    )
    /// Stage 4 stub — recording active, waveform visible.
    case recording(meetingId: UUID, audioLevel: Double, duration: TimeInterval)
    /// Stage 9 stub — recording paused (e.g. sleep), waveform dimmed.
    case paused(meetingId: UUID, audioLevel: Double, duration: TimeInterval)
}

/// Why the pill dismissed. The coordinator engages cooldown on both,
/// but observability separates them so we can see in Console.app how
/// many users actively click Skip vs ignore the pill.
enum MeetingPillDismissReason: Equatable, Sendable {
    case user
    case timeout
}

/// Events emitted by `MeetingPillController` for the coordinator to
/// consume. The coordinator wires `.dismiss` → `buffer.gc()` +
/// `detector.engageCooldown()`, `.accept` → AcceptEvent (Stage 4), and
/// `.stop` → MeetingRecorder.stop (Stage 4).
enum MeetingPillEvent: Equatable, Sendable {
    case dismiss(reason: MeetingPillDismissReason)
    case accept(meetingId: UUID, bufferSnapshot: Data)
    case reconnect(
        previousMeetingId: UUID,
        gapSeconds: TimeInterval,
        bufferSnapshot: Data
    )
    case stop(meetingId: UUID)
    /// Stage 4 — Pause button on the recording pill. Coordinator routes
    /// to `MeetingRecorder.pause()`, which flushes the current chunk and
    /// releases the mic input until `.resume` fires.
    case pause(meetingId: UUID)
    /// Stage 4 — Play button on the paused pill. Coordinator routes to
    /// `MeetingRecorder.resume()`, which re-acquires inputs and starts
    /// the next chunk index.
    case resume(meetingId: UUID)
}

// MARK: - Controller

/// MainActor host for the suggestion pill. Owns:
/// - The `MeetingPillState` state machine (published so the SwiftUI
///   view can observe it).
/// - The final action routing from the SwiftUI nudge.
/// - The buffer attachment used to capture a snapshot on Yes.
/// - The events `AsyncStream` the coordinator drains.
///
/// The actual NSPanel + SwiftUI hosting lives in `MeetingPillPanel`,
/// which the controller wires up only when running in the app (we keep
/// it out of the controller's tests so XCTest does not need a key
/// window — see `_testTapAccept` / `_testTapDismiss` for the same code
/// path the SwiftUI buttons invoke).
@MainActor
final class MeetingPillController: ObservableObject, MeetingPillDisplaying {

    /// os_log surface — spec / plan call out `pill` category. Privacy
    /// invariant: never logs audio samples, only ids / counts.
    private static let log = OSLog(
        subsystem: "com.sidekey.meetings",
        category: "pill"
    )

    /// Legacy injection seam kept so older tests and coordinator setup
    /// can still construct the controller without churn. The suggesting
    /// countdown now lives in `MeetingNudgeView` because it pauses while
    /// the user hovers either half of the nudge.
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Published so SwiftUI re-renders on transitions. Tests inspect it
    /// synchronously after `show()` / `hide()` / button actions.
    @Published private(set) var state: MeetingPillState = .hidden

    /// Drain point for the coordinator. The controller terminates the
    /// stream on `deinit`; the coordinator's draining task then exits
    /// its `for await` loop.
    let events: AsyncStream<MeetingPillEvent>
    private let eventsContinuation: AsyncStream<MeetingPillEvent>.Continuation

    private let buffer: MeetingPillBufferAttaching

    /// Bumped every state transition. The value is still useful for
    /// keeping older state-machine paths explicit even though the
    /// suggesting countdown now lives in `MeetingNudgeView`.
    private var generation: UInt64 = 0

    init(
        buffer: MeetingPillBufferAttaching,
        scheduler: Scheduler? = nil
    ) {
        self.buffer = buffer
        let (stream, continuation) = AsyncStream<MeetingPillEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
        _ = scheduler
    }

    deinit {
        Task { @MainActor in
            AppState.shared.meetingSuggestionActive = false
            AppState.shared.meetingSuggestionDeadline = nil
            AppState.shared.clearMeetingRecordingState()
        }
        eventsContinuation.finish()
    }

    // MARK: - Public surface

    /// Show the pill in the given state. For `.suggesting`, the SwiftUI
    /// nudge owns the countdown so hover can pause it. For `.hidden`,
    /// equivalent to `hide()`. `.recording` / `.paused` update `state`
    /// without scheduling.
    func show(_ newState: MeetingPillState) {
        generation &+= 1
        setState(newState)

        if case .suggesting(let meetingId, _) = newState {
            os_log(
                "pill suggested (meetingId: %{public}@, deadline_s: %{public}.0f)",
                log: Self.log, type: .info,
                meetingId.uuidString,
                MeetingsConfig.pillDecisionTimeoutSeconds
            )
        } else if case .suggestingReconnect(
            let meetingId, let previousMeetingId, let gapSeconds, _
        ) = newState {
            os_log(
                "pill suggested reconnect (meetingId: %{public}@, previousMeetingId: %{public}@, gap_s: %{public}.1f)",
                log: Self.log, type: .info,
                meetingId.uuidString, previousMeetingId.uuidString, gapSeconds
            )
        }
    }

    /// Force-hide the pill. Used by the coordinator on app shutdown or
    /// when a higher-priority surface (Stage 4+ recording) takes over.
    /// Does NOT emit a `.dismiss` event — the caller is expected to
    /// handle cleanup themselves.
    func hide() {
        generation &+= 1
        setState(.hidden)
    }

    /// Pause button code path on the recording pill. Emits
    /// `.pause(meetingId)` and transitions to `.paused` with the same
    /// audio level / duration values currently on screen. No-op when the
    /// controller is not in `.recording` — protects against double-tap
    /// races between the SwiftUI button and the underlying state.
    func pause() {
        guard case .recording(let meetingId, let audioLevel, let duration) = state else { return }
        os_log(
            "pill paused (meetingId: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString
        )
        eventsContinuation.yield(.pause(meetingId: meetingId))
        generation &+= 1
        setState(.paused(meetingId: meetingId, audioLevel: audioLevel, duration: duration))
    }

    /// Play button code path on the paused pill. Emits
    /// `.resume(meetingId)` and transitions back to `.recording`. No-op
    /// when not in `.paused`.
    func resume() {
        guard case .paused(let meetingId, let audioLevel, let duration) = state else { return }
        os_log(
            "pill resumed (meetingId: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString
        )
        eventsContinuation.yield(.resume(meetingId: meetingId))
        generation &+= 1
        setState(.recording(meetingId: meetingId, audioLevel: audioLevel, duration: duration))
    }

    /// Stop button code path on the recording / paused pill. Emits
    /// `.stop(meetingId)` and transitions to `.hidden`. No-op when not
    /// in `.recording` or `.paused`.
    func stopRecording() {
        let meetingId: UUID?
        switch state {
        case .recording(let id, _, _): meetingId = id
        case .paused(let id, _, _): meetingId = id
        default: meetingId = nil
        }
        guard let meetingId else { return }
        os_log(
            "pill stop (meetingId: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString
        )
        eventsContinuation.yield(.stop(meetingId: meetingId))
        generation &+= 1
        setState(.hidden)
    }

    /// Push a fresh `(audioLevel, duration)` snapshot into the current
    /// `.recording` / `.paused` state without changing meetingId or
    /// emitting events. Wired by `MeetingsCoordinator` to forward live
    /// audio level + timer ticks from the recorder. No-op when not in
    /// `.recording` or `.paused`.
    func updateLiveState(audioLevel: Double, duration: TimeInterval) {
        switch state {
        case .recording(let id, _, _):
            setState(.recording(meetingId: id, audioLevel: audioLevel, duration: duration))
        case .paused(let id, _, _):
            setState(.paused(meetingId: id, audioLevel: audioLevel, duration: duration))
        default:
            break
        }
    }

    // MARK: - Internal (called by SwiftUI buttons + test seams)

    /// Yes-button code path. Takes a snapshot from the attached buffer,
    /// emits `.accept(meetingId, snapshot)`, and transitions to hidden.
    /// `async` because `buffer.snapshot()` is actor-isolated.
    func _testTapAccept() async {
        let meetingId: UUID
        switch state {
        case .suggesting(let id, _), .suggestingReconnect(let id, _, _, _):
            meetingId = id
        default:
            return
        }
        let snapshot = await buffer.snapshot()
        os_log(
            "pill accepted (meetingId: %{public}@, snapshot_bytes: %{public}d)",
            log: Self.log, type: .info,
            meetingId.uuidString, snapshot.count
        )
        eventsContinuation.yield(.accept(meetingId: meetingId, bufferSnapshot: snapshot))
        generation &+= 1
        setState(.hidden)
    }

    func _testTapReconnect() async {
        guard case .suggestingReconnect(
            _, let previousMeetingId, let gapSeconds, _
        ) = state else { return }
        let snapshot = await buffer.snapshot()
        eventsContinuation.yield(
            .reconnect(
                previousMeetingId: previousMeetingId,
                gapSeconds: gapSeconds,
                bufferSnapshot: snapshot
            )
        )
        generation &+= 1
        setState(.hidden)
    }

    /// No-button code path. Emits `.dismiss(reason: .user)` and hides.
    /// Sync because the dismiss path does not need to touch the actor
    /// — the coordinator will call `buffer.gc()` on its own when it
    /// observes the dismiss event.
    func _testTapDismiss() async {
        switch state {
        case .suggesting, .suggestingReconnect:
            break
        default:
            return
        }
        fireDismiss(reason: .user)
    }

    /// Timeout path called by `MeetingNudgeView` when its hover-aware
    /// countdown drains to zero.
    func _testSuggestionTimedOut() {
        switch state {
        case .suggesting, .suggestingReconnect:
            break
        default:
            return
        }
        fireDismiss(reason: .timeout)
    }

    /// Single-point emission for both timeout and user-dismiss paths.
    /// Keeps the state-transition / log-event / continuation-yield
    /// sequence in one place so the two callers (button + scheduler)
    /// cannot drift.
    private func fireDismiss(reason: MeetingPillDismissReason) {
        let meetingId: UUID?
        if case .suggesting(let id, _) = state {
            meetingId = id
        } else if case .suggestingReconnect(let id, _, _, _) = state {
            meetingId = id
        } else {
            meetingId = nil
        }
        os_log(
            "pill dismissed (meetingId: %{public}@, reason: %{public}@)",
            log: Self.log, type: .info,
            meetingId?.uuidString ?? "nil",
            reason == .user ? "user" : "timeout"
        )
        eventsContinuation.yield(.dismiss(reason: reason))
        generation &+= 1
        setState(.hidden)
    }

    private func setState(_ newState: MeetingPillState) {
        state = newState

        switch newState {
        case .suggesting(_, let deadline):
            AppState.shared.meetingSuggestionActive = true
            AppState.shared.meetingSuggestionDeadline = deadline
            AppState.shared.clearMeetingRecordingState()

        case .suggestingReconnect(_, _, _, let deadline):
            AppState.shared.meetingSuggestionActive = true
            AppState.shared.meetingSuggestionDeadline = deadline
            AppState.shared.clearMeetingRecordingState()

        case .recording(_, let audioLevel, let duration):
            AppState.shared.meetingSuggestionActive = false
            AppState.shared.meetingSuggestionDeadline = nil
            AppState.shared.updateMeetingRecordingState(
                audioLevel: audioLevel,
                duration: duration,
                paused: false
            )

        case .paused(_, let audioLevel, let duration):
            AppState.shared.meetingSuggestionActive = false
            AppState.shared.meetingSuggestionDeadline = nil
            AppState.shared.updateMeetingRecordingState(
                audioLevel: audioLevel,
                duration: duration,
                paused: true
            )

        case .hidden:
            AppState.shared.meetingSuggestionActive = false
            AppState.shared.meetingSuggestionDeadline = nil
            AppState.shared.clearMeetingRecordingState()
        }
    }
}
