import Foundation

/// Pure-logic decision: is this freshly-captured recording worth
/// transcribing at all (on-device or with the user's STT provider), or is
/// it a hot-key misfire we should drop silently?
///
/// Why this exists:
///   A fast tap-and-release of either the Agent gesture (Right Cmd) or
///   the Drop hotkey (Option + /) produces a tiny WAV containing mostly
///   background noise. The recording isn't empty in bytes — there's a
///   WAV header plus a few PCM frames — so `AudioRecorder.stop()`'s
///   `!data.isEmpty` guard lets it through. The transcriber then chews
///   on near-silence, returns nothing useful (or an error), and the user
///   sees an alarming error block for what was really just a
///   finger-twitch.
///
///   The fix is a client-side guard: if the gesture didn't last long
///   enough to plausibly contain speech, OR the audio peak never crossed
///   the codebase's existing `voiceNoiseGate` (0.04), drop the recording
///   and return to idle without touching the network. The user sees
///   "nothing happened" — which is the right outcome when nothing was
///   said.
///
///   Decision lives in a separate type from `AudioRecorder` so it can be
///   unit-tested without instantiating an `AVAudioRecorder`.
struct AudioSilenceDetector {
    /// Minimum gesture duration to consider plausibly-speech. 0.4s is
    /// below the duration of any natural single-word utterance ("yes",
    /// "no", "да") so a deliberate one-word command still goes through,
    /// while the typical sub-200ms tap-and-release misfire is rejected.
    /// Picked by ear / Maxim's typical speaking cadence — adjust if the
    /// guard starts eating real one-word commands.
    static let minimumDurationSeconds: TimeInterval = 0.4

    /// Peak-energy threshold below which the recording is considered
    /// silence-only. Reuses the same `voiceNoiseGate = 0.04` constant the
    /// orb already uses to decide "the user is speaking" so the guard's
    /// floor is consistent with the visual feedback — if the orb didn't
    /// see voice, the recording isn't worth transcribing.
    static let minimumPeakEnergy: Float = Float(VoiceOrbView.voiceNoiseGate)

    /// Why a recording was dropped. Reported via `os_log` so we can
    /// distinguish "user fat-fingered the gesture" from "user held the
    /// gesture but never spoke" in telemetry without touching the audio
    /// content itself.
    enum DropReason: String, Equatable {
        case tooShort
        case silenceOnly
    }

    enum Decision: Equatable {
        case proceed
        case drop(DropReason)
    }

    let minimumDurationSeconds: TimeInterval
    let minimumPeakEnergy: Float

    init(
        minimumDurationSeconds: TimeInterval = AudioSilenceDetector.minimumDurationSeconds,
        minimumPeakEnergy: Float = AudioSilenceDetector.minimumPeakEnergy
    ) {
        self.minimumDurationSeconds = minimumDurationSeconds
        self.minimumPeakEnergy = minimumPeakEnergy
    }

    /// Decide whether a recording is worth transcribing at all.
    ///
    /// `durationSeconds` is the wall-clock length of the gesture (not the
    /// in-WAV sample count — `AVAudioRecorder`'s metering already happens
    /// against the wall clock, and we'd rather over-report duration than
    /// trust a possibly-truncated file).
    ///
    /// `peakEnergy` is the maximum normalized [0..1] meter reading
    /// observed across the recording — i.e. the loudest moment. We use
    /// the peak rather than an average because a 5-second recording with
    /// one spoken word and four seconds of silence has a low average but
    /// a high peak; the average would reject real speech.
    ///
    /// Order matters: the duration rule fires first so the reason
    /// reported to telemetry is deterministic when both signals trip on
    /// the same misfire (a short tap with no audio captured).
    func decide(durationSeconds: TimeInterval, peakEnergy: Float) -> Decision {
        if durationSeconds < minimumDurationSeconds {
            return .drop(.tooShort)
        }
        // Non-finite peak (NaN / ±inf) from a transient meter hiccup is
        // treated as silence — we cannot prove the recording contains
        // speech, and surfacing an "unavailable" toast in this case is
        // strictly worse than dropping. Same defensive shape as
        // `AudioMeter.normalize`.
        if !peakEnergy.isFinite || peakEnergy < minimumPeakEnergy {
            return .drop(.silenceOnly)
        }
        return .proceed
    }
}
