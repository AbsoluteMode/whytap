import Foundation

/// Drop "stop automatically": with a Toggle shortcut the user presses once,
/// speaks, and the take ends when they stop. Pressing again still stops it at
/// once. Off by default; it does nothing for a hold shortcut, where releasing
/// the key is the end.
/// WHY: .project-docs/decisions/2026-11-11-drop-auto-stop.md
@MainActor
final class DropAutoStopPreferences {
    static let shared = DropAutoStopPreferences()
    static let enabledDefaultsKey = "com.sidekey.drop.autoStop.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledDefaultsKey) }
        set { defaults.set(newValue, forKey: Self.enabledDefaultsKey) }
    }
}

/// End-of-speech timing, adjustable without a rebuild while it is being
/// calibrated on real speech:
///
///     defaults write com.rootwise.sidekey com.sidekey.drop.autoStop.quietSeconds -float 1.5
///
/// Read when a take starts. Out-of-range or missing values use the defaults.
enum DropAutoStopTuning {
    static let quietSecondsKey = "com.sidekey.drop.autoStop.quietSeconds"

    static let defaultQuietSeconds: TimeInterval = 2
    static let quietSecondsRange: ClosedRange<TimeInterval> = 0.5...5

    /// Quiet in the live transcript that ends the take (every provider).
    static func quietSeconds(_ defaults: UserDefaults = .standard) -> TimeInterval {
        value(defaults, quietSecondsKey, in: quietSecondsRange, fallback: defaultQuietSeconds)
    }

    private static func value(
        _ defaults: UserDefaults, _ key: String, in range: ClosedRange<Double>, fallback: Double
    ) -> Double {
        guard let stored = defaults.object(forKey: key) as? NSNumber else { return fallback }
        let number = stored.doubleValue
        return number.isFinite && range.contains(number) ? number : fallback
    }
}

/// Decides when a take nobody will stop by key is over: when the live
/// transcript stops changing, or when no words came at all. It is always an
/// ordinary stop, never a cancel: the delivery ladder then pastes nothing for
/// silence and still recovers the retained audio if the connection dropped.
/// The same rule for every provider: a provider's own commit never ends a
/// take, since Scribe also commits at its ~36 s segment cap mid-sentence.
/// WHY: .project-docs/decisions/2026-11-12-drop-auto-stop-local-rule-only.md
///
/// A provider can also hold its live text back while the speaker goes on
/// (Scribe did for over 1.5 s before its segment cap), so a quiet transcript
/// ends the take only once the microphone is quiet too. Sound that is not
/// speech cannot hold a take open for longer than `voiceHoldLimit`.
/// WHY: .project-docs/decisions/2026-11-13-drop-auto-stop-voice-guard.md
/// Pure: the caller supplies the clock.
struct DropAutoStopRule: Equatable {
    enum Decision: Equatable {
        case keepListening
        case finish
    }

    /// Time to start speaking once recording has begun. Shorter than the
    /// streaming session's 6 s silent-stall check, which would otherwise close
    /// the provider connection first.
    static let noSpeechTimeout: TimeInterval = 5

    /// Longest a quiet transcript is kept open by sound in the microphone.
    /// Past it the sound is taken for the room, not the speaker.
    static let voiceHoldLimit: TimeInterval = 6

    /// How far above the quietest level of this take the microphone must be
    /// to count as a voice (normalized level, 0.15 = 9 dB).
    static let voiceMargin: Float = 0.15

    private let startedAt: TimeInterval
    private let quietAfterSpeech: TimeInterval
    private var lastText = ""
    private var lastChangeAt: TimeInterval?
    private var quietestLevel: Float?
    private var lastVoiceAt: TimeInterval?

    /// - Parameter now: when recording began (after session setup).
    init(now: TimeInterval, quietAfterSpeech: TimeInterval = DropAutoStopTuning.defaultQuietSeconds) {
        startedAt = now
        self.quietAfterSpeech = quietAfterSpeech
    }

    mutating func transcriptChanged(_ text: String, now: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastText else { return }
        lastText = trimmed
        lastChangeAt = now
    }

    /// The loudest microphone level since the previous call (normalized
    /// 0...1). Exact zero is a dropped buffer and teaches nothing.
    mutating func microphoneLevel(_ level: Float, now: TimeInterval) {
        guard level > 0 else { return }
        let quietest = min(quietestLevel ?? level, level)
        quietestLevel = quietest
        if level >= quietest + Self.voiceMargin { lastVoiceAt = now }
    }

    func decision(now: TimeInterval) -> Decision {
        guard !lastText.isEmpty, let lastChangeAt else {
            return now - startedAt >= Self.noSpeechTimeout ? .finish : .keepListening
        }
        let transcriptQuiet = now - lastChangeAt
        guard transcriptQuiet >= quietAfterSpeech else { return .keepListening }
        if transcriptQuiet < Self.voiceHoldLimit,
           let lastVoiceAt, now - lastVoiceAt < quietAfterSpeech {
            return .keepListening
        }
        return .finish
    }
}

/// The rule for the take in progress, owned by the app delegate.
///
/// Words can arrive before the watcher's first poll, so the rule must exist
/// from the moment recording begins: `transcriptChanged` creates it when the
/// watcher has not yet, and nothing said is ever counted as silence.
@MainActor
final class DropAutoStopWatch {
    private var rule: DropAutoStopRule?
    private let quietSeconds: () -> TimeInterval

    init(quietSeconds: @escaping () -> TimeInterval = { DropAutoStopTuning.quietSeconds() }) {
        self.quietSeconds = quietSeconds
    }

    /// Recording began. Idempotent: the first caller sets the start time.
    func recordingBegan(now: TimeInterval) {
        guard rule == nil else { return }
        rule = DropAutoStopRule(now: now, quietAfterSpeech: quietSeconds())
    }

    func transcriptChanged(_ text: String, now: TimeInterval) {
        recordingBegan(now: now)
        rule?.transcriptChanged(text, now: now)
    }

    func microphoneLevel(_ level: Float, now: TimeInterval) {
        recordingBegan(now: now)
        rule?.microphoneLevel(level, now: now)
    }

    /// The decision for a take that is recording.
    func decision(now: TimeInterval) -> DropAutoStopRule.Decision {
        recordingBegan(now: now)
        return rule?.decision(now: now) ?? .keepListening
    }

    func reset() {
        rule = nil
    }
}
