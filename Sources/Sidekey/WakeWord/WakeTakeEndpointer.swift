import Foundation

/// Decides when a wake-word take is over. Nobody releases a key, so the take
/// ends when the live transcript stops changing, and is dropped when nothing
/// was said at all (a false trigger). Works for every provider; a provider
/// that predicts the end of a turn simply finishes the take earlier.
/// Pure: the caller supplies the clock.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
struct WakeTakeEndpointer: Equatable {
    enum Decision: Equatable {
        case keepListening
        /// Words were said and then the transcript went quiet: deliver them.
        case finish
        /// No words arrived: discard the take without pasting.
        case cancel
    }

    /// Time to start speaking once recording has begun. Shorter than the
    /// streaming session's 6 s silent-stall check, which would otherwise close
    /// the provider connection first.
    static let noSpeechTimeout: TimeInterval = 5
    /// Quiet after the last transcript change that ends the take; the
    /// default of `WakeWordTuning.quietSeconds`.
    static let quietAfterSpeech: TimeInterval = WakeWordTuning.defaultQuietSeconds
    /// A take nobody can release is never longer than this: a false trigger
    /// next to a TV must not stream the room for the 10-minute hotkey cap.
    static let maximumDuration: TimeInterval = 60

    private let startedAt: TimeInterval
    private let quietAfterSpeech: TimeInterval
    private var lastText = ""
    private var lastChangeAt: TimeInterval?

    /// - Parameter now: when recording began (after session setup).
    init(now: TimeInterval, quietAfterSpeech: TimeInterval = WakeTakeEndpointer.quietAfterSpeech) {
        startedAt = now
        self.quietAfterSpeech = quietAfterSpeech
    }

    mutating func transcriptChanged(_ text: String, now: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastText else { return }
        lastText = trimmed
        lastChangeAt = now
    }

    func decision(now: TimeInterval) -> Decision {
        if now - startedAt >= Self.maximumDuration { return lastText.isEmpty ? .cancel : .finish }
        guard !lastText.isEmpty, let lastChangeAt else {
            return now - startedAt >= Self.noSpeechTimeout ? .cancel : .keepListening
        }
        return now - lastChangeAt >= quietAfterSpeech ? .finish : .keepListening
    }
}
