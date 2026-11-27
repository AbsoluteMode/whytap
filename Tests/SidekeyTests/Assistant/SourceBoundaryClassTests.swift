import XCTest
@testable import Sidekey

/// Second review of PR #491 (ticket 629): each boundary is tested as a class,
/// enumerating every input and every surface, not one instance.
@MainActor
final class SourceBoundaryClassTests: XCTestCase {
    static let sentinel = "synthetic_value_for_secret_redaction_check"
    private var box = InMemoryTokenStore.Box()

    // MARK: - Point 1: setup inputs × preview, decision, persistence and launch

    /// Every way a credential can sit on a command line or in an address.
    static var commandLines: [[String]] {
        let s = sentinel
        return [["--token", s], ["--api-key=" + s], ["--access_token", s], ["-e", "GITHUB_TOKEN=" + s],
                ["--header", "Authorization: Bearer " + s], ["-H", "X-Api-Key: " + s], ["--password", s], ["--auth", s],
                ["https://x.example/mcp?token=" + s], ["https://user:" + s + "@x.example/mcp"], ["ghp_" + s],
                ["--client-secret", s], ["--session", s], ["Bearer " + s], ["--url=https://x.example/?key=" + s]]
    }

    static var addresses: [String] {
        let s = sentinel
        return ["https://mcp.example.com/mcp?api_key=" + s, "https://user:" + s + "@mcp.example.com/mcp",
                "https://mcp.example.com/ghp_" + s + "/mcp", "https://mcp.example.com/mcp?sig=" + s,
                "https://mcp.example.com/mcp#access_token=" + s, "https://mcp.example.com/mcp?x=" + s + s]
    }

