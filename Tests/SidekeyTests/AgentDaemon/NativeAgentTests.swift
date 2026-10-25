import AppKit
import SwiftUI
import WhytapCaseKit
import XCTest
@testable import Sidekey

@MainActor
final class NativeAgentTests: XCTestCase {
    private func fixture() throws -> (URL, ProviderKeyStore, NativeAgentHTTP) {
        StubURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset(); try? FileManager.default.removeItem(at: directory) }
        return (directory, keys, NativeAgentHTTP(session: session))
    }

    private func serve(_ object: [String: Any]) -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    private func router(_ message: [String: Any], finish: String = "stop") -> [String: Any] {
        ["choices": [["message": message, "finish_reason": finish]], "usage": ["cost": 0.001]]
    }

    private func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[index]) as? [String: Any])
    }

    func testFirstRequestHasToolsAndExactRouteWithoutBootstrapAndActionsStayOutOfText() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("router-secret", account: OpenRouterLLMKeyStore.account)
        try keys.save("wrong-openai-secret", account: ProviderAccount.openAIKeychainAccount)
        try Data("Prefer Russian.".utf8).write(to: directory.appendingPathComponent("AGENTS.md"))
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 { return self.serve(self.router(["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "action", "type": "function", "function": ["name": "show_actions", "arguments": "{\"items\":[{\"type\":\"path\",\"path\":\"/tmp/project\",\"description\":\"Открыть папку\"}]}"]]
            ]], finish: "tool_calls")) }
            return self.serve(self.router(["role": "assistant", "content": "Проект здесь:\n```\n/tmp/project\n``` "]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "Where is the project?", resumeSessionID: nil,
            options: .init(model: "vendor/exact-model", allowActions: false, openRouterProvider: "endpoint/pin")) { events.append(event) }
        XCTAssertEqual(calls, 2, "No version check, catalog fetch, MCP bootstrap or extra model request")
        let first = try body(0)
        XCTAssertEqual(first["model"] as? String, "vendor/exact-model")
        XCTAssertEqual((first["provider"] as? [String: Any])?["only"] as? [String], ["endpoint/pin"])
        let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "web_search" })
        XCTAssertFalse(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "run_command" })
        XCTAssertEqual(StubURLProtocol.capturedRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer router-secret")
        XCTAssertFalse(String(decoding: StubURLProtocol.capturedBodies[0], as: UTF8.self).contains("wrong-openai-secret"))
        XCTAssertTrue(events.contains { if case .blockComplete(.usefulActions(let block)) = $0 { return block.items.count == 1 }; return false })
        XCTAssertTrue(events.contains(.finalAnswer(text: "Проект здесь:\n```\n/tmp/project\n```")))
        XCTAssertEqual(events.last, .done(sources: []))
        XCTAssertNotNil(provider.lastSessionID)
        let saved = try String(contentsOf: directory.appendingPathComponent(NativeAgentConversation.fileName), encoding: .utf8)
        XCTAssertFalse(saved.contains("tool_calls")); XCTAssertFalse(saved.contains("base64"))
        XCTAssertFalse(saved.contains("Prefer Russian"), "Memory is supplied once, not duplicated into history")
    }

    func testPlainFinalLinksAndFoundFoldersEmitKeyboardActionsWithoutExtraModelCalls() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        let folder = directory.appendingPathComponent("My Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let answer = "Источник: https://example.com/source\nПапка: `\(folder.path)`"
        StubURLProtocol.handler = { _ in self.serve(self.router(["role": "assistant", "content": answer])) }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var items: [ActionItem] = []
        var final: String?
        for await event in provider.run(prompt: "Find the source and folder", resumeSessionID: nil, options: .init(model: "model", allowActions: false)) {
            if case .blockComplete(.usefulActions(let block)) = event { items = block.items }
            if case .finalAnswer(let text) = event { final = text }
        }
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "Artifact presentation must not need another model or tool request")
        XCTAssertEqual(final, answer)
        XCTAssertEqual(items.map(\.insertText), ["https://example.com/source", folder.path])
        let selection = UsefulLinksSelectionState(items: items)
        XCTAssertTrue(selection.selectedItemSupportsOpen)
        selection.selectNext()
        XCTAssertEqual(selection.selectedItem?.openTarget?.path, folder.path)
        XCTAssertEqual(selection.selectedItem?.insertText, folder.path)
    }

    func testOpenAIResponsesRetainsReasoningAndCallIDAndReturnsImage() async throws {
        let (_, _, http) = try fixture()
        var count = 0
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            count += 1
            return self.serve(count == 1 ? ["status": "completed", "output": [
                ["type": "reasoning", "id": "r1", "summary": [], "encrypted_content": "opaque"],
                ["type": "function_call", "call_id": "fc1", "name": "capture_screen", "arguments": "{}"]
            ]] : ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Visible fixture."]]]]])
        }
        var model = NativeAgentModel(options: .init(model: "exact-openai", openCodeProvider: .openAI), key: "own-openai-key", system: "system",
                                     history: [], prompt: "Read the screen", http: http, usageSink: { _ in })
        let (_, calls) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        model.append(results: [(calls[0], .init(text: "Captured", image: "synthetic-pixels"))])
        let (answer, _) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        XCTAssertEqual(answer, "Visible fixture.")
        let next = try body(1)
        XCTAssertEqual(next["store"] as? Bool, false)
        XCTAssertEqual(next["include"] as? [String], ["reasoning.encrypted_content"])
        let input = try XCTUnwrap(next["input"] as? [[String: Any]])
        XCTAssertTrue(input.contains { $0["encrypted_content"] as? String == "opaque" })
        XCTAssertTrue(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "fc1" })
        XCTAssertTrue(String(decoding: StubURLProtocol.capturedBodies[1], as: UTF8.self).replacingOccurrences(of: "\\/", with: "/").contains("data:image/jpeg;base64,synthetic-pixels"))
        XCTAssertEqual(StubURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer own-openai-key")
    }

    func testAnthropicToolResultPreservesThinkingSignatureAndImage() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
            return self.serve(["stop_reason": "tool_use", "content": [
                ["type": "thinking", "thinking": "reasoning", "signature": "signed"],
                ["type": "tool_use", "id": "tool1", "name": "capture_screen", "input": [:]]
            ]])
        }
        var model = NativeAgentModel(options: .init(model: "exact-anthropic", openCodeProvider: .anthropic), key: "anthropic-key", system: "system", history: [], prompt: "screen", http: http, usageSink: { _ in })
        let (_, calls) = try await model.next(tools: NativeAgentTools.definitions(allowActions: false))
        model.append(results: [(calls[0], .init(text: "Captured", image: "pixels", mimeType: "image/png"))])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: model.messages), as: UTF8.self)
        XCTAssertTrue(encoded.contains("signed")); XCTAssertTrue(encoded.contains("tool_use_id")); XCTAssertTrue(encoded.replacingOccurrences(of: "\\/", with: "/").contains("image/png"))
        XCTAssertEqual((model.messages.last?["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String, "tool1")
    }

    func testOpenRouterPreservesNativeReasoningAndToolPairing() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { _ in self.serve(self.router(["role": "assistant", "content": NSNull(),
            "reasoning_details": [["type": "reasoning.encrypted", "data": "opaque-state"]],
            "tool_calls": [["id": "id1", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"file\"}"]]]], finish: "tool_calls")) }
        var model = NativeAgentModel(options: .init(model: "vendor/model"), key: "key", system: "system", history: [], prompt: "read", http: http, usageSink: { _ in })
        let (_, calls) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        model.append(results: [(calls[0], .init(text: "result"))])
        XCTAssertEqual(model.messages.last?["tool_call_id"] as? String, "id1")
        XCTAssertNotNil(model.messages[1]["reasoning_details"])
    }

    func testDisabledActionsAreEnforcedEvenWhenModelRequestsHiddenTool() async throws {
        let (directory, keys, _) = try fixture()
        let tools = NativeAgentTools(directory: directory, allowActions: false, keys: keys)
        let result = await tools.execute(.init(id: "1", name: "write_file", arguments: ["path": "forbidden.txt", "content": "bad"]))
        XCTAssertTrue(result.text.contains("unavailable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden.txt").path))
        let command = await tools.execute(.init(id: "2", name: "run_command", arguments: ["command": "touch forbidden.txt"]))
        XCTAssertTrue(command.text.contains("unavailable"))
    }

    func testTavilySendsOnlyQueryWithItsOwnKeyAndBoundsResults() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.tavily.com/search")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tavily-secret")
            return self.serve(["results": (0..<8).map { ["url": "https://example.com/\($0)", "title": "Title", "content": String(repeating: "a", count: 5000)] }])
        }
        let result = try await TavilySearch(http: http).search(query: "current weather", key: "tavily-secret")
        let sent = try body(0)
        XCTAssertEqual(sent["query"] as? String, "current weather")
        XCTAssertEqual(sent["search_depth"] as? String, "basic")
        XCTAssertEqual(sent["include_raw_content"] as? Bool, false)
        XCTAssertNil(sent["messages"]); XCTAssertNil(sent["api_key"])
        let results = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])?["results"] as? [[String: String]])
        XCTAssertEqual(results.count, 5); XCTAssertEqual(results[0]["content"]?.count, 3000)
    }

    func testTavilyValidatesWithoutPaidSearchAndFailedReplacementPreservesKey() async throws {
        let (_, keys, http) = try fixture()
        try keys.save("old-key", account: TavilySearch.keychainAccount)
        let settings = TavilySettings(keys: keys, search: .init(http: http))
        settings.draftKey = "bad-key"
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/usage")
            return (401, [:], Data("private provider response".utf8))
        }
        await settings.save()
        XCTAssertEqual(keys.read(account: TavilySearch.keychainAccount), "old-key")
        XCTAssertTrue(settings.configured)
        XCTAssertTrue(settings.messageIsError)
        XCTAssertTrue(settings.message?.contains("Check the key and connection") == true)
        settings.draftKey = "retry-key"
        XCTAssertNil(settings.message, "Editing the replacement clears its old validation error")
        XCTAssertFalse(settings.messageIsError)
        await settings.save()
        XCTAssertNotNil(settings.message)
        settings.clearDraft()
        XCTAssertTrue(settings.draftKey.isEmpty)
        XCTAssertNil(settings.message, "Leaving Settings must clear the notice with its draft")
        XCTAssertEqual(keys.read(account: TavilySearch.keychainAccount), "old-key")
        StubURLProtocol.handler = { _ in self.serve(["key": ["usage": 1]]) }
        settings.draftKey = "new-key"
        await settings.save()
        XCTAssertEqual(keys.read(account: TavilySearch.keychainAccount), "new-key")
        XCTAssertTrue(settings.draftKey.isEmpty)
        XCTAssertFalse(settings.messageIsError)
    }

    func testMissingKeyAndSearchKeyAreReportedWithoutNetwork() async throws {
        let (directory, keys, http) = try fixture()
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "hi", resumeSessionID: nil, options: .init(model: "model")) { events.append(event) }
        XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false })
        let tools = NativeAgentTools(directory: directory, allowActions: true, keys: keys, tavily: .init(http: http))
        let result = await tools.execute(.init(id: "1", name: "web_search", arguments: ["query": "news"]))
        XCTAssertTrue(result.text.contains("Connect Tavily")); XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    func testHTTPFailuresDoNotEchoProviderBodiesAndOversizedResponsesFail() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { _ in (403, [:], Data("secret-request-content".utf8)) }
        let request = URLRequest(url: URL(string: "https://example.com")!)
        do { _ = try await http.json(request); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret-request-content")) }
        StubURLProtocol.handler = { _ in (200, [:], Data(repeating: 65, count: 200)) }
        do { _ = try await http.json(request, limit: 100); XCTFail("Expected bounded response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }

    func testConversationExpiresAndNeverCrossesProviderOrModel() throws {
        let (directory, _, _) = try fixture()
        let now = Date()
        var conversation = NativeAgentConversation.load(directory: directory, resumeID: nil, route: "route1", now: now)
        for i in 0..<12 { try conversation.append(user: "ask \(i)", assistant: "answer", directory: directory, now: now) }
        XCTAssertEqual(conversation.pairs.count, 6)
        XCTAssertEqual(NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route1", now: now).pairs.count, 6)
        XCTAssertTrue(NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route2", now: now).pairs.isEmpty)
        XCTAssertTrue(NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route1", now: now.addingTimeInterval(901)).pairs.isEmpty)
        XCTAssertTrue(NativeAgentConversation.load(directory: directory, resumeID: nil, route: "route1", now: now).pairs.isEmpty)
    }

    func testShellUsesWorkspaceAndCapsOutput() async throws {
        let (directory, _, _) = try fixture()
        let result = await NativeAgentCommand().run(command: "pwd; /usr/bin/yes x | /usr/bin/head -c 40000", directory: directory, helper: nil)
        XCTAssertTrue(result.contains(directory.path)); XCTAssertTrue(result.contains("Output shortened"))
        XCTAssertLessThan(result.utf8.count, 33_000)
        XCTAssertTrue(CaseBuiltInAgentProcesses.shared.pids.isEmpty)
    }

    func testShellTimeoutKillsStubbornProcessGroupAndReleasesCaseIdentity() async throws {
        let (directory, _, _) = try fixture()
        let start = ContinuousClock.now
        let result = await NativeAgentCommand().run(command: "trap '' TERM; while :; do :; done", directory: directory, helper: nil, timeout: .milliseconds(100))
        XCTAssertTrue(result.contains("stopped")); XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertTrue(CaseBuiltInAgentProcesses.shared.pids.isEmpty)
    }

    func testShellCancellationStopsBeforeLateWrite() async throws {
        let (directory, _, _) = try fixture()
        let task = Task { await NativeAgentCommand().run(command: "sleep 1; touch late-file", directory: directory, helper: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.contains("stopped"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-file").path))
    }

    func testCancellationKillsStubbornDescendantAfterShellExits() async throws {
        let (directory, _, _) = try fixture()
        let task = Task { await NativeAgentCommand().run(
            command: "/bin/sh -c 'trap \"\" TERM; echo $$ > stubborn-pid; while :; do :; done' & wait",
            directory: directory, helper: nil) }
        let pidFile = directory.appendingPathComponent("stubborn-pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        task.cancel()
        _ = await task.value
        // A reparented killed child may briefly remain as a zombie, so check
        // that it cannot keep running by observing no continued CPU activity.
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "Cancellation must stop descendants even when their parent exits first")
    }


    private func detachedCommandFixture(_ directory: URL) throws -> (URL, URL) {
        let source = directory.appendingPathComponent("detached.c")
        let binary = directory.appendingPathComponent("detached-job").resolvingSymlinksInPath()
        let ready = directory.appendingPathComponent("detached-pid")
        try Data(#"""
        #include <unistd.h>
        #include <stdio.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            pid_t child = fork();
            if (child < 0) return 2;
            if (child > 0) {
                for (int i=0; i<200 && access(argv[1], F_OK)!=0; i++) usleep(5000);
                if (argc > 2) usleep(500000);
                return 0;
            }
            if (setsid() < 0) _exit(3);
            FILE *file = fopen(argv[1], "w");
            if (!file) _exit(4);
            fprintf(file, "%d", getpid()); fclose(file);
            sleep(3);
            _exit(0);
        }
        """#.utf8).write(to: source)
        let compiler = Process()
        let errors = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", binary.path]
        compiler.standardError = errors
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        return (binary, ready)
    }

    private func cleanDetachedFixture(_ binary: URL, ready: URL) {
        guard let raw = try? String(contentsOf: ready, encoding: .utf8), let pid = Int32(raw),
              let process = CaseSystemProcessInspector().info(pid: pid),
              URL(fileURLWithPath: process.executablePath).resolvingSymlinksInPath() == binary else { return }
        kill(pid, SIGKILL)
    }

    func testDetachedOutputCannotKeepCommandWaitingAfterLeaderExit() async throws {
        let (directory, _, _) = try fixture()
        let (binary, ready) = try detachedCommandFixture(directory)
        defer { cleanDetachedFixture(binary, ready: ready) }
        let started = ContinuousClock.now
        let result = await NativeAgentCommand().run(command: "printf 'before\\n'; '\(binary.path)' '\(ready.path)'; printf 'leader-done\\n'", directory: directory, helper: nil, timeout: .milliseconds(250))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertTrue(result.hasPrefix("before\nleader-done\n"), "Preserve output even while a detached process holds the pipe open: \(result)")
        XCTAssertNotNil(result.range(of: "Detached child processes may still be running", options: .caseInsensitive), result)
        XCTAssertFalse(result.contains("[Exit 0]"), "An inherited open pipe is not a clean successful completion")
        XCTAssertTrue(CaseBuiltInAgentProcesses.shared.pids.isEmpty)
    }

    func testCancellationFinishesDespiteDetachedOutput() async throws {
        let (directory, _, _) = try fixture()
        let (binary, ready) = try detachedCommandFixture(directory)
        defer { cleanDetachedFixture(binary, ready: ready) }
        let command = "'\(binary.path)' '\(ready.path)' hold-parent"
        let task = Task { await NativeAgentCommand().run(command: command, directory: directory, helper: nil) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertTrue(result.contains("stopped waiting"))
        XCTAssertTrue(result.contains("Detached"))
    }

    func testCommandsDoNotInheritUnrelatedAppFileDescriptors() async throws {
        let (directory, _, _) = try fixture()
        let file = directory.appendingPathComponent("owned-descriptor")
        try Data("fixture".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_SETFD, 0)
        let command = "if [ -e /dev/fd/\(handle.fileDescriptor) ]; then printf inherited; else printf closed; fi"
        let result = await NativeAgentCommand().run(command: command, directory: directory, helper: nil)
        XCTAssertTrue(result.hasPrefix("closed"), result)
    }

    func testTerminatedShellIsNotReportedAsSuccessfulExit() async throws {
        let (directory, _, _) = try fixture()
        let result = await NativeAgentCommand().run(command: "kill -KILL $$", directory: directory, helper: nil)
        XCTAssertTrue(result.contains("Terminated by signal 9"))
        XCTAssertFalse(result.contains("[Exit 0]"))
    }

    func testMultipleActionCallsAccumulateAndActionOnlyHistoryHasContent() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        var step = 0
        StubURLProtocol.handler = { _ in
            step += 1
            if step == 1 {
                let calls = ["/tmp/first", "/tmp/second"].enumerated().map { index, path -> [String: Any] in
                    let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["items": [["type": "path", "path": path]]]), as: UTF8.self)
                    return ["id": "call\(index)", "type": "function", "function": ["name": "show_actions", "arguments": args]]
                }
                return self.serve(self.router(["role": "assistant", "content": NSNull(), "tool_calls": calls], finish: "tool_calls"))
            }
            return self.serve(self.router(["role": "assistant", "content": ""]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var actionCount = 0
        for await event in provider.run(prompt: "return both folders", resumeSessionID: nil, options: .init(model: "model")) {
            if case .blockComplete(.usefulActions(let block)) = event { actionCount = block.items.count }
        }
        XCTAssertEqual(actionCount, 2)
        let history = NativeAgentConversation.load(directory: directory, resumeID: provider.lastSessionID, route: "openrouter/model/")
        XCTAssertEqual(history.pairs.last?.assistant, "/tmp/first\n/tmp/second")
        var model = NativeAgentModel(options: .init(model: "model", openCodeProvider: .anthropic), key: "key", system: "system", history: history.pairs, prompt: "continue", http: http, usageSink: { _ in })
        model.append(results: [(.init(id: "read", name: "read_file", arguments: [:]), .init(text: ""))])
        let result = try XCTUnwrap((model.messages.last?["content"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(result.first?["text"] as? String, "[Empty tool result]")
    }

    func testNativeMigrationPreservesDisconnectedStateAndModelPreferences() throws {
        let suite = "NativeMigration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AgentProviderStore(defaults: defaults).activeProvider)
        defaults.set("opencode", forKey: "agent.activeProvider")
        defaults.set("vendor/model", forKey: "agent.opencode.model")
        XCTAssertEqual(AgentProviderStore(defaults: defaults).activeProvider, .native)
        XCTAssertEqual(defaults.string(forKey: "agent.activeProvider"), "opencode", "Keep the rollback app’s persisted provider ID")
        let connected = AgentProviderStore(defaults: defaults)
        connected.markConnected(.native)
        XCTAssertEqual(defaults.string(forKey: "agent.preferredProvider"), "opencode")
        XCTAssertEqual(AgentProviderStore(defaults: defaults).preferredProvider, .native)
        XCTAssertEqual(defaults.string(forKey: "agent.opencode.model"), "vendor/model")
        AgentProviderStore(defaults: defaults).disconnect()
        XCTAssertNil(AgentProviderStore(defaults: defaults).activeProvider)
    }
    func testSyntheticScreenshotIsReturnedAsMediaAndNeverWritten() async throws {
        let (directory, keys, _) = try fixture()
        var captures = 0
        let tools = NativeAgentTools(directory: directory, allowActions: false, keys: keys, capture: { _ in
            captures += 1
            return .success(.object(["image": .string("synthetic-base64"), "mimeType": .string("image/jpeg")]))
        }, helper: nil)
        let result = await tools.execute(.init(id: "s1", name: "capture_screen", arguments: [:]))
        XCTAssertEqual(captures, 1); XCTAssertEqual(result.image, "synthetic-base64")
        XCTAssertFalse(result.text.contains("synthetic-base64"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testReadAndSearchStayBoundedAndWritingEmptyContentIsSupported() async throws {
        let (directory, keys, _) = try fixture()
        let file = directory.appendingPathComponent("sample.txt")
        try Data(String(repeating: "a", count: 40_000).utf8).write(to: file)
        let tools = NativeAgentTools(directory: directory, allowActions: true, keys: keys, helper: nil)
        let result = await tools.execute(.init(id: "r", name: "read_file", arguments: ["path": "sample.txt"]))
        XCTAssertTrue(result.text.contains("continue at byte offset 32000")); XCTAssertLessThan(result.text.count, 32_100)
        let found = await tools.execute(.init(id: "f", name: "search_files", arguments: ["path": directory.path, "query": "sample"]))
        XCTAssertTrue(found.text.contains(file.path))
        let written = await tools.execute(.init(id: "w", name: "write_file", arguments: ["path": "sample.txt", "content": ""]))
        XCTAssertTrue(written.text.contains("Saved")); XCTAssertEqual(try Data(contentsOf: file).count, 0)
        let invalid = await tools.execute(.init(id: "x", name: "read_file", arguments: ["path": "/dev/zero"]))
        XCTAssertTrue(invalid.text.contains("regular text file"))
    }

    func testOffscreenAgentsSettings() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_NATIVE_AGENT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_NATIVE_AGENT_RENDER_DIR for native Settings review images")
        }
        let (directory, _, _) = try fixture()
        let suite = "AgentRender-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(.init(account: .openRouter, model: "vendor/lightweight-model"), for: .agent)
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing)
        let store = AgentProviderStore(defaults: defaults)
        store.markConnected(.native)
        let model = AgentModeViewModel(store: store, probe: { _ in .connected(sessionID: nil) }, notify: { _ in })
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for connected in [false, true] {
            if connected { store.markConnected(.native) } else { store.disconnect() }
            for dark in [false, true] {
                for width in [560.0, 760.0] {
                    let view = AgentModeView(viewModel: model, settings: settings, store: store, agentEnabled: { true },
                                             onAgentToggle: { _ in }, openAPIAndModels: { _ in })
                        .background(MacSettingsTheme.bgContent)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let size = NSSize(width: width, height: 940)
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: size.height),
                                          styleMask: .borderless, backing: .buffered, defer: true)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "agents-\(connected ? "connected" : "disconnected")-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name))
                    XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
                    window.close()
                    window.contentView = nil
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("AGENTS.md").path))
    }

}
