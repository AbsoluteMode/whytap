import Foundation

/// Protocol surface for the Meeting Notes feature.
///
/// - `MeetingDetectorProtocol`  -> `MeetingDetector`, `MicInUseProbe`,
///   `SystemAudioVADProbe`
/// - `MeetingPillDisplaying`    -> `MeetingPillController` + `MeetingPillView`
/// - `MeetingRecording`         -> `MeetingRecorder`
/// - `MeetingsStoring`          -> `MeetingsStore` over SQLite + `.md` cache
///
/// Adding members here later is non-breaking; renaming or removing is
/// breaking — flagged by `test_meetings_feature_protocols_compile`.

@MainActor
protocol MeetingDetectorProtocol: AnyObject {
    /// Begin emitting trigger events into whatever stream
    /// `MeetingsCoordinator` wires up. The contract is just "called exactly
    /// once when the feature flag is on".
    func subscribe()
}

/// A detector that also vends a `.triggered` event stream + cooldown
/// engagement. Layered on top of `MeetingDetectorProtocol` so the
/// `StubbedMeetingDetector` (and the coordinator tests' stub) can keep
/// conforming to the simpler base protocol without growing the API they
/// have to implement. The coordinator down-casts to this surface when
/// wiring the pill, so tests can inject a stub without instantiating the
/// real `MeetingDetector` (which transitively pulls in FluidAudio and
/// CoreAudio).
@MainActor
protocol MeetingDetectorEventEmitting: MeetingDetectorProtocol {
    /// Events stream — drained by `MeetingsCoordinator` to wire pill /
    /// recorder reactions. The concrete `MeetingDetector` vends its
    /// `events` here; stubs can synthesise their own.
    var events: AsyncStream<MeetingDetectorEvent> { get }

    /// Lock new triggers in the current mic-session for
    /// `MeetingsConfig.cooldownAfterDismissMinutes` minutes. Called by
    /// `MeetingsCoordinator` on `.dismiss` from the pill.
    func engageCooldown()
}

@MainActor
protocol MeetingPillDisplaying: AnyObject {}

@MainActor
protocol MeetingRecording: AnyObject {}

/// Logical source of a recorded WAV chunk. `mixed` is the (m+s)*0.5 mix;
/// `mic` and `system` are the aligned per-source tracks the fully-local
/// pipeline labels as "Me" / remote speakers.
enum MeetingAudioTrack: String, Codable, CaseIterable, Sendable {
    case mixed
    case mic
    case system
}

/// One diarized segment of the meeting transcript. Produced by the
/// on-device diarizer (or as a single whole-meeting segment on the BYOK
/// path) and persisted as JSON so the notes viewer can render speaker
/// attributions without re-parsing.
struct TranscriptSegment: Sendable, Codable, Equatable {
    let speaker: String?
    let start: Double
    let end: Double
    let text: String
}

/// Empty marker — the concrete `MeetingsStore` is an `actor`, not a
/// `@MainActor` class, so this protocol stays actor-agnostic. Adding
/// members later remains non-breaking.
protocol MeetingsStoring: AnyObject {}

/// Reference no-op detector kept for tests / future fallbacks.
/// `AppDelegate.installMeetingsCoordinator()` wires the real
/// `MeetingDetector` (mic-in-use + system audio VAD) by default; this stub
/// remains so the `MeetingDetectorProtocol` contract has a minimal concrete
/// implementation that does not depend on CoreAudio or FluidAudio (handy
/// for headless / offline tests that only need the protocol to type-check).
@MainActor
final class StubbedMeetingDetector: MeetingDetectorProtocol {
    func subscribe() {
        // Intentionally empty — see doc comment.
    }
}
