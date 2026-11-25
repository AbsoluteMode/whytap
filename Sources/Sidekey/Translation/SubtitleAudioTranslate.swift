import Foundation

/// Subtitles' one engine: a live speech-translation session that hears the
/// system audio and returns the translation and the heard original. Soniox
/// real-time translation runs whenever the Soniox key (the one Drop uses)
/// can be read: it is about five times faster and twenty times cheaper than
/// OpenAI `gpt-realtime-translate`, which remains the fallback with the
/// OpenAI key. There is no engine choice in Keys & models: the Subtitles row
/// shows the engine the keys give. Without either key Start says what is
/// missing and opens Keys & models.
// WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-engine.md
// WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
enum SubtitleAudioTranslate {
    enum Engine: Equatable, Sendable {
        case soniox, openAI

        var account: ProviderAccount { self == .soniox ? .soniox : .openAI }
        var model: String { self == .soniox ? SonioxRealtimeTranslateAdapter.model : OpenAIRealtimeTranslateAdapter.model }
        var providerName: String { self == .soniox ? "Soniox" : "OpenAI" }
        /// The Models row's label.
        var label: String { "\(providerName) · \(model)" }
    }

    /// The OpenAI fallback's model, kept for Costs and older callers.
    static let account = ProviderAccount.openAI
    static let model = OpenAIRealtimeTranslateAdapter.model
    static let keychainAccount = ProviderAccount.openAIKeychainAccount

    /// A key, as the Keychain gives it.
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

    /// A session that failed to open, with the provider its message names.
    struct EngineFailure: Error, Equatable {
        let failure: SpeechTranslationFailure
        let provider: String
    }

    /// Opens the engine the keys give, metered for Costs.
    static func open(source: String?, target: String,
                     keys: ProviderKeyStore = ProviderKeyStore()) async throws -> SpeechTranslationSession {
        let (engine, key) = try engineAndKey(from: keys)
        let session: SpeechTranslationSession
        do {
            switch engine {
            case .soniox:
                session = try await SonioxRealtimeTranslateAdapter(apiKey: key).open(source: source, target: target)
            case .openAI:
                session = try await OpenAIRealtimeTranslateAdapter(apiKey: key, model: engine.model).open(target: target)
            }
        } catch let failure as SpeechTranslationFailure {
            throw EngineFailure(failure: failure, provider: engine.providerName)
        }
        let context = AIUsageContext(feature: .subtitlesAudio, account: engine.account, model: engine.model)
        return AIUsageMeteredSpeechTranslation(session: session, context: context)
    }

    /// The engine the keys give: Soniox with its key, otherwise OpenAI with
    /// its key; nil with neither.
    static func engine(soniox: KeyState, openAI: KeyState) -> Engine? {
        if soniox == .present { return .soniox }
        if openAI == .present { return .openAI }
        return nil
    }

    /// Without an engine: unreadable when a key exists but cannot be read.
    static func unavailable(soniox: KeyState, openAI: KeyState) -> Unavailable {
        soniox == .unreadable || openAI == .unreadable ? .unreadableKey : .missingKey
    }

    /// The engine and its key for a Subtitles start, or why there is none.
    static func engineAndKey(from keys: ProviderKeyStore = ProviderKeyStore()) throws -> (Engine, String) {
        let soniox = keys.lookup(account: BYOKKeyStore.account(for: .soniox))
        if case .key(let key) = soniox { return (.soniox, key) }
        let openAI = keys.lookup(account: keychainAccount)
        if case .key(let key) = openAI { return (.openAI, key) }
        throw unavailable(soniox: KeyState(soniox), openAI: KeyState(openAI))
    }

    /// The OpenAI key (the fallback engine's), or why there is none.
    static func key(from keys: ProviderKeyStore = ProviderKeyStore()) throws -> String {
        switch keys.lookup(account: keychainAccount) {
        case .key(let key): return key
        case .absent: throw Unavailable.missingKey
        case .unreadable: throw Unavailable.unreadableKey
        }
    }
}
