// Sources/Sidekey/Settings/SelfKeyPreferences.swift
import Foundation

/// Where drop transcription runs (and, for BYOK, with which provider). A
/// missing level means the user has not chosen a provider yet.
enum TranscriptionIsolationLevel: String, Codable {
    /// User's key, direct to the provider's cloud (never through Whytap).
    case yourKey
}

/// Where smart text processing runs (Drop cleanup, meeting notes, and related
/// post-transcription workflows). A missing level means none was chosen.
enum LLMIsolationLevel: String, Codable {
    /// OpenRouter direct route using the user's OpenRouter key.
    case yourKey
    /// User-hosted OpenAI-compatible `/chat/completions` endpoint, for example
    /// vLLM, LiteLLM, Ollama's OpenAI shim, or an internal gateway.
    case custom
}

/// BYOK transcription provider. `openAI` and `selfHosted` speak the OpenAI
/// Realtime transcription standard; soniox/deepgram/elevenLabs have native
/// client-direct adapters.
enum BYOKProvider: String, CaseIterable, Codable {
    case openAI
    case selfHosted
    case deepgram
    case soniox
    case elevenLabs

    /// Default realtime model for the provider (used when the user hasn't
    /// picked one yet).
    var defaultTranscriptionModel: String {
        switch self {
        case .openAI: return ModelRegistry.openAILiveModel
        case .selfHosted: return "gpt-4o-transcribe"
        case .deepgram: return "nova-3"
        case .soniox: return ModelRegistry.sonioxRealtimeModel
        case .elevenLabs: return ModelRegistry.elevenLabsRealtimeModel
        }
    }

    /// Realtime models offered in the Models UI picker for this provider.
    /// `selfHosted` is free-text (the user types any OpenAI-compatible model),
    /// so it has no fixed list.
    var availableTranscriptionModels: [String] {
        switch self {
        case .openAI: return [ModelRegistry.openAILiveModel]
        case .selfHosted: return []
        case .deepgram: return ["nova-3"]
        case .soniox: return [ModelRegistry.sonioxRealtimeModel]
        case .elevenLabs: return [ModelRegistry.elevenLabsRealtimeModel]
        }
    }
}

/// Synchronous UserDefaults-backed config for the Models / BYOK settings.
/// Secrets (API keys) are NOT here — they live in `BYOKKeyStore` (Keychain).
@MainActor
struct SelfKeyPreferences {
    private let defaults: UserDefaults
    private let isAppleSilicon: Bool

    init(defaults: UserDefaults = .standard, isAppleSilicon: Bool = HostArchitecture.isAppleSilicon) {
        self.defaults = defaults
        self.isAppleSilicon = isAppleSilicon
    }

    private enum Key {
        static let level = "sidekey.models.transcriptionLevel"
        static let provider = "sidekey.models.byokProvider"
        static let baseURL = "sidekey.models.selfHostedBaseURL"
        static let model = "sidekey.models.selfHostedModel"
        static let modelPerProvider = "sidekey.models.byokModel"  // suffixed with ".<provider>"
        static let llmLevel = "sidekey.models.llmLevel"
        static let openRouterModel = "sidekey.models.openRouterModel"
        static let customLLMBaseURL = "sidekey.models.customLLMBaseURL"
        static let customLLMModel = "sidekey.models.customLLMModel"
    }

    static let defaultModel = "gpt-4o-transcribe"
    static let defaultOpenRouterModel = "openai/gpt-4o-mini"
    static let defaultCustomLLMModel = "local-model"

    /// `nil` = not configured: Drop opens Settings -> Keys & models instead of
    /// recording. See `storedLevel(forKey:)` for the retired Local route.
    var transcriptionLevel: TranscriptionIsolationLevel? {
        get { storedLevel(forKey: Key.level) }
        nonmutating set { setStoredLevel(newValue?.rawValue, forKey: Key.level) }
    }

