import Foundation

/// Small presentation descriptor for a recording-source brand mark. Despite
/// the name (kept for source compatibility) it now covers any source the
/// Dynamic Island breathing ticker can show during a voice turn: transcription
/// providers (drop dictation), the user's agent CLI (Codex / Claude Code), and
/// Google search. The same value can render in Settings rows or in the island.
struct TranscriptionProviderBrand: Equatable, Sendable {
    let assetName: String?
    let systemName: String?
    let label: String
    /// When `true`, the breathing island mark renders the bundled asset in its
    /// native colors (loaded non-template) instead of flattening it to the
    /// monochrome white tint every other provider mark receives. Used for the
    /// on-device Qwen mark, whose blue glyph would otherwise read as a generic
    /// white blob. Settings rows already render Qwen full-color via a dedicated
    /// view; this carries the same intent into the island.
    let isFullColor: Bool

    init(assetName: String, label: String, isFullColor: Bool = false) {
        self.assetName = assetName
        self.systemName = nil
        self.label = label
        self.isFullColor = isFullColor
    }

    init(systemName: String, label: String) {
        self.assetName = nil
        self.systemName = systemName
        self.label = label
        self.isFullColor = false
    }

    static func byok(_ provider: BYOKProvider) -> TranscriptionProviderBrand {
        switch provider {
        case .openAI:
            return TranscriptionProviderBrand(assetName: "openai", label: "OpenAI")
        case .selfHosted:
            return TranscriptionProviderBrand(systemName: "server.rack", label: "Self-hosted")
        case .deepgram:
            return TranscriptionProviderBrand(assetName: "deepgram", label: "Deepgram")
        case .soniox:
            return TranscriptionProviderBrand(assetName: "soniox", label: "Soniox")
        case .elevenLabs:
            return TranscriptionProviderBrand(assetName: "elevenlabs", label: "ElevenLabs")
        }
    }

    /// Brand for the user's active agent CLI, shown in the island breathing
    /// ticker during agent voice (Right Cmd hold).
    static func agent(_ provider: CLIProviderID) -> TranscriptionProviderBrand {
        switch provider {
        case .codex:
            return TranscriptionProviderBrand(assetName: "codex", label: "Codex")
        case .claude:
            return TranscriptionProviderBrand(assetName: "claude-code", label: "Claude Code")
        }
    }

    /// Brand shown in the island breathing ticker during Google voice search
    /// (Right Option hold).
    static let google = TranscriptionProviderBrand(assetName: "google", label: "Google")

    /// Brand shown while Drop's LLM cleanup runs directly through OpenRouter.
    static let openRouter = TranscriptionProviderBrand(assetName: "openrouter", label: "OpenRouter")

    /// Brand shown while Drop's LLM cleanup runs through a custom
    /// OpenAI-compatible endpoint.
    static let customLLM = TranscriptionProviderBrand(systemName: "server.rack", label: "Custom LLM")

    /// Brand shown while Drop transcription runs fully on-device. The local
    /// stack is Qwen (Parakeet STT + on-device Qwen LLM cleanup), so the island
    /// shows the genuine Qwen mark in full color rather than a generic CPU glyph.
    static let localTranscription = TranscriptionProviderBrand(
        assetName: "qwen",
        label: "Qwen",
        isFullColor: true
    )

    @MainActor
    static func currentDrop() -> TranscriptionProviderBrand? {
        let prefs = SelfKeyPreferences.shared
        switch prefs.transcriptionLevel {
        case .yourKey:
            return byok(prefs.selectedProvider)
        case .local:
            return .localTranscription
        }
    }

    @MainActor
    static func currentDropCleanup() -> TranscriptionProviderBrand? {
        switch SelfKeyPreferences.shared.llmLevel {
        case .local:
            // On-device LLM has no cloud provider brand to surface.
            return nil
        case .yourKey:
            return .openRouter
        case .custom:
            return .customLLM
        }
    }
}
