import Foundation

/// Subtitles' engine: a live speech-translation session that hears the system
/// audio and returns the translation and the heard original. Keys & models →
/// Models → Subtitles chooses Soniox real-time translation or OpenAI
/// `gpt-realtime-translate`. Without a choice Soniox runs when its key (the
/// one Drop uses) can be read, otherwise OpenAI with the OpenAI key. A chosen
/// engine never falls back to the other: without its key Start names that key
/// and opens Keys & models.
// WHY: .project-docs/decisions/2026-11-27-subtitle-engine-choice.md
// WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-engine.md
// WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
enum SubtitleAudioTranslate {
    enum Engine: String, Equatable, CaseIterable, Sendable {
        case soniox, openAI

        var account: ProviderAccount { self == .soniox ? .soniox : .openAI }
        var model: String { self == .soniox ? SonioxRealtimeTranslateAdapter.model : OpenAIRealtimeTranslateAdapter.model }
        var providerName: String { self == .soniox ? "Soniox" : "OpenAI" }
        /// The Models row's label.
        var label: String { "\(providerName) · \(model)" }
    }

    /// The user's engine in Keys & models; absent means "by the keys".
    static let engineChoiceKey = "subtitles.engine"

    static func storedChoice(_ defaults: UserDefaults = .standard) -> Engine? {
        defaults.string(forKey: engineChoiceKey).flatMap(Engine.init(rawValue:))
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

    /// Why Subtitles cannot start; the engine is the chosen one, nil when
    /// none is chosen and neither key works.
    enum Unavailable: Error, Equatable {
        case missingKey(Engine?), unreadableKey(Engine?)
    }

    /// A session that failed to open, with the provider its message names.
    struct EngineFailure: Error, Equatable {
        let failure: SpeechTranslationFailure
        let provider: String
    }

    /// Opens the engine the keys give, metered for Costs.
    static func open(source: String?, target: String,
                     keys: ProviderKeyStore = ProviderKeyStore(),
                     choice: Engine? = storedChoice()) async throws -> SpeechTranslationSession {
        let (engine, key) = try engineAndKey(from: keys, choice: choice)
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

    /// The engine that runs: the chosen one when its key can be read; without
    /// a choice Soniox with its key, otherwise OpenAI with its key; else nil.
    static func engine(choice: Engine? = nil, soniox: KeyState, openAI: KeyState) -> Engine? {
        if let choice { return (choice == .soniox ? soniox : openAI) == .present ? choice : nil }
        if soniox == .present { return .soniox }
        if openAI == .present { return .openAI }
        return nil
    }

    /// Without an engine: unreadable when the relevant key exists but cannot be read.
    static func unavailable(choice: Engine? = nil, soniox: KeyState, openAI: KeyState) -> Unavailable {
        if let choice {
            return (choice == .soniox ? soniox : openAI) == .unreadable ? .unreadableKey(choice) : .missingKey(choice)
        }
        return soniox == .unreadable || openAI == .unreadable ? .unreadableKey(nil) : .missingKey(nil)
    }

    /// The engine and its key for a Subtitles start, or why there is none.
    /// Reads only the Keychain accounts it needs: the chosen engine's alone,
    /// and without a choice OpenAI's only when Soniox has no usable key.
    static func engineAndKey(from keys: ProviderKeyStore = ProviderKeyStore(),
                             choice: Engine? = nil) throws -> (Engine, String) {
        if let choice {
            let lookup = keys.lookup(account: keychainAccount(for: choice))
            if case .key(let key) = lookup { return (choice, key) }
            throw KeyState(lookup) == .unreadable ? Unavailable.unreadableKey(choice) : Unavailable.missingKey(choice)
        }
        let soniox = keys.lookup(account: keychainAccount(for: .soniox))
        if case .key(let key) = soniox { return (.soniox, key) }
        let openAI = keys.lookup(account: keychainAccount(for: .openAI))
        if case .key(let key) = openAI { return (.openAI, key) }
        throw unavailable(choice: nil, soniox: KeyState(soniox), openAI: KeyState(openAI))
    }

    /// The Keychain account that holds an engine's key.
    static func keychainAccount(for engine: Engine) -> String {
        engine == .soniox ? BYOKKeyStore.account(for: .soniox) : keychainAccount
    }

    /// The OpenAI key (the fallback engine's), or why there is none.
    static func key(from keys: ProviderKeyStore = ProviderKeyStore()) throws -> String {
        switch keys.lookup(account: keychainAccount) {
        case .key(let key): return key
        case .absent: throw Unavailable.missingKey(.openAI)
        case .unreadable: throw Unavailable.unreadableKey(.openAI)
        }
    }
}