    /// The old Models tab's provider. A stored OpenAI choice stays OpenAI (it
    /// was read as Soniox while OpenAI was not offered, which moved audio to
    /// a provider the user never chose); nothing stored reads as Soniox.
    /// WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
    var selectedProvider: BYOKProvider {
        get { defaults.string(forKey: Key.provider).flatMap(BYOKProvider.init) ?? .soniox }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.provider) }
    }

    var selfHostedBaseURL: String? {
        get { defaults.string(forKey: Key.baseURL) }
        nonmutating set {
            if let v = newValue, !v.isEmpty { defaults.set(v, forKey: Key.baseURL) }
            else { defaults.removeObject(forKey: Key.baseURL) }
        }
    }

    var selfHostedModel: String {
        get { defaults.string(forKey: Key.model) ?? Self.defaultModel }
        nonmutating set { defaults.set(newValue, forKey: Key.model) }
    }

    /// Per-provider selected transcription model. `selfHosted` is stored in the
    /// existing `selfHostedModel` field (free-text); every other provider gets a
    /// dedicated key, defaulting to the provider's `defaultTranscriptionModel`.
    func transcriptionModel(for provider: BYOKProvider) -> String {
        if provider == .selfHosted { return selfHostedModel }
        return defaults.string(forKey: "\(Key.modelPerProvider).\(provider.rawValue)") ?? provider.defaultTranscriptionModel
    }

    nonmutating func setTranscriptionModel(_ model: String, for provider: BYOKProvider) {
        if provider == .selfHosted { selfHostedModel = model; return }
        defaults.set(model, forKey: "\(Key.modelPerProvider).\(provider.rawValue)")
    }

    /// `nil` = not configured: Drop cleanup returns the no-LLM output and
    /// meeting notes wait for a provider. See `storedLevel(forKey:)`.
    var llmLevel: LLMIsolationLevel? {
        get { storedLevel(forKey: Key.llmLevel) }
        nonmutating set { setStoredLevel(newValue?.rawValue, forKey: Key.llmLevel) }
    }

    var openRouterModel: String {
        get { defaults.string(forKey: Key.openRouterModel) ?? Self.defaultOpenRouterModel }
        nonmutating set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? Self.defaultOpenRouterModel : trimmed, forKey: Key.openRouterModel)
        }
    }

    var customLLMBaseURL: String? {
        get { defaults.string(forKey: Key.customLLMBaseURL) }
        nonmutating set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty { defaults.removeObject(forKey: Key.customLLMBaseURL) }
            else { defaults.set(trimmed, forKey: Key.customLLMBaseURL) }
        }
    }

    var customLLMModel: String {
        get { defaults.string(forKey: Key.customLLMModel) ?? Self.defaultCustomLLMModel }
        nonmutating set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? Self.defaultCustomLLMModel : trimmed, forKey: Key.customLLMModel)
        }
    }

    /// On-device models were removed. Their audio and text never left this
    /// Mac, so a stored `local` level, and no level on Apple Silicon (where
    /// Local was the default), stay unconfigured until the user chooses a
    /// provider, even when a provider key is already stored. Intel always
    /// defaulted to the user's key and keeps that default. A value this build
    /// no longer knows (the retired cloud level) reads like no stored level.
    /// WHY: .project-docs/decisions/2026-10-18-remove-local-models.md
    private func storedLevel<Level: RawRepresentable>(forKey key: String) -> Level?
    where Level.RawValue == String {
        let stored = defaults.string(forKey: key)
        if stored == Self.retiredLocalLevel { return nil }
        if let level = stored.flatMap(Level.init(rawValue:)) { return level }
        return isAppleSilicon ? nil : Level(rawValue: "yourKey")
    }

    /// Assigning `nil` removes the stored choice, which then reads as the
    /// hardware default above (the user's key on Intel), not as "not
    /// configured". Settings never assigns `nil`.
    private func setStoredLevel(_ rawValue: String?, forKey key: String) {
        if let rawValue { defaults.set(rawValue, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private static let retiredLocalLevel = "local"

    static let shared = SelfKeyPreferences()
}
