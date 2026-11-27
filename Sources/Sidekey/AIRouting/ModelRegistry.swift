import Foundation

/// Models the app picks itself, because they are not a user choice: the
/// recorded-audio model of a provider whose real-time route names a streaming
/// model. Anything the user picks lives in a `FeatureRoute`.
enum ModelRegistry {
    /// Catalog capability metadata only; the separate Decision route is retired.
    static let openAIDecisionModel = "gpt-6-luna"

    /// Soniox async (file) transcription, the batch counterpart of `stt-rt-*`.
    /// The same model `SonioxFileAPI` and the meeting transcriber send.
    static let sonioxRecordedModel = "stt-async-v6"
    /// Soniox v6 replaced v5 (deprecated, removed by Soniox on 2026-12-15).
    // WHY: .project-docs/decisions/2026-11-20-speech-model-lists.md
    static let sonioxRealtimeModel = "stt-rt-v6"
    static let sonioxRetiredRealtimeModel = "stt-rt-v5"
    static let sonioxRetiredRecordedModel = "stt-async-v5"
    /// ElevenLabs Scribe v3 for recorded audio; the streaming model is not
    /// accepted by the speech-to-text endpoint.
    static let elevenLabsRecordedModel = "scribe_v3"
    /// ElevenLabs Scribe v3 Live, the streaming model. It replaced
    /// `scribe_v2_realtime` (`elevenLabsRetiredRealtimeModel`) on the owner's
    /// decision; saved routes are moved by `AIRoutingStore`.
    // WHY: .project-docs/decisions/2026-11-20-elevenlabs-scribe-v3.md
    static let elevenLabsRealtimeModel = "scribe_v3_live"
    static let elevenLabsRetiredRealtimeModel = "scribe_v2_realtime"

    /// The model a finished meeting is sent with on ElevenLabs: a streaming
    /// model (which the speech-to-text endpoint refuses) maps to Scribe v3,
    /// any other picked model is kept.
    // WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
    static func elevenLabsRecordedModel(for model: String) -> String {
        model == elevenLabsRetiredRealtimeModel || model.hasSuffix("_live") || model.hasSuffix("_realtime")
            ? elevenLabsRecordedModel : model
    }
    /// OpenAI speech, on the shared OpenAI key: two models. `gpt-live-transcribe`
    /// streams words while the user speaks (live dictation, the island);
    /// recorded audio (Drop's batch rung and Retry) goes to
    /// `/v1/audio/transcriptions` with `gpt-transcribe`. Pickers offer nothing
    /// else; a route saved on another OpenAI transcription model moves to
    /// these by role (`AIRoutingStore.narrowOpenAISpeechModelsIfNeeded`).
    // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
    static let openAILiveModel = "gpt-live-transcribe"
    static let openAIRecordedModel = "gpt-transcribe"
    /// Streams within a turn like the live model; no longer offered.
    static let openAIRealtimeWhisperModel = "gpt-realtime-whisper"
    /// OpenAI transcription models no longer offered: `gpt-realtime-whisper`
    /// and the deprecated ones (OpenAI shuts them down on 2027-02-26).
    static let openAIRetiredSpeechModels = [
        openAIRealtimeWhisperModel, "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1",
    ]

    /// The model a saved OpenAI speech route moves to, or `nil` when it stays:
    /// a retired transcription model (or a dated snapshot of one) becomes
    /// `gpt-live-transcribe` on a live feature and `gpt-transcribe` on a
    /// recorded one; `gpt-transcribe` on a live feature becomes the live model.
    /// Anything else (the live model, a text model) is left alone.
    static func openAISpeechReplacement(for model: String, mode: AIFeatureMode) -> String? {
        let target: String
        switch mode {
        case .realtime: target = openAILiveModel
        case .recorded: target = openAIRecordedModel
        case .llm, .decision: return nil
        }
        let retired = openAIRetiredSpeechModels.contains { model == $0 || model.hasPrefix($0 + "-") }
        let otherRole = mode == .realtime
            && (model == openAIRecordedModel || model.hasPrefix(openAIRecordedModel + "-"))
        return retired || otherRole ? target : nil
    }

    /// Whether an OpenAI transcription model streams text within one turn
    /// (one commit when the take ends). The others need server VAD turns.
    static func openAIStreamsWithinTurn(_ model: String) -> Bool {
        model.hasPrefix(openAILiveModel) || model.hasPrefix(openAIRealtimeWhisperModel)
    }

    /// OpenAI's published transcription prices, USD per audio minute
    /// (developers.openai.com/api/docs/pricing, checked 2026-11-22). Costs
    /// marks them ≈; an unknown model has no price, never zero.
    static func openAISpeechUSDPerMinute(_ model: String) -> Double? {
        switch model {
        case openAILiveModel, openAIRealtimeWhisperModel: return 0.017
        case openAIRecordedModel: return 0.0045
        case "gpt-4o-transcribe", "whisper-1": return 0.006
        case "gpt-4o-mini-transcribe": return 0.003
        default: return nil
        }
    }

