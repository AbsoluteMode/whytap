import Foundation

/// Answers from whytap.ai: the question, the screen the person is on and up to
/// three earlier exchanges go to Ask's Lil Bro endpoint, which answers with
/// claude-sonnet-5-5 and names a place from the app's own catalog only when
/// the person asked to go there or set something up.
///
/// Used for every question; there is no switch to turn it off (REV 13, the
/// maintainer's decision: Lil Bro works only through Sonnet). Nothing else is
/// sent: no keys, no dictated text, no settings, no identifier of this Mac.
/// The server keeps the question text 90 days without an address or visitor.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md
struct LilBroRemoteBrain: LilBroBrain {
    static let endpoint = URL(string: "https://whytap.ai/api/ask/lilbro")!
    /// The server counts Unicode scalars (Python `len`): a question of 3-300
    /// after collapsing whitespace; earlier exchanges up to 300 and 600.
    static let questionLimit = 300
    static let questionMinimum = 3
    static let historyQuestionLimit = 300
    static let historyAnswerLimit = 600
    static let timeout: TimeInterval = 25

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            try await LilBroRemoteBrain.session.data(for: request)
        }
    }

    /// No cookies, no cache, no stored credentials, no redirects.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// The conversation goes only to `endpoint`: a redirect anywhere is
    /// refused, and its 3xx reads as unavailable.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    /// What Python's `str.split()` on the server treats as whitespace
    /// (`str.isspace`), by Unicode scalar.
    static let serverWhitespace: Set<UInt32> = Set([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0,
                                                   0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000] + Array(0x2000...0x200A))

    /// The question as the server's `clean_question` reads it: split on its
    /// whitespace by scalar and joined with single spaces, cut at a character
    /// boundary to 300 scalars, trailing space trimmed again; nil under three.
    static func prepared(_ question: String) -> String? {
        var words: [String.UnicodeScalarView] = []
        var word = String.UnicodeScalarView()
        for scalar in question.unicodeScalars {
            if serverWhitespace.contains(scalar.value) {
                if !word.isEmpty { words.append(word); word = String.UnicodeScalarView() }
            } else {
                word.append(scalar)
            }
        }
        if !word.isEmpty { words.append(word) }
        var joined = String.UnicodeScalarView()
        for (index, word) in words.enumerated() {
            if index > 0 { joined.append(" ") }
            joined.append(contentsOf: word)
        }
        var text = clipped(String(joined), to: questionLimit).unicodeScalars
        while let last = text.last, serverWhitespace.contains(last.value) { text.removeLast() }
        return text.count >= questionMinimum ? String(text) : nil
    }

    /// Whether a question would leave this Mac (long enough for the server).
    static func sends(_ question: String) -> Bool { prepared(question) != nil }

    /// At most `limit` Unicode scalars, never splitting a character.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var out = ""
        var count = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard count + size <= limit else { break }
            out.append(character)
            count += size
        }
        return out
    }

    func reply(to question: LilBroQuestion) async -> LilBroReply {
        // The server needs three characters; nothing shorter is sent.
        guard let text = Self.prepared(question.text) else { return .tooShort }
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
            body["history"] = question.history.suffix(3).map {
                ["q": prepared($0.question) ?? clipped($0.question, to: historyQuestionLimit),
                 "a": clipped($0.answer.trimmingCharacters(in: .whitespacesAndNewlines), to: historyAnswerLimit)]
            }
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
                                        destination: offtopic ? nil : destination(object["go"])))
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
        // One row of a tab; the server also names its tab for older builds.
        if let raw = go["row"] as? String, let row = LilBroRow.named(raw) { return .row(row) }
        if let raw = go["feature"] as? String, let feature = AppFeature(rawValue: raw) { return .feature(feature) }
        // A former tab (Agents, Notifications) is now a feature's screen: he runs there.
        if let raw = go["tab"] as? String, let tab = SettingsWindowTab(rawValue: raw) {
            return tab.featureScreen.map(LilBroDestination.feature) ?? .tab(tab)
        }
        if go["keys"] as? Bool == true { return .apiKeys }
        return nil
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
