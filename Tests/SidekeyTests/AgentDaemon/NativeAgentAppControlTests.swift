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
        let layout: HoverLayoutStore
        let hotkeys: HotkeyPreferences
        let defaults: UserDefaults
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
        let layout = HoverLayoutStore(defaults: defaults)
        let hotkeys = HotkeyPreferences(defaults: defaults)
        let controller = AppControlController(routing: routing, models: models,
            preferences: UserPreferencesCache(defaults: defaults), languages: PrivacyPreferences(defaults: defaults),
            idle: IslandIdlePreferences(defaults: defaults),
            identity: AppBuildIdentity(info: ["CFBundleVersion": "test-1"], bundleURL: URL(fileURLWithPath: "/tmp/Whytap.app")),
            activity: { .object(["drop": .string("idle")]) }, planner: { planner },
            googleCalendarReview: { false }, agentWorkspace: { directory.path },
            layout: { layout }, hotkeys: { hotkeys })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel(); StubURLProtocol.reset()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return Env(routing: routing, probe: probe, planner: planner, controller: controller, keys: keys,
                   directory: directory, http: NativeAgentHTTP(session: session),
                   layout: layout, hotkeys: hotkeys, defaults: defaults)
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
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    /// The model's call of the one whytap tool: operation + arguments string.
    private func app(_ operation: String, _ arguments: [String: Any], id: String) -> [String: Any] {
        call(NativeAgentAppControl.toolName, ["operation": operation, "arguments": json(arguments)], id: id)
    }
    private func dispatch(_ operation: String, _ arguments: [String: Any]) -> NativeAgentToolCall {
        NativeAgentToolCall(id: "x", name: NativeAgentAppControl.toolName,
                            arguments: ["operation": operation, "arguments": json(arguments)])
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
            app("whytap_get_state", [:], id: "s"),
            app("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
                                      "model": "candidate-text", "expected": [
                                        "account": "openRouter", "model": "old-text", "provider": "old/pin"]], id: "m"),
            final("Готово.")
        ])
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "candidate-text")
        XCTAssertEqual(result.finalText, "Drop Smart cleanup → candidate-text\n\nГотово.")
        XCTAssertTrue(result.labels.contains("Reading Whytap settings"))
        XCTAssertTrue(result.labels.contains("Drop Smart cleanup → candidate-text"), "\(result.labels)")
        XCTAssertEqual(result.events.last, .done(sources: []))
        // The model got the one whytap tool and the app-owned instructions.
        let first = try XCTUnwrap(result.bodies.first)
        let names = (first["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names.filter { $0.hasPrefix("whytap") }, [NativeAgentAppControl.toolName])
        let system = (first["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertTrue(system.contains("The whytap tool reads and changes this app itself"))
        XCTAssertFalse(result.toolResults().joined().contains("fake-provider-key"))
    }

    func testAddTaskWithStrictNullsSavesExactlyTheTask() async throws {
        let e = try env()
        let result = try await turn(e, "добавь задачу купить молоко", [
            app("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(),
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
            app("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(),
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
            app("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(), "tasks": [
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
            app("whytap_todo_add", ["titles": NSNull(), "parentID": NSNull(), "tasks": [
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
            app("whytap_todo_update", ["id": id, "title": NSNull(), "status": "", "parentID": NSNull(),
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
            app("whytap_list_models", ["feature": "dropSmartCleanup", "query": NSNull(), "account": NSNull(),
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
            app("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
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
            app("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
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
        // "hotkey" names keyboard shortcuts, not provider keys.
        XCTAssertFalse(names.contains { $0.replacingOccurrences(of: "hotkey", with: "").localizedCaseInsensitiveContains("key")
            || $0.contains("clipboard") })
        let result = try await turn(e, "покажи мой ключ OpenRouter", [
            app("whytap_get_key", ["account": "openRouter"], id: "k"),
            app("whytap_set_setting", ["key": "openRouterApiKey", "value": "x", "expected": NSNull()], id: "s"),
            app("whytap_get_settings", [:], id: "g"),
            final("Ключи нельзя показать.")
        ])
        let told = result.toolResults()
        XCTAssertTrue(told[0].contains("unknown_operation"), told[0])
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
                dispatch("whytap_list_models", arguments), handler: handler)
            XCTAssertTrue(result.text.contains("invalid_arguments"), "\(arguments): \(result.text)")
            XCTAssertNil(result.change)
        }
        let write = await NativeAgentAppControl.execute(dispatch("whytap_set_setting",
            ["key": "dropMode", "value": "turbo", "expected": "fast"]), handler: handler)
        XCTAssertTrue(write.text.contains("invalid_arguments"), write.text)
        XCTAssertNil(write.change)
        // The arguments string itself: not JSON, not an object, unknown operation.
        for call in [NativeAgentToolCall(id: "j", name: NativeAgentAppControl.toolName,
                                         arguments: ["operation": "whytap_get_state", "arguments": "{broken"]),
                     NativeAgentToolCall(id: "a", name: NativeAgentAppControl.toolName,
                                         arguments: ["operation": "whytap_get_state", "arguments": "[1,2]"]),
                     NativeAgentToolCall(id: "n", name: NativeAgentAppControl.toolName,
                                         arguments: ["operation": "whytap_get_state", "arguments": 42])] {
            let result = await NativeAgentAppControl.execute(call, handler: handler)
            XCTAssertTrue(result.text.contains("invalid_arguments"), result.text)
        }
        let unknown = await NativeAgentAppControl.execute(dispatch("whytap_delete_everything", [:]), handler: handler)
        XCTAssertTrue(unknown.text.contains("unknown_operation"), unknown.text)
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
    }

    func testSettingChangeLineComesFromSavedValue() async throws {
        let e = try env()
        let handler: NativeAgentAppControl.Handler = { await e.controller.handle($0) }
        let result = await NativeAgentAppControl.execute(dispatch("whytap_set_setting",
            ["key": "dropMode", "value": "smart", "expected": "fast"]), handler: handler)
        XCTAssertEqual(result.change, "Drop mode → Smart")
        let language = await NativeAgentAppControl.execute(dispatch("whytap_set_setting",
            ["key": "inputLanguage", "value": "ru", "expected": NSNull()]), handler: handler)
        XCTAssertEqual(language.change, "Input language → Russian")
    }

    func testWithoutTheAppTheAgentIsOfferedNoWhytapTools() async throws {
        let e = try env()
        let result = try await turn(e, "переключи модель", [
            app("whytap_set_model", ["feature": "dropSmartCleanup", "account": "openRouter",
                                      "model": "candidate-text", "expected": NSNull()], id: "m"),
            final("Не могу.")
        ], installed: false)
        let names = (result.bodies.first?["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(names.contains { $0.hasPrefix("whytap") })
        XCTAssertTrue(result.toolResults().first?.contains("unavailable") == true)
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
        let system = (result.bodies.first?["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertFalse(system.contains("whytap_"))
    }

    // MARK: Island tools and hotkeys

    private let defaultPinned = ["inputLang", "notes", "meetingRecord", "hotkeys", "monitor"]
    private func combo(_ keys: String) -> HotkeyShortcut { .combo(WhytapLink.linkCombo(from: keys)!) }
    /// US layout answers, so the lines do not depend on this Mac's layout.
    private func usKeyboard() {
        let saved = AppControlToolbox.keyboardCharacter
        AppControlToolbox.keyboardCharacter = { ["option+f": "ƒ", "option+s": "ß"][WhytapLink.linkKeys(for: $0)] }
        addTeardownBlock { await MainActor.run { AppControlToolbox.keyboardCharacter = saved } }
    }

    /// Maxim's acceptance request, word for word: "quick actions (hover)" is
    /// the island's hover tools and "option f" is ⌥F. One request pins Shot,
    /// assigns ⌥F and answers with one line that warns about ƒ.
    func testQuickActionsHoverShotWithOptionFIsOneLine() async throws {
        let e = try env()
        usKeyboard()
        let result = try await turn(e, "добавь мне shot в быстрые действия (ховер) и поставь хоткей option f", [
            app("whytap_toolbox_get", [:], id: "g"),
            app("whytap_toolbox_set", ["tool": "screenshot", "pinned": true, "expected": defaultPinned], id: "p"),
            app("whytap_hotkey_set", ["tool": "screenshot", "keys": "option f", "expected": NSNull()], id: "h"),
            final("Готово.")
        ])
        XCTAssertEqual(e.layout.slots.suffix(2), [.screenshot, .settings])
        XCTAssertEqual(e.hotkeys.toolShortcuts[.screenshot], combo("option+f"))
        XCTAssertEqual(result.finalText, "Toolbox + Shot · ⌥F (no longer types “ƒ” in text fields)\n\nГотово.")
        XCTAssertEqual(result.labels.last { $0.hasPrefix("Toolbox") }, "Toolbox + Shot · ⌥F (no longer types “ƒ” in text fields)")
        XCTAssertTrue(result.toolResults()[2].contains(#""typesInTextFields":"ƒ""#), result.toolResults()[2])
        // What lets the model map the words: the tool description and prompt.
        let first = try XCTUnwrap(result.bodies.first)
        let tools = first["tools"] as? [[String: Any]] ?? []
        let whytap = tools.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == NativeAgentAppControl.toolName }
        XCTAssertTrue((whytap?["description"] as? String ?? "").contains("quick actions the island shows on hover"))
        let system = (first["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertTrue(system.contains("hover tools (quick actions") && system.contains("\"option f\" means the keys option+f"))
    }

    /// Keys the rules refuse, or that another action owns, name the reason
    /// and the nearest free keys; nothing changes.
    func testRefusedKeysNameTheNearestFreeOnes() async throws {
        let e = try env()
        let result = try await turn(e, "поставь Shot на command f, или на option q", [
            app("whytap_hotkey_set", ["tool": "screenshot", "keys": "command+f", "expected": NSNull()], id: "a"),
            app("whytap_hotkey_set", ["tool": "screenshot", "keys": "option+q", "expected": NSNull()], id: "b"),
            final("Обе не подходят.")
        ])
        XCTAssertNil(e.hotkeys.toolShortcuts[.screenshot])
        let results = result.toolResults()
        XCTAssertTrue(results[0].contains("invalid_hotkey") && results[0].contains("Nearest free keys: option+f (⌥F)"), results[0])
        XCTAssertTrue(results[1].contains("Agent close") && results[1].contains("Nearest free keys: option+shift+q"), results[1])
        XCTAssertEqual(result.finalText, "Обе не подходят.")
    }

    func testTypedCharacterOnlyForOptionTypingKeys() {
        XCTAssertNil(AppControlToolbox.typedCharacter(WhytapLink.linkCombo(from: "control+option+f")!))
        XCTAssertNil(AppControlToolbox.typedCharacter(WhytapLink.linkCombo(from: "option+f5")!))
        XCTAssertNil(AppControlToolbox.typedCharacter(WhytapLink.linkCombo(from: "control+f")!))
        XCTAssertNotNil(AppControlToolbox.typedCharacter(WhytapLink.linkCombo(from: "option+f")!))
    }

    /// "добавь Shot и поставь ⌥S": both changes saved in the Settings stores,
    /// joined in one app-owned line, visible to a fresh store (Settings, island).
    func testAddShotWithOptionSSavesBothAndShowsOneLine() async throws {
        let e = try env()
        usKeyboard()
        let result = try await turn(e, "добавь в меню Shot и поставь ему ⌥S", [
            app("whytap_toolbox_get", [:], id: "g"),
            app("whytap_toolbox_set", ["tool": "screenshot", "pinned": true, "position": NSNull(),
                                        "expected": defaultPinned], id: "p"),
            app("whytap_hotkey_set", ["tool": "screenshot", "keys": "option+s", "expected": NSNull()], id: "h"),
            final("Готово.")
        ])
        XCTAssertEqual(e.layout.slots, [.inputLang, .notes, .meetingRecord, .hotkeys, .monitor, .screenshot, .settings])
        XCTAssertEqual(e.hotkeys.toolShortcuts[.screenshot], combo("option+s"))
        XCTAssertEqual(result.finalText, "Toolbox + Shot · ⌥S (no longer types “ß” in text fields)\n\nГотово.")
        XCTAssertTrue(result.labels.contains("Reading Whytap tools"), "\(result.labels)")
        XCTAssertTrue(result.labels.contains("Toolbox + Shot"), "\(result.labels)")
        XCTAssertTrue(result.labels.contains("Toolbox + Shot · ⌥S (no longer types “ß” in text fields)"), "\(result.labels)")
        // The read listed Shot unpinned with no hotkey, before the change.
        let read = try XCTUnwrap(result.toolResults().first)
        XCTAssertTrue(read.contains(#""hotkey":null"#) && read.contains(#""tool":"screenshot""#), read)
        // Saved where Settings and the island read them.
        XCTAssertEqual(HoverLayoutStore(defaults: e.defaults).slots, e.layout.slots)
        XCTAssertEqual(HotkeyPreferences(defaults: e.defaults).toolShortcuts[.screenshot], combo("option+s"))
        XCTAssertEqual(ToolHotkeyBinding.resolve(e.hotkeys.toolShortcuts).map(\.tool), [.screenshot])
    }

    /// "убери Monitor": gone from the island, its hotkey still works.
    func testRemoveMonitorKeepsItsHotkey() async throws {
        let e = try env()
        XCTAssertEqual(e.hotkeys.assignToolShortcut(combo("option+d"), to: .monitor), .saved)
        let result = try await turn(e, "убери Monitor из меню", [
            app("whytap_toolbox_set", ["tool": "monitor", "pinned": false, "expected": defaultPinned], id: "p"),
            final("Убрал.")
        ])
        XCTAssertEqual(e.layout.slots, [.inputLang, .notes, .meetingRecord, .hotkeys, .settings])
        XCTAssertEqual(e.hotkeys.toolShortcuts[.monitor], combo("option+d"))
        XCTAssertEqual(result.finalText, "Toolbox − Monitor\n\nУбрал.")
    }

    func testMovePinnedToolShowsItsNewPlace() async throws {
        let e = try env()
        let result = try await turn(e, "поставь Monitor первым", [
            app("whytap_toolbox_set", ["tool": "monitor", "pinned": true, "position": 1, "expected": defaultPinned], id: "p"),
            final("Готово.")
        ])
        XCTAssertEqual(e.layout.slots, [.monitor, .inputLang, .notes, .meetingRecord, .hotkeys, .settings])
        XCTAssertEqual(result.finalText, "Toolbox: Monitor → place 1\n\nГотово.")
    }

    /// Keys another action owns are refused, never taken over.
    func testHotkeyConflictChangesNothing() async throws {
        let e = try env()
        XCTAssertEqual(e.hotkeys.assignToolShortcut(combo("option+t"), to: .translate), .saved)
        let before = e.hotkeys.configuration
        let result = try await turn(e, "поставь Shot на ⌥Q, а если занято — на ⌥T", [
            app("whytap_hotkey_set", ["tool": "screenshot", "keys": "option+q", "expected": NSNull()], id: "a"),
            app("whytap_hotkey_set", ["tool": "screenshot", "keys": "option+t", "expected": NSNull()], id: "b"),
            final("Обе комбинации заняты.")
        ])
        XCTAssertEqual(e.hotkeys.configuration, before)
        XCTAssertNil(e.hotkeys.toolShortcuts[.screenshot])
        XCTAssertEqual(e.hotkeys.toolShortcuts[.translate], combo("option+t"))
        let results = result.toolResults()
        XCTAssertTrue(results[0].contains("hotkey_conflict") && results[0].contains("Agent close"), results[0])
        XCTAssertTrue(results[1].contains("hotkey_conflict") && results[1].contains("⌥T is already used by Translate"), results[1])
        XCTAssertEqual(result.finalText, "Обе комбинации заняты.")
    }

    /// The same request again changes nothing and shows no line.
    func testRepeatingAddShotWithOptionSIsQuiet() async throws {
        let e = try env()
        let steps = { (pinned: [String], hotkey: Any) in [
            self.app("whytap_toolbox_set", ["tool": "screenshot", "pinned": true, "expected": pinned], id: "p"),
            self.app("whytap_hotkey_set", ["tool": "screenshot", "keys": "option+s", "expected": hotkey], id: "h"),
            self.final("Готово.")
        ] }
        _ = try await turn(e, "добавь Shot и поставь ⌥S", steps(defaultPinned, NSNull()))
        let saved = (e.layout.slots, e.hotkeys.configuration)
        let again = try await turn(e, "добавь Shot и поставь ⌥S", steps(defaultPinned + ["screenshot"], "option+s"))
        XCTAssertEqual(e.layout.slots, saved.0)
        XCTAssertEqual(e.hotkeys.configuration, saved.1)
        XCTAssertEqual(again.finalText, "Готово.")
        let repeated = again.toolResults().suffix(2) // the stub keeps the first turn's bodies too
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(repeated.allSatisfy { $0.contains(#""changed":false"#) }, "\(repeated)")
        XCTAssertFalse(again.labels.contains { $0.hasPrefix("Toolbox") || $0.hasPrefix("Hotkey:") }, "\(again.labels)")
    }

    func testUnknownToolsDisallowedKeysAndStaleExpectedChangeNothing() async {
        let e = try! env()
        let layout = e.layout.slots, hotkeys = e.hotkeys.configuration
        func code(_ operation: String, _ arguments: [String: Any]) async -> String {
            let result = await NativeAgentAppControl.execute(dispatch(operation, arguments)) { request in
                await e.controller.handle(request)
            }
            XCTAssertNil(result.change, operation)
            return result.text
        }
        let cases: [(String, [String: Any], String)] = [
            ("whytap_toolbox_set", ["tool": "spotify", "pinned": true, "expected": defaultPinned], "unknown_tool"),
            ("whytap_hotkey_set", ["tool": "spotify", "keys": "option+s", "expected": NSNull()], "unknown_tool"),
            ("whytap_toolbox_set", ["tool": "settings", "pinned": false, "expected": defaultPinned], "not_movable"),
            ("whytap_toolbox_set", ["tool": "screenshot", "pinned": true, "expected": ["notes"]], "conflict"),
            ("whytap_toolbox_set", ["tool": "screenshot", "pinned": true, "position": 9, "expected": defaultPinned], "invalid_position"),
            ("whytap_toolbox_set", ["tool": "monitor", "pinned": false, "position": 1, "expected": defaultPinned], "invalid_arguments"),
            ("whytap_hotkey_set", ["tool": "quit", "keys": "option+x", "expected": NSNull()], "hotkey_not_allowed"),
            ("whytap_hotkey_set", ["tool": "screenshot", "keys": "command+s", "expected": NSNull()], "invalid_hotkey"),
            ("whytap_hotkey_set", ["tool": "screenshot", "keys": "shift+s", "expected": NSNull()], "invalid_hotkey"),
            ("whytap_hotkey_set", ["tool": "screenshot", "keys": "option+space", "expected": NSNull()], "invalid_hotkey"),
            ("whytap_hotkey_set", ["tool": "screenshot", "keys": "option+s", "expected": "option+x"], "conflict"),
            ("whytap_hotkey_set", ["tool": "screenshot", "keys": 5, "expected": NSNull()], "invalid_arguments"),
            ("whytap_toolbox_get", ["extra": true], "invalid_arguments"),
        ]
        for (operation, arguments, expected) in cases {
            let text = await code(operation, arguments)
            XCTAssertTrue(text.contains(#""code":"\#(expected)""#), "\(operation) \(arguments): \(text)")
        }
        XCTAssertEqual(e.layout.slots, layout)
        XCTAssertEqual(e.hotkeys.configuration, hotkeys)
    }

    /// Clearing a hotkey and spelling the expected keys in another order.
    func testClearHotkeyAcceptsAnyKeyOrderAsExpected() async throws {
        let e = try env()
        XCTAssertEqual(e.hotkeys.assignToolShortcut(combo("option+shift+s"), to: .screenshot), .saved)
        let result = try await turn(e, "сними хоткей у Shot", [
            app("whytap_hotkey_set", ["tool": "screenshot", "keys": NSNull(), "expected": "shift+option+s"], id: "h"),
            final("Снял.")
        ])
        XCTAssertNil(e.hotkeys.toolShortcuts[.screenshot])
        XCTAssertEqual(result.finalText, "Hotkey: Shot — none\n\nСнял.")
    }

    // MARK: Suggesting Whytap's own tools

    /// Build 1712: "Можешь сделать скриншот моего экрана?" got ⇧⌘3/⇧⌘4. The
    /// Agent reads the island's tools and suggests Shot with its own hotkey;
    /// it only suggests, nothing opens or changes.
    func testScreenshotRequestSuggestsShotWithItsHotkey() async throws {
        let e = try env()
        XCTAssertEqual(e.hotkeys.assignToolShortcut(combo("option+s"), to: .screenshot), .saved)
        let layout = e.layout.slots, hotkeys = e.hotkeys.configuration
        let result = try await turn(e, "Можешь сделать скриншот моего экрана?", [
            app("whytap_toolbox_get", [:], id: "g"),
            final("Нажми ⌥S — это Shot.")
        ])
        XCTAssertEqual(result.finalText, "Нажми ⌥S — это Shot.", "a read adds no change line")
        XCTAssertEqual(result.labels.first, "Reading Whytap tools")
        XCTAssertEqual(e.layout.slots, layout)
        XCTAssertEqual(e.hotkeys.configuration, hotkeys)
        // The read names Shot by the registry's own description and hotkey.
        let shot = try XCTUnwrap(toolEntry(result.toolResults().first, "screenshot"))
        XCTAssertEqual(shot["title"] as? String, "Shot")
        XCTAssertEqual(shot["description"] as? String, HoverToolRegistry.info(for: .screenshot).description)
        XCTAssertEqual((shot["hotkey"] as? [String: Any])?["display"] as? String, "⌥S")
        // The rule that makes the model do it, and only suggest.
        let first = try XCTUnwrap(result.bodies.first)
        let system = (first["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertTrue(system.contains("Whytap's own tools come first"))
        XCTAssertTrue(system.contains("\"Press ⌥S — that's Shot\""))
        XCTAssertTrue(system.contains("Do not recommend macOS shortcuts such as ⇧⌘3 or ⇧⌘4"))
        XCTAssertTrue(system.contains("never capture the screen to take a screenshot"))
        XCTAssertTrue(system.contains("Only suggest"))
    }

    /// No hotkey and not in the island: the read says so, so the Agent can
    /// point to the hover's search and offer a hotkey instead of a key.
    func testToolboxReadListsEveryRegistryToolForSuggestions() async throws {
        let e = try env()
        let response = await e.controller.handle(AppControlRequest("toolbox_get"))
        XCTAssertTrue(response.ok)
        let text = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let tools = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["data"]
            as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["tool"] as? String }, HoverTool.allCases.map(\.rawValue))
        for entry in tools {
            let tool = try XCTUnwrap(HoverTool(rawValue: entry["tool"] as? String ?? ""))
            XCTAssertEqual(entry["description"] as? String, HoverToolRegistry.info(for: tool).description, tool.rawValue)
        }
        let shot = try XCTUnwrap(toolEntry(text, "screenshot"))
        XCTAssertEqual(shot["pinned"] as? Bool, false)
        XCTAssertTrue(shot["hotkey"] is NSNull)
        XCTAssertEqual(shot["hotkeyAssignable"] as? Bool, true)
        // Suggesting never launches: no operation starts or opens a tool.
        let operations = NativeAgentAppControl.tools.map(\.operation)
        XCTAssertFalse(operations.contains { ["open_tool", "start", "launch", "run", "capture"].contains(where: $0.contains) }, "\(operations)")
    }

    private func toolEntry(_ result: String?, _ id: String) -> [String: Any]? {
        guard let result, let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              let tools = (object["data"] as? [String: Any])?["tools"] as? [[String: Any]] else { return nil }
        return tools.first { $0["tool"] as? String == id }
    }

    // MARK: Catalog contract

    func testOneToolCarriesEveryMCPOperationWithItsDescriptionAndSchema() throws {
        let mcp = AppControlMCPServer.tools.compactMap(\.object)
        XCTAssertEqual(NativeAgentAppControl.tools.count, mcp.count)
        let native = NativeAgentTools.structuredDefinitions(allowActions: false, appControl: true)
        XCTAssertFalse(native.contains { ($0["name"] as? String)?.hasPrefix("whytap_") == true })
        let tool = try XCTUnwrap(native.first { $0["name"] as? String == NativeAgentAppControl.toolName })
        XCTAssertEqual(tool["strict"] as? Bool, true)
        let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
        let operation = try XCTUnwrap((parameters["properties"] as? [String: Any])?["operation"] as? [String: Any])
        XCTAssertEqual(operation["enum"] as? [String], mcp.compactMap { $0["name"]?.string })
        let description = try XCTUnwrap(tool["description"] as? String)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for entry in mcp {
            let name = try XCTUnwrap(entry["name"]?.string)
            XCTAssertTrue(description.contains(name + ": " + (entry["description"]?.string ?? "-")), name)
            let schema = String(decoding: try encoder.encode(try XCTUnwrap(entry["inputSchema"])), as: UTF8.self)
            XCTAssertTrue(description.contains("Arguments schema: " + schema), name)
        }
    }

    /// Every first request must compile on each native route, with and
    /// without file edits and commands. Anthropic: at most 20 strict tools,
    /// 24 optional and 16 union parameters across them, no recursion
    /// (https://platform.claude.com/docs/en/build-with-claude/structured-outputs).
    /// OpenAI strict: every property required, closed objects, nesting <= 10.
    func testFirstRequestFitsStrictSchemaLimitsOnEveryRoute() async throws {
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (500, ["Content-Type": "application/json"], Data("{}".utf8)) }
        for provider in [OpenCodeModelProvider.anthropic, .openAI, .openRouter] {
            for allowActions in [false, true] {
                let options = AgentRunOptions(model: "synthetic-model", allowActions: allowActions, openCodeProvider: provider)
                var model = NativeAgentModel(options: options, key: "fixture-only", system: "Fixture", history: [],
                                             prompt: "Say hello", http: NativeAgentHTTP(session: session),
                                             usageSink: { _ in }, diagnosticsSink: { _ in })
                _ = try? await model.next(tools: NativeAgentTools.structuredDefinitions(allowActions: allowActions,
                                                                                     appControl: true),
                                          structuredCompletion: true)
                let label = "\(provider) allowActions=\(allowActions)"
                let data = try XCTUnwrap(StubURLProtocol.capturedBodies.last, label)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let tools = try XCTUnwrap(body["tools"] as? [[String: Any]], label)
                let strict = tools.map { $0["function"] as? [String: Any] ?? $0 }.filter { $0["strict"] as? Bool == true }
                XCTAssertEqual(strict.count, tools.count, label + ": one strict mode across the catalog")
                XCTAssertTrue(strict.contains { $0["name"] as? String == NativeAgentAppControl.toolName }, label)
                XCTAssertTrue(strict.contains { $0["name"] as? String == NativeAgentFinalAnswer.toolName }, label)
                // Island tools and hotkeys ride the same one tool, adding no strict tool.
                let whytap = try XCTUnwrap(strict.first { $0["name"] as? String == NativeAgentAppControl.toolName }, label)
                let schema = (whytap["input_schema"] ?? whytap["parameters"]) as? [String: Any]
                let operations = ((schema?["properties"] as? [String: Any])?["operation"] as? [String: Any])?["enum"] as? [String] ?? []
                XCTAssertTrue(Set(["whytap_toolbox_get", "whytap_toolbox_set", "whytap_hotkey_set"]).isSubset(of: operations), label)
                XCTAssertLessThanOrEqual(strict.count, 20, label)
                var count = SchemaCount()
                for tool in strict {
                    let schema = tool["input_schema"] ?? tool["parameters"] ?? NSNull()
                    count.visit(schema, depth: 1, path: label + "/" + (tool["name"] as? String ?? "?"))
                }
                XCTAssertLessThanOrEqual(count.unions, 16, label)
                XCTAssertLessThanOrEqual(count.optional, 24, label)
                XCTAssertLessThanOrEqual(count.depth, 10, label)
                XCTAssertTrue(count.problems.isEmpty, label + ": " + count.problems.joined(separator: "; "))
            }
        }
    }

    private struct SchemaCount {
        var unions = 0, optional = 0, depth = 0
        var problems: [String] = []
        mutating func visit(_ node: Any, depth level: Int, path: String) {
            guard let schema = node as? [String: Any] else { return }
            depth = max(depth, level)
            for banned in ["$ref", "$defs", "oneOf", "minLength", "maxLength", "maxItems", "minimum", "maximum"]
                where schema[banned] != nil { problems.append("\(path) has \(banned)") }
            let branches = schema["anyOf"] as? [Any] ?? []
            if !branches.isEmpty || schema["type"] is [Any] { unions += 1 }
            branches.forEach { visit($0, depth: level, path: path) }
            if schema["type"] as? String == "object" {
                let properties = schema["properties"] as? [String: Any] ?? [:]
                let required = Set(schema["required"] as? [String] ?? [])
                optional += properties.keys.filter { !required.contains($0) }.count
                if schema["additionalProperties"] as? Bool != false { problems.append("\(path) is open") }
                for (key, value) in properties { visit(value, depth: level + 1, path: path + "." + key) }
            }
            if let items = schema["items"] { visit(items, depth: level + 1, path: path + "[]") }
        }
    }

    func testInstructionsKeepTheSingleReplyLanguageRule() {
        XCTAssertFalse(NativeAgentAppControl.instructions.contains("language"))
        let combined = NativeAgentProvider.systemPrompt + NativeAgentAppControl.instructions
        XCTAssertEqual(combined.components(separatedBy: "language").count - 1, 1)
    }
}
