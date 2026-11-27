import Foundation
import XCTest
@testable import Sidekey

/// Connected sources ship gated off until the owner decides whether the
/// feature stays. These tests prove that, with the shipped gate, the user
/// sees no entry, the Agent is offered no source tool or context, no server
/// process starts, no other app's configuration is read and nothing is
/// written to Application Support or Keychain.
/// WHY: .project-docs/decisions/2026-11-27-agent-sources-gated.md
@MainActor
final class AgentSourcesGateTests: XCTestCase {
    // MARK: - Shipped state

    func testTheFeatureShipsGatedOff() {
        XCTAssertFalse(AgentSourcesGate.isEnabled, "Connected sources stay hidden until the owner decides")
        XCTAssertFalse(AgentFeatureSettings.showsSources, "Settings → Agent shows no Sources section or Add source…")
        XCTAssertFalse(SourcesController.shared.isEnabled)
        XCTAssertFalse(MCPConfigImporter().isEnabled)
    }

    // MARK: - Controller: no files, Keychain, processes or Agent tools

    private struct Fixture {
        let controller: SourcesController
        let directory: URL
        let box: InMemoryTokenStore.Box
        let launcher: URL
        let marker: URL
        let resolved: LockedCount
    }

    final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// A gated-off controller next to a real launcher that would leave a
    /// marker file if anything ever started it.
    private func gatedOff(manifest: Data? = nil) throws -> Fixture {
        let fake = try FakeMCPServer.install()
        let directory = fake.directory.appendingPathComponent("assistant")
        if let manifest {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try manifest.write(to: directory.appendingPathComponent("sources.json"))
        }
        let marker = fake.directory.appendingPathComponent("launched")
        let launcher = fake.directory.appendingPathComponent("launch.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\nexec '\(fake.script.path)'\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let resolved = LockedCount()
        let environment = SourceProcessEnvironment(resolve: { resolved.increment(); return $0.hasPrefix("/") ? $0 : nil },
                                                   base: { ["PATH": "/usr/bin:/bin"] })
        let controller = SourcesController(directory: directory, keys: keys, classifier: nil, environment: environment)
        addTeardownBlock { @MainActor in
            await controller.stopAll()
            try? FileManager.default.removeItem(at: fake.directory)
        }
        return Fixture(controller: controller, directory: directory, box: box, launcher: launcher, marker: marker, resolved: resolved)
    }

    private func draft(_ launcher: URL) -> SourceDraft {
        var draft = SourceDraft(name: "Tracker", kind: .custom, transport: .stdio(command: launcher.path, arguments: [], directory: nil))
        draft.environment = [SourceValue(name: "SECRET_TOKEN", secret: true, value: nil)]
        draft.secrets["SECRET_TOKEN"] = "tok-abcdef"
        return draft
    }

    private func assertNothingHappened(_ fixture: Fixture, manifestExpected: Bool = false,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let manifest = fixture.directory.appendingPathComponent("sources.json")
        XCTAssertEqual(FileManager.default.fileExists(atPath: manifest.path), manifestExpected,
                       "No sources manifest is created in Application Support", file: file, line: line)
        if !manifestExpected {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path),
                           "Not even the sources directory is created", file: file, line: line)
        }
        XCTAssertTrue(fixture.box.with { $0.isEmpty }, "Nothing is written to Keychain", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path), "No server process starts", file: file, line: line)
        XCTAssertEqual(fixture.resolved.value, 0, "No server command is even resolved", file: file, line: line)
        XCTAssertEqual(fixture.controller.liveClientCount, 0, file: file, line: line)
        XCTAssertNil(fixture.controller.agentCatalog(), "The Agent is offered no source tools", file: file, line: line)
    }

    func testAddingASourceWithTheGateOffStoresAndStartsNothing() async throws {
        let fixture = try gatedOff()
        let id = await fixture.controller.add(draft(fixture.launcher))
        XCTAssertNil(id)
        XCTAssertTrue(fixture.controller.sources.isEmpty)
        let folder = SourceDraft(name: "Notes", kind: .folder, transport: .folder(path: fixture.directory.deletingLastPathComponent().path))
        let folderID = await fixture.controller.add(folder)
        XCTAssertNil(folderID)
        assertNothingHappened(fixture)
    }

    func testAnExistingManifestIsNeitherReadNorRewrittenNorConnected() async throws {
        // A manifest from a build that had the feature on, pointing at the launcher.
        let enabledDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gate-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: enabledDirectory) }
        let seeded = try gatedOff()
        let writer = SourcesController(enabled: true, directory: enabledDirectory,
                                       keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0) }),
                                       classifier: nil,
                                       environment: SourceProcessEnvironment(resolve: { _ in nil }, base: { [:] }))
        _ = await writer.add(draft(seeded.launcher))
        let manifest = try Data(contentsOf: enabledDirectory.appendingPathComponent("sources.json"))
        XCTAssertFalse(writer.sources.isEmpty, "The seeding controller wrote a real record")
        await writer.stopAll()

        let fixture = try gatedOff(manifest: manifest)
        let before = try Data(contentsOf: fixture.directory.appendingPathComponent("sources.json"))
        fixture.controller.loadIfNeeded()
        XCTAssertTrue(fixture.controller.sources.isEmpty, "The manifest is not read")
        let id = try XCTUnwrap(writer.sources.first?.id)
        await fixture.controller.check(id)
        await fixture.controller.setEnabled(true, id: id)
        await fixture.controller.setSecret("tok-new", name: "SECRET_TOKEN", id: id)
        do {
            _ = try await fixture.controller.callRead(sourceID: id, tool: "search_issues", arguments: .object([:]))
            XCTFail("A read through a gated-off controller must be refused")
        } catch let error as MCPError {
            XCTAssertEqual(error, .notAllowed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent("sources.json")), before,
                       "The manifest is left exactly as it was")
        assertNothingHappened(fixture, manifestExpected: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.marker.path),
                       "The server named in the manifest is never started")
    }

    // MARK: - Importer and gh

    func testConfigurationsOfOtherAppsAreNotScanned() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let files = [
            ".cursor/mcp.json": #"{"mcpServers": {"tracker": {"command": "srv", "args": ["-y"]}}}"#,
            ".claude.json": #"{"mcpServers": {"docs": {"type": "http", "url": "https://docs.example/mcp"}}}"#,
            ".codex/config.toml": "[mcp_servers.ok]\ncommand = \"srv\"\n",
            "Library/Application Support/Code/User/mcp.json": "not json",
        ]
        for (path, contents) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let enabled = MCPConfigImporter(enabled: true, home: home).scan()
        XCTAssertFalse(enabled.candidates.isEmpty, "Control: the same files do produce candidates with the gate on")
        XCTAssertFalse(enabled.problems.isEmpty, "Control: the broken VS Code file is reported with the gate on")
        XCTAssertEqual(MCPConfigImporter(home: home).scan(), SourceImportScan(), "Nothing is read with the gate off")
    }

    func testGitHubSignInDoesNotRunGhWithTheGateOff() async {
        let token = await GitHubCLISignIn.token()
        XCTAssertNil(token)
    }

    // MARK: - The Agent

    func testTheAgentIsOfferedNoSourceToolOrContextEvenWhenACatalogIsInstalled() async throws {
        NativeAgentEffort.refusals.removeAll()
        StubURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("router-key", account: OpenRouterLLMKeyStore.account)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let previous = NativeAgentSources.installed
        addTeardownBlock { @MainActor in
            NativeAgentSources.installed = previous
            session.invalidateAndCancel(); StubURLProtocol.reset()
            try? FileManager.default.removeItem(at: directory)
        }
        var asked = 0
        let catalog = AgentSourceCatalog(tools: [
            .init(id: "github__search_pull_requests", sourceID: "github-1", sourceName: "GitHub", tool: "search_pull_requests",
                  signature: "search_pull_requests(query*: string)", description: "Search pull requests."),
        ]) { _, _ in MCPToolResult(text: "x", isError: false, shortened: false) }
        // As if something had wired the catalog in despite the gate.
        NativeAgentSources.installed = { asked += 1; return catalog }
        XCTAssertNotNil(NativeAgentSources.offered(enabled: true), "Control: an enabled gate would offer it")
        asked = 0

        StubURLProtocol.handler = { _ in
            let finish: [String: Any] = ["id": "final", "type": "function", "function": [
                "name": "finish_answer",
                "arguments": #"{"status":"answered","answer":"Done.","sources":[],"actions":[]}"#]]
            let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [finish]],
                                                    "finish_reason": "tool_calls"]], "usage": ["cost": 0.001]]
            return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: body))
        }
        // The production default: no `sources:` argument.
        let provider = NativeAgentProvider(keys: keys, http: NativeAgentHTTP(session: session), workspace: { directory },
                                           appControl: { nil }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "find the PR where we changed retry", resumeSessionID: nil,
                                        options: .init(model: "vendor/model", allowActions: true)) { events.append(event) }
        XCTAssertTrue(events.contains(.finalAnswer(text: "Done.")))
        XCTAssertEqual(asked, 0, "The installed catalog is never consulted")
        let request = try XCTUnwrap(StubURLProtocol.capturedBodies.first)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let names = (first["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(names.isEmpty, "Control: the request did carry the Agent's other tools")
        XCTAssertFalse(names.contains(NativeAgentSources.toolName), "No source_call tool")
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertFalse(text.contains("Connected sources"), "No source context in the prompt")
        XCTAssertFalse(text.contains("github__search_pull_requests"))
    }

    // MARK: - Every entry point checks the gate

    private func source(_ path: String) throws -> String {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 where !FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
            cursor.deleteLastPathComponent()
        }
        return try String(contentsOf: cursor.appendingPathComponent(path), encoding: .utf8)
    }

    /// The UI and app wiring cannot be exercised headlessly, so their source
    /// is checked: the Sources section is mounted, and the Agent catalog is
    /// installed, only inside the gate's branch, and nothing else in the app
    /// reaches the feature's entry points.
    func testTheSettingsMountAndTheAppWiringAreInsideTheGate() throws {
        let screens = try source("Sources/Sidekey/Settings/Features/SwitchFeatureScreens.swift")
        let mount = try XCTUnwrap(screens.range(of: "AgentSourcesSection("))
        let guardRange = try XCTUnwrap(screens.range(of: "if Self.showsSources {"))
        XCTAssertLessThan(guardRange.lowerBound, mount.lowerBound)
        XCTAssertFalse(screens[guardRange.upperBound..<mount.lowerBound].contains("}"),
                       "The Sources section is mounted only inside the gate's branch")
        XCTAssertEqual(screens.components(separatedBy: "AgentSourcesSection(").count, 2, "One mount only")

        let delegate = try source("Sources/Sidekey/AppDelegate.swift")
        let install = try XCTUnwrap(delegate.range(of: "NativeAgentSources.installed ="))
        let gate = try XCTUnwrap(delegate.range(of: "if AgentSourcesGate.isEnabled {"))
        XCTAssertLessThan(gate.lowerBound, install.lowerBound)
        XCTAssertFalse(delegate[gate.upperBound..<install.lowerBound].contains("}"),
                       "The Agent catalog is installed only inside the gate's branch")
        XCTAssertEqual(delegate.components(separatedBy: "NativeAgentSources.installed").count, 2)
    }

    func testNoOtherAppCodeReachesTheFeature() throws {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 where !FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
            cursor.deleteLastPathComponent()
        }
        let root = cursor.appendingPathComponent("Sources")
        let own: Set<String> = [
            "Sidekey/Settings/Features/AgentSourcesSettings.swift", "Sidekey/Settings/Features/AddSourceSheet.swift",
            "Sidekey/Settings/Features/SwitchFeatureScreens.swift", "Sidekey/AppDelegate.swift",
            "Sidekey/AgentDaemon/NativeAgentSources.swift", "Sidekey/AgentDaemon/NativeAgentProvider.swift",
        ]
        let entryPoints = ["AgentSourcesSection(", "AddSourceSheet(", "SourcesController.shared", "SourcesController(",
                           "MCPConfigImporter(", "GitHubCLISignIn.", "NativeAgentSources.installed"]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative.hasPrefix("Sidekey/Assistant/Connections/") || own.contains(relative) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for entry in entryPoints where text.contains(entry) { offenders.append("\(relative): \(entry)") }
        }
        XCTAssertEqual(offenders, [], "A new path into connected sources must check AgentSourcesGate")
    }
}

