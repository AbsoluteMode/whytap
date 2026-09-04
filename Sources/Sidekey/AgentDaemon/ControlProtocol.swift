import Foundation

/// The user's decision on a `can_use_tool` permission ask.
enum PermissionDecision: Equatable {
    /// `inputJSON` is the canonical JSON of the request's `input` object,
    /// echoed back verbatim as `updatedInput` (required by the protocol).
    case allow(inputJSON: String)
    case deny(message: String)
}

/// Pure builders for the three stdin lines of the stdio control protocol.
/// Shapes verified against `claude` v2.1.152 (see plan header).
enum ControlProtocol {
    static func userMessage(_ prompt: String) -> String {
        jsonLine(["type": "user",
                  "message": ["role": "user", "content": prompt]])
    }

    static func controlResponse(requestId: String, decision: PermissionDecision) -> String {
        let inner: [String: Any]
        switch decision {
        case .allow(let inputJSON):
            let updated = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)))
                as? [String: Any] ?? [:]
            inner = ["behavior": "allow", "updatedInput": updated]
        case .deny(let message):
            inner = ["behavior": "deny", "message": message]
        }
        return jsonLine([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestId, "response": inner],
        ])
    }

    private static func jsonLine(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
