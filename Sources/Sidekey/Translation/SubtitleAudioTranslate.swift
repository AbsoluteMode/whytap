import Foundation

/// Subtitles run only on OpenAI `gpt-realtime-translate`: one session hears
/// the system audio and returns the translation and the heard original. API
/// & Models -> Models -> Subtitles has this one Audio translate slot with the
/// model filled in; there is no Speech or LLM choice and no switch. It runs
/// exactly when the OpenAI key from API keys can be read. Without it Start
/// says what is missing and opens Keys & models.
// WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
enum SubtitleAudioTranslate {
    static let account = ProviderAccount.openAI
    static let model = OpenAIRealtimeTranslateAdapter.model
    static let keychainAccount = ProviderAccount.openAIKeychainAccount

    /// The OpenAI key, as the Keychain gives it.
    enum KeyState: Equatable, Sendable {
        case present, missing, unreadable

        init(_ lookup: ProviderKeyStore.KeyLookup) {
            switch lookup {
            case .key: self = .present
            case .absent: self = .missing
            case .unreadable: self = .unreadable
            }
        }
    }

    /// Why Subtitles cannot start.
    enum Unavailable: Error, Equatable {
        case missingKey, unreadableKey
    }

    /// The key for a Subtitles start, or why there is none.
    static func key(from keys: ProviderKeyStore = ProviderKeyStore()) throws -> String {
        switch keys.lookup(account: keychainAccount) {
        case .key(let key): return key
        case .absent: throw Unavailable.missingKey
        case .unreadable: throw Unavailable.unreadableKey
        }
    }
}