extension AgentSourcesGateTests {
    func testBuilder700DisabledControllerNeverQueriesSourceCredentialPresence() throws {
        let lookedUp = LockedCount()
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: {
            lookedUp.increment()
            return InMemoryTokenStore(account: $0, box: box)
        })
        let record = SourceRecord(
            id: "fixture", name: "Fixture", kind: .custom, importedFrom: nil,
            transport: .http(url: "https://example.invalid/mcp"),
            environment: [SourceValue(name: "ENV_FIXTURE", secret: true, value: nil)],
            headers: [SourceValue(name: "X-Fixture", secret: true, value: nil)]
        )
        try keys.save("fixture-value", account: SourceRecord.keychainAccount(
            source: record.id, name: "ENV_FIXTURE"))
        let before = lookedUp.value
        let off = SourcesController(enabled: false, keys: keys)
        XCTAssertFalse(off.hasSecret("ENV_FIXTURE", id: record.id),
                       "A disabled controller must not expose whether an existing item is present")
        XCTAssertEqual(lookedUp.value, before, "Individual presence must never reach the store")
        _ = off.missingSecrets(record)
        XCTAssertEqual(lookedUp.value, before, "Bulk presence must not query environment or header items")

        let on = SourcesController(enabled: true, keys: keys)
        XCTAssertTrue(on.hasSecret("ENV_FIXTURE", id: record.id))
        XCTAssertEqual(on.missingSecrets(record), ["header.X-Fixture"])
    }
}

