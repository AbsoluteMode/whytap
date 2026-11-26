import XCTest
@testable import Sidekey

/// Lil Bro's answers from whytap.ai as the server sends them: what goes out,
/// how each reply and error reads in his balloon, and that a place the app
/// does not have is never opened.
@MainActor
final class LilBroRemoteBrainTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private func brain(status: Int, json: String, box: Box = Box()) -> LilBroRemoteBrain {
        LilBroRemoteBrain { request in
            box.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
    }

    private func failing(_ error: Error) -> LilBroRemoteBrain {
        LilBroRemoteBrain { _ in throw error }
    }

    func test_the_question_screen_and_three_earlier_answers_go_to_the_lil_bro_endpoint_only() async throws {
        let box = Box()
        let history = (1...5).map { LilBroQuestion.Exchange(question: "q\($0)", answer: "a\($0)") }
        _ = await brain(status: 200, json: #"{"text":["Hi"]}"#, box: box)
            .reply(to: LilBroQuestion(text: "  how do I dictate  ", screen: "features/drop", history: history))
        let request = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://whytap.ai/api/ask/lilbro")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["question", "screen", "history"], "nothing else is sent")
        XCTAssertEqual(body["question"] as? String, "how do I dictate")
        XCTAssertEqual(body["screen"] as? String, "features/drop")
        XCTAssertEqual((body["history"] as? [[String: String]])?.map { $0["q"] }, ["q3", "q4", "q5"])
    }

    func test_a_long_question_is_cut_to_what_the_server_takes_and_a_short_one_stays_local() async throws {
        let box = Box()
        let remote = brain(status: 200, json: #"{"text":["Hi"]}"#, box: box)
        _ = await remote.reply(to: LilBroQuestion(text: String(repeating: "a", count: 400)))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: box.requests[0].httpBody!) as? [String: Any])
        XCTAssertEqual((body["question"] as? String)?.count, 300)
        _ = await remote.reply(to: LilBroQuestion(text: "hi"))
        XCTAssertEqual(box.requests.count, 1, "under three characters nothing is sent")
    }

