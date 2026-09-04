// Sources/Sidekey/Streaming/BYOK/BYOKRealtimeURL.swift
import Foundation

enum BYOKRealtimeURL {
    /// Build the OpenAI Realtime transcription WS URL. `baseURL` nil → OpenAI
    /// (`api.openai.com`); otherwise the user's self-hosted host. Any scheme
    /// (http/https/ws/wss) is normalized to `wss`.
    static func openAIRealtime(baseURL: String?) -> URL {
        let fallback = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        let raw = (baseURL?.isEmpty == false ? baseURL! : "https://api.openai.com")
        guard var components = URLComponents(string: raw) else { return fallback }
        components.scheme = "wss"
        components.path = "/v1/realtime"
        components.query = "intent=transcription"
        return components.url ?? fallback
    }
}
