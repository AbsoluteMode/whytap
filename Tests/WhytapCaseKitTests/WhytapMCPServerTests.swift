import XCTest
@testable import WhytapCaseKit

/// `whytap mcp`: one server with the application tools and the names-only Case
/// tools. Case calls are the same broker requests `whytap case mcp` sends, so
/// the broker's registration, scope and approval checks are unchanged.
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
final class WhytapMCPServerTests: XCTestCase {
    private let helperPath = "/Applications/Whytap.app/Contents/Helpers/whytap"

    /// Answers application controls; Case listings answer `caseAnswer`.
    private final class Broker: CaseBrokerCalling, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [CaseBrokerRequest] = []
        let caseAnswer: CaseBrokerResponse
        init(caseAnswer: CaseBrokerResponse) { self.caseAnswer = caseAnswer }
        var requests: [CaseBrokerRequest] { lock.withLock { sent } }
        func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
            lock.withLock { sent.append(request) }
            if case .appControl = request { return .appControl(.success(.object(["build": .string("test-build")]))) }
            return caseAnswer
        }
    }

    private func unified(_ broker: Broker, accessProbe: (() -> Void)? = nil) -> AppControlMCPServer {
        let command = AppControlCommand(client: broker)
        return AppControlMCPServer(accessProbe: accessProbe,
                                   caseServer: CaseMCPServer(client: broker, executablePath: helperPath),
                                   call: command.call)
    }

    private func decode(_ line: String?) throws -> AppControlValue {
        try JSONDecoder().decode(AppControlValue.self, from: Data(try XCTUnwrap(line).utf8))
    }

    private func toolNames(_ line: String?) throws -> [String] {
        try decode(line).object?["result"]?.object?["tools"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
    }

    /// No request the unified server sends may ask for a value or run a command.
    private func assertNamesOrAppControlOnly(_ requests: [CaseBrokerRequest], file: StaticString = #filePath, line: UInt = #line) {
        for request in requests {
            switch request {
            case .appControl, .listKeys, .listProjects: break
            case .resolveRun: XCTFail("The MCP server must never resolve a run", file: file, line: line)
            }
        }
    }

    // MARK: One server, both sets of tools

    func test_one_server_lists_every_app_tool_and_both_case_tools() throws {
        let server = unified(Broker(caseAnswer: .projects([])))
        let names = try toolNames(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let appOnly = try toolNames(AppControlMCPServer { _ in .success(.null) }
            .handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        XCTAssertEqual(names, appOnly + ["case_list_projects", "case_list_keys"])
        XCTAssertEqual(Set(names).count, names.count, "no tool name twice")
        XCTAssertTrue(names.contains("whytap_meetings_search"))
        XCTAssertTrue(names.contains("whytap_todo_add"))
        XCTAssertFalse(names.contains("whytap_capture_screen"), "screen capture stays in the agent's own server")
        XCTAssertFalse(names.contains { $0.contains("run") || $0.contains("value") || $0.contains("secret") })

        // The Case tools are the Case server's own definitions, unchanged.
        let caseServer = CaseMCPServer(client: nil, executablePath: helperPath)
        let caseListing = try decode(caseServer.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let unifiedListing = try decode(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        XCTAssertEqual(Array(unifiedListing.object?["result"]?.object?["tools"]?.array?.suffix(2) ?? []),
                       caseListing.object?["result"]?.object?["tools"]?.array)
    }

    func test_initialize_names_one_server_and_carries_both_guides() throws {
        let reply = try decode(unified(Broker(caseAnswer: .projects([])))
            .handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let result = try XCTUnwrap(reply.object?["result"]?.object)
        XCTAssertEqual(result["serverInfo"]?.object?["name"], .string("whytap"))
        XCTAssertEqual(result["protocolVersion"], .string("2025-06-18"))
        let instructions = try XCTUnwrap(result["instructions"]?.string)
        XCTAssertTrue(instructions.hasPrefix("Control the running Whytap app"))
        XCTAssertTrue(instructions.contains("whytap_meetings_search"))
        XCTAssertTrue(instructions.contains("Whytap Case keeps secrets on this Mac. You can see project and key names, never values."))
        XCTAssertTrue(instructions.contains("\(helperPath) case run --only KEY_NAME"))
        XCTAssertTrue(instructions.contains("No key values, clipboard, shell commands or app installation here."))
        XCTAssertFalse(instructions.contains("No keys,"), "key names are offered here, values are not")
    }

    func test_case_tools_send_names_only_requests_and_render_no_values() throws {
        let broker = Broker(caseAnswer: .keys([
            CaseKeyInfo(name: "OPENAI_KEY", description: "main", project: "App"),
            CaseKeyInfo(name: "SONIOX_API_KEY", description: "Speech", project: "App"),
        ]))
        let server = unified(broker)
        let reply = try XCTUnwrap(server.handle(line:
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"case_list_keys","arguments":{"query":"speech"}}}"#))
        let result = try XCTUnwrap(try decode(reply).object?["result"]?.object)
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["content"]?.array?.first?.object?["text"], .string("SONIOX_API_KEY — Speech [App]"))
        XCTAssertEqual(try decode(reply).object?["id"], .int(7))
        XCTAssertEqual(broker.requests, [.listKeys(project: nil)])

        let projects = Broker(caseAnswer: .projects([CaseProjectInfo(name: "App", description: "main", keyCount: 2)]))
        let listing = try XCTUnwrap(unified(projects).handle(line:
            #"{"jsonrpc":"2.0","id":"p","method":"tools/call","params":{"name":"case_list_projects"}}"#))
        XCTAssertTrue(listing.contains("App — main (2 keys)"))
        XCTAssertEqual(projects.requests, [.listProjects])

        // A broker that misbehaves and answers with an environment renders nothing.
        let evil = Broker(caseAnswer: .runEnvironment(["K": "sk-secret-123"]))
        let out = try XCTUnwrap(unified(evil).handle(line:
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"case_list_keys"}}"#))
        XCTAssertFalse(out.contains("sk-secret-123"))
        XCTAssertEqual(try decode(out).object?["result"]?.object?["isError"], .bool(true))
        assertNamesOrAppControlOnly(broker.requests + projects.requests + evil.requests)
    }

    /// The broker decides who may list Case names, exactly as for `case mcp`.
    /// A refusal there leaves the application tools of the same server working.
    func test_unregistered_client_gets_no_case_data_but_app_controls_still_work() throws {
        let broker = Broker(caseAnswer: .denied(reason: .notRegistered))
        let server = unified(broker)
        let denied = try XCTUnwrap(server.handle(line:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_keys","arguments":{"query":"KEY"}}}"#))
        let deniedResult = try XCTUnwrap(try decode(denied).object?["result"]?.object)
        XCTAssertEqual(deniedResult["isError"], .bool(true))
        let text = try XCTUnwrap(deniedResult["content"]?.array?.first?.object?["text"]?.string)
        XCTAssertTrue(text.hasPrefix("Access denied:"))
        XCTAssertTrue(text.contains("Case -> Connect"))

        // The same denial text `whytap case mcp` gives.
        let old = try XCTUnwrap(CaseMCPServer(client: broker, executablePath: helperPath).handle(line:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_keys","arguments":{"query":"KEY"}}}"#))
        XCTAssertEqual(try decode(old).object?["result"]?.object?["content"], deniedResult["content"])

        let state = try XCTUnwrap(server.handle(line:
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"whytap_get_state"}}"#))
        XCTAssertTrue(state.contains("test-build"))
        XCTAssertEqual(try decode(state).object?["result"]?.object?["isError"], .bool(false))
        // One listing each from the new and the old server, then the app read.
        XCTAssertEqual(broker.requests, [.listKeys(project: nil), .listKeys(project: nil), .appControl(AppControlRequest("get_state"))])
        assertNamesOrAppControlOnly(broker.requests)
    }

    func test_without_whytap_the_case_tools_say_so_and_nothing_is_sent() throws {
        let server = AppControlMCPServer(caseServer: CaseMCPServer(client: nil, executablePath: helperPath),
                                         call: AppControlCommand(client: nil).call)
        let reply = try XCTUnwrap(server.handle(line:
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_projects"}}"#))
        XCTAssertTrue(reply.contains("Whytap is not available"))
        XCTAssertEqual(try decode(reply).object?["result"]?.object?["isError"], .bool(true))
    }

    // MARK: Broken input never stops the server

    func test_broken_input_gets_an_error_and_never_reaches_the_broker() throws {
        let broker = Broker(caseAnswer: .keys([CaseKeyInfo(name: "K", description: "", project: "P")]))
        let server = unified(broker)
        for invalid in [
            "{ not json",
            "[]",
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_keys","arguments":[]}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_keys","arguments":"x"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_run"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":7}}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"tools/call","params":{"name":"case_list_keys"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":"case_list_keys"}"#,
            #"{"id":1,"method":"tools/call","params":{"name":"case_list_keys"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            String(repeating: "x", count: AppControlMCPServer.maxLineBytes + 1)
        ] {
            let reply = try decode(server.handle(line: invalid))
            XCTAssertNotNil(reply.object?["error"], String(invalid.prefix(80)) + " must be an error")
        }
        // A notification never answers and never acts.
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"case_list_keys"}}"#))
        XCTAssertTrue(broker.requests.isEmpty)
    }

    /// Over stdio, as the agent host starts it: bad lines in between, then the
    /// session keeps answering both kinds of tool.
    func test_stdio_session_survives_bad_lines_and_serves_both_kinds_of_tool() throws {
        let broker = Broker(caseAnswer: .keys([CaseKeyInfo(name: "DEPLOY_TOKEN", description: "deploy", project: "Infra")]))
        let command = AppControlCommand(client: broker, direct: broker)
        var lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "{ broken",
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"case_list_keys","arguments":{"query":"deploy"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"whytap_get_state"}}"#,
        ][...]
        let lock = NSLock()
        var replies: [String] = []
        let replied = DispatchSemaphore(value: 0)
        let status = command.serveMCP(caseServer: CaseMCPServer(client: broker, executablePath: helperPath), readLine: {
            if lines.isEmpty {
                // Keep stdin open until both tool calls answered: EOF cancels pending calls.
                for _ in 0..<2 { XCTAssertEqual(replied.wait(timeout: .now() + 5), .success) }
                return nil
            }
            return lines.popFirst()
        }, write: { line in
            lock.withLock { replies.append(line) }
            if line.contains(#""id":3"#) || line.contains(#""id":4"#) { replied.signal() }
        })
        XCTAssertEqual(status, 0)
        let all = lock.withLock { replies }
        XCTAssertEqual(all.count, 5, "initialize, parse error, list, two calls")
        XCTAssertTrue(all.contains { $0.contains("Parse error") })
        XCTAssertTrue(all.contains { $0.contains("case_list_keys") && $0.contains("whytap_set_model") })
        XCTAssertTrue(all.contains { $0.contains("DEPLOY_TOKEN — deploy [Infra]") })
        XCTAssertTrue(all.contains { $0.contains("test-build") })
        // The harness access question is asked once after the handshake, as in `app mcp`.
        let deadline = Date().addingTimeInterval(5)
        while !broker.requests.contains(.appControl(AppControlRequest("request_access"))), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(broker.requests.filter { $0 == .appControl(AppControlRequest("request_access")) }.count, 1)
        assertNamesOrAppControlOnly(broker.requests)
    }

    // MARK: The older commands keep working

    /// `whytap app mcp`: exactly the application server, no Case tools.
    func test_app_mcp_command_still_serves_only_the_app_tools() throws {
        let broker = Broker(caseAnswer: .keys([CaseKeyInfo(name: "K", description: "", project: "P")]))
        var lines = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
                     #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                     #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"case_list_keys"}}"#][...]
        let lock = NSLock()
        var replies: [String] = []
        let called = DispatchSemaphore(value: 0)
        XCTAssertEqual(AppControlCommand(client: broker).run(args: ["mcp"], readLine: {
            if lines.isEmpty { XCTAssertEqual(called.wait(timeout: .now() + 5), .success); return nil }
            return lines.popFirst()
        }, write: { line in
            lock.withLock { replies.append(line) }
            if line.contains(#""id":3"#) { called.signal() }
        }), 0)
        replies = lock.withLock { replies }
        XCTAssertEqual(replies.count, 3)
        XCTAssertTrue(replies[0].contains("No keys, clipboard, shell commands or app installation here."))
        XCTAssertFalse(replies[0].contains("Whytap Case keeps secrets"))
        XCTAssertTrue(replies[1].contains("whytap_get_state"))
        XCTAssertFalse(replies[1].contains("case_list_keys"))
        XCTAssertTrue(replies[2].contains("Unknown tool"))
        XCTAssertTrue(broker.requests.isEmpty)
    }

    /// `whytap case mcp`: the Case server itself, as before.
    func test_case_mcp_server_still_serves_only_the_case_tools() throws {
        let broker = Broker(caseAnswer: .keys([CaseKeyInfo(name: "OPENAI_KEY", description: "main", project: "App")]))
        var lines = [#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
                     #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                     #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"case_list_keys"}}"#,
                     #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"whytap_get_state"}}"#][...]
        var replies: [String] = []
        CaseMCPServer(client: broker, executablePath: helperPath).run(readLine: { lines.popFirst() }, write: { replies.append($0) })
        XCTAssertEqual(replies.count, 4)
        XCTAssertTrue(replies[0].contains(#""name":"whytap-case""#))
        XCTAssertFalse(replies[1].contains("whytap_get_state"))
        XCTAssertTrue(replies[2].contains("OPENAI_KEY — main [App]"))
        XCTAssertTrue(replies[3].contains("Unknown tool."))
        XCTAssertEqual(broker.requests, [.listKeys(project: nil)])
        XCTAssertTrue(CaseCommand.usage.contains("mcp"))
    }

    func test_the_agents_screen_server_never_gains_case_tools() throws {
        let server = AppControlMCPServer(screenOnly: true, caseServer: CaseMCPServer(client: nil, executablePath: helperPath)) { _ in
            .success(.null)
        }
        XCTAssertEqual(try toolNames(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)), ["whytap_capture_screen"])
        XCTAssertTrue(try XCTUnwrap(server.handle(line:
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"case_list_keys"}}"#)).contains("Unknown tool"))
    }
}
