import Foundation

/// Models the app picks itself, because they are not a user choice: the
/// recorded-audio model of a provider whose real-time route names a streaming
/// model. Anything the user picks lives in a `FeatureRoute`.
enum ModelRegistry {
    /// Decision models calibrated for the Meeting Assistant detector; a user's
    /// explicit choice lives in FeatureRoute.
    static let meetingDetectorModel = "typesafe/jev-1.14"
    static let openAIDecisionModel = "gpt-6-luna"

    /// Soniox async (file) transcription, the batch counterpart of `stt-rt-*`.
    /// The same model `SonioxFileAPI` and the meeting transcriber send.
    static let sonioxRecordedModel = "stt-async-v5"
    /// ElevenLabs Scribe v2 for recorded audio; `scribe_v2_realtime` is the
    /// streaming model and is not accepted by the speech-to-text endpoint.
    static let elevenLabsRecordedModel = "scribe_v2"
    /// The agent's model on Anthropic's own API.
    static let anthropicAgentModel = "claude-sonnet-5-5"
}

/// A model the app ships knowledge about: what it is for, and whether the
/// provider can label speakers with it. "Verified" means the app's adapters
/// are written and checked against this model.
struct RegistryModel: Equatable, Sendable {
    let kind: AIProviderKind
    let id: String
    let uses: Set<ModelUse>
    let diarization: Bool
}

extension ModelRegistry {
    /// Speech catalogs without release timestamps use only exact model IDs
    /// whose launch dates were checked against the provider's announcement.
    /// New/unknown IDs never inherit a date from a name, alias or model family.
    static func documentedReleaseDate(for id: String, kind: AIProviderKind) -> Date? {
        let day: String
        switch (kind, id) {
        // https://soniox.com/docs/stt/models#june-16-2026
        case (.soniox, "stt-rt-v5"): day = "2026-06-16"
        // https://soniox.com/docs/stt/models#june-11-2026
        case (.soniox, "stt-async-v5"): day = "2026-06-11"
        // https://elevenlabs.io/blog/introducing-scribe-v2-realtime
        case (.elevenLabs, "scribe_v2_realtime"): day = "2025-11-11"
        // https://elevenlabs.io/blog/introducing-scribe-v2
        case (.elevenLabs, "scribe_v2"): day = "2026-01-09"
        default: return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: day)
    }

    static let models: [RegistryModel] = [
        RegistryModel(kind: .openRouter, id: meetingDetectorModel, uses: [.decision], diarization: false),
        RegistryModel(kind: .openAI, id: openAIDecisionModel, uses: [.decision], diarization: false),
        RegistryModel(kind: .soniox, id: "stt-rt-v5", uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .soniox, id: sonioxRecordedModel, uses: [.asyncSTT], diarization: true),
        RegistryModel(kind: .deepgram, id: "nova-3", uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .elevenLabs, id: "scribe_v2_realtime", uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .elevenLabs, id: elevenLabsRecordedModel, uses: [.asyncSTT], diarization: false),
        RegistryModel(kind: .openRouter, id: "google/gemini-3.8-flash", uses: [.chat], diarization: false),
        RegistryModel(kind: .openRouter, id: "anthropic/claude-sonnet-5.5", uses: [.chat, .chatWithTools], diarization: false),
        RegistryModel(kind: .anthropic, id: anthropicAgentModel, uses: [.chatWithTools], diarization: false),
    ]

    /// Smallest context window a model needs for Meeting notes (N) and for the
    /// Agent (M), in tokens. Smaller ones get a warning, not a ban.
    static let meetingNotesMinContext = 64_000
    static let agentMinContext = 64_000

    /// True when the app ships this model for this use.
    static func isVerified(_ id: String, kind: AIProviderKind, use: ModelUse) -> Bool {
        models.contains { $0.kind == kind && $0.id == id && $0.uses.contains(use) }
    }

    /// The model offered first for a feature on a provider, or `nil` when the
    /// provider does not serve the feature or has no model the app chooses
    /// (a user's own server). Exhaustive on purpose: a new provider kind has
    /// to decide its cells here.
    static func recommended(for feature: AIFeature, kind: AIProviderKind) -> String? {
        switch kind {
        case .soniox:
            switch feature {
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .subtitlesAudio, .meetingAssistantAudio: return "stt-rt-v5"
            case .meetings: return sonioxRecordedModel
            case .dropSmartCleanup, .dropSmartDecision, .meetingNotes, .translation, .subtitlesTranslation, .agent, .meetingAssistant, .meetingAssistantDetector: return nil
            }
        case .deepgram:
            switch feature {
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .subtitlesAudio, .meetingAssistantAudio, .meetings: return "nova-3"
            case .dropSmartCleanup, .dropSmartDecision, .meetingNotes, .translation, .subtitlesTranslation, .agent, .meetingAssistant, .meetingAssistantDetector: return nil
            }
        case .elevenLabs:
            switch feature {
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .subtitlesAudio, .meetingAssistantAudio, .meetings: return "scribe_v2_realtime"
            case .dropSmartCleanup, .dropSmartDecision, .meetingNotes, .translation, .subtitlesTranslation, .agent, .meetingAssistant, .meetingAssistantDetector: return nil
            }
        case .openRouter:
            switch feature {
            case .dropSmartDecision: return nil
            case .meetingAssistantDetector: return meetingDetectorModel
            case .dropSmartCleanup, .meetingNotes, .translation, .subtitlesTranslation: return "google/gemini-3.8-flash"
            case .agent, .meetingAssistant: return "anthropic/claude-sonnet-5.5"
            case .dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch, .subtitlesAudio, .meetingAssistantAudio: return nil
            }
        case .anthropic:
            switch feature {
            case .dropSmartDecision, .meetingAssistantDetector: return nil
            case .agent, .meetingAssistant: return anthropicAgentModel
            case .dropSmartCleanup, .meetingNotes, .translation, .subtitlesTranslation: return anthropicAgentModel
            case .dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch, .subtitlesAudio, .meetingAssistantAudio: return nil
            }
        case .openAI:
            // The authenticated live catalog is the source of available IDs.
            return nil
        case .openAICompatible:
            return nil
        }
    }

    /// Bumped when an adapter changes in a way that makes an earlier "checked
    /// when picked" result stale. Every adapter is at 1 for now.
    static func adapterVersion(_ kind: AIProviderKind, _ use: ModelUse) -> Int {
        1
    }

    /// Why the app cannot run a model it can see in a catalog, or `nil`.
    static func knownUnsupportedReason(_ id: String, kind: AIProviderKind, use: ModelUse) -> String? {
        if use == .decision {
            // The detector threshold was measured for these models only.
            // WHY: docs/decisions/2026-10-27-meeting-assistant-detector.md
            switch kind {
            case .openRouter: return id == meetingDetectorModel ? nil : "not a calibrated detector model"
            case .openAI: return id == openAIDecisionModel ? nil : "not a calibrated detector model"
            case .soniox, .deepgram, .elevenLabs, .anthropic, .openAICompatible: return "no decision API adapter"
            }
        }
        if kind == .openRouter, id.hasPrefix("typesafe/jev-"), id != "typesafe/jev-router" {
            return "decision model, does not generate text"
        }
        switch kind {
        case .deepgram:
            return id.hasPrefix("flux-") ? "needs Deepgram's v2 streaming API" : nil
        case .soniox, .elevenLabs, .openRouter, .openAI, .anthropic, .openAICompatible:
            return nil
        }
    }
}