    private func home(_ files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-" + UUID().uuidString)
        for (path, contents) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func toml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func testNoSetupPathShowsKeepsOrAcceptsACredentialOnACommandLineOrInAnAddress() throws {
        let s = Self.sentinel
        var servers: [String: Any] = [:]
        var codex = ""
        for (index, arguments) in Self.commandLines.enumerated() {
            servers["argv\(index)"] = ["command": "/usr/local/bin/srv", "args": arguments]
            codex += "[mcp_servers.argv\(index)]\ncommand = \"srv\"\nargs = [\(arguments.map(toml).joined(separator: ", "))]\n\n"
            // Refused for another reason first (an unsupported key): the preview is still masked.
            codex += "[mcp_servers.other\(index)]\ncommand = \"srv\"\nstartup_timeout_sec = 5\nargs = [\(arguments.map(toml).joined(separator: ", "))]\n\n"
        }
        for (index, address) in Self.addresses.enumerated() {
            servers["url\(index)"] = ["url": address]
            servers["bad\(index)"] = ["url": address, "timeout": 5]
            codex += "[mcp_servers.url\(index)]\nurl = \(toml(address))\n\n"
        }
        let scan = MCPConfigImporter(home: try home([".cursor/mcp.json": json(["mcpServers": servers]),
                                                     ".codex/config.toml": codex])).scan()
        XCTAssertEqual(scan.candidates.count, servers.count + 2 * Self.commandLines.count + Self.addresses.count, "Every entry is listed")
        for candidate in scan.candidates {
            XCTAssertNil(candidate.draft, candidate.name)
            XCTAssertNotNil(candidate.note, candidate.name)
            for surface in [candidate.summary, candidate.note ?? "", "\(candidate)"] {
                XCTAssertFalse(surface.contains(s), "\(candidate.app) \(candidate.name): \(surface)")
            }
        }
        XCTAssertFalse("\(scan)".contains(s))

        // The custom form, the policy, the preview and `add` for the same inputs.
        for arguments in Self.commandLines {
            let command = (["srv"] + arguments.map { "'" + $0 + "'" }).joined(separator: " ")
            guard case .failure(let problem) = AddSourceSheet.customDraft(name: "", remote: false, command: command, url: "", values: "") else {
                return XCTFail(command)
            }
            XCTAssertFalse(problem.message.contains(s))
            let transport = SourceTransport.stdio(command: "srv", arguments: arguments, directory: nil)
            XCTAssertNotNil(SourceCredentialPolicy.problem(transport, sendsSecrets: false), "\(arguments)")
            XCTAssertFalse(SourceCredentialPolicy.display(transport).contains(s), "\(arguments)")
            XCTAssertFalse("\(SourceCredentialPolicy.redacted(transport))".contains(s))
        }
        for address in Self.addresses {
            guard case .failure(let problem) = AddSourceSheet.customDraft(name: "", remote: true, command: "", url: address, values: "") else {
                return XCTFail(address)
            }
            XCTAssertFalse(problem.message.contains(s))
            XCTAssertNotNil(SourceCredentialPolicy.problem(.http(url: address), sendsSecrets: false), address)
            XCTAssertFalse(SourceCredentialPolicy.display(.http(url: address)).contains(s), address)
        }
    }

    func testOrdinaryArgumentsAndAddressesStayAccepted() {
        for arguments in [["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"], ["--path", "/tmp/x"],
                          ["--port", "3000"], ["-e", "GITHUB_PERSONAL_ACCESS_TOKEN"], ["--keyboard-layout", "us"],
                          ["run", "-i", "--rm", "ghcr.io/github/github-mcp-server"], ["https://example.com/docs"]] {
            XCTAssertNil(SourceCredentialPolicy.problem(.stdio(command: "srv", arguments: arguments, directory: nil), sendsSecrets: false),
                         "\(arguments)")
        }
        for address in ["https://api.githubcopilot.com/mcp/", "https://mcp.linear.app/mcp?project=web", "http://127.0.0.1:3000/mcp"] {
            XCTAssertNil(SourceCredentialPolicy.problem(.http(url: address), sendsSecrets: false), address)
        }
    }

    /// The controller refuses each one at `add`, and a manifest edited to
    /// carry one never launches; nothing persisted or shown contains it.
    func testAddAndLaunchRefuseEveryCredentialFormAndNothingStoredOrShownHasIt() async throws {
        let (controller, directory) = try makeController()
        let transports = Self.commandLines.map { SourceTransport.stdio(command: "/usr/bin/true", arguments: $0, directory: nil) }
            + Self.addresses.map { SourceTransport.http(url: $0) }
        for transport in transports {
            let added = await controller.add(SourceDraft(name: "x", kind: .custom, transport: transport))
            XCTAssertNil(added, "\(SourceCredentialPolicy.display(transport))")
            XCTAssertFalse((controller.error ?? "").contains(Self.sentinel))
        }
        let records = transports.enumerated().map { SourceRecord(id: "t-\($0.offset)", name: "T", kind: .custom, transport: $0.element) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (tampered, tamperedDirectory) = try makeController()
        try FileManager.default.createDirectory(at: tamperedDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: tampered.fileURL)
        tampered.loadIfNeeded()
        XCTAssertEqual(tampered.sources.count, records.count)
        for record in records {
            await tampered.check(record.id)
            guard case .failed(let text) = tampered.statuses[record.id] else { return XCTFail("\(record.id) launched") }
            XCTAssertFalse(text.contains(Self.sentinel))
            XCTAssertFalse(tampered.record(record.id)!.summary.contains(Self.sentinel))
        }
        XCTAssertEqual(tampered.liveClientCount, 0)
    }

    // MARK: - Point 1: every server text × every destination

    /// A server that echoes its token in tool metadata, structured results,
    /// error results, JSON-RPC errors and its stderr: no copy reaches the
    /// manifest, a status line, the classification model, the Agent's
    /// prompt and tools, or a result the Agent receives.
    func testAKnownSecretEchoedByTheServerIsMaskedOnEveryPath() async throws {
        let s = Self.sentinel
        var classified: [String] = []
        let classifier = SourceToolModelClassifier { tools in
            classified.append(SourceToolModelClassifier.prompt(tools)); return nil
        }
        let (controller, _) = try makeController(classifier: classifier)
        let fake = try FakeMCPServer.install()
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directory) }
        var draft = SourceDraft(name: "Leaky", kind: .github, transport: .stdio(command: fake.script.path, arguments: [], directory: nil))
        draft.environment = [SourceValue(name: "FAKE_MODE", secret: false, value: "leak"),
                             SourceValue(name: "FAKE_LOG", secret: false, value: fake.log.path),
                             SourceValue(name: "SECRET_TOKEN", secret: true, value: nil)]
        draft.secrets["SECRET_TOKEN"] = s
        let added = await controller.add(draft)
        let id = try XCTUnwrap(added)
        var seen: [String] = []
        let record = try XCTUnwrap(controller.record(id))
        XCTAssertFalse(record.tools.contains { $0.name.contains("steal") }, "A tool named with the secret is dropped")
        seen.append(try String(contentsOf: controller.fileURL, encoding: .utf8))
        seen.append("\(controller.statuses)")
        seen += classified
        if let catalog = controller.agentCatalog() {
            seen.append(NativeAgentSources.prompt(catalog))
            seen.append("\(NativeAgentSources.definition(catalog))")
        }
        for query in ["plain", "rpc", "exit"] {
            do {
                let result = try await controller.callRead(sourceID: id, tool: "search_issues", arguments: .object(["query": .string(query)]))
                seen.append(result.text)
            } catch let error as MCPError {
                seen += [error.message, error.agentMessage, "\(error)"]
            }
            seen.append("\(controller.statuses)")
        }
        let me = try await controller.callRead(sourceID: id, tool: "get_me", arguments: .object([:]))
        seen.append(me.text)
        XCTAssertTrue(me.text.contains("octo"), "Structured content still arrives, masked")
        for (index, text) in seen.enumerated() {
            XCTAssertFalse(text.contains(s), "surface \(index): \(text.prefix(300))")
        }
        XCTAssertTrue(seen.joined().contains(SourceCredentialPolicy.masked))
    }

