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
    /// On this Mac: the model is still loading.
    case localModelPreparing
    /// On this Mac: the model did not load.
    case localModelFailed
    /// On this Mac: a model that loaded during the take gave no text.
    case localModelNoText

    /// `nil` for a failure that says nothing about the provider (a cancelled
    /// request, no batch path, a malformed answer): the caller keeps its own
    /// wording.
    init?(_ error: Error) {
        if let local = error as? OnDeviceSpeechError {
            switch local {
            case .modelPreparing: self = .localModelPreparing
            case .modelLoadFailed, .modelNotDownloaded: self = .localModelFailed
            case .modelNoText: self = .localModelNoText
            case .noAudio: return nil
            }
            return
        }
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
        case .localModelPreparing: return "Local model still preparing, retry soon"
        case .localModelFailed: return "Local model didn't load"
        case .localModelNoText: return "No text from local model, Retry"
        }
    }

    /// What the key's tile shows afterwards, or `nil` when the failure says
    /// nothing lasting about the key.
    var keyStatus: KeyStatus? {
        switch self {
        case .keyRefused: return .rejected(.invalidKey)
        case .missingPermission: return .rejected(.missingSpeechPermission)
        case .outOfCredit: return .rejected(.outOfCredit)
        case .refused, .busy, .notResponding, .noConnection, .localModelPreparing, .localModelFailed,
             .localModelNoText: return nil
        }
    }

    /// Only the user can fix it, in Keys & models: Retry alone cannot help.
    /// A model that did not load is shown there with Try Again.
    var needsSettings: Bool { keyStatus != nil || self == .localModelFailed }

    /// The still-preparing message with the preparation's time left, so the
    /// user knows when Retry will work.
    // WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
    static func localModelPreparingMessage(_ timeLeft: OnDeviceSpeechTimeLeft?) -> String {
        guard case .seconds(let seconds) = timeLeft else { return ProviderFailure.localModelPreparing.dropMessage(provider: "") }
        return seconds > 60
            ? "Local model: about \(OnDeviceSpeechProgressText.minutes(seconds)) min left"
            : "Local model: less than a minute left"
    }
}
