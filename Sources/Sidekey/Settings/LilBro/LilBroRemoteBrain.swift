import Foundation

/// Answers from whytap.ai: the question, the screen the person is on and up to
/// three earlier exchanges go to Ask's Lil Bro endpoint, which answers with
/// claude-haiku-5-5 and names one place from the app's own catalog.
///
/// Used only after the person turns answers on in his balloon. Nothing else is
/// sent: no keys, no dictated text, no settings, no identifier of this Mac.
/// The server keeps the question text 90 days without an address or visitor.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md
struct LilBroRemoteBrain: LilBroBrain {
    static let endpoint = URL(string: "https://whytap.ai/api/ask/lilbro")!
    /// The server accepts 3-300 characters.
    static let questionLimit = 300
    static let timeout: TimeInterval = 25

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            try await LilBroRemoteBrain.session.data(for: request)
        }
    }

    /// No cookies, no cache, no stored credentials.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }()

    func reply(to question: LilBroQuestion) async -> LilBroReply {
        var text = question.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A two-letter question gets the local guide; the server needs three.
        guard text.count >= 3 else { return LilBroLocalGuide.match(text) }
        if text.count > Self.questionLimit { text = String(text.prefix(Self.questionLimit)) }
        let request: URLRequest
        do {
            request = try Self.request(for: LilBroQuestion(text: text, screen: question.screen,
                                                           history: question.history))
        } catch {
            return .unavailable
        }
        do {
            let (data, response) = try await transport(request)
            return Self.reply(data: data, response: response)
        } catch is CancellationError {
            return .offline
        } catch {
            return .offline
        }
    }

    static func request(for question: LilBroQuestion) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        var body: [String: Any] = ["question": question.text]
        if !question.screen.isEmpty { body["screen"] = question.screen }
        if !question.history.isEmpty {
            body["history"] = question.history.suffix(3).map { ["q": $0.question, "a": $0.answer] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The server's reply → what he says. A place the app does not have is
    /// dropped; the answer still shows.
    static func reply(data: Data, response: URLResponse) -> LilBroReply {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 200:
            guard let object else { return .unavailable }
            let paragraphs = strings(object["text"])
            guard !paragraphs.isEmpty else { return .unavailable }
            let offtopic = object["offtopic"] as? Bool == true
            return .answer(LilBroAnswer(paragraphs: paragraphs,
                                        bullets: offtopic ? [] : strings(object["bullets"]),
                                        destination: offtopic ? nil : destination(object["go"]),
                                        followUps: offtopic ? [] : Array(strings(object["followUps"]).prefix(2))))
        case 429:
            return .limit
        case 503 where object?["error"] as? String == "budget_exhausted":
            return .limit
        default:
            return .unavailable
        }
    }

    static func destination(_ value: Any?) -> LilBroDestination? {
        guard let go = value as? [String: Any] else { return nil }
        if let raw = go["feature"] as? String, let feature = AppFeature(rawValue: raw) { return .feature(feature) }
        if let raw = go["tab"] as? String, let tab = SettingsWindowTab(rawValue: raw) { return .tab(tab) }
        if go["keys"] as? Bool == true { return .apiKeys }
        return nil
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
