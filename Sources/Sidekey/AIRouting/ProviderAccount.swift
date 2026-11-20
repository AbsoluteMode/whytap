import Foundation

/// One credential a route can run on: a built-in provider's key, or one of the
/// user's own OpenAI-compatible servers (each server is its own account).
///
/// Persisted as a single string, `storageID`, so a stored route reads
/// `"account": "soniox"` and not a nested object.
enum ProviderAccount: Hashable, Codable, Sendable {
    case soniox
    case deepgram
    case elevenLabs
    case openRouter
    case openAI
    case anthropic
    /// The speech model downloaded to this Mac. It has no key: the model's
    /// files are its credential (`OnDeviceSpeechReadiness`).
    case thisMac
    case server(UUID)

    private static let serverPrefix = "server:"

    var kind: AIProviderKind {
        switch self {
        case .soniox: return .soniox
        case .deepgram: return .deepgram
        case .elevenLabs: return .elevenLabs
        case .openRouter: return .openRouter
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .thisMac: return .onDevice
        case .server: return .openAICompatible
        }
    }

    /// `"soniox"`, `"deepgram"`, `"elevenLabs"`, `"openRouter"`, `"anthropic"`, `"thisMac"` or
    /// `"server:<uuid, lower case>"`.
    var storageID: String {
        switch self {
        case .soniox: return "soniox"
        case .deepgram: return "deepgram"
        case .elevenLabs: return "elevenLabs"
        case .openRouter: return "openRouter"
        case .openAI: return "openAI"
        case .anthropic: return "anthropic"
        case .thisMac: return "thisMac"
        case .server(let id): return Self.serverPrefix + id.uuidString.lowercased()
        }
    }

    /// Inverse of `storageID`; `nil` for any other string.
    init?(storageID: String) {
        let parsed: ProviderAccount
        switch storageID {
        case "soniox": parsed = .soniox
        case "deepgram": parsed = .deepgram
        case "elevenLabs": parsed = .elevenLabs
        case "openRouter": parsed = .openRouter
        case "openAI": parsed = .openAI
        case "anthropic": parsed = .anthropic
        case "thisMac": parsed = .thisMac
        default:
            guard storageID.hasPrefix(Self.serverPrefix),
                  let id = UUID(uuidString: String(storageID.dropFirst(Self.serverPrefix.count)))
            else { return nil }
            parsed = .server(id)
        }
        // One account, one spelling: this turns away an upper-case UUID.
        guard parsed.storageID == storageID else { return nil }
        self = parsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let account = ProviderAccount(storageID: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown provider account")
        }
        self = account
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageID)
    }
}

/// A user's own OpenAI-compatible server (vLLM, LiteLLM, Ollama's shim, a
/// company gateway). Its API key is optional and lives in the Keychain under
/// `keyAccount`: `byok.server.<uuid, lower case>.api_key` for servers added in
/// API & Models, but the old Models-tab accounts (`byok.selfHosted.api_key`,
/// `byok.custom_llm.api_key`) for servers the migration carries over, so no
/// stored key has to move.
struct ServerEndpoint: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var baseURL: String
    let keyAccount: String
}