    /// A speech model's published pay-as-you-go list price in USD per audio
    /// minute, for the model pickers, or `nil` when no price is known (a
    /// user's server, On this Mac, any model not listed here): never a guess
    /// or a zero. `startingAt` marks a base price that grows with options the
    /// provider bills extra (Deepgram's multilingual Nova-3 and keyterms;
    /// ElevenLabs keyterms). Checked 2026-11-22 against
    /// https://soniox.com/pricing (about $0.12/h real-time, $0.10/h async),
    /// https://deepgram.com/pricing (Nova-3 monolingual pay-as-you-go,
    /// $0.0048/min streaming promo price, $0.0043/min pre-recorded) and
    /// https://elevenlabs.io/pricing/api (Scribe v3 $0.20/h, v3 Live $0.22/h).
    // WHY: .project-docs/decisions/2026-11-22-speech-model-prices.md
    static func speechListPrice(_ model: String, kind: AIProviderKind, use: ModelUse) -> SpeechListPrice? {
        switch (kind, use) {
        case (.openAI, .realtimeSTT), (.openAI, .asyncSTT):
            return openAISpeechUSDPerMinute(model).map { SpeechListPrice(usdPerMinute: $0) }
        case (.soniox, .realtimeSTT), (.soniox, .asyncSTT):
            switch model {
            case sonioxRealtimeModel, sonioxRetiredRealtimeModel: return SpeechListPrice(usdPerMinute: 0.12 / 60)
            case sonioxRecordedModel, sonioxRetiredRecordedModel: return SpeechListPrice(usdPerMinute: 0.10 / 60)
            default: return nil
            }
        case (.deepgram, .realtimeSTT), (.deepgram, .asyncSTT):
            guard model == "nova-3" else { return nil }
            return SpeechListPrice(usdPerMinute: use == .realtimeSTT ? 0.0048 : 0.0043, startingAt: true)
        case (.elevenLabs, .realtimeSTT), (.elevenLabs, .asyncSTT):
            switch model {
            case elevenLabsRealtimeModel, elevenLabsRetiredRealtimeModel:
                return SpeechListPrice(usdPerMinute: 0.22 / 60, startingAt: true)
            case elevenLabsRecordedModel, "scribe_v2":
                return SpeechListPrice(usdPerMinute: 0.20 / 60, startingAt: true)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The speech model the On this Mac provider downloads and runs.
    static let onDeviceSpeechModel = OnDeviceSpeechModel.parakeetTdtV3.rawValue
    /// The agent's model on Anthropic's own API.
    static let anthropicAgentModel = "claude-sonnet-5-5"
}

/// A model the app ships knowledge about: what it is for, and whether the
/// provider can label speakers with it. "Verified" means the app's adapters
/// are written and checked against this model.
/// A list price per audio minute (`ModelRegistry.speechListPrice`).
struct SpeechListPrice: Equatable, Sendable {
    let usdPerMinute: Double
    var startingAt = false
}

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
        // https://docs.soniox.com/stt/models#november-3-2026
        case (.soniox, "stt-rt-v6"), (.soniox, "stt-async-v6"): day = "2026-11-03"
        // https://soniox.com/docs/stt/models#june-16-2026
        case (.soniox, "stt-rt-v5"): day = "2026-06-16"
        // https://soniox.com/docs/stt/models#june-11-2026
        case (.soniox, "stt-async-v5"): day = "2026-06-11"
        // https://elevenlabs.io/blog/introducing-scribe-v2-realtime
        case (.elevenLabs, "scribe_v2_realtime"): day = "2025-11-11"
        // https://elevenlabs.io/blog/introducing-scribe-v2
        case (.elevenLabs, "scribe_v2"): day = "2026-01-09"
        // https://elevenlabs.io/blog/scribe-v3
        case (.elevenLabs, "scribe_v3_live"), (.elevenLabs, "scribe_v3"): day = "2026-11-10"
        default: return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: day)
    }

    static let models: [RegistryModel] = [
        RegistryModel(kind: .soniox, id: sonioxRealtimeModel, uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .soniox, id: sonioxRecordedModel, uses: [.asyncSTT], diarization: true),
        RegistryModel(kind: .deepgram, id: "nova-3", uses: [.realtimeSTT, .asyncSTT], diarization: true),
        RegistryModel(kind: .elevenLabs, id: elevenLabsRealtimeModel, uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .elevenLabs, id: elevenLabsRecordedModel, uses: [.asyncSTT], diarization: true),
        RegistryModel(kind: .onDevice, id: onDeviceSpeechModel, uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .openAI, id: openAILiveModel, uses: [.realtimeSTT], diarization: false),
        RegistryModel(kind: .openAI, id: openAIRecordedModel, uses: [.asyncSTT], diarization: false),
        RegistryModel(kind: .openAI, id: OpenAIRealtimeTranslateAdapter.model, uses: [.speechTranslation], diarization: false),
        RegistryModel(kind: .openRouter, id: "google/gemini-3.8-flash", uses: [.chat], diarization: false),
        RegistryModel(kind: .openRouter, id: "anthropic/claude-sonnet-5.5", uses: [.chat], diarization: false),
    ]