    func testTheMaskCoversEscapedForms() {
        let mask = SourceSecretMask(["Bearer abc\"def/ghi"])
        XCTAssertFalse(mask(#"{"t":"abc\"def\/ghi"}"#).contains("def"))
        XCTAssertFalse(mask("abc%22def%2Fghi").contains("def"))
        XCTAssertFalse(mask("token abc\"def/ghi").contains("def"))
        XCTAssertEqual(SourceSecretMask(["true"])("true"), "true", "Short values are not treated as secrets")
    }

    // MARK: - Point 2: every await before a call × every revocation

    enum Revocation: CaseIterable { case disable, remove, reclassify, stopAll }
    enum Point: CaseIterable { case resolve, environment, connect, list, classify, call }

    func testARevocationAtEveryAwaitBeforeACallWins() async throws {
        for point in Point.allCases {
            for revocation in Revocation.allCases {
                try await revoke(revocation, at: point)
            }
        }
    }

    private func revoke(_ revocation: Revocation, at point: Point) async throws {
        let resolveGate = TestCheckpoint(), environmentGate = TestCheckpoint(), classifyGate = TestCheckpoint()
        let classifier = SourceToolModelClassifier { _ in await classifyGate.pass(); return nil }
        let environment = SourceProcessEnvironment(
            resolve: { await resolveGate.pass(); return $0.hasPrefix("/") ? $0 : nil },
            base: { await environmentGate.pass(); return ["PATH": "/usr/bin:/bin"] })
        let (controller, _) = try makeController(classifier: classifier, environment: environment)
        let fake = try FakeMCPServer.install()
        let modeFile = fake.directory.appendingPathComponent("mode")
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        var draft = SourceDraft(name: "Tracker", kind: .github, transport: .stdio(command: fake.script.path, arguments: [], directory: nil))
        draft.environment = [SourceValue(name: "FAKE_LOG", secret: false, value: fake.log.path),
                             SourceValue(name: "FAKE_MODE_FILE", secret: false, value: modeFile.path)]
        let added = await controller.add(draft)
        let id = try XCTUnwrap(added)
        XCTAssertEqual(FakeMCPServer.calls(fake.log), ["get_me {}"], "proof")
        await controller.stop(id)
        let label = "\(revocation) at \(point)"
        switch point {
        case .resolve: await resolveGate.arm()
        case .environment: await environmentGate.arm()
        case .connect: FakeMCPServer.setMode("slow_init", file: modeFile)
        case .list: FakeMCPServer.setMode("slow_list", file: modeFile)
        case .classify: FakeMCPServer.setMode("new_tool", file: modeFile); await classifyGate.arm()
        case .call: FakeMCPServer.setMode("slow_call", file: modeFile)
        }
        let calling = Task { try await controller.callRead(sourceID: id, tool: "get_me", arguments: .object([:])) }
        switch point {
        case .resolve: try await resolveGate.untilWaiting()
        case .environment: try await environmentGate.untilWaiting()
        case .classify: try await classifyGate.untilWaiting()
        case .connect, .list: try await Task.sleep(nanoseconds: 600_000_000)
        case .call:
            for _ in 0..<100 where FakeMCPServer.calls(fake.log).count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        switch revocation {
        case .disable: await controller.setEnabled(false, id: id)
        case .remove: await controller.remove(id)
        case .reclassify: controller.setClass(.outward, tool: "get_me", id: id)
        case .stopAll: await controller.stopAll()
        }
        await resolveGate.release(); await environmentGate.release(); await classifyGate.release()
        do { let result = try await calling.value; XCTFail("\(label): got \(result.text)") }
        catch {}
        let calls = FakeMCPServer.calls(fake.log)
        if point == .call {
            XCTAssertEqual(calls, ["get_me {}", "get_me {}"], "\(label): the late answer is discarded")
        } else {
            XCTAssertEqual(calls, ["get_me {}"], "\(label): nothing reached the server")
        }
        if revocation != .reclassify {
            XCTAssertEqual(controller.liveClientCount, 0, "\(label): nothing left running")
        }
        if revocation != .stopAll {
            // Stopping is not revoking: the source stays approved and reconnects (and re-lists) on its next call.
            XCTAssertFalse(controller.agentCatalog()?.tools.contains { $0.sourceID == id && $0.tool == "get_me" } ?? false, label)
        }
        await controller.stopAll()
    }

    // MARK: - Third review (ticket 644), class 1: masking happens before every clip

    /// Any 10-character piece of the sentinel: a clipped fragment counts as a leak.
    static func leaksFragment(_ text: String) -> Bool {
        let secret = Array(sentinel)
        return (0...(secret.count - 10)).contains { text.contains(String(secret[$0..<$0 + 10])) }
    }

    /// The server places the known value right across each limit Whytap
    /// applies (tool description 2,000, result 24,000, structured content,
    /// error result 2,000 for the model, proof 120, JSON-RPC error 200, exit
    /// detail 200 and the 4 KB stderr tail): no surface keeps a fragment.
    func testAValueStraddlingEveryClipLimitLeavesNoFragmentOnAnySurface() async throws {
        let s = Self.sentinel
        var classified: [String] = []
        let classifier = SourceToolModelClassifier { tools in classified.append(SourceToolModelClassifier.prompt(tools)); return nil }
        let (controller, _) = try makeController(classifier: classifier)
        let fake = try FakeMCPServer.install()
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directory) }
        var draft = SourceDraft(name: "Clip", kind: .github, transport: .stdio(command: fake.script.path, arguments: [], directory: nil))
        draft.environment = [SourceValue(name: "FAKE_MODE", secret: false, value: "clip"),
                             SourceValue(name: "SECRET_TOKEN", secret: true, value: nil)]
        draft.secrets["SECRET_TOKEN"] = s
        let added = await controller.add(draft)
        let id = try XCTUnwrap(added)
        var seen: [String] = []
        seen.append("\(controller.statuses)")          // proof failure, clipped to 120
        seen.append(try String(contentsOf: controller.fileURL, encoding: .utf8))
        seen += classified
        seen += controller.record(id)?.tools.map(\.description) ?? []
        let catalog = try XCTUnwrap(controller.agentCatalog())
        seen.append(NativeAgentSources.prompt(catalog))
        let tool = try XCTUnwrap(catalog.tools.first { $0.tool == "search_issues" })
        for query in ["text", "structured", "iserror", "rpc", "exit", "exitcut"] {
            let call = NativeAgentToolCall(id: query, name: NativeAgentSources.toolName,
                                           arguments: ["tool": tool.id, "arguments": #"{"query":"\#(query)"}"#])
            let (result, _) = await NativeAgentSources.execute(call, catalog: catalog)
            seen.append(result.text)                      // what the model receives
            do { seen.append(try await controller.callRead(sourceID: id, tool: "search_issues",
                                                           arguments: .object(["query": .string(query)])).text) }
            catch let error as MCPError { seen += [error.message, error.agentMessage, "\(error)"] }
            seen.append("\(controller.statuses)")         // exit and error text in Settings
        }
        for (index, text) in seen.enumerated() {
            XCTAssertFalse(Self.leaksFragment(text), "surface \(index): …\(text.suffix(260))")
        }
        XCTAssertTrue(seen.joined().contains(SourceCredentialPolicy.masked), "The value was there and was masked")
    }

    func testAnUnsupportedProtocolStringIsMaskedBeforeItsClip() async throws {
        let fake = try FakeMCPServer.install()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let launch = FakeMCPServer.launch(fake.script, mode: "clip_protocol", extra: ["SECRET_TOKEN": Self.sentinel])
        let client = MCPClient(transport: MCPStdioTransport(launch: launch), mask: SourceSecretMask([Self.sentinel]))
        do { try await client.connect(timeout: 10); XCTFail() }
        catch let error as MCPError {
            guard case .unsupportedProtocol = error else { return XCTFail("\(error)") }
            XCTAssertFalse(Self.leaksFragment(error.message), error.message)
        }
        await client.close()
    }

    // MARK: - Class 2: a list that changed while it was being classified is never applied

    func testAListOvertakenByAChangeNoticeDuringClassificationIsReadAgainNotApplied() async throws {
        let gate = TestCheckpoint()
        await gate.arm()
        var runs = 0
        let classifier = SourceToolModelClassifier { _ in runs += 1; await gate.pass(); return nil }
        let (controller, _) = try makeController(classifier: classifier)
        let fake = try FakeMCPServer.install()
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directory) }
        var draft = SourceDraft(name: "Notes", kind: .github, transport: .stdio(command: fake.script.path, arguments: [], directory: nil))
        // The server announces a change right after its first list, then describes search_issues differently.
        draft.environment = [SourceValue(name: "FAKE_MODE", secret: false, value: "clip"),
                             SourceValue(name: "FAKE_NOTIFY_AFTER_LIST", secret: false, value: "1"),
                             SourceValue(name: "FAKE_LOG", secret: false, value: fake.log.path)]
        let adding = Task { await controller.add(draft) }
        try await gate.untilWaiting()
        try await Task.sleep(nanoseconds: 300_000_000)    // the notice arrives while classification waits
        await gate.release()
        let addedID = await adding.value
        let id = try XCTUnwrap(addedID)
        let record = try XCTUnwrap(controller.record(id))
        XCTAssertGreaterThanOrEqual(runs, 1)
        XCTAssertEqual(record.tools.first { $0.name == "search_issues" }?.description,
                       "Search issues by text. NEW: also sends them elsewhere.",
                       "The list applied is the one read after the notice, not the stale one")
    }

    // MARK: - Class 2: folder sources, also ones loaded from disk, are revoked mid-read

    func testAFolderReadInFlightIsDiscardedByEveryRevocationIncludingAFolderLoadedFromDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folder-rev-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("retry notes".utf8).write(to: folder.appendingPathComponent("notes.md"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let (writer, directory) = try makeController()
        let added = await writer.add(SourceDraft(name: "Notes", kind: .folder, transport: .folder(path: folder.path)))
        let id = try XCTUnwrap(added)
        for revocation in Revocation.allCases {
            // A fresh controller loads the folder from disk, as after a relaunch.
            let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: InMemoryTokenStore.Box()) })
            let loaded = SourcesController(directory: directory, keys: keys, classifier: nil)
            loaded.loadIfNeeded()
            let gate = TestCheckpoint()
            await gate.arm()
            loaded.folderReader = { folder, tool, arguments in
                await gate.pass()
                return try await SourcesController.folderCall(folder, tool: tool, arguments: arguments)
            }
            let reading = Task { try await loaded.callRead(sourceID: id, tool: "search", arguments: .object(["query": .string("retry")])) }
            try await gate.untilWaiting()
            switch revocation {
            case .disable: await loaded.setEnabled(false, id: id)
            case .remove: await loaded.remove(id)
            case .reclassify: loaded.setClass(.outward, tool: "search", id: id)
            case .stopAll: await loaded.stopAll()
            }
            await gate.release()
            do { let result = try await reading.value; XCTFail("\(revocation): got \(result.text)") }
            catch let error as MCPError { XCTAssertEqual(error, .notAllowed, "\(revocation)") }
            // Put the manifest back for the next case.
            try JSONEncoder().encode(writer.sources).write(to: writer.fileURL)
        }
    }

    // MARK: - Class 2: the send boundary and the answer are bound to the approved list

    func testAuthorizationIsCheckedAtTheSendBoundaryAndOnTheAnswer() async throws {
        // Revoked between the client's check and the transport's first byte.
        let transport = ScriptedTransport()
        let client = MCPClient(transport: transport)
        try await client.connect(timeout: 5)
        let (tools, epoch) = try await client.listTools(timeout: 5)
        let lease = SourceLease()
        transport.holdCalls = true
        let calling = Task {
            try await client.callTool("search", arguments: .object([:]), timeout: 5, maxCharacters: 100,
                                      lease: lease, epoch: epoch, expectedPin: tools[0].pinHash)
        }
        try await transport.untilHeld()
        lease.revoke()
        transport.releaseCalls()
        do { _ = try await calling.value; XCTFail() } catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        XCTAssertEqual(transport.sentCalls, 0, "Nothing left after the revocation")

        // A change notice that precedes the answer voids it.
        let (fresh, current) = try await client.listTools(timeout: 5)
        transport.noticeBeforeAnswer = true
        do {
            _ = try await client.callTool("search", arguments: .object([:]), timeout: 5, maxCharacters: 100,
                                          lease: SourceLease(), epoch: current, expectedPin: fresh[0].pinHash)
            XCTFail()
        } catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        XCTAssertEqual(transport.sentCalls, 1, "It was sent, but its answer was not returned")
        await client.close()
    }

    // MARK: - Class 3: one deadline from the start of a connect; every write

    func testConnectDeadlineCoversASlowTransportStartAndClosesItWhenItFinishesLate() async throws {
        let transport = ScriptedTransport()
        transport.startDelay = 0.25
        let client = MCPClient(transport: transport)
        let started = Date()
        do { try await client.connect(timeout: 0.025); XCTFail() }
        catch let error as MCPError { guard case .timedOut = error else { return XCTFail("\(error)") } }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "The deadline holds while the transport starts")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(transport.closedAfterStart, "A start that finished late was closed")
    }

    func testAWriteChecksItsDeadlineAndAuthorizationEvenWhenThePipeHasRoom() async throws {
        let lines = LockedBox<Int>()
        lines.set(0)
        let process = try MCPProcess(executable: "/bin/cat", arguments: [], environment: [:],
                                     onLine: { _ in lines.set((lines.value ?? 0) + 1) }, onExit: { _, _, _ in })
        defer { process.stop() }
        do { try await process.write(Data("{}".utf8), deadline: Date().addingTimeInterval(-1)); XCTFail() }
        catch let error as MCPError { guard case .timedOut = error else { return XCTFail("\(error)") } }
        do { try await process.write(Data("{}".utf8), deadline: .distantFuture, authorize: { false }); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        try await process.write(Data("{}".utf8), deadline: .distantFuture)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(lines.value, 1, "Only the authorized, timely write reached the pipe")
    }

    func testAnHTTPSendChecksAuthorizationAndDeadlineBeforeTheRequest() async throws {
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data("{}".utf8)) }
        let transport = MCPHTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!, headers: [:], session: session)
        try await transport.start { _ in }
        do { try await transport.send(Data("{}".utf8), responseID: 1, deadline: .distantFuture, authorize: { false }); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .notAllowed) }
        do { try await transport.send(Data("{}".utf8), responseID: 1, deadline: Date().addingTimeInterval(-1)); XCTFail() }
        catch let error as MCPError { guard case .timedOut = error else { return XCTFail("\(error)") } }
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: - Fixture

    private func makeController(classifier: SourceToolModelClassifier? = nil,
                                environment: SourceProcessEnvironment? = nil) throws -> (SourcesController, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sources-" + UUID().uuidString)
        box = InMemoryTokenStore.Box()
        let box = box
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let environment = environment ?? SourceProcessEnvironment(resolve: { $0.hasPrefix("/") ? $0 : nil },
                                                                  base: { ["PATH": "/usr/bin:/bin"] })
        let controller = SourcesController(directory: directory, keys: keys, classifier: classifier, environment: environment)
        addTeardownBlock { @MainActor in
            await controller.stopAll()
            try? FileManager.default.removeItem(at: directory)
        }
        return (controller, directory)
    }
}

