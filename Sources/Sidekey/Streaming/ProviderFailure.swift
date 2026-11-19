import Foundation

/// Why a provider turned a request down, in terms a user can act on. Built
/// from the status code or the kind of error only: a provider's own message
/// can quote dictated text and is never read here.
// WHY: .project-docs/decisions/2026-11-19-provider-failure-reasons.md
enum ProviderFailure: Equatable, Sendable {
    /// 401 or 403: the key is wrong, revoked, or lacks the permission.
    case keyRefused
    /// 402: the account has no credit left.
    case outOfCredit
    /// 429: a rate or usage limit.
    case busy
    /// 5xx, or a job the provider never finished.
    case notResponding
    /// The request did not reach the provider.
    case noConnection

    /// `nil` for a failure that says nothing about the provider (a cancelled
    /// request, no batch path, a malformed answer): the caller keeps its own
    /// wording.
    init?(_ error: Error) {
        if let failure = error as? ProviderBatchTranscriptionError {
            switch failure {
            case .httpStatus(401), .httpStatus(403): self = .keyRefused
            case .httpStatus(402): self = .outOfCredit
            case .httpStatus(429): self = .busy
            case .httpStatus(let status) where status >= 500: self = .notResponding
            case .timedOut, .jobFailed: self = .notResponding
            case .httpStatus, .malformedResponse: return nil
            }
            return
        }
        if let urlError = error as? URLError {
            guard urlError.code != .cancelled else { return nil }
            self = .noConnection
            return
        }
        return nil
    }

    /// The line the island shows next to Retry. `provider` is the name of the
    /// provider the take ran on.
    func dropMessage(provider: String) -> String {
        switch self {
        case .keyRefused: return "\(provider) refused the key"
        case .outOfCredit: return "\(provider): out of credit"
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
        case .outOfCredit: return .rejected(.outOfCredit)
        case .busy, .notResponding, .noConnection: return nil
        }
    }

    /// Only the user can fix it, in API & Models: Retry alone cannot help.
    var needsSettings: Bool { keyStatus != nil }
}
