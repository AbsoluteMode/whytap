import CryptoKit
import Foundation

/// One model the user added to their own server, with what it does. A
/// server's `/v1/models` (when it has one) lists IDs only, and names differ
/// from server to server (`ut-llm`, `qwen3-asr`), so the user says what each
/// model is; only these models appear in pickers, and only for their kind.
// WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
struct ServerModel: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case llm
        case transcription

        var label: String {
            switch self {
            case .llm: return "LLM"
            case .transcription: return "Transcription"
            }
        }

        /// A transcription model serves the live socket and recorded audio
        /// (`/v1/audio/transcriptions`, batch recovery) alike.
        var uses: Set<ModelUse> {
            switch self {
            case .llm: return [.chat, .chatWithTools]
            case .transcription: return [.realtimeSTT, .asyncSTT]
            }
        }

        /// The kind a feature needs from a server; `nil` when a server cannot serve it.
        init?(_ feature: AIFeature) {
            switch feature.modelUse(on: .openAICompatible) {
            case .realtimeSTT?, .asyncSTT?: self = .transcription
            case .chat?, .chatWithTools?: self = .llm
            case .decision?, .speechTranslation?, nil: return nil
            }
        }
    }

    var name: String
    var kind: Kind
    /// The check when it was added passed. `false`: the user saved it without
    /// one (the server was down or refused), shown as Not checked.
    var checked: Bool
}

extension ServerEndpoint {
    /// The added models of `kind`, in the order they were added.
    func models(of kind: ServerModel.Kind) -> [ServerModel] {
        (models ?? []).filter { $0.kind == kind }
    }

    func hasModel(_ name: String, kind: ServerModel.Kind) -> Bool {
        (models ?? []).contains { $0.name == name && $0.kind == kind }
    }

    /// `<base>/v1/<path>` like `modelsURL`: `ws`/`wss` become `http`/`https`,
    /// a base ending in `/v1` gets the path, anything else `/v1/<path>`.
    func apiURL(_ path: String) -> URL? {
        guard var components = modelsURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        components.path = String(components.path.dropLast("models".count)) + path
        return components.url
    }
}

extension ServerEndpoint {
    /// What the server is called everywhere: its address, without scheme or
    /// path, the port kept unless it is the scheme's own. A local port that
    /// names a known server adds that name: `Ollama · localhost:11434`,
    /// `LM Studio · localhost:1234`; any other address is just itself
    /// (`vllm.company.ru`). `nil` for a base URL without a host.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    static func displayName(for baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let components = URLComponents(string: withScheme), let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        let scheme = components.scheme?.lowercased()
        let defaultPort = (scheme == "https" || scheme == "wss") ? 443 : 80
        var address = host
        if let port = components.port, port != defaultPort { address += ":\(port)" }
        switch components.port {
        case 11434?: return "Ollama · " + address
        case 1234?: return "LM Studio · " + address
        default: return address
        }
    }

    var displayName: String { Self.displayName(for: baseURL) ?? name }
}

/// Guesses a model's kind from its name, only to preselect the type when the
/// user adds a model: the user decides. Unknown names guess LLM.
enum ServerModelClassifier {
    /// Parts of a name that mark speech recognition.
    private static let speechFragments = [
        "whisper", "transcri", "parakeet", "canary", "speech-to-text", "speech2text",
        "wav2vec", "conformer", "sensevoice", "voxtral", "moonshine", "gigaam",
    ]
    /// Whole words (between `-`, `_`, `/`, `:`, `.`) with the same meaning.
    private static let speechWords: Set<String> = ["stt", "asr", "ctc", "rnnt", "tdt", "vosk"]

    static func suggestedKind(for model: String) -> ServerModel.Kind {
        let name = model.lowercased()
        let words = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if speechFragments.contains(where: name.contains) || !words.isDisjoint(with: speechWords) { return .transcription }
        return .llm
    }
}

/// What the check of a model being added found.
enum ServerModelCheckResult: Equatable, Sendable {
    case passed
    /// The server answered and refused: the message says what and where.
    case failed(String)
    /// No answer: the server is down, unreachable or too slow.
    case unreachable(String)
}

/// What a check ran against: the server's address and its key at that
/// moment (a digest, never the key). A result counts only while both are
/// still the same; a key replaced or an address synced from another Mac
/// during the check makes it stale.
// WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
struct ServerModelTarget: Equatable, Sendable {
    let account: ProviderAccount
    let baseURL: String
    let keyDigest: String?

