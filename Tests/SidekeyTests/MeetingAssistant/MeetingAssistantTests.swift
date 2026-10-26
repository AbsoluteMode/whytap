import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantTests: XCTestCase {
    private func fixture(account: ProviderAccount = .openRouter) throws -> (MeetingAssistantRunner, URL, UserDefaults) {
        StubURLProtocol.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "meeting-assistant-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel(); StubURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
        }
        let runner = MeetingAssistantRunner(http: .init(session: session), resolve: {
            ResolvedRoute(feature: .meetingAssistant, account: account, model: "fixture-model", apiKey: "fixture-key", server: nil)
        }, endpoint: { nil }, usageSink: { _ in })
        return (runner, root, defaults)
    }
    private func space(_ root: URL, id: String = "project") -> MeetingSpace {
        .init(version: 1, id: id, name: id, purpose: "Project", instructions: "", sources: [
            .init(id: "repo", kind: "repository", name: "Repo", location: try! SpaceRepository.root(root.path).path, scope: ["."], access: "read")
        ])
    }
    private var answer: [String: Any] { ["conclusion": "Готово", "points": ["Первый **важный** пункт"], "followups": ["Что дальше?", "Какие риски?"], "sources": []] }
    private func serve(_ value: [String: Any]) -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: value))
    }
    private func routerAnswer() -> [String: Any] {
        ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "tool_calls": [
            ["id": "final", "type": "function", "function": ["name": "answer", "arguments": String(data: try! JSONSerialization.data(withJSONObject: answer), encoding: .utf8)!]]
        ]]]]]
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition timed out")
    }
    func testAllProvidersReceiveInitialImagesAndOnlyScopedTools() async throws {
        for account in [ProviderAccount.openRouter, .openAI, .anthropic] {
            let (runner, root, _) = try fixture(account: account)
            StubURLProtocol.handler = { _ in
                switch account {
                case .openAI: return self.serve(["status": "completed", "output": [["type": "function_call", "call_id": "answer1", "name": "answer", "arguments": String(data: try! JSONSerialization.data(withJSONObject: self.answer), encoding: .utf8)!]]])
                case .anthropic: return self.serve(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "answer1", "name": "answer", "input": self.answer]]])
                default: return self.serve(self.routerAnswer())
                }
            }
            let value = try await runner.answer(question: "Fixture question", space: space(root), transcript: "", history: [], images: [.init(data: Data("synthetic-image".utf8), mimeType: "image/jpeg")])
            XCTAssertEqual(value.followups.count, 2)
            let body = try XCTUnwrap(StubURLProtocol.capturedBodies.last)
            let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            XCTAssertTrue(text.contains(Data("synthetic-image".utf8).base64EncodedString()))
            XCTAssertFalse(text.contains("capture_screen")); XCTAssertFalse(text.contains("run_command"))
            XCTAssertFalse(text.contains("write_file")); XCTAssertFalse(text.contains("case_list_keys")); XCTAssertFalse(text.contains("web_search"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "No repository or agent history writes")
            if account == .openAI { XCTAssertTrue(text.contains("input_image")); XCTAssertTrue(text.contains("\"store\":false")) }
            if account == .anthropic { XCTAssertTrue(text.contains("\"media_type\":\"image/jpeg\"")) }
        }
    }
    func testDeliveredPhotosAreConsumedAndClarificationSurvivesCollapseAndRootReopen() async throws {
        let (runner, root, defaults) = try fixture()
        StubURLProtocol.handler = { _ in self.serve(self.routerAnswer()) }
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner)
        model.spaces = [space(root)]; model.selectedSpaceID = "project"
        model.screenshots = [.init(image: NSImage(size: NSSize(width: 10, height: 10)), payload: .init(data: Data("fixture".utf8), mimeType: "image/jpeg"))]
        model.draft = "Вопрос"; model.submit()
        try await wait { model.busy == nil }
        XCTAssertTrue(model.screenshots.isEmpty); XCTAssertEqual(model.completed.count, 1)
        let rootQuestion = try XCTUnwrap(model.completed.first)
        model.followupDraft = "Уточнение"; model.submitFollowup()
        try await wait { model.busy == nil }
        let continuation = model.selected
        model.answerVisible = false; model.restoreAnswer()
        XCTAssertEqual(model.selected, continuation); XCTAssertEqual(model.previous.count, 1)
        model.ask(rootQuestion)
        XCTAssertEqual(model.selected, continuation); XCTAssertEqual(model.previous.count, 1)
        XCTAssertEqual(model.completed.count, 1)
        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 2, "Cached reopen sends no model request")
        let body = String(decoding: StubURLProtocol.capturedBodies[1], as: UTF8.self)
        XCTAssertFalse(body.contains(Data("fixture".utf8).base64EncodedString()), "Old photos are not replayed in text history")
    }
    func testCancelAndSpaceSwitchRejectLateAnswersAndRetainPhotosOnlyInOriginalDraft() async throws {
        let (runner, root, defaults) = try fixture()
        StubURLProtocol.handler = { _ in Thread.sleep(forTimeInterval: 0.1); return self.serve(self.routerAnswer()) }
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner)
        model.spaces = [space(root), space(root, id: "other")]; model.selectedSpaceID = "project"
        model.screenshots = [.init(image: NSImage(size: NSSize(width: 10, height: 10)), payload: .init(data: Data("fixture".utf8), mimeType: "image/jpeg"))]
        model.draft = "Отмени"; model.submit(); model.cancel()
        try await Task.sleep(for: .milliseconds(180))
        model.restoreAnswer()
        XCTAssertFalse(model.notice.isEmpty); XCTAssertTrue(model.completed.isEmpty); XCTAssertEqual(model.screenshots.count, 1)
        model.draft = "Смени Space"; model.submit(); model.selectSpace("other")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(model.completed.isEmpty); XCTAssertTrue(model.screenshots.isEmpty)
        model.selectSpace("project")
        XCTAssertTrue(model.completed.isEmpty); XCTAssertFalse(model.notice.isEmpty)
        XCTAssertTrue(model.screenshots.isEmpty)
    }
    func testActiveManifestEditInvalidatesConversation() async throws {
        let (runner, root, defaults) = try fixture()
        var value = space(root)
        let file = root.appendingPathComponent("project.json")
        try JSONEncoder().encode(value).write(to: file)
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner)
        await model.reloadSpaces()
        model.completed = [.init(question: "Previous", conclusion: "Previous answer")]
        value.instructions = "New scope instructions"
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        await model.reloadSpaces()
        XCTAssertTrue(model.completed.isEmpty); XCTAssertEqual(model.currentSpace, value)
    }
    func testMalformedAnswerIsNotDelivered() throws {
        var invalid = MeetingAssistantAnswer(conclusion: "Answer", points: [], followups: [], sources: [])
        XCTAssertThrowsError(try invalid.validated())
        invalid.followups = ["Same", "Same"]
        XCTAssertThrowsError(try invalid.validated())
        XCTAssertEqual(AIFeature.meetingAssistantAudio.mode, .realtime)
        XCTAssertEqual(AIFeature.meetingAssistant.mode, .llmWithTools)
        XCTAssertEqual(HoverSlotRouter.effect(for: .meetingAssistant), .openMeetingAssistant)
        XCTAssertEqual(WhytapLink.destination(for: .meetingAssistant), .meetingAssistant)
    }
    func testInactiveManifestEditInvalidatesItsSavedConversationAndUnchangedCatalogDoesNotPublish() async throws {
        let (runner, root, defaults) = try fixture()
        var first = space(root)
        let second = space(root, id: "second")
        let firstFile = root.appendingPathComponent("project.json")
        try JSONEncoder().encode(first).write(to: firstFile)
        try JSONEncoder().encode(second).write(to: root.appendingPathComponent("second.json"))
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner)
        await model.reloadSpaces()
        model.completed = [.init(question: "Old question", conclusion: "Old scope")]
        model.selectSpace("second")
        first.instructions = "Changed while inactive"
        try JSONEncoder().encode(first).write(to: firstFile, options: .atomic)
        await model.reloadSpaces()
        model.selectSpace("project")
        XCTAssertTrue(model.completed.isEmpty)
        try await wait { !model.releasingAudio }
        var publications = 0
        model.onChange = { publications += 1 }
        await model.reloadSpaces()
        XCTAssertEqual(publications, 0)
    }
    func testLiveFinalsBecomeQuestionsAndMalformedDetectionDoesNotStopAudio() async throws {
        let (runner, root, defaults) = try fixture()
        let source = FixtureSubtitleAudio(), upstream = FixtureSubtitleUpstream()
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { upstream })
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            let text = calls == 1 ? "not JSON" : "```json\n{\"questions\":[\"Какие риски проекта?\"]}\n```"
            return self.serve(["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": text]]]])
        }
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio, detectionInterval: .milliseconds(10))
        model.spaces = [space(root)]; model.selectedSpaceID = "project"
        model.startListening(); try await wait { audio.ready }
        upstream.pair.continuation.yield(.final("Расскажите пожалуйста об основных рисках проекта?"))
        try await wait { !model.audioIssue.isEmpty }
        XCTAssertTrue(model.listening); XCTAssertFalse(upstream.closed)
        upstream.pair.continuation.yield(.final(" И уточните пожалуйста ближайшие шаги."))
        try await wait { model.pending.count == 1 }
        XCTAssertEqual(model.pending.first?.question, "Какие риски проекта?")
        XCTAssertTrue(model.audioIssue.isEmpty)
        for data in StubURLProtocol.capturedBodies {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(body["tools"])
        }
        model.setMeetingEnabled(false); try await wait { !model.releasingAudio }
        XCTAssertFalse(model.transcript.isEmpty, "Stop preserves meeting evidence for the pending question")
        XCTAssertTrue(upstream.closed); XCTAssertGreaterThan(source.stopped, 0)
        let callsWhenStopped = StubURLProtocol.capturedRequests.count
        upstream.pair.continuation.yield(.final("Ещё один вопрос после выключения ассистента?"))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, callsWhenStopped,
                       "Turning off must stop extraction even if a late transcript event arrives")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        model.suspend(); XCTAssertTrue(model.transcript.isEmpty)
    }
    func testFencedQuestionsAndUsageFeatureAcrossAllProviders() async throws {
        for account in [ProviderAccount.openRouter, .openAI, .anthropic] {
            var (runner, _, _) = try fixture(account: account)
            var events: [AIUsageEvent] = []
            runner.usageSink = { events.append($0) }
            StubURLProtocol.handler = { _ in
                let text = "```json\n{\"questions\":[\"What changed?\"]}\n```"
                switch account {
                case .openAI: return self.serve(["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]])
                case .anthropic: return self.serve(["stop_reason": "end_turn", "content": [["type": "text", "text": text]]])
                default: return self.serve(["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": text]]]])
                }
            }
            let questions = try await runner.questions(transcript: "Could you explain what changed?", seen: [])
            XCTAssertEqual(questions, ["What changed?"])
            XCTAssertEqual(events.first?.context.feature, .meetingAssistant)
        }
    }
    func testConfiguredMeetingsStayOffUntilExplicitlyEnabledAndNextMeetingStartsOff() async throws {
        let (runner, root, defaults) = try fixture()
        let catalog = root.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try JSONEncoder().encode(space(root)).write(to: catalog.appendingPathComponent("project.json"))
        let probe = MeetingAssistantFixtureProbe()
        var sources: [FixtureSubtitleAudio] = []
        let audio = MeetingAssistantAudio(makeAudio: {
            let source = FixtureSubtitleAudio(); sources.append(source); return source
        }, open: { FixtureSubtitleUpstream() })
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(20), makeProbe: { probe })
        let model = MeetingAssistantModel(directory: catalog, defaults: defaults, runner: runner, audio: audio,
            meetingScope: scope, routesConfigured: { true })
        XCTAssertFalse(model.hoverState.visible)
        model.prepare()
        try await wait { probe.subscriptions == 1 }
        probe.emit(false)
        await model.reloadSpaces()
        XCTAssertTrue(sources.isEmpty, "Configuration alone must not capture outside meetings")
        probe.emit(true)
        try await wait { scope.isMeetingActive }
        await model.reloadSpaces()
        model.show(); model.dismiss()
        await model.reloadSpaces()
        XCTAssertFalse(model.listening)
        XCTAssertFalse(model.startRequested)
        XCTAssertTrue(sources.isEmpty, "A detected meeting, panel open and metadata refresh must not open audio")
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty, "Off must not send extraction requests")
        model.setMeetingEnabled(true)
        await model.reloadSpaces()
        try await wait { model.listening && audio.ready }
        XCTAssertTrue(model.visible, "An explicit enable shows the assistant")
        XCTAssertEqual(model.hoverState.phase, .listening)
        model.show(); model.dismiss()
        XCTAssertTrue(model.listening, "Closing answers must not disconnect a configured assistant")
        probe.emit(false)
        try await wait { !model.listening && !model.releasingAudio }
        XCTAssertEqual(model.hoverState.phase, .off); XCTAssertTrue(model.hoverState.visible)
        XCTAssertTrue(model.audioIssue.contains("выключено"))
        probe.emit(true)
        try await wait { scope.isMeetingActive }
        await model.reloadSpaces()
        XCTAssertFalse(model.listening)
        XCTAssertFalse(model.startRequested)
        XCTAssertEqual(sources.count, 1, "A later meeting must require its own explicit enable")
        model.setMeetingEnabled(true)
        await model.reloadSpaces()
        try await wait { model.listening && audio.ready && sources.count == 2 }
        XCTAssertTrue(sources.allSatisfy { $0.started == 1 })
        XCTAssertNil(defaults.object(forKey: "meetingAssistant.enabled"), "Model routes are the configuration; no extra switch")
        model.suspend()
    }

    func testWandOffStaysOffAcrossMeetingsAndRemovingConfigurationStopsMonitoring() async throws {
        let (runner, root, defaults) = try fixture()
        try JSONEncoder().encode(space(root)).write(to: root.appendingPathComponent("project.json"))
        let probe = MeetingAssistantFixtureProbe()
        var starts = 0, configured = true
        let audio = MeetingAssistantAudio(makeAudio: { starts += 1; return FixtureSubtitleAudio() }, open: { FixtureSubtitleUpstream() })
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(20), makeProbe: { probe })
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio,
            meetingScope: scope, routesConfigured: { configured })
        model.prepare(); try await wait { probe.subscriptions == 1 }
        probe.emit(true); try await wait { scope.isMeetingActive }
        await model.reloadSpaces()
        XCTAssertEqual(starts, 0)
        model.setMeetingEnabled(true)
        await model.reloadSpaces(); try await wait { audio.ready }
        model.setMeetingEnabled(false)
        try await wait { !model.releasingAudio }
        await model.reloadSpaces(); probe.emit(true)
        await model.reloadSpaces()
        XCTAssertFalse(model.listening); XCTAssertEqual(starts, 1)
        probe.emit(false); try await wait { !scope.isMeetingActive }
        probe.emit(true); try await wait { scope.isMeetingActive }
        await model.reloadSpaces()
        XCTAssertFalse(model.listening); XCTAssertEqual(starts, 1)
        model.setMeetingEnabled(true)
        await model.reloadSpaces(); try await wait { audio.ready && starts == 2 }
        configured = false; model.configurationChanged()
        try await wait { !model.releasingAudio }
        XCTAssertFalse(model.listening); XCTAssertEqual(probe.stops, 1)
        model.suspend()
    }

    func testUnconfiguredAndSuspendedAssistantCannotAutomaticallyCapture() async throws {
        let (runner, root, defaults) = try fixture()
        try JSONEncoder().encode(space(root)).write(to: root.appendingPathComponent("project.json"))
        let probe = MeetingAssistantFixtureProbe(), source = FixtureSubtitleAudio()
        var configured = false
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { FixtureSubtitleUpstream() })
        let scope = MeetingAssistantMeetingScope(makeProbe: { probe })
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio,
            meetingScope: scope, routesConfigured: { configured })
        await model.reloadSpaces()
        XCTAssertEqual(probe.subscriptions, 0); XCTAssertEqual(source.started, 0)
        configured = true; model.configurationChanged()
        try await wait { probe.subscriptions == 1 }
        probe.emit(true); try await wait { scope.isMeetingActive }
        await model.reloadSpaces()
        XCTAssertEqual(source.started, 0)
        model.setMeetingEnabled(true)
        await model.reloadSpaces(); try await wait { audio.ready }
        model.suspend()
        await model.reloadSpaces()
        try await wait { !model.releasingAudio }
        XCTAssertFalse(model.startRequested); XCTAssertFalse(model.listening)
        XCTAssertEqual(source.started, 1); XCTAssertEqual(probe.stops, 1)
    }

    func testFailedExplicitConnectionNeverRetriesWithoutAnotherExplicitEnable() async throws {
        let (runner, root, defaults) = try fixture()
        try JSONEncoder().encode(space(root)).write(to: root.appendingPathComponent("project.json"))
        let probe = MeetingAssistantFixtureProbe()
        var attempts = 0
        let audio = MeetingAssistantAudio(open: { attempts += 1; throw URLError(.notConnectedToInternet) })
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(20), makeProbe: { probe })
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio,
            meetingScope: scope, routesConfigured: { true })
        model.prepare(); try await wait { probe.subscriptions == 1 }
        probe.emit(true); try await wait { scope.isMeetingActive }
        await model.reloadSpaces()
        XCTAssertEqual(attempts, 0)
        model.setMeetingEnabled(true)
        await model.reloadSpaces(); try await wait { !model.audioIssue.isEmpty }
        for _ in 0..<3 { await model.reloadSpaces() }
        XCTAssertEqual(attempts, 1); XCTAssertFalse(model.listening)
        probe.emit(false); try await wait { !scope.isMeetingActive }
        probe.emit(true); try await wait { scope.isMeetingActive }
        await model.reloadSpaces()
        XCTAssertEqual(attempts, 1)
        model.setMeetingEnabled(true)
        await model.reloadSpaces(); try await wait { attempts == 2 }
        model.suspend()
    }

    func testTurningOffPendingHoverStartCannotOpenAudioLater() async throws {
        let (runner, root, defaults) = try fixture()
        try JSONEncoder().encode(space(root)).write(to: root.appendingPathComponent("project.json"))
        let source = FixtureSubtitleAudio(), upstream = FixtureSubtitleUpstream()
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { upstream })
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio)
        model.setMeetingEnabled(true); model.setMeetingEnabled(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.startRequested); XCTAssertFalse(model.listening); XCTAssertEqual(source.started, 0)
        model.dismiss()
    }

    func testStartupPreparationOnlyReadsMetadataWithoutWindowOrCapture() async throws {
        let (runner, root, defaults) = try fixture()
        try JSONEncoder().encode(space(root)).write(to: root.appendingPathComponent("project.json"))
        let source = FixtureSubtitleAudio(), upstream = FixtureSubtitleUpstream()
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { upstream })
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio, routesConfigured: { true })
        var hover = MeetingAssistantHoverState()
        let panel = MeetingAssistantPanel(model: model, protected: false, openSettings: { _ in }, activityChanged: { _, _ in },
            hoverChanged: { hover = $0 })
        panel.prepare()
        try await wait { hover.available }
        XCTAssertFalse(model.visible); XCTAssertFalse(model.listening); XCTAssertEqual(source.started, 0)
        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 0)
        XCTAssertEqual(hover.phase, .off)
        panel.suspend()
    }

    func testIdleStopNeverShowsCleanupAndRepeatedActiveStopKeepsItsGate() async throws {
        let (runner, root, defaults) = try fixture()
        let source = FixtureSubtitleAudio(), upstream = FixtureSubtitleUpstream()
        let audio = MeetingAssistantAudio(makeAudio: { source }, open: { upstream })
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, audio: audio)
        model.stopListening()
        XCTAssertFalse(model.releasingAudio); XCTAssertFalse(model.hoverState.visible)
        model.spaces = [space(root)]; model.selectedSpaceID = "project"
        model.startListening()
        XCTAssertTrue(audio.active)
        model.stopListening(); XCTAssertTrue(model.releasingAudio)
        model.stopListening(); XCTAssertTrue(model.releasingAudio, "A second stop must retain an existing cleanup gate")
        try await wait { !model.releasingAudio }
        model.dismiss()
        XCTAssertFalse(model.releasingAudio)
    }

    func testPassiveMetadataRefreshFindsSpaceCreatedAfterStartup() async throws {
        let (runner, root, defaults) = try fixture()
        let model = MeetingAssistantModel(directory: root, defaults: defaults, runner: runner, routesConfigured: { true })
        model.spaces = [space(root)]; model.selectedSpaceID = "project"
        let panel = MeetingAssistantPanel(model: model, protected: false, openSettings: { _ in }, activityChanged: { _, _ in })
        panel.prepare()
        try await wait { model.spaces.isEmpty }
        XCTAssertFalse(model.visible); XCTAssertFalse(model.hoverState.visible)
        try JSONEncoder().encode(space(root)).write(to: root.appendingPathComponent("project.json"))
        panel.prepare()
        try await wait { model.hoverState.available }
        XCTAssertFalse(model.visible); XCTAssertFalse(model.listening)
        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 0)
        panel.suspend()
    }

}
