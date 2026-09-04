import Foundation

/// Drop output selector, stored locally in `UserPreferencesCache`.
///
/// - `fast`: the realtime transcript is pasted as-is (filler stripping only,
///   no LLM cleanup).
/// - `smart`: the transcript runs through the configured cleanup LLM
///   (on-device MLX, OpenRouter, or a custom OpenAI-compatible endpoint)
///   before it is pasted. When no LLM route is usable the Drop degrades to
///   the `fast` output instead of failing the paste.
///
/// Brand-new users default to `fast`.
enum TranscriptionMode: String, Codable, CaseIterable, Equatable, Sendable {
    case fast
    case smart
}
