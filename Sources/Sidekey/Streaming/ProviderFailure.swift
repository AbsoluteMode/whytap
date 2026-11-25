import Foundation

/// Why a provider turned a request down, in terms a user can act on. Built
/// from the status code, the kind of error or an allowlisted refusal code
/// only: a provider's own message can quote dictated text and is never read.
// WHY: .project-docs/decisions/2026-11-19-provider-failure-reasons.md
enum ProviderFailure: Equatable, Sendable {
    /// 401: the key is wrong or revoked.
    case keyRefused
    /// The key is real but may not transcribe.
    case missingPermission
    /// 402, or a quota the provider names: no credit left.
    case outOfCredit
    /// 403: refused, but not necessarily by the key (a plan, a region, a
    /// proxy in between). Shown, never recorded against the key.
    case refused
    /// 429: a rate or usage limit.
    case busy
    /// 5xx, an unfinished job, or a connection the provider did not keep.
    case notResponding
    /// The request did not leave this Mac.
    case noConnection

    /// `nil` for a failure that says nothing about the provider (a cancelled
    /// request, no batch path, a malformed answer): the caller keeps its own
    /// wording.
    init?(_ error: Error) {
        if let failure = error as? ProviderBatchTranscriptionError {
            switch failure {
            case .elevenLabs(_, .missingPermissions): self = .missingPermission
            case .elevenLabs(_, .quotaExceeded): self = .outOfCredit
            case .elevenLabs(_, .invalidKey): self = .keyRefused
            // OpenAI's 429 is a rate limit unless its code names the balance.
            case .openAI(_, .outOfCredit): self = .outOfCredit
            case .openAI(_, .invalidKey): self = .keyRefused
            case .httpStatus(401): self = .keyRefused
            case .httpStatus(402): self = .outOfCredit
            case .httpStatus(403): self = .refused
            case .httpStatus(429): self = .busy
            case .httpStatus(let status) where status >= 500: self = .notResponding
            case .timedOut, .jobFailed: self = .notResponding
            case .httpStatus, .malformedResponse: return nil
            }
            return
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return nil
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                self = .noConnection
            default:
                // A timeout, a broken TLS handshake or a garbled answer is the
                // far end's trouble, not the user's network.
                self = .notResponding
            }
            return
        }
        return nil
    }

    /// The line the island shows next to Retry. `provider` is the name of the
    /// provider the take ran on.
    func dropMessage(provider: String) -> String {
        switch self {
        case .keyRefused: return "\(provider) refused the key"
        case .missingPermission: return "\(provider) key: no Speech to Text access"
        case .outOfCredit: return "\(provider): out of credit"
        case .refused: return "\(provider) refused the request"
        case .busy: return "\(provider) is busy, try again"
        case .notResponding: return "\(provider) is not responding"
        case .noConnection: return "No connection"
        }
    }

    /// What the key's tile shows afterwards, or `nil` when the failure says
    /// nothing lasting about the key.
    var keyStatus: KeyStatus? {
        switch self {
        case .keyRefused: return .rejected(.invalidKey)
        case .missingPermission: return .rejected(.missingSpeechPermission)
        case .outOfCredit: return .rejected(.outOfCredit)
        case .refused, .busy, .notResponding, .noConnection: return nil
        }
    }

    /// Only the user can fix it, in Keys & models: Retry alone cannot help.
    var needsSettings: Bool { keyStatus != nil }
}
