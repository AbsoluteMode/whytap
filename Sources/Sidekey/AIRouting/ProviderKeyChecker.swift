import Foundation
import os

/// Why a provider turned a key down.
enum KeyRejection: String, Codable {
    /// The provider does not know the key.
    case invalidKey
    /// The key is fine but the account has no credit left.
    case outOfCredit
}

/// What a key check found out.
enum KeyStatus: Codable, Equatable {
    case valid
    /// The key works, but not for everything (a scoped key that cannot list
    /// models, for example).
    case limited
    case rejected(KeyRejection)
    /// No answer worth trusting (offline, 5xx, an unexpected code): the caller
    /// shows a neutral state and keeps the previous status.
    case unreachable
}

/// The outcome of one check and when it ran. Never the key.
struct KeyCheckRecord: Codable, Equatable {
    var status: KeyStatus
    var checkedAt: Date
}

protocol ProviderKeyChecking: Sendable {
    /// `apiKey` is the caller's to read from the Keychain; a server without a
    /// key sends no `Authorization`. `allowPaidProbe` lets an ElevenLabs key
    /// that failed the free request prove itself with a one-second recording.
    func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus
}

/// Checks keys with each provider's free account request (see the spec,
/// "Проверка ключа"). Logs the provider, the status and the milliseconds taken.
struct ProviderKeyChecker: ProviderKeyChecking {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "key-check")

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let sonioxURL = URL(string: "https://api.soniox.com/v1/models")!
    private static let deepgramURL = URL(string: "https://api.deepgram.com/v1/projects")!
    private static let elevenLabsURL = URL(string: "https://api.elevenlabs.io/v1/user")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/key")!

    func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
        let started = ContinuousClock.now
        let outcome = await run(account, apiKey: apiKey, server: server, allowPaidProbe: allowPaidProbe)
        os_log("key check provider=%{public}@ status=%{public}@ ms=%{public}d",
               log: Self.log, type: .info,
               account.kind.rawValue, Self.label(outcome), Self.milliseconds(since: started))
        return outcome
    }

    private func run(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        switch account {
        case .soniox:
            guard let key else { return .rejected(.invalidKey) }
            let answer = await get(Self.sonioxURL, header: "Authorization", value: "Bearer \(key)")
            return Self.interpret(answer, forbidden: .limited, paymentRequired: .rejected(.outOfCredit))
        case .deepgram:
            guard let key else { return .rejected(.invalidKey) }
            let answer = await get(Self.deepgramURL, header: "Authorization", value: "Token \(key)")
            return Self.interpretDeepgram(answer)
        case .elevenLabs:
            guard let key else { return .rejected(.invalidKey) }
            let answer = await get(Self.elevenLabsURL, header: "xi-api-key", value: key)
            if case .status(403, _) = answer, allowPaidProbe {
                return await paidProbe(apiKey: key)
            }
            if case .status(401, let body) = answer, Self.elevenLabsMissingPermissions(body) {
                return .limited
            }
            return Self.interpret(answer, forbidden: .limited, paymentRequired: .rejected(.outOfCredit))
        case .openRouter:
            guard let key else { return .rejected(.invalidKey) }
            let answer = await get(Self.openRouterURL, header: "Authorization", value: "Bearer \(key)")
            // A metadata permission refusal does not establish a credit problem.
            // Proxies can also return an HTML 403; that is no key verdict at all.
            // WHY: docs/decisions/2026-10-26-openrouter-key-status.md
            if case .status(403, let body) = answer {
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let error = object["error"] as? [String: Any], error["code"] as? Int == 403
                else { return .unreachable }
                return .limited
            }
            return Self.interpret(answer, forbidden: .unreachable, paymentRequired: .rejected(.outOfCredit))
        case .anthropic:
            // The free models list. 403 is a permission or limit refusal.
            guard let key else { return .rejected(.invalidKey) }
            let answer = await get(ModelCatalogFetcher.anthropicModelsPage(after: nil),
                                   headers: ModelCatalogFetcher.anthropicHeaders(apiKey: key))
            return Self.interpret(answer, forbidden: .rejected(.outOfCredit), paymentRequired: .rejected(.outOfCredit))
        case .openAI:
            guard let key else { return .rejected(.invalidKey) }
            let answer = await get(ModelCatalogFetcher.openAIModelsURL, header: "Authorization", value: "Bearer \(key)")
            return Self.interpret(answer, forbidden: .limited, paymentRequired: .rejected(.outOfCredit))
        case .server:
            guard let url = server?.modelsURL else { return .unreachable }
            let answer = await get(url, header: key == nil ? nil : "Authorization", value: key.map { "Bearer \($0)" })
            return Self.interpretServer(answer)
        }
    }

    // MARK: - Interpretation

    private enum Answer {
        case status(Int, body: Data)
        case offline
    }

    private static func interpret(_ answer: Answer, forbidden: KeyStatus, paymentRequired: KeyStatus) -> KeyStatus {
        guard case .status(let code, _) = answer else { return .unreachable }
        switch code {
        case 200..<300: return .valid
        case 401: return .rejected(.invalidKey)
        case 402: return paymentRequired
        case 403: return forbidden
        default: return .unreachable
        }
    }

    /// A 401 that names missing permissions is a working key without the scope;
    /// any other 401 is a key Deepgram does not know.
    private static func interpretDeepgram(_ answer: Answer) -> KeyStatus {
        if case .status(401, let body) = answer {
            let text = String(decoding: body, as: UTF8.self)
            return text.contains("INSUFFICIENT_PERMISSIONS") ? .limited : .rejected(.invalidKey)
        }
        return interpret(answer, forbidden: .limited, paymentRequired: .rejected(.outOfCredit))
    }

    /// ElevenLabs answers a key scoped away from `/v1/user` with 401 and
    /// `detail.status = "missing_permissions"`: the key works, it just may not
    /// read the account. Only the parsed field counts; the body is never logged.
    private static func elevenLabsMissingPermissions(_ body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let detail = object["detail"] as? [String: Any]
        else { return false }
        return detail["status"] as? String == "missing_permissions"
    }

    /// A server that has no `/models` route still accepted the connection.
    private static func interpretServer(_ answer: Answer) -> KeyStatus {
        guard case .status(let code, _) = answer else { return .unreachable }
        switch code {
        case 200..<300, 404: return .valid
        case 401, 403: return .rejected(.invalidKey)
        default: return .unreachable
        }
    }

    // MARK: - Transport

    private func get(_ url: URL, header: String?, value: String?) async -> Answer {
        var headers: [String: String] = [:]
        if let header, let value { headers[header] = value }
        return await get(url, headers: headers)
    }

    private func get(_ url: URL, headers: [String: String]) async -> Answer {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .offline }
            return .status(http.statusCode, body: data)
        } catch {
            return .offline
        }
    }

    // MARK: - ElevenLabs paid probe

    /// One second of silence through the recorded-speech endpoint. Only a 401
    /// condemns the key and no connection says nothing; any other answer
    /// leaves it a working scoped key.
    private func paidProbe(apiKey: String) async -> KeyStatus {
        let transcriber = ProviderBatchTranscriber(
            route: { .elevenLabs(apiKey: apiKey, model: "scribe_v2") },
            session: session
        )
        let silence = Data(count: 16_000 * 2)
        do {
            _ = try await transcriber.transcribe(audio: silence, language: nil)
            return .limited
        } catch ProviderBatchTranscriptionError.httpStatus(401) {
            return .rejected(.invalidKey)
        } catch is URLError {
            return .unreachable
        } catch {
            return .limited
        }
    }

    // MARK: - Logging

    private static func label(_ status: KeyStatus) -> String {
        switch status {
        case .valid: return "valid"
        case .limited: return "limited"
        case .rejected(.invalidKey): return "invalid_key"
        case .rejected(.outOfCredit): return "out_of_credit"
        case .unreachable: return "unreachable"
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The latest key check per account, kept across launches. Holds the outcome
/// and the time only, never a key.
@MainActor
final class KeyStatusStore: ObservableObject {
    static let shared = KeyStatusStore()

    static let defaultsKey = "sidekey.aiRouting.keyStatus.v1"
    private static let maxAge: TimeInterval = 86_400

    /// Keyed by `ProviderAccount.storageID`.
    @Published private(set) var records: [String: KeyCheckRecord]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.records = Self.load(from: defaults)
    }

    func record(for account: ProviderAccount) -> KeyCheckRecord? {
        records[account.storageID]
    }

    func set(_ status: KeyStatus, for account: ProviderAccount, at date: Date) {
        records[account.storageID] = KeyCheckRecord(status: status, checkedAt: date)
        save()
    }

    /// Working keys need at most a daily free check. A transient refusal must
    /// recover when Settings is revisited, rather than stay red for a whole day.
    func needsCheck(_ account: ProviderAccount, now: Date) -> Bool {
        guard let record = records[account.storageID] else { return true }
        let maxAge: TimeInterval
        switch record.status {
        case .valid, .limited: maxAge = Self.maxAge
        case .rejected: maxAge = 300
        case .unreachable: maxAge = 60
        }
        return now.timeIntervalSince(record.checkedAt) >= maxAge
    }

    func forget(_ account: ProviderAccount) {
        guard records.removeValue(forKey: account.storageID) != nil else { return }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [String: KeyCheckRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([String: KeyCheckRecord].self, from: data)
        else { return [:] }
        return records
    }
}
