import XCTest
@testable import Sidekey

/// Settings → Agent → Sources end to end against a real stdio server:
/// secrets, classes, explicit approval, proof, pinning at the current
/// connection, revocation, crash, removal and folders.
@MainActor
final class SourcesControllerTests: XCTestCase {
    private var box = InMemoryTokenStore.Box()
    private var modeFile: URL!

    private func fixture(classifier: SourceToolModelClassifier? = nil) throws -> (SourcesController, URL, URL, ProviderKeyStore) {
        let fake = try FakeMCPServer.install()
        let directory = fake.directory.appendingPathComponent("assistant")
        modeFile = fake.directory.appendingPathComponent("mode")
        box = InMemoryTokenStore.Box()
        let box = box
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let environment = SourceProcessEnvironment(resolve: { $0.hasPrefix("/") ? $0 : nil },
                                                   base: { ["PATH": "/usr/bin:/bin"] })
        let controller = SourcesController(enabled: true, directory: directory, keys: keys, classifier: classifier, environment: environment)
        addTeardownBlock { @MainActor in
            await controller.stopAll()
            try? FileManager.default.removeItem(at: fake.directory)
        }
        return (controller, fake.script, fake.log, keys)
    }

    private func draft(_ script: URL, log: URL, mode: String = "normal", token: String? = "tok-abcdef",
                       kind: SourceKind = .custom) -> SourceDraft {
        var draft = SourceDraft(name: "Tracker", kind: kind, transport: .stdio(command: script.path, arguments: [], directory: nil))
        draft.environment = [SourceValue(name: "FAKE_LOG", secret: false, value: log.path),
                             SourceValue(name: "FAKE_MODE_FILE", secret: false, value: modeFile.path),
                             SourceValue(name: "FAKE_MODE", secret: true, value: nil),
                             SourceValue(name: "SECRET_TOKEN", secret: true, value: nil)]
        draft.secrets["FAKE_MODE"] = mode
        if let token { draft.secrets["SECRET_TOKEN"] = token }
        return draft
    }

    /// Adds a custom source and approves its tools, as the user would.
    private func approved(_ controller: SourcesController, _ script: URL, _ log: URL) async throws -> String {
        let idValue = await controller.add(draft(script, log: log))
        let id = try XCTUnwrap(idValue)
        await controller.approveChanges(id: id)
        return id
    }

    // MARK: - Secrets, classes, explicit approval, proof