    /// The server counts Unicode scalars (builder review of #465, ticket
    /// 604): mixed emoji and long earlier turns stay within its limits.
    func test_lengths_are_counted_as_the_server_counts_them() async throws {
        let box = Box()
        let remote = brain(status: 200, json: #"{"text":["Hi"]}"#, box: box)
        let thumbs = String(repeating: "👍🏽", count: 160)  // 160 characters, 320 scalars
        let history = [LilBroQuestion.Exchange(question: String(repeating: "é", count: 401),
                                               answer: "  " + String(repeating: "a🇫🇷", count: 300) + "  ")]
        _ = await remote.reply(to: LilBroQuestion(text: "ok " + thumbs + "   end", history: history))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: box.requests[0].httpBody!) as? [String: Any])
        let question = try XCTUnwrap(body["question"] as? String)
        XCTAssertLessThanOrEqual(question.unicodeScalars.count, 300)
        XCTAssertEqual(question.unicodeScalars.count, 299, "cut before a character that would split")
        XCTAssertTrue(question.hasPrefix("ok 👍🏽"))
        let sent = try XCTUnwrap((body["history"] as? [[String: String]])?.first)
        XCTAssertLessThanOrEqual(sent["q"]!.unicodeScalars.count, 300)
        XCTAssertLessThanOrEqual(sent["a"]!.unicodeScalars.count, 600)
        XCTAssertFalse(sent["a"]!.hasPrefix(" "))
        // Whitespace is collapsed as on the server; under three scalars stays local.
        XCTAssertEqual(LilBroRemoteBrain.prepared("  how   do\nI  dictate "), "how do I dictate")
        XCTAssertNil(LilBroRemoteBrain.prepared(" a  "))
        XCTAssertFalse(LilBroRemoteBrain.sends("hi"))
        XCTAssertTrue(LilBroRemoteBrain.sends("hey"))
    }

    /// Normalisation by scalar with the server's whitespace set (Python
    /// `str.split`), checked against `clean_question` on these inputs
    /// (builder review of #465, ticket 606).
    func test_the_question_is_normalised_as_the_server_does() {
        // U+001C–U+001F are whitespace to Python: one letter is left, too short.
        XCTAssertNil(LilBroRemoteBrain.prepared("\u{1C}\u{1D}a"))
        // A combining mark after a space stays, as Python keeps it.
        XCTAssertEqual(LilBroRemoteBrain.prepared("a  \u{301} b").map { Array($0.unicodeScalars).map(\.value) },
                       [0x61, 0x20, 0x301, 0x20, 0x62])
        XCTAssertEqual(LilBroRemoteBrain.prepared("how\u{A0}do\u{2003}I\u{3000}dictate"), "how do I dictate")
        // A cluster longer than the limit is dropped and the space before it
        // trimmed before the minimum: "ab" is too short, it stays local.
        XCTAssertNil(LilBroRemoteBrain.prepared("ab e" + String(repeating: "\u{301}", count: 300)))
        XCTAssertEqual(LilBroRemoteBrain.prepared("abc e" + String(repeating: "\u{301}", count: 300)), "abc")
        // Whatever is sent is already what the server makes of it.
        for raw in ["  x  y  ", "a\u{1F}b\u{1E}c", "👍🏽 " + String(repeating: "é ", count: 200), "\u{85}tab\tnew\nline"] {
            guard let sent = LilBroRemoteBrain.prepared(raw) else { continue }
            XCTAssertLessThanOrEqual(sent.unicodeScalars.count, 300, raw)
            XCTAssertEqual(LilBroRemoteBrain.prepared(sent), sent, raw)
            XCTAssertFalse(sent.unicodeScalars.contains { LilBroRemoteBrain.serverWhitespace.contains($0.value) && $0 != " " })
            XCTAssertFalse(sent.hasPrefix(" ") || sent.hasSuffix(" "), raw)
        }
    }

    func test_a_redirect_away_from_the_endpoint_is_refused() async {
        let delegate = LilBroRemoteBrain.NoRedirects()
        let response = HTTPURLResponse(url: LilBroRemoteBrain.endpoint, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://example.com/collect"])!
        let task = URLSession.shared.dataTask(with: LilBroRemoteBrain.endpoint)
        let next = await delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                                             newRequest: URLRequest(url: URL(string: "https://example.com/collect")!))
        XCTAssertNil(next)
        task.cancel()
        let reply = await brain(status: 302, json: "").reply(to: LilBroQuestion(text: "how do I dictate"))
        XCTAssertEqual(reply, .unavailable, "an unfollowed redirect reads as unavailable")
    }

    func test_an_answer_names_a_feature_a_tab_or_the_keys() async {
        let feature = await brain(status: 200, json: """
            {"text":["Drop types what you say."],"bullets":["Download the model"],"followUps":["a","b","c"],
             "go":{"feature":"drop"},"offtopic":false,"cached":false}
            """).reply(to: LilBroQuestion(text: "dictation?"))
        XCTAssertEqual(feature, .answer(LilBroAnswer(paragraphs: ["Drop types what you say."],
                                                     bullets: ["Download the model"],
                                                     destination: .feature(.drop), followUps: ["a", "b"])))
        let tab = await brain(status: 200, json: #"{"text":["Here."],"go":{"tab":"hotkeys"}}"#)
            .reply(to: LilBroQuestion(text: "shortcuts"))
        XCTAssertEqual(tab, .answer(LilBroAnswer(paragraphs: ["Here."], destination: .tab(.hotkeys))))
        // A former tab is now a feature's screen: he runs to that screen.
        for (raw, feature) in [("notifications", AppFeature.notify), ("agentMode", .agent)] {
            let former = await brain(status: 200, json: #"{"text":["Here."],"go":{"tab":"\#(raw)"}}"#)
                .reply(to: LilBroQuestion(text: "where"))
            XCTAssertEqual(former, .answer(LilBroAnswer(paragraphs: ["Here."], destination: .feature(feature))), raw)
        }
        let keys = await brain(status: 200, json: #"{"text":["Here."],"go":{"keys":true}}"#)
            .reply(to: LilBroQuestion(text: "my key"))
        XCTAssertEqual(keys, .answer(LilBroAnswer(paragraphs: ["Here."], destination: .apiKeys)))
    }

    func test_a_place_this_app_does_not_have_is_dropped_but_the_answer_stays() async {
        for go in [#"{"feature":"teleport"}"#, #"{"tab":"secret"}"#, #"{"keys":false}"#, "null", #""drop""#] {
            let reply = await brain(status: 200, json: #"{"text":["Words."],"go":\#(go)}"#)
                .reply(to: LilBroQuestion(text: "where"))
            XCTAssertEqual(reply, .answer(LilBroAnswer(paragraphs: ["Words."])), go)
        }
    }

    func test_off_topic_is_one_sentence_and_opens_nothing() async {
        let reply = await brain(status: 200, json: """
            {"text":["I only help with Whytap."],"bullets":["x"],"go":{"feature":"drop"},"followUps":["y"],"offtopic":true}
            """).reply(to: LilBroQuestion(text: "weather"))
        XCTAssertEqual(reply, .answer(LilBroAnswer(paragraphs: ["I only help with Whytap."])))
    }

    func test_errors_read_as_limit_unavailable_or_offline() async {
        let cases: [(Int, String, LilBroReply)] = [
            (429, #"{"error":"rate_limited","retry_after":60}"#, .limit),
            (503, #"{"error":"budget_exhausted"}"#, .limit),
            (503, #"{"error":"busy"}"#, .unavailable),
            (503, #"{"error":"temporarily_unavailable"}"#, .unavailable),
            (400, #"{"error":"invalid_body"}"#, .unavailable),
            (502, "<html>Bad gateway</html>", .unavailable),
            (200, "not json", .unavailable),
            (200, #"{"text":[]}"#, .unavailable),
            (200, #"{"text":["  "]}"#, .unavailable),
        ]
        for (status, json, expected) in cases {
            let reply = await brain(status: status, json: json).reply(to: LilBroQuestion(text: "how do I dictate"))
            XCTAssertEqual(reply, expected, "\(status) \(json)")
        }
        let offline = await failing(URLError(.notConnectedToInternet)).reply(to: LilBroQuestion(text: "dictate?"))
        XCTAssertEqual(offline, .offline)
        let slow = await failing(URLError(.timedOut)).reply(to: LilBroQuestion(text: "dictate?"))
        XCTAssertEqual(slow, .offline)
    }

    func test_only_lil_bro_talks_to_whytap_ai_from_the_app() throws {
        // Links that open whytap.ai in the browser are fine; a request to it
        // from the app is made only by LilBroRemoteBrain.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var callers: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("whytap.ai/api") { callers.append(file.lastPathComponent) }
        }
        XCTAssertEqual(callers, ["LilBroRemoteBrain.swift"])
    }
}
