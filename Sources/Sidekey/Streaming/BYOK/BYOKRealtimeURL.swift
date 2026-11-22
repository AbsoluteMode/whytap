// Sources/Sidekey/Streaming/BYOK/BYOKRealtimeURL.swift
import Foundation

enum BYOKRealtimeURL {
    /// OpenAI's own realtime transcription socket, used only by a route on
    /// the OpenAI account. A server route never reaches it: its URL comes
    /// from `openAIRealtime(baseURL:)`, which has no default host.
    // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
    static let openAIHosted = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    /// Build the OpenAI Realtime transcription WS URL on the user's
    /// self-hosted host. Any scheme (http/https/ws/wss) is normalized to `wss`.
    /// There is no default host: a nil, empty or unparseable `baseURL` returns
    /// nil, so a broken endpoint fails instead of reaching `api.openai.com`.
    /// WHY: .project-docs/decisions/2026-10-18-no-default-realtime-host.md
    static func openAIRealtime(baseURL: String?) -> URL? {
        guard let baseURL, !baseURL.isEmpty,
              var components = URLComponents(string: baseURL) else { return nil }
        components.scheme = "wss"
        components.path = "/v1/realtime"
        components.query = "intent=transcription"
        return components.url
    }
}
