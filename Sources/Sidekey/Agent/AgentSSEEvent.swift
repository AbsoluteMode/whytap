import Foundation

enum AgentSSEEvent: Decodable, Equatable {
    case toolExecuting(tool: String, label: String)
    case summaryDelta(text: String)
    /// Local-CLI path: incremental "thinking" narration accumulated into a
    /// hidden buffer (NOT shown live), used only as a fallback at `done` if no
    /// `finalAnswer` was captured. Kept separate from `summaryDelta` (the
    /// streaming contract shared by both CLI mappers) so the pill shows tool
    /// steps during the turn instead of the agent's intermediate narration.
    case narrationDelta(text: String)
    /// Local-CLI path: the canonical final answer (Claude `result` text or
    /// Codex's last `agent_message`). Replaces any prior candidate; revealed
    /// into the pill at `done`.
    case finalAnswer(text: String)
    case blockComplete(UIBlock)
    case done(sources: [Source])
    case error(code: String, message: String, retryable: Bool)
    case voiceTranscript(text: String)
    /// First event of a turn. Carries the `turn_id` that ties the turn's
    /// client-side bookkeeping together; `request_id` and `session_id` mirror
    /// the chat-stack session for log correlation.
    case started(turnId: String, requestId: String, sessionId: String)
    /// Emitted by ClaudeCodeProvider when the local CLI asks to use a gated tool
    /// (Bash / network / MCP-write). The user answers via the pill; the decision
    /// is written back through ClaudeCodeProvider.respondToPermission(requestId:).
    /// `inputJSON` is the canonical JSON of the tool input, echoed on allow.
    case permissionRequest(id: String, toolName: String, summary: String, inputJSON: String)
    /// Emitted by the CLI mappers only: a short narrative
    /// phrase the agent emitted between actions ("I'll run the tests first").
    /// Drives the live progress line exactly like a toolExecuting label, but
    /// is NOT recorded as a tool in chat history.
    case statusNarration(text: String)

    init(rawSSE: String) throws {
        let message = try Self.parse(rawSSE: rawSSE)
        try self.init(event: message.event, data: message.data)
    }

    init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            try self.init(rawSSE: raw)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        let data: Data
        if let dataString = try? container.decode(String.self, forKey: .data) {
            data = Data(dataString.utf8)
        } else {
            let value = try container.decode(AnyCodable.self, forKey: .data)
            data = try JSONEncoder().encode(value)
        }
        try self.init(event: event, data: data)
    }

    init(event: String, data: Data) throws {
        let decoder = JSONDecoder()
        switch event {
        case "tool.executing":
            let payload = try decoder.decode(ToolExecutingPayload.self, from: data)
            self = .toolExecuting(tool: payload.tool, label: payload.label)
        case "summary.delta":
            let payload = try decoder.decode(SummaryDeltaPayload.self, from: data)
            self = .summaryDelta(text: payload.text)
        case "block.complete":
            self = .blockComplete(
                try UIBlock.decodeWithGracefulFallback(data, env: BuildConfig.flavor, decoder: decoder)
            )
        case "done":
            let payload = try decoder.decode(DonePayload.self, from: data)
            // The `done` payload may omit `sources` when the turn produced
            // none. Tolerate
            // both shapes — making it required here caused the entire `done`
            // event to be dropped, which in turn skipped
            // `AgentController.finalizeHistoryEntry()` so no agent history
            // row was ever persisted.
            self = .done(sources: payload.sources ?? [])
        case "error":
            let payload = try decoder.decode(ErrorPayload.self, from: data)
            self = .error(
                code: payload.code,
                message: payload.message,
                retryable: payload.retryable
            )
        case "voice.transcript":
            let payload = try decoder.decode(VoiceTranscriptPayload.self, from: data)
            self = .voiceTranscript(text: payload.text)
        case "started":
            let payload = try decoder.decode(StartedPayload.self, from: data)
            self = .started(
                turnId: payload.turn_id,
                requestId: payload.request_id,
                sessionId: payload.session_id
            )
        default:
            throw AgentSSEEventDecodingError.unknownEvent(event)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case event
        case data
    }

    private static func parse(rawSSE: String) throws -> SSEMessage {
        var event: String?
        var dataLines: [String] = []

        for rawLine in rawSSE.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.isEmpty, !line.hasPrefix(":") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let field = parts.first else { continue }
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.first == " " {
                value.removeFirst()
            }

            switch field {
            case "event":
                event = value
            case "data":
                dataLines.append(value)
            default:
                continue
            }
        }

        guard let event, !event.isEmpty else {
            throw AgentSSEEventDecodingError.missingEvent
        }
        guard !dataLines.isEmpty else {
            throw AgentSSEEventDecodingError.missingData(event: event)
        }

        return SSEMessage(event: event, data: Data(dataLines.joined(separator: "\n").utf8))
    }
}

enum AgentLocalStatus: String, Codable, Equatable {
    case recording
    case uploading
    case transcribing
    case thinking
    case ready
    case failed
}

enum AgentSSEEventDecodingError: Error, Equatable, CustomStringConvertible {
    case missingEvent
    case missingData(event: String)
    case unknownEvent(String)

    var description: String {
        switch self {
        case .missingEvent:
            return "SSE event name is missing."
        case .missingData(let event):
            return "SSE data is missing for event \(event)."
        case .unknownEvent(let event):
            return "Unknown Agent SSE event: \(event)"
        }
    }
}

private struct SSEMessage {
    let event: String
    let data: Data
}

private struct ToolExecutingPayload: Decodable {
    let tool: String
    let label: String
}

private struct SummaryDeltaPayload: Decodable {
    let text: String
}

private struct DonePayload: Decodable {
    let sources: [Source]?
}

private struct ErrorPayload: Decodable {
    let code: String
    let message: String
    let retryable: Bool
}

private struct VoiceTranscriptPayload: Decodable {
    let text: String
}

/// Payload for the `started` event. All three keys are required by the
/// mapper contract. Decoder uses
/// snake_case field names to match the wire shape verbatim — no CodingKeys
/// indirection needed because the property names align with the JSON.
private struct StartedPayload: Decodable {
    // swiftlint:disable identifier_name
    let turn_id: String
    let request_id: String
    let session_id: String
    // swiftlint:enable identifier_name
}

