// Sources/Sidekey/Settings/SelfKeyPreferences.swift
import Foundation

/// Where drop transcription runs (and, for BYOK, with which provider).
enum TranscriptionIsolationLevel: String, CaseIterable, Codable {
    /// User's key, direct to the provider's cloud (never through Whytap).
    case yourKey
    /// On-device FluidAudio Parakeet model (Apple Silicon only).
    case local

    /// Level a fresh install (or a stored value this build no longer knows)
    /// resolves to: on-device on Apple Silicon, BYOK everywhere else.
    static func defaultLevel(isAppleSilicon: Bool = LocalModelSupport.isAppleSilicon) -> TranscriptionIsolationLevel {
        isAppleSilicon ? .local : .yourKey
    }
}

/// Where smart text processing runs (Drop cleanup, meeting notes, and related
/// post-transcription workflows).
enum LLMIsolationLevel: String, CaseIterable, Codable {
    /// OpenRouter direct route using the user's OpenRouter key.
    case yourKey
    /// User-hosted OpenAI-compatible `/chat/completions` endpoint, for example
    /// vLLM, LiteLLM, Ollama's OpenAI shim, or an internal gateway.
    case custom
    /// On-device MLX model (Apple Silicon only). Cleanup and meeting notes run
    /// locally after a one-time download; nothing leaves the device.
    case local

    /// Level a fresh install (or a stored value this build no longer knows)
    /// resolves to: on-device on Apple Silicon, OpenRouter BYOK everywhere else.
    static func defaultLevel(isAppleSilicon: Bool = LocalModelSupport.isAppleSilicon) -> LLMIsolationLevel {
        isAppleSilicon ? .local : .yourKey
    }
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
        case .openAI, .selfHosted: return "gpt-4o-transcribe"
        case .deepgram: return "nova-3"
        case .soniox: return "stt-rt-v5"
        case .elevenLabs: return "scribe_v2_realtime"
        }
    }

    /// Realtime models offered in the Models UI picker for this provider.
    /// `selfHosted` is free-text (the user types any OpenAI-compatible model),
    /// so it has no fixed list.
    var availableTranscriptionModels: [String] {
        switch self {
        case .openAI: return ["gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
        case .selfHosted: return []
        case .deepgram: return ["nova-3"]
        case .soniox: return ["stt-rt-v5"]
        case .elevenLabs: return ["scribe_v2_realtime"]
        }
    }

    /// Providers offered in the BYOK picker. OpenAI is excluded: its realtime
    /// transcription doesn't stream partials, so offering it for BYOK would be
    /// a dead end for long holds. The `.openAI` case stays for decoding any
    /// legacy stored value. WHY: docs/decisions/2026-06-23-byok-models-ui-cleanup.md
    static var selectable: [BYOKProvider] { allCases.filter { $0 != .openAI } }
}

/// Synchronous UserDefaults-backed config for the Models / BYOK settings.
/// Secrets (API keys) are NOT here — they live in `BYOKKeyStore` (Keychain).
@MainActor
struct SelfKeyPreferences {
    private let defaults: UserDefaults
    private let isAppleSilicon: Bool

    init(defaults: UserDefaults = .standard, isAppleSilicon: Bool = LocalModelSupport.isAppleSilicon) {
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

    /// A stored value this build no longer offers (older installs persisted a
    /// cloud level) decodes to `defaultLevel` instead of failing.
    var transcriptionLevel: TranscriptionIsolationLevel {
        get {
            defaults.string(forKey: Key.level).flatMap(TranscriptionIsolationLevel.init)
                ?? TranscriptionIsolationLevel.defaultLevel(isAppleSilicon: isAppleSilicon)
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.level) }
    }

    var selectedProvider: BYOKProvider {
        // OpenAI is no longer offered for BYOK; resolve a legacy/default OpenAI
        // selection to soniox so it's gone from the UI AND the runtime path.
        get {
            let stored = defaults.string(forKey: Key.provider).flatMap(BYOKProvider.init) ?? .soniox
            return BYOKProvider.selectable.contains(stored) ? stored : .soniox
        }
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

    /// A stored value this build no longer offers (older installs persisted a
    /// cloud level) decodes to `defaultLevel` instead of failing.
    var llmLevel: LLMIsolationLevel {
        get {
            defaults.string(forKey: Key.llmLevel).flatMap(LLMIsolationLevel.init)
                ?? LLMIsolationLevel.defaultLevel(isAppleSilicon: isAppleSilicon)
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.llmLevel) }
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

    static let shared = SelfKeyPreferences()
}