    func testACustomServerIsNotCalledBeforeTheUserApprovesItsTools() async throws {
        let (controller, script, log, _) = try fixture()
        let idValue = await controller.add(draft(script, log: log))
        let id = try XCTUnwrap(idValue)
        let record = try XCTUnwrap(controller.record(id))
        XCTAssertEqual(record.readTools, [], "The server's own Read hints do not approve anything")
        XCTAssertEqual(record.decisions["search_issues"]?.toolClass, .read)
        XCTAssertEqual(record.decisions["create_issue"]?.toolClass, .outward)
        XCTAssertEqual(record.decisions["delete_repository"]?.toolClass, .destructive)
        XCTAssertEqual(controller.statuses[id], .warning("Connected · approve its tools in Details before the Agent uses them"))
        XCTAssertEqual(FakeMCPServer.calls(log), [], "No tool, not even the proof, runs before approval")
        XCTAssertNil(controller.agentCatalog())
        await controller.approveChanges(id: id)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["search_issues", "get_me"])
        XCTAssertEqual(controller.statuses[id], .ready("Works · signed in as @octo · 2 read tools"))
        XCTAssertEqual(FakeMCPServer.calls(log), ["get_me {}"], "The proof is one harmless read call, after approval")
    }

    func testAModelSuggestionDoesNotApproveACustomServersTool() async throws {
        let classifier = SourceToolModelClassifier { tools in
            .init(classes: Dictionary(uniqueKeysWithValues: tools.map { ($0.name, SourceToolClass.read) }),
                  proof: SourceProofCall(tool: "search_issues", arguments: .object(["query": .string("x")])))
        }
        let (controller, script, log, _) = try fixture(classifier: classifier)
        let idValue = await controller.add(draft(script, log: log))
        let id = try XCTUnwrap(idValue)
        XCTAssertEqual(controller.record(id)?.readTools, [])
        XCTAssertEqual(FakeMCPServer.calls(log), [])
    }

    func testAReviewedPresetIsTrustedOnConnectAndProvedAtOnce() async throws {
        let (controller, script, log, _) = try fixture()
        let idValue = await controller.add(draft(script, log: log, kind: .github))
        let id = try XCTUnwrap(idValue)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["search_issues", "get_me"])
        XCTAssertEqual(FakeMCPServer.calls(log), ["get_me {}"])
    }

    func testSecretsStayInKeychainAndTheManifestKeepsNames() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
        XCTAssertEqual(box.with { $0[SourceRecord.keychainAccount(source: id, name: "SECRET_TOKEN")] }, "tok-abcdef")
        let manifest = try String(contentsOf: controller.fileURL, encoding: .utf8)
        XCTAssertFalse(manifest.contains("tok-abcdef"), "The manifest keeps names, never secret values")
        XCTAssertTrue(manifest.contains("SECRET_TOKEN"))
        let attributes = try FileManager.default.attributesOfItem(atPath: controller.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testADraftBreakingTheCredentialPolicyIsRefusedEvenIfItGetsThisFar() async throws {
        let (controller, _, _, _) = try fixture()
        let argv = SourceDraft(name: "x", kind: .custom, transport: .stdio(command: "/usr/bin/true", arguments: ["--token", "abc"], directory: nil))
        let added = await controller.add(argv)
        XCTAssertNil(added)
        let url = SourceDraft(name: "y", kind: .custom, transport: .http(url: "https://mcp.example.com/mcp?api_key=abc"))
        let addedURL = await controller.add(url)
        XCTAssertNil(addedURL)
        XCTAssertTrue(controller.sources.isEmpty)
    }

    func testATamperedManifestWithASecretOnTheCommandLineIsNotLaunched() async throws {
        let (controller, _, _, _) = try fixture()
        let record = SourceRecord(id: "t-1", name: "T", kind: .custom,
                                  transport: .stdio(command: "/usr/bin/true", arguments: ["ghp_abcdef123"], directory: nil))
        try FileManager.default.createDirectory(at: controller.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([record]).write(to: controller.fileURL)
        controller.loadIfNeeded()
        await controller.check("t-1")
        XCTAssertEqual(controller.statuses["t-1"], .failed(MCPError.notAllowed.message))
        XCTAssertFalse(controller.record("t-1").map(SourcesController.summaryOf)?.contains("ghp_") ?? true)
    }

    // MARK: - Gating at the current connection

    func testTheAgentCanCallOnlyApprovedReadTools() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
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

    func testAToolThatChangedWhileDisconnectedIsReListedOnReconnectBeforeAnyCall() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
        // The server is restarted (idle stop, sleep) and now describes a tool differently.
        await controller.stop(id)
        FakeMCPServer.setMode("changed", file: modeFile)
        do { _ = try await controller.callRead(sourceID: id, tool: "search_issues", arguments: .object(["query": .string("x")])); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        XCTAssertFalse(FakeMCPServer.calls(log).contains { $0.hasPrefix("search_issues") })
        XCTAssertEqual(controller.statuses[id], .warning("1 tool changed · Review in Details"))
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["get_me"])
        await controller.approveChanges(id: id)
        let result = try await controller.callRead(sourceID: id, tool: "search_issues", arguments: .object(["query": .string("x")]))
        XCTAssertTrue(result.text.hasPrefix("Found"))
    }

    func testAFailedReListOnReconnectKeepsEveryToolUnavailable() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
        await controller.stop(id)
        FakeMCPServer.setMode("list_error", file: modeFile)
        for tool in ["get_me", "get_me"] {
            do { _ = try await controller.callRead(sourceID: id, tool: tool, arguments: .object([:])); XCTFail() }
            catch {}
        }
        XCTAssertEqual(FakeMCPServer.calls(log), ["get_me {}"], "Only the proof before the restart ran")
    }

    func testAListChangedNoticeHoldsToolsForConcurrentCallsUntilANewListIsApplied() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
        FakeMCPServer.setMode("notify_change", file: modeFile)
        // The server announces a change before answering: that answer is discarded too.
        do { _ = try await controller.callRead(sourceID: id, tool: "get_me", arguments: .object([:])); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        FakeMCPServer.setMode("normal", file: modeFile)
        async let first = try? controller.callRead(sourceID: id, tool: "search_issues", arguments: .object(["query": .string("a")]))
        async let second = try? controller.callRead(sourceID: id, tool: "search_issues", arguments: .object(["query": .string("b")]))
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 0, "Both calls saw the changed tool and were refused")
        XCTAssertFalse(FakeMCPServer.calls(log).contains { $0.hasPrefix("search_issues") })
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["get_me"])
    }

    func testDisablingWhileClassifyingWinsAndNothingIsCalled() async throws {
        let gate = Gate()
        let classifier = SourceToolModelClassifier { _ in await gate.wait(); return nil }
        let (controller, script, log, _) = try fixture(classifier: classifier)
        let adding = Task { await controller.add(self.draft(script, log: log, kind: .github)) }
        try await gate.untilWaiting()
        let id = try XCTUnwrap(controller.sources.first?.id)
        await controller.setEnabled(false, id: id)
        await gate.open()
        _ = await adding.value
        XCTAssertEqual(controller.statuses[id], .off)
        XCTAssertNil(controller.agentCatalog())
        XCTAssertEqual(controller.liveClientCount, 0)
        XCTAssertEqual(FakeMCPServer.calls(log), [], "No proof ran for a source turned off mid-check")
    }

    func testRemovingWhileConnectingRevokesAtOnceAndLeavesNoServer() async throws {
        let (controller, script, log, _) = try fixture()
        FakeMCPServer.setMode("slow_init", file: modeFile)
        let adding = Task { await controller.add(self.draft(script, log: log, kind: .github)) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let id = try XCTUnwrap(controller.sources.first?.id)
        await controller.remove(id)
        XCTAssertNil(controller.record(id))
        XCTAssertNil(controller.agentCatalog())
        _ = await adding.value
        XCTAssertNil(controller.record(id), "A finishing check does not bring it back")
        XCTAssertNil(controller.statuses[id])
        XCTAssertEqual(controller.liveClientCount, 0)
        XCTAssertTrue(box.with { $0.keys.filter { $0.hasPrefix("integration.\(id).") } }.isEmpty)
    }

    func testStopAllAlsoEndsConnectionsInFlight() async throws {
        let (controller, script, log, _) = try fixture()
        FakeMCPServer.setMode("slow_init", file: modeFile)
        let adding = Task { await controller.add(self.draft(script, log: log, kind: .github)) }
        try await Task.sleep(nanoseconds: 400_000_000)
        await controller.stopAll()
        let idValue = await adding.value
        let id = try XCTUnwrap(idValue)
        XCTAssertEqual(controller.liveClientCount, 0)
        XCTAssertNotEqual(controller.statuses[id], .ready("Works · signed in as @octo · 2 read tools"))
    }

    func testUserCanMarkAToolReadOrTakeReadAway() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
        controller.setClass(.outward, tool: "get_me", id: id)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["search_issues"])
        controller.setClass(.read, tool: "create_issue", id: id)
        XCTAssertEqual(controller.record(id)?.readTools.map(\.name), ["search_issues", "create_issue"])
        XCTAssertEqual(controller.record(id)?.decisions["create_issue"]?.origin, .user)
    }

    func testMissingSecretShowsWhatToPasteAndConnectsOnceGiven() async throws {
        let (controller, script, log, _) = try fixture()
        let idValue = await controller.add(draft(script, log: log, token: nil))
        let id = try XCTUnwrap(idValue)
        XCTAssertEqual(controller.statuses[id], .needsValue(["SECRET_TOKEN"]))
        XCTAssertNil(controller.agentCatalog())
        await controller.setSecret("  tok-later  ", name: "SECRET_TOKEN", id: id)
        XCTAssertEqual(box.with { $0[SourceRecord.keychainAccount(source: id, name: "SECRET_TOKEN")] }, "tok-later")
        guard case .warning = controller.statuses[id] else { return XCTFail("\(String(describing: controller.statuses[id]))") }
    }

    func testCrashIsReportedAndTheNextCallRestartsAndReValidates() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
        FakeMCPServer.setMode("crash_on_call", file: modeFile)
        do { _ = try await controller.callRead(sourceID: id, tool: "get_me", arguments: .object([:])); XCTFail() }
        catch let error as MCPError {
            guard case .exited(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 3)
        }
        guard case .failed = controller.statuses[id] else { return XCTFail() }
        FakeMCPServer.setMode("normal", file: modeFile)
        let result = try await controller.callRead(sourceID: id, tool: "get_me", arguments: .object([:]))
        XCTAssertTrue(result.text.contains("octo"), "A restarted server is re-listed, then called")
    }

    func testRemovingASourceDeletesItsKeychainValuesAndStopsIt() async throws {
        let (controller, script, log, _) = try fixture()
        let id = try await approved(controller, script, log)
        await controller.remove(id)
        XCTAssertNil(controller.record(id))
        XCTAssertEqual(controller.liveClientCount, 0)
        XCTAssertTrue(box.with { $0.keys.filter { $0.hasPrefix("integration.\(id).") } }.isEmpty)
        let manifest = try String(contentsOf: controller.fileURL, encoding: .utf8)
        XCTAssertFalse(manifest.contains(id))
    }

    // MARK: - Classes

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

    func testProofSummaries() {
        XCTAssertEqual(SourcesController.proofSummary(#"{"login":"octo"}"#), "Works · signed in as @octo")
        XCTAssertEqual(SourcesController.proofSummary(#"{"total_count":12,"items":[]}"#), "Works · found 12 items")
        XCTAssertEqual(SourcesController.proofSummary(#"{"total_count":1e300}"#), "Works", "An absurd number never traps")
        XCTAssertEqual(SourcesController.proofSummary(#"[1,2,3]"#), "Works · found 3 items")
        XCTAssertEqual(SourcesController.proofSummary("plain text"), "Works")
    }

    // MARK: - Folder

    func testFolderSourceSearchesInsideAndRefusesSecretsEscapesLinksAndSpecialFiles() async throws {
        let (controller, _, _, _) = try fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folder-" + UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }
        try Data("We changed the retry backoff to 2s.".utf8).write(to: folder.appendingPathComponent("docs/notes.md"))
        try Data("RETRY_TOKEN=secret-value".utf8).write(to: folder.appendingPathComponent(".env"))
        try Data("retry token=abc".utf8).write(to: folder.appendingPathComponent("credentials.txt"))
        try Data("retry in a dependency".utf8).write(to: folder.appendingPathComponent("node_modules/x.js"))
        try Data("retry outside the folder".utf8).write(to: outside.appendingPathComponent("away.md"))
        let manager = FileManager.default
        // A link to a file in the same folder, a link to a folder outside, and a FIFO.
        try manager.createSymbolicLink(at: folder.appendingPathComponent("alias.md"), withDestinationURL: folder.appendingPathComponent("docs/notes.md"))
        try manager.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("pipe.md").path, 0o600), 0)
        let idValue = await controller.add(SourceDraft(name: "Notes", kind: .folder, transport: .folder(path: folder.path)))
        let id = try XCTUnwrap(idValue)
        XCTAssertEqual(controller.statuses[id], .ready("Works · 1 text files"))
        let found = try await controller.callRead(sourceID: id, tool: "search", arguments: .object(["query": .string("retry")]))
        XCTAssertEqual(found.text, "docs/notes.md:1: We changed the retry backoff to 2s.")
        let read = try await controller.callRead(sourceID: id, tool: "read_file", arguments: .object(["path": .string("docs/notes.md")]))
        XCTAssertTrue(read.text.contains("2s"))
        for path in [".env", "credentials.txt", "../../etc/passwd", "alias.md", "linked/away.md", "pipe.md", "docs/../.env",
                     "/etc/passwd", "node_modules/x.js"] {
            let refused = try await controller.callRead(sourceID: id, tool: "read_file", arguments: .object(["path": .string(path)]))
            XCTAssertEqual(refused.text, FolderSource.refusal, path)
        }
        for offset: MCPValue in [.number(-1), .number(1e300), .string("3")] {
            let bad = try await controller.callRead(sourceID: id, tool: "read_file",
                                                    arguments: .object(["path": .string("docs/notes.md"), "offset": offset]))
            XCTAssertTrue(bad.isError)
        }
    }
}

/// Holds a classifier until the test lets it go.
actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var waiting = false

    func wait() async {
        guard !isOpen else { return }
        waiting = true
        await withCheckedContinuation { waiter = $0 }
    }

    func open() { isOpen = true; waiter?.resume(); waiter = nil }

    nonisolated func untilWaiting() async throws {
        for _ in 0..<200 {
            if await waiting { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("The classifier was never reached")
    }
}
