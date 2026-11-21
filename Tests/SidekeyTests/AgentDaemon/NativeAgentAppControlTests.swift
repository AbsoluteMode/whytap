import XCTest
import WhytapCaseKit
@testable import Sidekey

private actor AgentControlProbe: ModelProbing {
    var outcome: ProbeOutcome = .passed
    var calls = 0
    func configure(_ outcome: ProbeOutcome) { self.outcome = outcome }
    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
        calls += 1
        return outcome
    }
}

private struct OfflineCatalog: ModelCatalogFetching {
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        throw CatalogFetchError.offline
    }
}

private struct NoEndpoints: OpenRouterEndpointsFetching {
    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
}

/// The built-in agent controls Whytap with the plugin's own tools, in process.
/// Each scenario runs the real native loop against a stubbed model and the
/// real AppControlController on temporary stores.
@MainActor
final class NativeAgentAppControlTests: XCTestCase {
    private struct Env {
        let routing: AIRoutingStore
        let probe: AgentControlProbe
        let planner: PlannerStore
        let controller: AppControlController
        let keys: ProviderKeyStore
        let directory: URL
        let http: NativeAgentHTTP
    }

    private let oldRoute: AppControlValue = .object(["account": .string("openRouter"), "model": .string("old-text"),
                                                     "provider": .string("old/pin")])

