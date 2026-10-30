import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantDetectorTests: XCTestCase {
    private let jev = ResolvedRoute(feature: .meetingAssistantDetector, account: .openRouter, model: "typesafe/jev-1.14",
                                    apiKey: "router-key", server: nil)

    private func session() -> URLSession {
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset() }
        return session
    }
    private func serve(_ value: [String: Any], status: Int = 200) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: value))
    }
    private func jevAnswer(help: Double, handled: Double = 0) -> [String: Any] {
        ["model": "typesafe/jev-1.14-20261014", "usage": ["cost": 0.00004],
         "answers": ["needs_help": ["type": "noul", "noul": help], "already_handled": ["type": "noul", "noul": handled]]]
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition timed out")
    }

    // MARK: - Request and verdict

    func testJevReceivesOnlyBoundedNewSpeechContextAndOfferedQuestions() throws {
        let newSpeech = String(repeating: "н", count: 2_000) + " Как продлить сертификат TLS?"
        let state = MeetingAssistantDetector.state(newSpeech: newSpeech, context: String(repeating: "к", count: 900) + " раньше",
                                                   offered: ["Первый?", "Второй?", "Третий?", "Четвёртый?"])
        let request = try MeetingAssistantDetector.request(route: jev, state: state)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/alpha/decisions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer router-key")
        let sent = try body(request)
        XCTAssertEqual(sent["model"] as? String, "typesafe/jev-1.14")
        let questions = try XCTUnwrap(sent["questions"] as? [String: [String: String]])
        XCTAssertEqual(Set(questions.keys), ["needs_help", "already_handled"])
        XCTAssertTrue(questions.values.allSatisfy { $0["type"] == "noul" })
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((sent["state"] as! String).utf8)) as? [String: Any])
        let utterances = try XCTUnwrap(decoded["recent_utterances"] as? [[String: Any]])
        XCTAssertEqual(utterances.map { $0["new"] as? Bool }, [false, true])
        XCTAssertEqual((utterances[0]["text"] as? String)?.count, MeetingAssistantDetector.contextCharacters)
        XCTAssertEqual((utterances[1]["text"] as? String)?.count, MeetingAssistantDetector.newSpeechCharacters)
        XCTAssertTrue((utterances[1]["text"] as? String)?.hasSuffix("Как продлить сертификат TLS?") == true)
        XCTAssertEqual((decoded["past_help"] as? [[String: String]])?.map { $0["need"] }, ["Второй?", "Третий?", "Четвёртый?"])
    }

    func testOpenAIDecisionsUseNamedPredicates() throws {
        let route = ResolvedRoute(feature: .meetingAssistantDetector, account: .openAI, model: "gpt-6-luna", apiKey: "openai-key", server: nil)
        let request = try MeetingAssistantDetector.request(route: route, state: "{}")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/decisions")
        let questions = try XCTUnwrap(try body(request)["questions"] as? [[String: String]])
        XCTAssertEqual(questions.map { $0["name"] }, ["already_handled", "needs_help"])
        XCTAssertTrue(questions.allSatisfy { $0["type"] == "predicate" })
        let data = try JSONSerialization.data(withJSONObject: ["answers": [
            ["type": "predicate", "name": "needs_help", "probability": 0.8],
            ["type": "predicate", "name": "already_handled", "probability": 0.1]]])
        XCTAssertTrue(try MeetingAssistantDetector.verdict(from: data, account: .openAI).opensGate)
    }

    func testOnlyCalibratedDecisionModelsAreSent() {
        for model in ["typesafe/jev-1.13", "typesafe/jev-router", "anthropic/claude-sonnet-5.5"] {
            let route = ResolvedRoute(feature: .meetingAssistantDetector, account: .openRouter, model: model, apiKey: "key", server: nil)
            XCTAssertThrowsError(try MeetingAssistantDetector.request(route: route, state: "{}"), model)
        }
        let anthropic = ResolvedRoute(feature: .meetingAssistantDetector, account: .anthropic, model: "claude-haiku-5-5", apiKey: "key", server: nil)
        XCTAssertThrowsError(try MeetingAssistantDetector.request(route: anthropic, state: "{}"))
        XCTAssertEqual(ModelRegistry.recommended(for: .meetingAssistantDetector, kind: .openRouter), "typesafe/jev-1.14")
        XCTAssertNil(AIFeature.meetingAssistantDetector.modelUse(on: .anthropic))
    }

    func testThresholdsRepeatSuppressionAndMalformedAnswers() throws {
        func verdict(_ value: [String: Any]) throws -> MeetingAssistantDetector.Verdict {
            try MeetingAssistantDetector.verdict(from: JSONSerialization.data(withJSONObject: value), account: .openRouter)
        }
        XCTAssertTrue(try verdict(jevAnswer(help: 0.5)).opensGate)
        XCTAssertFalse(try verdict(jevAnswer(help: 0.49)).opensGate)
        XCTAssertFalse(try verdict(jevAnswer(help: 0.95, handled: 0.5)).opensGate, "An already offered question stays quiet")
        XCTAssertThrowsError(try verdict(["answers": ["needs_help": ["type": "noul", "noul": 0.9]]]))
        XCTAssertThrowsError(try verdict(jevAnswer(help: 1.2)))
        XCTAssertThrowsError(try verdict(["answers": "nope"]))
        let duplicated = try JSONSerialization.data(withJSONObject: ["answers": [
            ["type": "predicate", "name": "needs_help", "probability": 0.9], ["type": "predicate", "name": "needs_help", "probability": 0.1],
            ["type": "predicate", "name": "already_handled", "probability": 0.0]]])
        XCTAssertThrowsError(try MeetingAssistantDetector.verdict(from: duplicated, account: .openAI))
    }

    func testUsageIsRecordedUnderTheDetectorIncludingFailures() async throws {
        let session = session()
        var recorded: [AIUsageEvent] = []
        let detector = MeetingAssistantDetector(session: session, usageSink: { recorded.append($0) })
        StubURLProtocol.handler = { _ in self.serve(self.jevAnswer(help: 0.9)) }
        let open = try await detector.verdict(route: jev, newSpeech: "Как продлить сертификат?", context: "", offered: [])
        XCTAssertTrue(open.opensGate)
        StubURLProtocol.handler = { _ in self.serve(["error": "echoed speech"], status: 500) }
        do { _ = try await detector.verdict(route: jev, newSpeech: "x", context: "", offered: []); XCTFail("Expected failure") } catch {}
        StubURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        do { _ = try await detector.verdict(route: jev, newSpeech: "x", context: "", offered: []); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(recorded.map(\.context.feature), [.meetingAssistantDetector, .meetingAssistantDetector],
                       "A rejected request is not a charge; a lost connection may have been one")
        XCTAssertEqual(recorded[0].context.model, "typesafe/jev-1.14-20261014")
        XCTAssertEqual(recorded[0].amount, 0.00004)
        XCTAssertEqual(recorded[0].basis, .reported)
        XCTAssertNil(recorded[1].amount)
        XCTAssertEqual(recorded[1].basis, .unavailable)
    }

    // MARK: - Meeting flow

    private struct Flow {
        let model: MeetingAssistantModel
        let audio: MeetingAssistantAudio
        let upstream: FixtureSubtitleUpstream
        let root: URL
    }

    private func flow(detector: @escaping () throws -> ResolvedRoute?) throws -> Flow {
        let session = session()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-detector-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "meeting-assistant-detector-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let runner = MeetingAssistantRunner(http: .init(session: session), resolve: {
            ResolvedRoute(feature: .meetingAssistant, account: .openRouter, model: "anthropic/claude-sonnet-5.5", apiKey: "router-key", server: nil)
        }, endpoint: { nil }, usageSink: { _ in }, resolveDetector: detector,
           detector: MeetingAssistantDetector(session: session, usageSink: { _ in }))
        let source = FixtureSubtitleAudio(), upstream = FixtureSubtitleUpstream()
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { upstream })
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio,
                                          detectionInterval: .milliseconds(10), gatedDetectionInterval: .milliseconds(10))
        model.spaces = [.init(version: 1, id: "project", name: "project", purpose: "Project", instructions: "", sources: [
            .init(id: "repo", kind: "repository", name: "Repo", location: try SpaceRepository.root(root.path).path, scope: ["."], access: "read")
        ])]
        model.selectedSpaceID = "project"
        return Flow(model: model, audio: audio, upstream: upstream, root: root)
    }
    private func requests(to host: String) -> [URLRequest] {
        StubURLProtocol.capturedRequests.filter { $0.url?.path.hasSuffix(host) == true }
    }
    private func chatQuestions(_ questions: [String]) -> (Int, [String: String], Data) {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["questions": questions]), as: UTF8.self)
        return serve(["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": text]]]])
    }
    private func decisionBodies() throws -> [[String: Any]] {
        try zip(StubURLProtocol.capturedRequests, StubURLProtocol.capturedBodies)
            .filter { $0.0.url?.path.hasSuffix("/decisions") == true }
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.1) as? [String: Any]) }
    }
    private func stateNewSpeech(_ sent: [String: Any]) throws -> String {
        let state = try XCTUnwrap(sent["state"] as? String)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
        let utterances = try XCTUnwrap(decoded["recent_utterances"] as? [[String: Any]])
        return try XCTUnwrap(utterances.first { $0["new"] as? Bool == true }?["text"] as? String)
    }

    func testRoutineSpeechStaysWithJevAndOnlyAHelpSignalReachesTheAnswerModel() async throws {
        let f = try flow { self.jev }
        var helpful = false
        StubURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/decisions") == true { return self.serve(self.jevAnswer(help: helpful ? 0.9 : 0.1)) }
            return self.chatQuestions(["Как продлить сертификат TLS?"])
        }
        f.model.startListening(); try await wait { f.audio.ready }
        f.upstream.pair.continuation.yield(.final("Ну что, как продвигается интеграция к созвону?"))
        try await wait { self.requests(to: "/decisions").count == 1 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(requests(to: "/chat/completions").isEmpty, "Routine status speech must not spend an answer-model request")
        XCTAssertEqual(requests(to: "/decisions").count, 1, "Unchanged speech is not checked again")

        helpful = true
        f.upstream.pair.continuation.yield(.final(" Не помню, как продлить сертификат TLS, подскажете?"))
        try await wait { f.model.pending.count == 1 }
        XCTAssertEqual(f.model.pending.first?.question, "Как продлить сертификат TLS?")
        XCTAssertEqual(requests(to: "/chat/completions").count, 1)
        let second = try XCTUnwrap(try decisionBodies().last)
        XCTAssertEqual(try stateNewSpeech(second), " Не помню, как продлить сертификат TLS, подскажете?",
                       "Jev sees only speech it has not checked before")
        XCTAssertTrue(f.model.listening)
        f.model.setMeetingEnabled(false); try await wait { !f.model.releasingAudio }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [], "Nothing is written to disk")
    }

    func testMalformedDetectorKeepsListeningAndAFailedDetectorStopsVisibly() async throws {
        let f = try flow { self.jev }
        var reply: (Int, [String: String], Data) = serve(["answers": "garbled"])
        StubURLProtocol.handler = { request in
            request.url?.path.hasSuffix("/decisions") == true ? reply : self.chatQuestions([])
        }
        f.model.startListening(); try await wait { f.audio.ready }
        f.upstream.pair.continuation.yield(.final("Как сделать резервную копию базы данных?"))
        try await wait { f.model.audioIssue.hasPrefix("Детектор не разобрал") }
        XCTAssertTrue(f.model.listening)
        XCTAssertTrue(requests(to: "/chat/completions").isEmpty)

        reply = serve(["error": "unavailable"], status: 503)
        f.upstream.pair.continuation.yield(.final(" И где хранится последняя копия базы?"))
        try await wait { !f.model.listening }
        XCTAssertTrue(f.model.audioIssue.hasPrefix("Не удалось проверить реплики детектором"))
        XCTAssertTrue(requests(to: "/chat/completions").isEmpty, "A failed detector never falls back to the answer model")
        try await wait { f.upstream.closed }
    }

    func testUnresolvableDetectorRouteRefusesToStartListening() async throws {
        let f = try flow { throw FeatureRouteError.missingKey(.meetingAssistantDetector) }
        f.model.startListening()
        XCTAssertEqual(f.model.audioIssue, MeetingAssistantModel.detectorSetupIssue)
        XCTAssertFalse(f.audio.active)
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    func testWithoutDetectorEveryTranscriptChangeStillReachesTheAnswerModel() async throws {
        let f = try flow { nil }
        StubURLProtocol.handler = { _ in self.chatQuestions(["Как продлить сертификат?"]) }
        f.model.startListening(); try await wait { f.audio.ready }
        f.upstream.pair.continuation.yield(.final("Не помню, как продлить сертификат, подскажете?"))
        try await wait { f.model.pending.count == 1 }
        XCTAssertTrue(requests(to: "/decisions").isEmpty, "No speech goes to a decision model the user did not choose")
        f.model.setMeetingEnabled(false); try await wait { !f.model.releasingAudio }
    }
}
