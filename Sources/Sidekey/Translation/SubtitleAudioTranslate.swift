import Foundation

/// Subtitles' engine: a live speech-translation session that hears the
/// system audio and returns the translation and the heard original. The
/// user chooses it in Keys & models -> Models -> Subtitles: Soniox real-time
/// translation (the key Drop uses; about five times faster and twenty times
/// cheaper) or OpenAI `gpt-realtime-translate`. The saved choice is the only
/// source at Start; without one, OpenAI (the route 2.2.27 had) unless only
/// a Soniox key exists. A chosen engine without a readable key is never
/// replaced by the other: Start names its key and opens Keys & models.
// WHY: .project-docs/decisions/2026-11-28-subtitle-engine-choice.md
// WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-engine.md
// WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
enum SubtitleAudioTranslate {
    enum Engine: String, CaseIterable, Equatable, Sendable {
        case soniox, openAI

        var account: ProviderAccount { self == .soniox ? .soniox : .openAI }
        var keychainAccount: String {
            self == .soniox ? BYOKKeyStore.account(for: .soniox) : ProviderAccount.openAIKeychainAccount
        }
        var model: String { self == .soniox ? SonioxRealtimeTranslateAdapter.model : OpenAIRealtimeTranslateAdapter.model }
        var providerName: String { self == .soniox ? "Soniox" : "OpenAI" }
        /// The Models row's label.
        var label: String { "\(providerName) · \(model)" }
    }

    /// The OpenAI engine's model, kept for Costs and older callers.
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
        /// No choice and neither key.
        case missingKey
        /// The chosen engine has no key; the other one is not used instead.
        case chosenKeyMissing(Engine)
        /// The engine's key exists but the Keychain refused to give it.
        case unreadableKey(Engine)
    }

    /// A session that failed to open, with the provider its message names.
    struct EngineFailure: Error, Equatable {
        let failure: SpeechTranslationFailure
        let provider: String
    }

    /// The saved engine. Absent until the user picks one in Keys & models
    /// (or through app control), or Subtitles first open without a choice.
    struct Choice {
        static let defaultsKey = "sidekey.translation.subtitleEngine"
        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) { self.defaults = defaults }

        /// An unknown stored value (a newer build's engine) reads as no choice
        /// and is left in place.
        var saved: Engine? {
            get { defaults.string(forKey: Self.defaultsKey).flatMap(Engine.init(rawValue:)) }
            nonmutating set {
                if let newValue { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) }
                else { defaults.removeObject(forKey: Self.defaultsKey) }
            }
        }
    }

    /// Opens the engine the saved choice (or the default) names, metered for
    /// Costs. A default that opened is saved, so a key added later never
    /// moves Subtitles audio to another provider.
    static func open(source: String?, target: String,
                     keys: ProviderKeyStore = ProviderKeyStore(),
                     choice: Choice = Choice()) async throws -> SpeechTranslationSession {
        let saved = choice.saved
        let (engine, key) = try engineAndKey(saved: saved, from: keys)
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
        pinDefault(engine, savedAtStart: saved, choice: choice)
        let context = AIUsageContext(feature: .subtitlesAudio, account: engine.account, model: engine.model)
        return AIUsageMeteredSpeechTranslation(session: session, context: context)
    }

    /// Saves the default an opened session used, unless the user chose
    /// meanwhile or a value (even a newer build's) is already stored.
    static func pinDefault(_ engine: Engine, savedAtStart: Engine?, choice: Choice) {
        guard savedAtStart == nil, choice.defaults.object(forKey: Choice.defaultsKey) == nil else { return }
        choice.saved = engine
    }

    /// The engine Subtitles are meant to use, whether or not its key works:
    /// the saved choice; without one OpenAI, unless only a Soniox key exists.
    /// An unreadable OpenAI key still means OpenAI, so a Keychain hiccup never
    /// sends audio to Soniox.
    static func intended(saved: Engine?, soniox: KeyState, openAI: KeyState) -> Engine? {
        if let saved { return saved }
        if openAI != .missing { return .openAI }
        if soniox != .missing { return .soniox }
        return nil
    }

    /// The engine that can run now: the intended one when its key can be read.
    static func engine(saved: Engine?, soniox: KeyState, openAI: KeyState) -> Engine? {
        guard let engine = intended(saved: saved, soniox: soniox, openAI: openAI) else { return nil }
        return (engine == .soniox ? soniox : openAI) == .present ? engine : nil
    }

    /// Why `engine` gave nothing.
    static func unavailable(saved: Engine?, soniox: KeyState, openAI: KeyState) -> Unavailable {
        guard let engine = intended(saved: saved, soniox: soniox, openAI: openAI) else { return .missingKey }
        return (engine == .soniox ? soniox : openAI) == .unreadable ? .unreadableKey(engine) : .chosenKeyMissing(engine)
    }

    /// The engine and its key for a Subtitles start, or why there is none.
    static func engineAndKey(saved: Engine?, from keys: ProviderKeyStore = ProviderKeyStore()) throws -> (Engine, String) {
        let soniox = keys.lookup(account: Engine.soniox.keychainAccount)
        let openAI = keys.lookup(account: Engine.openAI.keychainAccount)
        let sonioxState = KeyState(soniox), openAIState = KeyState(openAI)
        switch engine(saved: saved, soniox: sonioxState, openAI: openAIState) {
        case .soniox?: if case .key(let key) = soniox { return (.soniox, key) }
        case .openAI?: if case .key(let key) = openAI { return (.openAI, key) }
        case nil: break
        }
        throw unavailable(saved: saved, soniox: sonioxState, openAI: openAIState)
    }
}