    private func env() throws -> Env {
        StubURLProtocol.reset()
        let suite = "native-app-control-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogFile = directory.appendingPathComponent("catalog.json")
        let snapshot = CatalogSnapshot(models: [CatalogModel(id: "candidate-text", uses: [.chat])], fetchedAt: Date(),
                                       lastRefreshFailed: false, limited: false)
        try JSONEncoder().encode(["openRouter": snapshot]).write(to: catalogFile)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let routing = AIRoutingStore(defaults: defaults)
        try keys.save("fake-provider-key-not-for-output", account: ProviderAccount.openRouter.keychainAccount(in: routing)!)
        try keys.save("router-secret", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "old-text", provider: "old/pin"), for: .dropSmartCleanup)
        let probe = AgentControlProbe()
        let models = APIAndModelsViewModel(routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: catalogFile, fetcher: OfflineCatalog()),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            probe: probe, endpoints: NoEndpoints(), inputLanguage: { nil })
        let planner = PlannerStore(url: directory.appendingPathComponent("Planner/planner-v1.json"))
        let controller = AppControlController(routing: routing, models: models,
            preferences: UserPreferencesCache(defaults: defaults), languages: PrivacyPreferences(defaults: defaults),
            idle: IslandIdlePreferences(defaults: defaults),
            identity: AppBuildIdentity(info: ["CFBundleVersion": "test-1"], bundleURL: URL(fileURLWithPath: "/tmp/Whytap.app")),
            activity: { .object(["drop": .string("idle")]) }, planner: { planner },
            googleCalendarReview: { false }, agentWorkspace: { directory.path })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel(); StubURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return Env(routing: routing, probe: probe, planner: planner, controller: controller, keys: keys,
                   directory: directory, http: NativeAgentHTTP(session: session))
    }

    // MARK: Model stub

    private func serve(_ object: [String: Any]) -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }
    private func call(_ name: String, _ arguments: [String: Any], id: String) -> [String: Any] {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [
            ["id": id, "type": "function", "function": ["name": name, "arguments": text]]]],
            "finish_reason": "tool_calls"]], "usage": ["cost": 0.001]]
    }
    private func final(_ answer: String) -> [String: Any] {
        call("finish_answer", ["status": "answered", "answer": answer, "sources": [], "actions": []], id: "final")
    }

    private struct Turn {
        let events: [AgentSSEEvent]
        let bodies: [[String: Any]]
        var finalText: String? {
            events.compactMap { if case .finalAnswer(let text) = $0 { return text }; return nil }.last
        }
        var labels: [String] {
            events.compactMap { if case .toolExecuting(_, let label) = $0 { return label }; return nil }
        }
        /// What the model was told by each tool, in order.
        func toolResults() -> [String] {
            bodies.dropFirst().compactMap { body in
                (body["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "tool" }?["content"] as? String
            }
        }
    }

    /// Runs one native agent turn whose model replies with `steps` in order.
    private func turn(_ e: Env, _ prompt: String, _ steps: [[String: Any]],
                      installed: Bool = true) async throws -> Turn {
        var index = 0
        StubURLProtocol.handler = { _ in
            defer { index += 1 }
            return self.serve(steps[min(index, steps.count - 1)])
        }
        let controller = e.controller
        var handler: NativeAgentAppControl.Handler?
        if installed { handler = { request in await controller.handle(request) } }
        let installedHandler = handler
        let provider = NativeAgentProvider(keys: e.keys, http: e.http, workspace: { e.directory },
                                           appControl: { installedHandler },
                                           usageSink: { _ in }, diagnosticsSink: { _ in })
        var events: [AgentSSEEvent] = []
        let options = AgentRunOptions(model: "vendor/agent-model", allowActions: false)
        for await event in provider.run(prompt: prompt, resumeSessionID: nil, options: options) {
            events.append(event)
        }
        let bodies = try StubURLProtocol.capturedBodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        return Turn(events: events, bodies: bodies)
    }

    // MARK: Scenarios

    func testSwitchDropSmartCleanupModelShowsOneConfirmedLine() async throws {
        let e = try env()
        let result = try await turn(e, "переключи Drop Smart cleanup на candidate-text", [
            call("whytap_get_state", [:], id: "s"),
            call("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
                                      "model": "candidate-text", "expected": [
                                        "account": "openRouter", "model": "old-text", "provider": "old/pin"]], id: "m"),
            final("Готово.")
        ])
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "candidate-text")
        XCTAssertEqual(result.finalText, "Drop Smart cleanup → candidate-text\n\nГотово.")
        XCTAssertTrue(result.labels.contains("Reading Whytap settings"))
        XCTAssertTrue(result.labels.contains("Drop Smart cleanup → candidate-text"), "\(result.labels)")
        XCTAssertEqual(result.events.last, .done(sources: []))
        // The model got the same tools and the app-owned instructions.
        let first = try XCTUnwrap(result.bodies.first)
        let names = (first["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(Set(AppControlMCPServer.tools.compactMap { $0.object?["name"]?.string }).isSubset(of: Set(names)))
        let system = (first["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertTrue(system.contains("Whytap tools (whytap_*) read and change this app itself"))
        XCTAssertFalse(result.toolResults().joined().contains("fake-provider-key"))
    }

    func testAddTaskWithStrictNullsSavesExactlyTheTask() async throws {
        let e = try env()
        let result = try await turn(e, "добавь задачу купить молоко", [
            call("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(),
                                     "tasks": [["title": "Купить молоко", "status": NSNull(), "children": NSNull()]]], id: "t"),
            final("Добавил.")
        ])
        e.planner.refreshFromDisk()
        XCTAssertEqual(e.planner.archive.tasks.map(\.node.title), ["Купить молоко"])
        XCTAssertNil(e.planner.archive.tasks.first?.node.status)
        XCTAssertEqual(result.finalText, "To-do + Купить молоко\n\nДобавил.")
    }

    // Regression (build queue ticket 368): todo_add reuses an active task with
    // the same title and saves the new status on it as "existing".
    func testTodoAddStatusOnReusedTaskShowsTheSavedChange() async throws {
        let e = try env()
        let seeded = await e.controller.handle(AppControlRequest("todo_add", arguments: ["tasks": .array([
            .object(["title": .string("Review agent"), "status": .string("waiting")])
        ])]))
        XCTAssertTrue(seeded.ok)
        let original = try XCTUnwrap(e.planner.archive.tasks.first?.node)
        let result = try await turn(e, "Add Review agent with the status ready", [
            call("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(),
                                     "tasks": [["title": "Review agent", "status": "ready", "children": NSNull()]]], id: "t"),
            final("Recorded.")
        ])
        e.planner.refreshFromDisk()
        XCTAssertEqual(e.planner.archive.tasks.count, 1)
        XCTAssertEqual(e.planner.archive.tasks.first?.node.id, original.id)
        XCTAssertEqual(e.planner.archive.tasks.first?.node.status, "ready")
        XCTAssertTrue(result.toolResults().first?.contains("\"result\":\"existing\"") == true)
        XCTAssertTrue(result.labels.contains("To-do: Review agent — ready"), "\(result.labels)")
        XCTAssertEqual(result.finalText, "To-do: Review agent — ready\n\nRecorded.")
    }

    func testRepeatedIdenticalTodoAddStaysQuiet() async throws {
        let e = try env()
        _ = await e.controller.handle(AppControlRequest("todo_add", arguments: ["tasks": .array([
            .object(["title": .string("Review agent"), "status": .string("waiting")])])]))
        _ = await e.controller.handle(AppControlRequest("todo_add", arguments: ["titles": .array([.string("Plain")])]))
        let result = try await turn(e, "Add Review agent (waiting) and Plain again", [
            call("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(), "tasks": [
                ["title": "Review agent", "status": "waiting", "children": NSNull()],
                ["title": "Plain", "status": NSNull(), "children": NSNull()]]], id: "t"),
            final("Already there.")
        ])
        e.planner.refreshFromDisk()
        XCTAssertEqual(e.planner.archive.tasks.count, 2)
        XCTAssertFalse(result.labels.contains { $0.hasPrefix("To-do") }, "\(result.labels)")
        XCTAssertEqual(result.finalText, "Already there.", "A retry that changes nothing adds no line")
    }

    func testTodoAddReportsNewAndUpdatedTasksTogether() async throws {
        let e = try env()
        _ = await e.controller.handle(AppControlRequest("todo_add", arguments: ["titles": .array([.string("Report")])]))
        let result = try await turn(e, "Report is in review, add Send it", [
            call("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(), "tasks": [
                ["title": "Report", "status": "in review", "children": NSNull()],
                ["title": "Send it", "status": NSNull(), "children": NSNull()]]], id: "t"),
            final("Done.")
        ])
        XCTAssertEqual(result.finalText, "To-do + 1 added, 1 updated\n\nDone.")
    }

    func testClearingStatusAndKeepingParentUseEmptyStringAndNull() async throws {
        let e = try env()
        let added = await e.controller.handle(AppControlRequest("todo_add", arguments: ["tasks": .array([
            .object(["title": .string("Отчёт"), "status": .string("жду данных")])])]))
        let id = try XCTUnwrap(added.data.object?["tasks"]?.array?.first?.object?["id"]?.string)
        let result = try await turn(e, "убери статус у задачи Отчёт и закрой её", [
            call("whytap_todo_update", ["id": id, "title": NSNull(), "status": "", "parentID": NSNull(),
                                        "completed": true], id: "u"),
            final("Сделано.")
        ])
        e.planner.refreshFromDisk()
        let node = try XCTUnwrap(e.planner.archive.tasks.first?.node)
        XCTAssertNil(node.status)
        XCTAssertNil(node.parentID)
        XCTAssertTrue(node.completed)
        XCTAssertEqual(result.finalText, "To-do: Отчёт ✓\n\nСделано.")
    }

    func testListModelsAnswersFromTheAppCatalogWithoutAChange() async throws {
        let e = try env()
        let result = try await turn(e, "какие у меня модели для Drop Smart cleanup", [
            call("whytap_list_models", ["feature": "dropSmartCleanup", "query": NSNull(), "account": NSNull(),
                                        "limit": NSNull()], id: "l"),
            final("candidate-text")
        ])
        let told = result.toolResults().joined()
        XCTAssertTrue(told.contains("\"ok\":true"), told)
        XCTAssertTrue(told.contains("candidate-text"), told)
        XCTAssertEqual(result.finalText, "candidate-text", "Reads add no change line")
        XCTAssertTrue(result.labels.contains("Looking up models"))
        let calls = await e.probe.calls
        XCTAssertEqual(calls, 0)
    }

    func testUnknownModelIsRefusedByTheSettingsCheckAndKeepsTheRoute() async throws {
        let e = try env()
        await e.probe.configure(.failed(reason: "model not found"))
        let result = try await turn(e, "поставь Drop Smart cleanup на no-such-model", [
            call("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
                                      "model": "no-such-model", "expected": [
                                        "account": "openRouter", "model": "old-text", "provider": "old/pin"]], id: "m"),
            final("Не получилось: такой модели нет.")
        ])
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
        XCTAssertTrue(result.toolResults().joined().contains("model_not_selected"))
        XCTAssertEqual(result.finalText, "Не получилось: такой модели нет.", "No change line without a change")
    }

    func testStaleExpectedValueIsAConflictAndChangesNothing() async throws {
        let e = try env()
        let result = try await turn(e, "переключи Drop Smart cleanup на candidate-text", [
            call("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
                                      "model": "candidate-text", "expected": NSNull()], id: "m"),
            final("Значение изменилось, перечитаю.")
        ])
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
        XCTAssertTrue(result.toolResults().joined().contains("\"conflict\""))
        XCTAssertFalse(result.labels.contains { $0.contains("→") })
        let calls = await e.probe.calls
        XCTAssertEqual(calls, 0, "A conflict never reaches the paid check")
    }

    func testKeyRequestHasNoToolAndReadsNeverContainKeys() async throws {
        let e = try env()
        let names = NativeAgentAppControl.tools.map(\.name)
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("key") || $0.contains("clipboard") })
        let result = try await turn(e, "покажи мой ключ OpenRouter", [
            call("whytap_get_key", ["account": "openRouter"], id: "k"),
            call("whytap_set_setting", ["key": "openRouterApiKey", "value": "x", "expected": NSNull()], id: "s"),
            call("whytap_get_settings", [:], id: "g"),
            final("Ключи нельзя показать.")
        ])
        let told = result.toolResults()
        XCTAssertTrue(told[0].contains("unavailable"), told[0])
        XCTAssertTrue(told[1].contains("invalid_arguments"), told[1])
        XCTAssertFalse(told.joined().contains("fake-provider-key"))
        XCTAssertFalse(told.joined().contains("router-secret"))
        XCTAssertEqual(result.finalText, "Ключи нельзя показать.")
    }

    func testBrokenArgumentsAreRejectedWithoutSideEffects() async throws {
        let e = try env()
        let handler: NativeAgentAppControl.Handler = { await e.controller.handle($0) }
        for arguments: [String: Any] in [["feature": 5], ["feature": "dropSmartCleanup", "bogus": "x"],
                                         ["feature": "noSuchFeature"], ["feature": ["nested": true]]] {
            let result = await NativeAgentAppControl.execute(
                NativeAgentToolCall(id: "x", name: "whytap_list_models", arguments: arguments), handler: handler)
            XCTAssertTrue(result.text.contains("invalid_arguments"), "\(arguments): \(result.text)")
            XCTAssertNil(result.change)
        }
        let write = await NativeAgentAppControl.execute(NativeAgentToolCall(id: "w", name: "whytap_set_setting",
            arguments: ["key": "dropMode", "value": "turbo", "expected": "fast"]), handler: handler)
        XCTAssertTrue(write.text.contains("invalid_arguments"), write.text)
        XCTAssertNil(write.change)
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
    }

    func testSettingChangeLineComesFromSavedValue() async throws {
        let e = try env()
        let handler: NativeAgentAppControl.Handler = { await e.controller.handle($0) }
        let result = await NativeAgentAppControl.execute(NativeAgentToolCall(id: "w", name: "whytap_set_setting",
            arguments: ["key": "dropMode", "value": "smart", "expected": "fast"]), handler: handler)
        XCTAssertEqual(result.change, "Drop mode → Smart")
        let language = await NativeAgentAppControl.execute(NativeAgentToolCall(id: "l", name: "whytap_set_setting",
            arguments: ["key": "inputLanguage", "value": "ru", "expected": NSNull()]), handler: handler)
        XCTAssertEqual(language.change, "Input language → Russian")
    }

    func testWithoutTheAppTheAgentIsOfferedNoWhytapTools() async throws {
        let e = try env()
        let result = try await turn(e, "переключи модель", [
            call("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
                                      "model": "candidate-text", "expected": NSNull()], id: "m"),
            final("Не могу.")
        ], installed: false)
        let names = (result.bodies.first?["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(names.contains { $0.hasPrefix("whytap_") })
        XCTAssertTrue(result.toolResults().first?.contains("unavailable") == true)
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
        let system = (result.bodies.first?["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertFalse(system.contains("whytap_"))
    }

    // MARK: Catalog contract

    func testDescriptionsAndNamesComeFromTheMCPCatalogAndSchemasAreStrict() throws {
        let mcp = AppControlMCPServer.tools.compactMap(\.object)
        let native = NativeAgentTools.structuredDefinitions(allowActions: false, appControl: true)
        XCTAssertEqual(NativeAgentAppControl.tools.count, mcp.count)
        for tool in mcp {
            let name = try XCTUnwrap(tool["name"]?.string)
            let definition = try XCTUnwrap(native.first { $0["name"] as? String == name }, name)
            XCTAssertEqual(definition["description"] as? String, tool["description"]?.string, name)
            XCTAssertEqual(definition["strict"] as? Bool, true, name)
            try assertStrict(definition["parameters"] as Any, path: name)
        }
        // To-do nesting keeps its five levels without a recursive $ref.
        let add = try XCTUnwrap(native.first { $0["name"] as? String == "whytap_todo_add" })
        var depth = 0
        var level = ((add["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["tasks"]
        while let array = (level as? [String: Any])?["anyOf"].flatMap({ ($0 as? [[String: Any]])?.first }) ?? (level as? [String: Any]),
              let item = array["items"] as? [String: Any] {
            depth += 1
            level = (item["properties"] as? [String: Any])?["children"]
        }
        XCTAssertEqual(depth, TodoTree.maxDepth)
    }

    private func assertStrict(_ schema: Any, path: String) throws {
        if let list = schema as? [Any] { for item in list { try assertStrict(item, path: path) }; return }
        guard let object = schema as? [String: Any] else { return }
        for banned in ["$ref", "$defs", "minLength", "maxLength", "minItems", "maxItems", "minimum", "maximum"] {
            XCTAssertNil(object[banned], "\(path) has \(banned)")
        }
        if let type = object["type"] { XCTAssertTrue(type is String, "\(path) uses a type list") }
        if object["type"] as? String == "object" {
            XCTAssertEqual(object["additionalProperties"] as? Bool, false, path)
            let properties = object["properties"] as? [String: Any] ?? [:]
            XCTAssertEqual(Set(object["required"] as? [String] ?? []), Set(properties.keys), path)
            for (key, value) in properties { try assertStrict(value, path: path + "." + key) }
        }
        if let items = object["items"] { try assertStrict(items, path: path + "[]") }
        if let anyOf = object["anyOf"] { try assertStrict(anyOf, path: path) }
    }

    func testInstructionsKeepTheSingleReplyLanguageRule() {
        XCTAssertFalse(NativeAgentAppControl.instructions.contains("language"))
        let combined = NativeAgentProvider.systemPrompt + NativeAgentAppControl.instructions
        XCTAssertEqual(combined.components(separatedBy: "language").count - 1, 1)
    }
}