/// An await point a test can hold: `pass()` returns at once until armed.
actor TestCheckpoint {
    private var armed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = false

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        waiting = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        armed = false
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    nonisolated func untilWaiting() async throws {
        for _ in 0..<250 {
            if await waiting { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("The checkpoint was never reached")
    }
}

/// An in-memory MCP server for client tests: it answers initialize,
/// tools/list and tools/call, can hold calls at the send boundary, announce a
/// change before an answer, and start slowly.
final class ScriptedTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onEvent: (@Sendable (MCPTransportEvent) -> Void)?
    private var held: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var started = false
    var startDelay: TimeInterval = 0
    var holdCalls = false
    var noticeBeforeAnswer = false
    private(set) var sentCalls = 0
    private(set) var closedAfterStart = false

    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws {
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        lock.withLock { self.onEvent = onEvent; started = true }
    }

    func send(_ message: Data, responseID: Int?, deadline: Date, authorize: @escaping @Sendable () -> Bool) async throws {
        guard let value = try? MCPValue.decode(message), let method = value["method"]?.string else { return }
        let deliver = lock.withLock { onEvent }
        if method == "tools/call", holdCalls {
            await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } }
        }
        guard authorize() else { throw MCPError.notAllowed }
        guard let id = value["id"] else { return }
        let result: MCPValue
        switch method {
        case "initialize": result = .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:])])
        case "tools/list": result = .object(["tools": .array([.object(["name": .string("search"), "description": .string("s"),
                                                                       "inputSchema": .object(["type": .string("object")])])])])
        default:
            lock.withLock { sentCalls += 1 }
            if noticeBeforeAnswer {
                deliver?(.message(try MCPValue.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")]).encoded()))
            }
            result = .object(["content": .array([.object(["type": .string("text"), "text": .string("answer")])])])
        }
        deliver?(.message(try MCPValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encoded()))
    }

    func untilHeld() async throws {
        for _ in 0..<200 {
            if lock.withLock({ !held.isEmpty }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("No call reached the transport")
    }

    func releaseCalls() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { held = [] }; holdCalls = false; return held }
        waiting.forEach { $0.resume() }
    }

    func setProtocolVersion(_ version: String) {}

    func close() async {
        lock.withLock {
            closed = true
            if started { closedAfterStart = true }
        }
    }
}