    init(account: ProviderAccount, baseURL: String, apiKey: String?) {
        self.account = account
        self.baseURL = baseURL
        self.keyDigest = apiKey.flatMap { $0.isEmpty ? nil : SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
}

/// One finished check of one model, bound to the server state it ran
/// against. The form adds the model from it, checked or (after a refusal)
/// unchecked, only while `target` is still the server's current state.
struct ServerModelCheck: Equatable, Sendable {
    let name: String
    let kind: ServerModel.Kind
    /// `nil` when the server was removed or its key could not be read.
    let target: ServerModelTarget?
    let result: ServerModelCheckResult
    /// The server's address or key changed while the request ran: the
    /// result says nothing about the server as it is now.
    var stale = false
}

/// The key form's one operation at a time: saving or removing the key, or
/// checking a model. Each blocks the others, the form is busy while either
/// runs, and finishing one never releases the other.
struct ServerFormActivity: Equatable, Sendable {
    private(set) var savingKey = false
    private(set) var checkingModel = false

    var busy: Bool { savingKey || checkingModel }

    /// Starts a key save; `false` (nothing started) while anything runs.
    mutating func beginKeySave() -> Bool {
        guard !busy else { return false }
        savingKey = true
        return true
    }

    mutating func finishKeySave() { savingKey = false }

    /// Starts a model check; `false` (nothing started) while anything runs.
    mutating func beginModelCheck() -> Bool {
        guard !busy else { return false }
        checkingModel = true
        return true
    }

    mutating func finishModelCheck() { checkingModel = false }

    /// Remove deletes the key and the server at once; never while a save or check runs.
    var canRemove: Bool { !busy }
}

protocol ServerModelChecking: Sendable {
    func check(_ model: String, kind: ServerModel.Kind, on server: ServerEndpoint, apiKey: String?) async -> ServerModelCheckResult
}

/// One small request to the server before a model is added: a one-word chat
/// completion for an LLM, half a second of silence to
/// `/audio/transcriptions` for a transcription model. It goes only to the
/// user's server, with the server's own key, and never carries user content.
// WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
struct ServerModelChecker: ServerModelChecking {
    /// Half a second of PCM16 mono at 16 kHz, all zeros.
    static let silence = Data(count: 16_000)

    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    func check(_ model: String, kind: ServerModel.Kind, on server: ServerEndpoint, apiKey: String?) async -> ServerModelCheckResult {
        let path = kind == .llm ? "chat/completions" : "audio/transcriptions"
        guard let url = server.apiURL(path) else { return .unreachable("The server's base URL isn't a web address") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        switch kind {
        case .llm:
            let body: [String: Any] = [
                "model": model, "max_tokens": 16, "stream": false,
                "messages": [["role": "user", "content": "Reply with OK."]],
            ]
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        case .transcription:
            var form = MultipartFormBody()
            form.field("model", model)
            form.field("response_format", "json")
            form.wav(ProviderBatchTranscriber.wavFile(Self.silence))
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = form.finished()
        }

        let data: Data
        let status: Int
        do {
            let (received, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable("The server didn't answer") }
            data = received
            status = http.statusCode
        } catch let error as URLError where error.code == .timedOut {
            return .unreachable("The server didn't answer within \(Int(timeout)) s")
        } catch {
            return .unreachable("Couldn't reach the server")
        }
        return Self.interpret(status: status, data: data, kind: kind, apiKey: apiKey)
    }

    static func interpret(status: Int, data: Data, kind: ServerModel.Kind, apiKey: String?) -> ServerModelCheckResult {
        let path = kind == .llm ? "/chat/completions" : "/audio/transcriptions"
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = object.flatMap { message(in: $0, apiKey: apiKey) }.map { " (\($0))" } ?? ""
        switch status {
        case 200..<300:
            guard let object else { return .failed("Server answered on \(path), but not with JSON") }
            switch kind {
            case .llm:
                if let choices = object["choices"] as? [Any], !choices.isEmpty { return .passed }
                return .failed("Server answered on \(path) without a reply\(detail)")
            case .transcription:
                // Silence transcribes to empty text; the field itself is the answer.
                if object["text"] is String { return .passed }
                return .failed("Server answered on \(path) without a transcript\(detail)")
            }
        case 401, 403:
            return .failed("Server refused the key (HTTP \(status))")
        case 400..<500:
            let verb = kind == .llm ? "chat" : "transcribe"
            return .failed("Server answered \(status) on \(path) — this model can't \(verb) here\(detail)")
        default:
            return .failed("Server answered \(status) on \(path)\(detail)")
        }
    }

    /// The server's own error text, shortened; a key it repeats is cut out.
    private static func message(in object: [String: Any], apiKey: String?) -> String? {
        var text: String?
        if let error = object["error"] as? [String: Any] { text = error["message"] as? String }
        else if let error = object["error"] as? String { text = error }
        else if let detail = object["detail"] as? String { text = detail }
        else { text = object["message"] as? String }
        guard var text, !text.isEmpty else { return nil }
        if let apiKey, !apiKey.isEmpty { text = text.replacingOccurrences(of: apiKey, with: "…") }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 100 ? String(flat.prefix(99)) + "…" : flat
    }
}
