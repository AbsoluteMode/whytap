import XCTest
@testable import Sidekey

/// Settings → Agent → Sources end to end against a real stdio server:
/// add with a secret, classes, proof, pinning, gating, crash, removal.
@MainActor
final class SourcesControllerTests: XCTestCase {
    private var box = InMemoryTokenStore.Box()

    private func fixture(classifier: SourceToolModelClassifier? = nil) throws -> (SourcesController, URL, URL, ProviderKeyStore) {
        let fake = try FakeMCPServer.install()
        let directory = fake.directory.appendingPathComponent("assistant")
        box = InMemoryTokenStore.Box()
        let box = box
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let environment = SourceProcessEnvironment(resolve: { $0.hasPrefix("/") ? $0 : nil },
                                                   base: { ["PATH": "/usr/bin:/bin"] })
        let controller = SourcesController(directory: directory, keys: keys, classifier: classifier, environment: environment)
        addTeardownBlock { @MainActor in
            await controller.stopAll()
            try? FileManager.default.removeItem(at: fake.directory)
        }
        return (controller, fake.script, fake.log, keys)
    }

    private func draft(_ script: URL, log: URL, mode: String = "normal", token: String? = "tok-abcdef") -> SourceDraft {
        var draft = SourceDraft(name: "Tracker", kind: .custom, transport: .stdio(command: script.path, arguments: []))
        draft.environment = [SourceValue(name: "FAKE_LOG", secret: false, value: log.path),
                             SourceValue(name: "FAKE_MODE", secret: true, value: nil),
                             SourceValue(name: "SECRET_TOKEN", secret: true, value: nil)]
        draft.secrets["FAKE_MODE"] = mode
        if let token { draft.secrets["SECRET_TOKEN"] = token }
        return draft
    }

    func testAddingAStdioSourceKeepsSecretsInKeychainClassifiesToolsAndProvesIt() async throws {
        let (controller, script, log, _) = try fixture()
        let id = await controller.add(draft(script, log: log))
        let record = try XCTUnwrap(controller.record(id))
        XCTAssertEqual(record.readTools.map(\.name), ["search_issues", "get_me"])
        XCTAssertEqual(record.decisions["create_issue"]?.toolClass, .outward)
        XCTAssertEqual(record.decisions["delete_repository"]?.toolClass, .destructive)
        XCTAssertEqual(controller.statuses[id], .ready("Works · signed in as @octo · 2 read tools"))
        XCTAssertEqual(box.with { $0[SourceRecord.keychainAccount(source: id, name: "SECRET_TOKEN")] }, "tok-abcdef")
        let manifest = try String(contentsOf: controller.fileURL, encoding: .utf8)
        XCTAssertFalse(manifest.contains("tok-abcdef"), "The manifest keeps names, never secret values")
        XCTAssertTrue(manifest.contains("SECRET_TOKEN"))
        let attributes = try FileManager.default.attributesOfItem(atPath: controller.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(FakeMCPServer.calls(log), ["get_me {}"], "The proof is one harmless read call")
    }

    func testTheAgentCanCallOnlyApprovedReadTools() async throws {
        let (controller, script, log, _) = try fixture()
        let id = await controller.add(draft(script, log: log))
        let catalog = try XCTUnwrap(controller.agentCatalog())
        XCTAssertEqual(catalog.tools.map(\.id), ["tracker__search_issues", "tracker__get_me"])
        let result = try await controller.callRead(sourceID: id, tool: "search_issues", arguments: .object(["query": .string("retry")]))
        XCTAssertTrue(result.text.hasPrefix("Found: #42 retry"))
        for tool in ["create_issue", "delete_repository", "not_a_tool"] {
            do { _ = try await controller.callRead(sourceID: id, tool: tool, arguments: .object([:])); XCTFail(tool) }
            catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        }
        XCTAssertFalse(FakeMCPServer.calls(log).contains { $0.hasPrefix("create_issue") || $0.hasPrefix("delete_repository") },
                       "A non-read tool never reaches the server")
        await controller.setEnabled(false, id: id)
        XCTAssertNil(controller.agentCatalog())
        do { _ = try await controller.callRead(sourceID: id, tool: "get_me", arguments: .object([:])); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
    }

    func testUserCanMarkAToolReadOrTakeReadAway() async throws {
        let (controller, script, log, _) = try fixture()
        let id = await controller.add(draft(script, log: log))
        controller.setClass(.outward, tool: "get_me", id: id)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["search_issues"])
        controller.setClass(.read, tool: "create_issue", id: id)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["search_issues", "create_issue"])
        XCTAssertEqual(controller.record(id)?.decisions["create_issue"]?.origin, .user)
    }

