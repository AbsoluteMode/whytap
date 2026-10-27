import Foundation

/// How a feature uses a model. Shown as a small caption next to the feature in
/// API & Models, and narrows the model list to what fits.
enum AIFeatureMode: String, Codable, Sendable {
    case realtime
    case recorded
    case llm
    case llmWithTools
    case decision

    var label: String {
        switch self {
        case .realtime: return "real-time"
        case .recorded: return "recorded"
        case .llm: return "LLM"
        case .llmWithTools: return "LLM with tools"
        case .decision: return "Decision"
        }
    }
}

/// Every place the app calls an AI model. Each feature has its own route
/// (provider account + model) in `AIRoutingStore`, stored under the raw value,
/// so raw values must not change. Declaration order is the row order in
/// API & Models.
enum AIFeature: String, CaseIterable, Codable, Sendable {
    case dropFast
    case dropSmart
    case dropSmartCleanup
    // Retained only to decode historical usage and old routing documents.
    case dropSmartDecision
    case meetings
    case meetingNotes
    case agent
    case agentVoice
    case meetingAssistant
    case meetingAssistantAudio
    /// Optional decision model that gates Meeting Assistant question extraction.
    case meetingAssistantDetector
    case voiceSearch
    case translation
    case subtitlesAudio
    case subtitlesTranslation

    var isActive: Bool { self != .dropSmartDecision }
    /// Not set is a valid choice: the feature works without this route.
    var isOptional: Bool { self == .meetingAssistantDetector }
    static var activeCases: [AIFeature] { allCases.filter(\.isActive) }

    var title: String {
        switch self {
        case .dropFast: return "Drop Fast"
        case .dropSmart: return "Drop Smart"
        case .dropSmartCleanup: return "Drop Smart cleanup"
        case .dropSmartDecision: return "Drop Smart decision"
        case .meetings: return "Meetings"
        case .meetingNotes: return "Meeting notes"
        case .agent: return "Agent"
        case .agentVoice: return "Agent voice"
        case .meetingAssistant: return "Meeting Assistant"
        case .meetingAssistantAudio: return "Meeting Assistant audio"
        case .meetingAssistantDetector: return "Meeting Assistant detector"
        case .voiceSearch: return "Voice search"
        case .translation: return "Translation"
        case .subtitlesAudio: return "Subtitles audio"
        case .subtitlesTranslation: return "Subtitles translation"
        }
    }

    var mode: AIFeatureMode {
        switch self {
        case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .subtitlesAudio, .meetingAssistantAudio: return .realtime
        case .meetings: return .recorded
        case .dropSmartCleanup, .meetingNotes, .translation, .subtitlesTranslation: return .llm
        case .agent, .meetingAssistant: return .llmWithTools
        case .dropSmartDecision, .meetingAssistantDetector: return .decision
        }
    }

    /// Fast and Smart Drop route separately: the feature for a Drop output mode.
    static func drop(_ mode: TranscriptionMode) -> AIFeature {
        switch mode {
        case .fast: return .dropFast
        case .smart: return .dropSmart
        }
    }

    /// What kind of model this feature needs from a provider of `kind`, or
    /// `nil` when that provider cannot serve it. The answer follows from the
    /// feature's mode; the switches are exhaustive on purpose, so a new
    /// provider kind or mode cannot be added without deciding every cell.
    ///
    /// Meetings are the odd one: Soniox transcribes the finished recording
    /// through its file API (async models), while Deepgram, ElevenLabs and a
    /// user's own server run the recording through their real-time adapter in
    /// chunks, so they offer real-time models (`docs/specs/api-and-models.md`,
    /// the recorded mode of meetings).
    func modelUse(on kind: AIProviderKind) -> ModelUse? {
        guard isActive else { return nil }
        switch mode {
        case .realtime:
            switch kind {
            case .soniox, .deepgram, .elevenLabs, .openAICompatible: return .realtimeSTT
            case .openRouter, .openAI, .anthropic: return nil
            }
        case .recorded:
            switch kind {
            case .soniox: return .asyncSTT
            case .deepgram, .elevenLabs, .openAICompatible: return .realtimeSTT
            case .openRouter, .openAI, .anthropic: return nil
            }
        case .llm:
            switch kind {
            case .openRouter, .openAI, .anthropic, .openAICompatible: return .chat
            case .soniox, .deepgram, .elevenLabs: return nil
            }
        case .decision:
            switch kind {
            case .openRouter, .openAI: return .decision
            case .soniox, .deepgram, .elevenLabs, .anthropic, .openAICompatible: return nil
            }
        case .llmWithTools:
            switch kind {
            case .openRouter, .openAI, .anthropic: return .chatWithTools
            case .soniox, .deepgram, .elevenLabs, .openAICompatible: return nil
            }
        }
    }
}

/// The kind of model a provider offers a feature.
enum ModelUse: String, Codable, Sendable {
    /// Streaming speech-to-text over a live connection.
    case realtimeSTT
    /// Speech-to-text of a finished recording.
    case asyncSTT
    /// Text in, text out.
    case chat
    /// Text in, text out, with tool calls (the agent).
    case chatWithTools
    /// Typed decisions and probabilities, with no generated text.
    case decision
}

/// What a provider can do. Which key it runs on is the account's business
/// (`ProviderAccount`): several user servers share the one kind.
enum AIProviderKind: String, CaseIterable, Codable, Sendable {
    case soniox
    case deepgram
    case elevenLabs
    case openRouter
    case openAI
    /// Anthropic's own Messages API and OpenCode's `anthropic` provider.
    case anthropic
    case openAICompatible

    var displayName: String {
        switch self {
        case .soniox: return "Soniox"
        case .deepgram: return "Deepgram"
        case .elevenLabs: return "ElevenLabs"
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .openAICompatible: return "OpenAI-compatible server"
        }
    }
}
