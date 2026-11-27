import XCTest
@testable import Sidekey

/// Second review of PR #491 (ticket 629), points 4–6 as classes: every kind
/// of folder entry × every folder operation, every import form Whytap can't
/// carry × a reason, the declared working folder, and the HTTP session.
final class SourceInputClassTests: XCTestCase {
    // MARK: - Point 4: entry kinds × operations

    private func folder() throws -> (root: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("folder-class-" + UUID().uuidString)
        let root = base.appendingPathComponent("root"), outside = base.appendingPathComponent("outside")
        let manager = FileManager.default
        for directory in ["docs", "node_modules", "linkedparent"] {
            try manager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        func write(_ path: String, in directory: URL = root) throws {
            try Data("marker in \(path)".utf8).write(to: directory.appendingPathComponent(path))
        }
        try write("docs/allowed.md")
        try write(".hidden.md"); try write("credentials.md"); try write("node_modules/dep.md")
        try write("away.md", in: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("link-inside.md"),
                                       withDestinationURL: root.appendingPathComponent("docs/allowed.md"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link-outside.md"),
                                       withDestinationURL: outside.appendingPathComponent("away.md"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: outside)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo.md").path, 0o600), 0)
        return (root, outside)
    }

    private func source(_ root: URL) throws -> FolderSource {
        FolderSource(identity: try XCTUnwrap(FolderSource.identify(root.path)))
    }

    func testOnlyAllowedRegularFilesAreListedSearchedOrReadWhateverTheEntryKind() throws {
        let (root, _) = try folder()
        let folder = try source(root)
        let refused = [".hidden.md", "credentials.md", "node_modules/dep.md", "link-inside.md", "link-outside.md",
                       "linkdir/away.md", "fifo.md", "docs/../credentials.md", "../outside/away.md"]
        XCTAssertEqual(try folder.countFiles(), 1, "count uses the same walk")
        let byContent = try folder.call("search", arguments: .object(["query": .string("marker")]), maxCharacters: 10_000).text
        XCTAssertEqual(byContent, "docs/allowed.md:1: marker in docs/allowed.md")
        for name in ["link", "fifo", "away", "hidden", "credentials", "dep"] {
            XCTAssertEqual(try folder.call("search", arguments: .object(["query": .string(name)]), maxCharacters: 10_000).text,
                           "No matches.", "A name is reported only after its entry opened as an allowed regular file: \(name)")
        }
        XCTAssertTrue(try folder.call("read_file", arguments: .object(["path": .string("docs/allowed.md")]), maxCharacters: 1000)
            .text.contains("marker"))
        for path in refused {
            let text = try folder.call("read_file", arguments: .object(["path": .string(path)]), maxCharacters: 1000).text
            XCTAssertFalse(text.contains("marker"), path)
        }
    }

    /// The selected folder is the directory that was added: replacing it
    /// (or a folder on its path) with another directory or a link refuses
    /// every operation instead of reading the replacement.
    func testAReplacedSelectedFolderOrAncestorIsRefusedByEveryOperation() throws {
        let (root, outside) = try folder()
        let folder = try source(root)
        let manager = FileManager.default
        let moved = root.deletingLastPathComponent().appendingPathComponent("moved")
        try manager.moveItem(at: root, to: moved)
        try manager.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("marker replacement".utf8).write(to: root.appendingPathComponent("docs/allowed.md"))
        func assertRefused(_ label: String) throws {
            XCTAssertNil(folder.openRoot(), label)
            XCTAssertThrowsError(try folder.countFiles(), label)
            XCTAssertFalse(try folder.call("search", arguments: .object(["query": .string("marker")]), maxCharacters: 1000).text.contains("marker"), label)
            XCTAssertFalse(try folder.call("read_file", arguments: .object(["path": .string("docs/allowed.md")]), maxCharacters: 1000).text.contains("marker"), label)
        }
        try assertRefused("another directory at the same path")
        try manager.removeItem(at: root)
        try manager.createSymbolicLink(at: root, withDestinationURL: moved)
        try assertRefused("a link to the original at the same path")
        // A folder added through a link is pinned to its real path.
        let alias = outside.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: moved)
        let identity = try XCTUnwrap(FolderSource.identify(alias.path))
        XCTAssertFalse(identity.path.contains("/alias"))
        XCTAssertEqual(try FolderSource(identity: identity).countFiles(), 1)
    }

    func testFolderReadsStopWhenCancelled() async throws {
        let (root, _) = try folder()
        let folder = try source(root)
        let task = Task { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try folder.countFiles()
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {}
        let file = open(root.appendingPathComponent("docs/allowed.md").path, O_RDONLY)
        defer { close(file) }
        let read = Task { () throws -> Data in
            withUnsafeCurrentTask { $0?.cancel() }
            return try FolderSource.read(file, offset: 0, limit: 100)
        }
        do { _ = try await read.value; XCTFail() } catch is CancellationError {}
    }

    // MARK: - Point 5: forms Whytap can't carry × a reason

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

    func testEveryJSONFormWhytapCantRunTheSameWayIsRefusedWithAReason() throws {
        let entries: [String: Any] = [
            "argsString": ["command": "srv", "args": "--flag"],
            "argsNumber": ["command": "srv", "args": ["a", 1]],
            "envArray": ["command": "srv", "env": ["A=1"]],
            "envNumber": ["command": "srv", "env": ["PORT": 3000]],
            "headersString": ["url": "https://x.example/mcp", "headers": "Authorization: x"],
            "commandNumber": ["command": 5],
            "cwdNumber": ["command": "srv", "cwd": 1],
            "typeGrpc": ["type": "grpc", "url": "https://x.example/mcp"],
            "typeSSE": ["type": "sse", "url": "https://x.example/sse"],
            "typeStdioWithURL": ["type": "stdio", "url": "https://x.example/mcp"],
            "typeHTTPWithCommand": ["type": "http", "command": "srv"],
            "both": ["command": "srv", "url": "https://x.example/mcp"],
            "neither": ["args": ["a"]],
            "disabled": ["command": "srv", "disabled": true],
            "enabledFalse": ["command": "srv", "enabled": false],
            "unknownKey": ["command": "srv", "envFile": ".env"],
            "timeout": ["command": "srv", "timeout": 30],
            "headersOnCommand": ["command": "srv", "headers": ["X": "y"]],
            "envOnURL": ["url": "https://x.example/mcp", "env": ["A": "b"]],
            "twoAddresses": ["url": "https://x.example/mcp", "serverUrl": "https://y.example/mcp"],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": entries])
        let scan = MCPConfigImporter(enabled: true, home: try home([".cursor/mcp.json": String(decoding: data, as: UTF8.self)])).scan()
        XCTAssertEqual(scan.candidates.count, entries.count)
        for candidate in scan.candidates {
            XCTAssertNil(candidate.draft, candidate.name)
            XCTAssertFalse((candidate.note ?? "").isEmpty, candidate.name)
        }
        let ok = MCPConfigImporter(enabled: true, home: try home([".cursor/mcp.json": #"{"mcpServers": {"a": {"type": "stdio", "command": "srv", "args": ["-y"], "env": {"A": "b"}, "cwd": "/tmp", "description": "x"}, "b": {"type": "http", "url": "https://x.example/mcp", "headers": {"Authorization": "Bearer ${T}"}}}}"#])).scan()
        XCTAssertEqual(ok.candidates.compactMap(\.draft).count, 2)
    }

    func testEveryCodexFormWhytapCantRunTheSameWayIsRefusedWithAReason() throws {
        let entries = [
            "timeout": "command = \"srv\"\nstartup_timeout_sec = 10",
            "toolTimeout": "command = \"srv\"\ntool_timeout_sec = 10",
            "enabledFalse": "command = \"srv\"\nenabled = false",
            "enabledText": "command = \"srv\"\nenabled = \"yes\"",
            "filter": "command = \"srv\"\nenabled_tools = [\"a\"]",
            "argsString": "command = \"srv\"\nargs = \"-y\"",
            "envNumber": "command = \"srv\"\nenv = { PORT = 3000 }",
            "envArray": "command = \"srv\"\nenv = [\"A\"]",
            "envVarsBad": "command = \"srv\"\nenv_vars = [\"A B\"]",
            "bearerOnCommand": "command = \"srv\"\nbearer_token_env_var = \"T\"",
            "headersNumber": "url = \"https://x.example/mcp\"\nhttp_headers = { X = 1 }",
            "argsOnURL": "url = \"https://x.example/mcp\"\nargs = [\"a\"]",
            "both": "command = \"srv\"\nurl = \"https://x.example/mcp\"",
            "escape": "command = \"srv\"\nargs = [\"a\\qb\"]",
            "dottedInline": "command = \"srv\"\nenv = { a.b = \"c\" }",
            "repeated": "command = \"srv\"\ncommand = \"other\"",
            "multilineString": "command = \"\"\"\nsrv\n\"\"\"",
            "bearerTwice": "url = \"https://x.example/mcp\"\nbearer_token_env_var = \"T\"\nhttp_headers = { Authorization = \"x\" }",
        ]
        var toml = ""
        for (name, body) in entries.sorted(by: { $0.key < $1.key }) { toml += "[mcp_servers.\(name)]\n\(body)\n\n" }
        toml += "[mcp_servers.subtable]\ncommand = \"srv\"\n[mcp_servers.subtable.env]\nA = \"b\"\n[mcp_servers.subtable.extra]\nx = 1\n\n"
        let scan = MCPConfigImporter(enabled: true, home: try home([".codex/config.toml": toml])).scan()
        let byName = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.name, $0) })
        for name in entries.keys.sorted() + ["subtable"] {
            let candidate = try XCTUnwrap(byName[name], name)
            XCTAssertNil(candidate.draft, name)
            XCTAssertFalse((candidate.note ?? "").isEmpty, name)
        }
        let good = MCPConfigImporter(enabled: true, home: try home([".codex/config.toml": "[mcp_servers.ok]\ncommand = \"srv\"\nargs = [\"tab\\there\", \"\\u00e9\"]\nenabled = true\nenv_vars = [\"HOME_TOKEN\"]\n"])).scan()
        let draft = try XCTUnwrap(good.candidates.first?.draft)
        XCTAssertEqual(draft.transport, .stdio(command: "srv", arguments: ["tab\there", "é"], directory: nil))
        XCTAssertEqual(draft.missing, ["HOME_TOKEN"], "env_vars become values to paste")
    }

    /// The declared working folder is part of the launch.
    func testTheWorkingFolderIsSetOrTheServerDoesNotStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cwd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let printed = expectation(description: "pwd")
        let line = LockedBox<String>()
        let process = try MCPProcess(executable: "/bin/pwd", arguments: ["-P"], environment: [:], directory: directory,
                                     onLine: { line.set(String(decoding: $0, as: UTF8.self)) }, onExit: { _, _, _ in printed.fulfill() })
        wait(for: [printed], timeout: 5)
        process.stop()
        XCTAssertEqual(line.value, FolderSource.identify(directory.path)?.path)
        XCTAssertThrowsError(try MCPProcess(executable: "/bin/pwd", arguments: [], environment: [:],
                                            directory: directory.appendingPathComponent("missing"),
                                            onLine: { _ in }, onExit: { _, _, _ in })) { error in
            guard case .commandNotFound(let what) = error as? MCPError else { return XCTFail("\(error)") }
            XCTAssertTrue(what.contains("working folder"), what)
        }
    }

    // MARK: - Point 2/6: an HTTP session is fixed by initialize

    func testAnotherSessionOnALaterAnswerEndsTheClient() async throws {
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            let body = StubURLProtocol.capturedBodies.last ?? Data()
            let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            guard let id = message["id"] else { return (202, ["Mcp-Session-Id": "session-1"], Data()) }
            let method = message["method"] as? String ?? ""
            let result: [String: Any] = method == "initialize"
                ? ["protocolVersion": "2025-06-18", "capabilities": [:]]
                : ["tools": [["name": "search", "description": "s", "inputSchema": ["type": "object"]]]]
            let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            return (200, ["Content-Type": "application/json", "Mcp-Session-Id": method == "initialize" ? "session-1" : "session-2"], data)
        }
        let client = MCPClient(transport: MCPHTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!, headers: [:], session: session))
        try await client.connect(timeout: 5)
        do { _ = try await client.listTools(timeout: 5); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .sessionExpired) }
        let open = await client.isOpen
        XCTAssertFalse(open, "Approval never carries over to another session")
        let epoch = await client.currentEpoch
        XCTAssertNil(epoch)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}