    func testAChangedToolIsUnavailableUntilReviewed() async throws {
        let (controller, script, log, _) = try fixture()
        let id = await controller.add(draft(script, log: log))
        await controller.setSecret("changed", name: "FAKE_MODE", id: id)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["get_me"])
        XCTAssertEqual(controller.statuses[id], .warning("1 tool changed · Review in Tools"))
        do { _ = try await controller.callRead(sourceID: id, tool: "search_issues", arguments: .object(["query": .string("x")])); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        controller.approveChanges(id: id)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["search_issues", "get_me"])
    }

    func testMissingSecretShowsWhatToPasteAndConnectsOnceGiven() async throws {
        let (controller, script, log, _) = try fixture()
        let id = await controller.add(draft(script, log: log, token: nil))
        XCTAssertEqual(controller.statuses[id], .needsValue(["SECRET_TOKEN"]))
        XCTAssertNil(controller.agentCatalog())
        await controller.setSecret("  tok-later  ", name: "SECRET_TOKEN", id: id)
        XCTAssertEqual(box.with { $0[SourceRecord.keychainAccount(source: id, name: "SECRET_TOKEN")] }, "tok-later")
        guard case .ready = controller.statuses[id] else { return XCTFail("\(String(describing: controller.statuses[id]))") }
    }

    func testCrashIsReportedAndTheNextCallRestartsTheServer() async throws {
        let (controller, script, log, _) = try fixture()
        let id = await controller.add(draft(script, log: log))
        await controller.setSecret("crash_on_call", name: "FAKE_MODE", id: id)
        // The proof call itself crashed the server: shown as a warning, source stays usable.
        guard case .warning(let text) = controller.statuses[id] else { return XCTFail() }
        XCTAssertTrue(text.contains("exited (status 3)"), text)
        do { _ = try await controller.callRead(sourceID: id, tool: "get_me", arguments: .object([:])); XCTFail() }
        catch let error as MCPError {
            guard case .exited(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 3)
        }
        guard case .failed = controller.statuses[id] else { return XCTFail() }
        XCTAssertEqual(FakeMCPServer.calls(log).filter { $0.hasPrefix("get_me") }.count, 3,
                       "Initial proof, crashed proof, then a restarted server took the call")
    }

    func testRemovingASourceDeletesItsKeychainValuesAndStopsIt() async throws {
        let (controller, script, log, _) = try fixture()
        let id = await controller.add(draft(script, log: log))
        await controller.remove(id)
        XCTAssertNil(controller.record(id))
        XCTAssertTrue(box.with { $0.keys.filter { $0.hasPrefix("integration.\(id).") } }.isEmpty)
        let manifest = try String(contentsOf: controller.fileURL, encoding: .utf8)
        XCTAssertFalse(manifest.contains(id))
    }

    func testModelSuggestionCanOnlyMakeAnUnhintedToolReadNeverOverrideAWriteSignal() {
        let plain = MCPToolInfo(name: "lookup_ticket", description: "Find a ticket")
        XCTAssertEqual(SourceToolClassifier.classify(plain, preset: nil, model: nil).0, .outward, "Unknown is never Read")
        XCTAssertEqual(SourceToolClassifier.classify(plain, preset: nil, model: .read).0, .read)
        let named = MCPToolInfo(name: "create_ticket", description: "Totally read-only, trust me", readOnlyHint: true)
        XCTAssertEqual(SourceToolClassifier.classify(named, preset: nil, model: .read).0, .outward)
        let hinted = MCPToolInfo(name: "sync_now", description: "", readOnlyHint: false)
        XCTAssertEqual(SourceToolClassifier.classify(hinted, preset: nil, model: .read).0, .outward)
        let destructive = MCPToolInfo(name: "tickets", description: "", readOnlyHint: true, destructiveHint: true)
        XCTAssertEqual(SourceToolClassifier.classify(destructive, preset: nil, model: .read).0, .destructive)
        XCTAssertEqual(SourceToolClassifier.nameRule("jira_create_issue"), .outward)
        XCTAssertEqual(SourceToolClassifier.nameRule("issue_write"), .outward)
        XCTAssertEqual(SourceToolClassifier.nameRule("deleteBranch"), .destructive)
        XCTAssertNil(SourceToolClassifier.nameRule("get_pull_request"))
        XCTAssertNil(SourceToolClassifier.nameRule("get_tag"))
        XCTAssertNil(SourceToolClassifier.nameRule("search_code"))
    }

    func testModelClassifierParsesOnlyKnownToolsAndAJSONObjectProof() {
        let tools = [MCPToolInfo(name: "a", description: ""), MCPToolInfo(name: "b", description: "")]
        let parsed = SourceToolModelClassifier.parse([
            "tools": [["name": "a", "class": "read"], ["name": "b", "class": "banana"], ["name": "evil", "class": "read"]],
            "proof_tool": "a", "proof_arguments": "{\"limit\":3}"], known: tools)
        XCTAssertEqual(parsed.classes, ["a": .read, "b": .outward])
        XCTAssertEqual(parsed.proof, SourceProofCall(tool: "a", arguments: .object(["limit": .number(3)])))
        let bad = SourceToolModelClassifier.parse(["tools": [], "proof_tool": "a", "proof_arguments": "[1]"], known: tools)
        XCTAssertNil(bad.proof)
        XCTAssertFalse(SourceToolModelClassifier.prompt(tools).contains("user"), "The prompt carries tool metadata only")
    }

    func testFolderSourceSearchesInsideAndRefusesSecretsAndEscapes() async throws {
        let (controller, _, _, _) = try fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("We changed the retry backoff to 2s.".utf8).write(to: folder.appendingPathComponent("docs/notes.md"))
        try Data("RETRY_TOKEN=secret-value".utf8).write(to: folder.appendingPathComponent(".env"))
        try Data("retry token=abc".utf8).write(to: folder.appendingPathComponent("credentials.txt"))
        try Data("retry in a dependency".utf8).write(to: folder.appendingPathComponent("node_modules/x.js"))
        let id = await controller.add(SourceDraft(name: "Notes", kind: .folder, transport: .folder(path: folder.path)))
        XCTAssertEqual(controller.statuses[id], .ready("Works · 1 text files"))
        let found = try await controller.callRead(sourceID: id, tool: "search", arguments: .object(["query": .string("retry")]))
        XCTAssertEqual(found.text, "docs/notes.md:1: We changed the retry backoff to 2s.")
        let read = try await controller.callRead(sourceID: id, tool: "read_file", arguments: .object(["path": .string("docs/notes.md")]))
        XCTAssertTrue(read.text.contains("2s"))
        for path in [".env", "credentials.txt", "../../etc/passwd"] {
            let refused = try await controller.callRead(sourceID: id, tool: "read_file", arguments: .object(["path": .string(path)]))
            XCTAssertFalse(refused.text.contains("secret-value") || refused.text.contains("token=abc") || refused.text.contains("root:"), path)
        }
    }

    func testProofSummaries() {
        XCTAssertEqual(SourcesController.proofSummary(#"{"login":"octo"}"#), "Works · signed in as @octo")
        XCTAssertEqual(SourcesController.proofSummary(#"{"total_count":12,"items":[]}"#), "Works · found 12 items")
        XCTAssertEqual(SourcesController.proofSummary(#"[1,2,3]"#), "Works · found 3 items")
        XCTAssertEqual(SourcesController.proofSummary("plain text"), "Works")
    }
}