    /// Smallest context window a model needs for Meeting notes (N) and for the
    /// Agent (M), in tokens. Smaller ones get a warning, not a ban.
    static let meetingNotesMinContext = 64_000
    static let agentMinContext = 64_000

    /// Deepgram's catalog lists dozens of domain, language and legacy rows
    /// (medical, pharma, Nova-2, enhanced, base) next to the one model people
    /// want, and Soniox keeps deprecated versions listed. Their pickers offer
    /// only the built-in models (Nova-3; Soniox v6 live and recorded); a route
    /// already saved on another model keeps it.
    // WHY: .project-docs/decisions/2026-11-20-speech-model-lists.md
    /// OpenAI speech offers its two models (`gpt-live-transcribe`,
    /// `gpt-transcribe`), not every transcription model its catalog lists.
    // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
    static func offersOnlyBuiltInModels(_ kind: AIProviderKind, use: ModelUse) -> Bool {
        switch kind {
        case .deepgram, .soniox: return true
        case .openAI: return use == .realtimeSTT || use == .asyncSTT
        case .elevenLabs, .openRouter, .anthropic, .openAICompatible, .onDevice: return false
        }
    }

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
            case .retiredMeetingText, .retiredMeetingAudio: return nil
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .subtitlesAudio: return sonioxRealtimeModel
            case .meetings: return sonioxRecordedModel
            case .dropSmartCleanup, .dropSmartDecision, .meetingNotes, .translation, .subtitlesTranslation, .agent: return nil
            }
        case .deepgram:
            switch feature {
            case .retiredMeetingText, .retiredMeetingAudio: return nil
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .subtitlesAudio, .meetings: return "nova-3"
            case .dropSmartCleanup, .dropSmartDecision, .meetingNotes, .translation, .subtitlesTranslation, .agent: return nil
            }
        case .elevenLabs:
            switch feature {
            case .retiredMeetingText, .retiredMeetingAudio: return nil
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch, .subtitlesAudio: return elevenLabsRealtimeModel
            case .meetings: return elevenLabsRecordedModel
            case .dropSmartCleanup, .dropSmartDecision, .meetingNotes, .translation, .subtitlesTranslation, .agent: return nil
            }
        case .openRouter:
            switch feature {
            case .retiredMeetingText, .retiredMeetingAudio: return nil
            case .dropSmartDecision: return nil
            case .dropSmartCleanup, .meetingNotes, .translation, .subtitlesTranslation: return "google/gemini-3.8-flash"
            case .agent: return "anthropic/claude-sonnet-5.5"
            case .dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch, .subtitlesAudio: return nil
            }
        case .anthropic:
            switch feature {
            case .retiredMeetingText, .retiredMeetingAudio: return nil
            case .dropSmartDecision: return nil
            case .agent: return anthropicAgentModel
            case .dropSmartCleanup, .meetingNotes, .translation, .subtitlesTranslation: return anthropicAgentModel
            case .dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch, .subtitlesAudio: return nil
            }
        case .openAI:
            switch feature {
            // Live speech: the streaming model. Meetings have no OpenAI model
            // (no speaker labels; a long recording exceeds the 25 MB file limit).
            case .dropFast, .dropSmart, .agentVoice, .voiceSearch: return openAILiveModel
            // Text models: the authenticated live catalog is the source of IDs.
            case .retiredMeetingText, .retiredMeetingAudio, .meetings, .subtitlesAudio,
                 .dropSmartCleanup, .dropSmartDecision, .meetingNotes, .translation, .subtitlesTranslation, .agent:
                return nil
            }
        case .openAICompatible:
            return nil
        case .onDevice:
            return feature.modelUse(on: .onDevice) == nil ? nil : onDeviceSpeechModel
        }
    }

    /// Bumped when an adapter changes in a way that makes an earlier "checked
    /// when picked" result stale. A stored check counts only for the adapter
    /// version that made it. Every adapter is at 1 for now.
    static func adapterVersion(_ kind: AIProviderKind, _ use: ModelUse) -> Int { 1 }

    /// Why the app cannot run a model it can see in a catalog, or `nil`.
    static func knownUnsupportedReason(_ id: String, kind: AIProviderKind, use: ModelUse) -> String? {
        if use == .decision {
            return "separate Decision processing is retired"
        }
        if kind == .openRouter, id.hasPrefix("typesafe/jev-"), id != "typesafe/jev-router" {
            return "decision model, does not generate text"
        }
        switch kind {
        case .deepgram:
            return id.hasPrefix("flux-") ? "needs Deepgram's v2 streaming API" : nil
        case .soniox, .elevenLabs, .openRouter, .openAI, .anthropic, .openAICompatible, .onDevice:
            return nil
        }
    }
}
