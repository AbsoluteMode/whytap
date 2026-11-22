import Foundation

/// Which of a user's server's models the pickers offer, and for what. A
/// server's `/v1/models` lists IDs only, without saying what each model does,
/// so by default the model's name decides; the user can override that per
/// server in API keys. Stored by raw value in the routing document, so raw
/// values must not change.
// WHY: .project-docs/decisions/2026-11-22-server-model-kinds.md
enum ServerModelKinds: String, Codable, CaseIterable, Sendable {
    /// By model name (`ServerModelClassifier`): speech models in speech
    /// pickers, language models in text pickers, embeddings, rerankers and
    /// voices in neither.
    case automatic
    /// Every model is a language model.
    case language
    /// Every model recognizes speech.
    case speech
    /// Every model is offered for both, as before this choice existed.
    case both

    var label: String {
        switch self {
        case .automatic: return "By model name"
        case .language: return "Language models"
        case .speech: return "Speech recognition"
        case .both: return "Both"
        }
    }

    /// What `model` on a server with this choice serves. `nil`: anything
    /// (the catalog's own "the provider does not say").
    func uses(of model: String) -> Set<ModelUse>? {
        switch self {
        case .automatic: return ServerModelClassifier.uses(of: model)
        case .language: return ServerModelClassifier.languageUses
        case .speech: return ServerModelClassifier.speechUses
        case .both: return nil
        }
    }
}

/// Sorts a server's model into speech, language or neither by its ID alone.
/// Names are what self-hosted servers share: Ollama tags (`qwen3:0.6b`),
/// Hugging Face repos (`Systran/faster-whisper-large-v3`), gateway aliases
/// (`whisper-1`). A name this does not recognize is a language model, the
/// common case on such servers; the per-server choice corrects a wrong guess.
enum ServerModelClassifier {
    enum Kind: Equatable, Sendable {
        case speech
        case language
        /// Embeddings, rerankers, voices, images: no feature uses them.
        case other
    }

    /// A server's speech model serves the live socket and recorded audio
    /// (`/v1/audio/transcriptions`, batch recovery) alike.
    static let speechUses: Set<ModelUse> = [.realtimeSTT, .asyncSTT]
    static let languageUses: Set<ModelUse> = [.chat, .chatWithTools]

    /// Parts of a name that mark a model no feature can use.
    private static let otherFragments = [
        "embed", "rerank", "text-to-speech", "diffusion", "dall-e", "moderation",
    ]
    /// Whole words (between `-`, `_`, `/`, `:`, `.`) with the same meaning.
    private static let otherWords: Set<String> = [
        "tts", "xtts", "kokoro", "piper", "bark", "bge", "gte", "minilm", "clip", "sdxl", "e5",
    ]
    /// Parts of a name that mark speech recognition.
    private static let speechFragments = [
        "whisper", "transcri", "parakeet", "canary", "speech-to-text", "speech2text",
        "wav2vec", "conformer", "sensevoice", "voxtral", "moonshine", "gigaam",
    ]
    private static let speechWords: Set<String> = ["stt", "asr", "ctc", "rnnt", "tdt", "vosk"]

    static func kind(of model: String) -> Kind {
        let name = model.lowercased()
        let words = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if otherFragments.contains(where: name.contains) || !words.isDisjoint(with: otherWords) { return .other }
        if speechFragments.contains(where: name.contains) || !words.isDisjoint(with: speechWords) { return .speech }
        return .language
    }

    static func uses(of model: String) -> Set<ModelUse> {
        switch kind(of: model) {
        case .speech: return speechUses
        case .language: return languageUses
        case .other: return []
        }
    }
}