extension AgentSourcesGateTests {
    /// The whole class of Keychain-reaching calls on an off controller:
    /// presence (single and bulk), the secret mask, writes, deletes and the
    /// paths that would read a secret to connect. None reaches the store.
    func testEveryKeychainPathOfAnOffControllerSkipsTheStore() async throws {
        let lookedUp = LockedCount()
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: {
            lookedUp.increment()
            return InMemoryTokenStore(account: $0, box: box)
        })
        let record = SourceRecord(
            id: "fixture", name: "Fixture", kind: .custom, importedFrom: nil,
            transport: .http(url: "https://example.invalid/mcp"),
            environment: [SourceValue(name: "ENV_FIXTURE", secret: true, value: nil)],
            headers: [SourceValue(name: "X-Fixture", secret: true, value: nil)])
        let account = SourceRecord.keychainAccount(source: record.id, name: "ENV_FIXTURE")
        try keys.save("fixture-value", account: account)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gate-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let before = lookedUp.value

        let off = SourcesController(enabled: false, directory: directory, keys: keys, classifier: nil,
                                    environment: SourceProcessEnvironment(resolve: { _ in nil }, base: { [:] }))
        XCTAssertFalse(off.hasSecret("ENV_FIXTURE", id: record.id))
        XCTAssertEqual(off.missingSecrets(record), record.secretNames, "Nothing is reported present")
        _ = off.mask(record.id)
        await off.setSecret("replacement", name: "ENV_FIXTURE", id: record.id)
        await off.remove(record.id)
        var draft = SourceDraft(name: "Fixture", kind: .custom, transport: .http(url: "https://example.invalid/mcp"))
        draft.headers = [SourceValue(name: "X-Fixture", secret: true, value: nil)]
        draft.secrets["header.X-Fixture"] = "fixture-header"
        _ = await off.add(draft)
        await off.check(record.id)
        XCTAssertNil(off.agentCatalog())
        _ = try? await off.callRead(sourceID: record.id, tool: "search", arguments: .object([:]))
        XCTAssertEqual(lookedUp.value, before, "An off controller never reaches the Keychain store")
        XCTAssertEqual(box.with { $0.count }, 1, "The existing item is neither replaced nor deleted, and nothing is added")
        XCTAssertEqual(keys.read(account: account), "fixture-value")
    }
}
