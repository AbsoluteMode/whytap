import XCTest
@testable import Sidekey

final class OpenCodeProviderTests: XCTestCase {
    func testOpenAIAgentKeepsOnlyItsOwnKeyAndUsesNativeModelMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = try OpenCodeEnvironment.make(workingDirectory: directory, model: "gpt-6.1-sol",
            provider: .openAI, key: "openai-key", allowActions: true,
            inherited: ["ANTHROPIC_API_KEY": "wrong-anthropic", "OPENROUTER_API_KEY": "wrong-router",
                        "OPENAI_API_KEY": "wrong-openai"])
        XCTAssertEqual(env["OPENAI_API_KEY"], "openai-key")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["OPENROUTER_API_KEY"])
        let text = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(text.contains("openai-key"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(json["enabled_providers"] as? [String], ["openai"])
        XCTAssertEqual(json["model"] as? String, "openai/gpt-6.1-sol")
        let providers = try XCTUnwrap(json["provider"] as? [String: [String: Any]])
        XCTAssertNil(providers["openai"]?["models"], "Do not override OpenCode's catalog with an empty model")
        XCTAssertEqual(OpenCodeModelProvider.openAI.account, .openAI)
    }
    func testCancellationKillsChildThatIgnoresSIGTERM() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = expectation(description: "child ready")
        let exited = expectation(description: "child reaped")
        let handle = OpenCodeProvider.defaultRunStreaming(binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "trap '' TERM; printf 'ready\\n'; while :; do :; done"],
            workingDirectory: directory, environment: ["PATH": "/usr/bin:/bin"], prompt: "",
            onLine: { if $0 == "ready" { ready.fulfill() } },
            onExit: { status in XCTAssertNotEqual(status, 0); exited.fulfill() })
        defer { handle.terminate() }
        await fulfillment(of: [ready], timeout: 3)
        handle.terminate()
        await fulfillment(of: [exited], timeout: 3)
        XCTAssertNil(handle.processIdentifier)
    }

    func testLatePreviousRunCannotReplaceCurrentSessionID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines: [(String) -> Void] = []
        var exits: [(Int32) -> Void] = []
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { _ in "test-key" },
            runStreaming: { _, _, _, _, _, onLine, onExit in
                lines.append(onLine); exits.append(onExit)
                return CodexProcessHandle.noop
            })
        let first = provider.run(prompt: "first", resumeSessionID: nil,
            options: AgentRunOptions(model: "vendor/model", workingDirectory: directory))
        let second = provider.run(prompt: "second", resumeSessionID: nil,
            options: AgentRunOptions(model: "vendor/model", workingDirectory: directory))
        lines[1](#"{"type":"text","sessionID":"second-session","part":{"text":"Second answer"}}"#)
        lines[0](#"{"type":"text","sessionID":"late-first-session","part":{"text":"Old answer"}}"#)
        XCTAssertEqual(provider.lastSessionID, "second-session")
        exits[0](0); exits[1](0)
        for await _ in first {}
        for await _ in second {}
        XCTAssertEqual(provider.lastSessionID, "second-session")
    }

    func testConnectChecksVersionAndKeyWithoutModelRequest() async {
        var validations = 0
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") },
            readKey: { _ in "test-key" },
            versionProbe: { _ in ProcessResult(stdout: "1.17.12\n", stderr: "", exitCode: 0) },
            validateKey: { _, _ in validations += 1; return .connected(sessionID: nil) })
        let result = await provider.probe()
        XCTAssertEqual(result, .connected(sessionID: nil))
        XCTAssertEqual(validations, 1)
    }

    func testOldCLIIsRejectedBeforeContactingProvider() async {
        var validations = 0
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") },
            readKey: { _ in "test-key" },
            versionProbe: { _ in ProcessResult(stdout: "1.16.0", stderr: "", exitCode: 0) },
            validateKey: { _, _ in validations += 1; return .connected(sessionID: nil) })
        guard case .failed(let code, _) = await provider.probe() else { return XCTFail("Expected update requirement") }
        XCTAssertEqual(code, "unsupported_version")
        XCTAssertEqual(validations, 0)
    }

    func testRunKeepsPromptAndKeyOutOfArgumentsAndWaitsForProcessExit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var capturedArguments: [String] = []
        var capturedInput = ""
        var capturedEnvironment: [String: String] = [:]
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { _ in "test-key" },
            runStreaming: { _, args, _, env, input, onLine, onExit in
                capturedArguments = args; capturedInput = input; capturedEnvironment = env
                onLine(#"{"type":"step_start","sessionID":"ses_123"}"#)
                onLine(#"{"type":"step_finish","part":{"reason":"tool-calls"}}"#)
                onLine(#"{"type":"text","sessionID":"ses_123","part":{"id":"p1","text":"Answer"}}"#)
                onExit(0)
                return CodexProcessHandle.noop
            })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "private question", resumeSessionID: "ses_previous",
            options: AgentRunOptions(model: "google/example", workingDirectory: directory)) { events.append(event) }
        XCTAssertEqual(capturedInput, "private question")
        XCTAssertFalse(capturedArguments.contains("private question"))
        XCTAssertFalse(capturedArguments.contains("test-key"))
        XCTAssertTrue(capturedArguments.contains("openrouter/google/example"))
        XCTAssertTrue(capturedArguments.contains("ses_previous"))
        XCTAssertFalse(capturedArguments.contains("--dir"), "V2 uses the Process working directory")
        XCTAssertEqual(capturedEnvironment["OPENROUTER_API_KEY"], "test-key")
        XCTAssertEqual(provider.lastSessionID, "ses_123")
        XCTAssertEqual(events.filter { if case .done = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(events.contains(.finalAnswer(text: "Answer")))
    }

    func testMissingModelDoesNotStartProcess() async {
        var started = false
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { _ in "test-key" },
            runStreaming: { _, _, _, _, _, _, _ in started = true; return CodexProcessHandle.noop })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "hello", resumeSessionID: nil, options: AgentRunOptions()) { events.append(event) }
        XCTAssertFalse(started)
        guard case .error(let code, _, _) = events.first else { return XCTFail("Expected missing model error") }
        XCTAssertEqual(code, "missing_model")
        if case .error(_, let message, _) = events.first {
            XCTAssertEqual(message, "Choose a model in Keys & models.")
        }
    }

    func testMissingKeyAndInvalidModelPointToAPIAndModels() async {
        let noKey = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { _ in nil },
            runStreaming: { _, _, _, _, _, _, _ in CodexProcessHandle.noop })
        var events: [AgentSSEEvent] = []
        for await event in noKey.run(prompt: "hello", resumeSessionID: nil, options: AgentRunOptions()) { events.append(event) }
        guard case .error(let code, let message, _) = events.first else { return XCTFail("Expected missing key error") }
        XCTAssertEqual(code, "missing_key")
        XCTAssertEqual(message, "Add your OpenRouter key in Settings → Keys & models.")

        let badModel = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { _ in "test-key" },
            runStreaming: { _, _, _, _, _, _, _ in CodexProcessHandle.noop })
        events = []
        for await event in badModel.run(prompt: "hello", resumeSessionID: nil, options: AgentRunOptions(model: "has space")) { events.append(event) }
        guard case .error(let badCode, let badMessage, _) = events.first else { return XCTFail("Expected missing model error") }
        XCTAssertEqual(badCode, "missing_model")
        XCTAssertEqual(badMessage, "Choose a model in Keys & models.")
    }

    /// The Agent route on Anthropic: OpenCode's `anthropic` provider, the key
    /// from the Anthropic Keychain item in `ANTHROPIC_API_KEY`, no OpenRouter.
    func test_opencode_config_for_anthropic_route() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked: [OpenCodeModelProvider] = []
        var capturedArguments: [String] = []
        var capturedEnvironment: [String: String] = [:]
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") },
            readKey: { asked.append($0); return $0 == .anthropic ? "sk-ant-keychain" : "or-keychain" },
            runStreaming: { _, args, _, env, _, _, onExit in
                capturedArguments = args; capturedEnvironment = env; onExit(0)
                return CodexProcessHandle.noop
            })
        let spec = OpenCodeModelSpec(toolCall: true, reasoning: true, contextLimit: 1_000_000, outputLimit: 128_000)
        for await _ in provider.run(prompt: "hi", resumeSessionID: nil,
            options: AgentRunOptions(model: "claude-sonnet-5-5", workingDirectory: directory,
                                     openCodeModelSpec: spec, openCodeProvider: .anthropic)) {}

        XCTAssertEqual(asked, [.anthropic])
        let modelFlag = try XCTUnwrap(capturedArguments.firstIndex(of: "--model"))
        XCTAssertEqual(capturedArguments[modelFlag + 1], "anthropic/claude-sonnet-5-5")
        XCTAssertFalse(capturedArguments.contains("sk-ant-keychain"))
        XCTAssertEqual(capturedEnvironment["ANTHROPIC_API_KEY"], "sk-ant-keychain")
        XCTAssertNil(capturedEnvironment["OPENROUTER_API_KEY"])

        let content = try XCTUnwrap(capturedEnvironment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(content.contains("sk-ant-keychain"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        XCTAssertEqual(json["enabled_providers"] as? [String], ["anthropic"])
        XCTAssertEqual(json["model"] as? String, "anthropic/claude-sonnet-5-5")
        let providers = try XCTUnwrap(json["provider"] as? [String: Any])
        XCTAssertNil(providers["openrouter"])
        let anthropic = try XCTUnwrap(providers["anthropic"] as? [String: Any])
        XCTAssertEqual((anthropic["options"] as? [String: String])?["apiKey"], "{env:ANTHROPIC_API_KEY}")
        let models = try XCTUnwrap(anthropic["models"] as? [String: Any])
        let model = try XCTUnwrap(models["claude-sonnet-5-5"] as? [String: Any])
        XCTAssertEqual(model["limit"] as? [String: Int], ["context": 1_000_000, "output": 128_000])
        XCTAssertEqual(model["tool_call"] as? Bool, true)
        XCTAssertEqual(model["reasoning"] as? Bool, true)
    }

    func test_missing_anthropic_key_message_names_anthropic() async throws {
        var started = false
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") },
            readKey: { $0 == .openRouter ? "or-keychain" : nil },
            runStreaming: { _, _, _, _, _, _, _ in started = true; return CodexProcessHandle.noop })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "hello", resumeSessionID: nil,
            options: AgentRunOptions(model: "claude-sonnet-5-5", openCodeProvider: .anthropic)) { events.append(event) }
        XCTAssertFalse(started, "an OpenRouter key never stands in for the Anthropic one")
        guard case .error(let code, let message, _) = events.first else { return XCTFail("Expected missing key error") }
        XCTAssertEqual(code, "missing_key")
        XCTAssertEqual(message, "Add your Anthropic key in Settings → Keys & models.")

        var mapper = OpenCodeEventMapper(provider: .anthropic)
        let auth = mapper.map(line: #"{"type":"error","error":{"name":"ProviderAuthError"}}"#)
        guard case .error(_, let authMessage, _) = auth.first else { return XCTFail("Expected auth error") }
        XCTAssertEqual(authMessage, "Check your Anthropic key in Settings → Keys & models.")

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exiting = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { _ in "k" },
            runStreaming: { _, _, _, _, _, _, onExit in onExit(1); return CodexProcessHandle.noop })
        events = []
        for await event in exiting.run(prompt: "hello", resumeSessionID: nil,
            options: AgentRunOptions(model: "claude-sonnet-5-5", workingDirectory: directory,
                                     openCodeProvider: .anthropic)) { events.append(event) }
        let exitMessage = events.compactMap { event -> String? in
            if case .error("opencode_exit", let message, _) = event { return message }
            return nil
        }.first
        XCTAssertEqual(exitMessage, "OpenCode stopped before completing the request. Check your model and Anthropic key, then retry.")
    }

    func test_connect_on_an_anthropic_route_checks_the_anthropic_key() async {
        var validated: [OpenCodeModelProvider] = []
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") },
            readKey: { $0 == .anthropic ? "sk-ant" : nil },
            currentProvider: { .anthropic },
            versionProbe: { _ in ProcessResult(stdout: "1.17.12\n", stderr: "", exitCode: 0) },
            validateKey: { provider, _ in validated.append(provider); return .connected(sessionID: nil) })
        let result = await provider.probe()
        XCTAssertEqual(result, .connected(sessionID: nil))
        XCTAssertEqual(validated, [.anthropic])
    }

    func testMapperDoesNotFinishOnToolStepOrRepeatParts() {
        var mapper = OpenCodeEventMapper()
        XCTAssertTrue(mapper.map(line: #"{"type":"step_finish","part":{"reason":"tool-calls"}}"#).isEmpty)
        let text = #"{"type":"text","sessionID":"ses_a","part":{"id":"part_1","text":"First"}}"#
        XCTAssertTrue(mapper.map(line: text).isEmpty)
        XCTAssertEqual(mapper.answer, "First")
        XCTAssertTrue(mapper.map(line: text).isEmpty)
        _ = mapper.map(line: #"{"type":"text","part":{"id":"part_2","text":"Second"}}"#)
        XCTAssertEqual(mapper.answer, "First\n\nSecond")
        XCTAssertEqual(mapper.sessionID, "ses_a")
    }

    func testMapperNeverEchoesSensitiveErrorPayload() {
        var mapper = OpenCodeEventMapper()
        let events = mapper.map(line: #"{"type":"error","error":{"name":"ProviderAuthError","data":{"message":"secret-key private prompt"}}}"#)
        XCTAssertTrue(mapper.failed)
        guard case .error(let code, let message, _) = events.first else { return XCTFail("Expected error") }
        XCTAssertEqual(code, "opencode_auth")
        XCTAssertEqual(message, "Check your OpenRouter key in Settings → Keys & models.")
        XCTAssertFalse(message.contains("secret-key"))
        XCTAssertFalse(message.contains("private prompt"))
    }

    func testEnvironmentIsProjectScopedAndDoesNotSerializeKey() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = try OpenCodeEnvironment.make(workingDirectory: directory, model: "vendor/model", key: "test-key",
            allowActions: true, inherited: ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "unrelated", "OPENCODE_CONFIG": "/private/config"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["OPENCODE_CONFIG"])
        XCTAssertEqual(env["OPENCODE_DISABLE_CLAUDE_CODE"], "true")
        for name in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
            XCTAssertTrue(env[name]?.hasPrefix(directory.path + "/") == true)
        }
        let config = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(config.contains("test-key"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        XCTAssertEqual(json["share"] as? String, "disabled")
        XCTAssertEqual(json["enabled_providers"] as? [String], ["openrouter"])
        XCTAssertEqual((json["permission"] as? [String: String])?["*"], "allow")
    }

    func testRunPassesTheCatalogSpecIntoTheEnvironment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var capturedEnvironment: [String: String] = [:]
        let provider = OpenCodeProvider(locate: { URL(fileURLWithPath: "/tmp/opencode") }, readKey: { _ in "test-key" },
            runStreaming: { _, _, _, env, _, _, onExit in
                capturedEnvironment = env; onExit(0)
                return CodexProcessHandle.noop
            })
        let spec = OpenCodeModelSpec(toolCall: true, reasoning: false, contextLimit: 300_000, outputLimit: 8_000)
        for await _ in provider.run(prompt: "hi", resumeSessionID: nil,
            options: AgentRunOptions(model: "vendor/model", workingDirectory: directory, openCodeModelSpec: spec)) {}
        let config = try XCTUnwrap(capturedEnvironment["OPENCODE_CONFIG_CONTENT"])
        XCTAssertTrue(config.contains("300000"))
        XCTAssertTrue(config.contains("8000"))
    }

    func testReadOnlyIsOptionalAndNeverTheDefault() throws {
        XCTAssertTrue(AgentRunOptions().allowActions)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = try OpenCodeEnvironment.make(workingDirectory: directory, model: "vendor/model", key: nil, allowActions: false)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(env["OPENCODE_CONFIG_CONTENT"]!.utf8)) as? [String: Any])
        XCTAssertEqual((json["permission"] as? [String: String])?["*"], "deny")
        XCTAssertEqual((json["permission"] as? [String: String])?["read"], "allow")
    }

    func testAutoRouterModelKeepsItsProviderNamespace() {
        XCTAssertEqual(OpenCodeEnvironment.normalizeModel("openrouter/auto"), "openrouter/auto")
        XCTAssertEqual(OpenCodeEnvironment.normalizeModel("openrouter/google/example"), "google/example")
    }

    func testStableV2VersionOutputAndPrivateLaunch() {
        XCTAssertTrue(OpenCodeProvider.supportsVersion("opencode v2.1.1\n"))
        XCTAssertTrue(OpenCodeProvider.supportsVersion("2.1.2"))
        XCTAssertTrue(OpenCodeProvider.supportsVersion("v1.19.3"), "Legacy CLI remains usable while the app copy updates")
        for version in ["2.1.1-beta.1", "2.0.0", "3.0.0", "2.1", "2.1.1 extra", "v2.1.1\n2.1.2"] {
            XCTAssertFalse(OpenCodeProvider.supportsVersion(version), version)
        }
        let args = ["run", "--format", "json", "--model", "openrouter/vendor/model"]
        XCTAssertEqual(OpenCodeProvider.runtimeArguments(args, version: "opencode v2.1.1"),
                       ["run", "--standalone"] + args.dropFirst())
        XCTAssertEqual(OpenCodeProvider.runtimeArguments(args, version: "1.17.12"), args)
        XCTAssertNil(OpenCodeProvider.runtimeArguments(args, version: "unknown"))
        XCTAssertNil(OpenCodeProvider.runtimeArguments([], version: "2.1.1"))
    }

    func testVersionProbeIsBoundedAndDoesNotInheritCredentials() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("opencode")
        try Data("#!/bin/sh\n[ -z \"$OPENROUTER_API_KEY$ANTHROPIC_API_KEY$OPENAI_API_KEY\" ] || exit 3\nprintf 'opencode v2.1.1\\n'\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(OpenCodeVersionProbe.run(binary)?.stdout, "opencode v2.1.1\n")
        try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: binary)
        XCTAssertNil(OpenCodeVersionProbe.run(binary, timeout: 0.05))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whytap-opencode-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
