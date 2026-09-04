import Foundation

enum AgentClientError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case payloadTooLarge
    case rateLimited
    case upstreamUnavailable
    case networkError
    case invalidRequest
    case unexpectedStatus(Int)

    var code: String {
        switch self {
        case .unauthorized:
            return "unauthorized"
        case .payloadTooLarge:
            return "payload_too_large"
        case .rateLimited:
            return "rate_limited"
        case .upstreamUnavailable:
            return "upstream_unavailable"
        case .networkError:
            return "network_error"
        case .invalidRequest:
            return "invalid_request"
        case .unexpectedStatus(let status):
            return "unexpected_status_\(status)"
        }
    }

    var description: String {
        switch self {
        case .unauthorized:
            return "Authentication required."
        case .payloadTooLarge:
            return "Too much text was selected. Select a smaller passage and try again."
        case .rateLimited:
            return "Rate limited. Try again later."
        case .upstreamUnavailable:
            return "Agent service is temporarily unavailable."
        case .networkError:
            return "Network error."
        case .invalidRequest:
            return "Invalid agent request."
        case .unexpectedStatus(let status):
            return "Unexpected response status \(status)."
        }
    }

    var retryable: Bool {
        switch self {
        case .rateLimited, .upstreamUnavailable, .networkError:
            return true
        case .unauthorized, .payloadTooLarge, .invalidRequest, .unexpectedStatus:
            return false
        }
    }

    init(statusCode: Int) {
        switch statusCode {
        case 401:
            self = .unauthorized
        case 413:
            self = .payloadTooLarge
        case 429:
            self = .rateLimited
        case 502, 503:
            self = .upstreamUnavailable
        default:
            self = .unexpectedStatus(statusCode)
        }
    }

    var sseEvent: AgentSSEEvent {
        .error(code: code, message: description, retryable: retryable)
    }
}
