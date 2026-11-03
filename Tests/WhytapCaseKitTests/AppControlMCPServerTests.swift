import XCTest
@testable import WhytapCaseKit

final class AppControlMCPServerTests: XCTestCase {
    func testScreenServerExposesOnlyCaptureAndReturnsImageContent() throws {
        let server = AppControlMCPServer(screenOnly: true) { request in
            XCTAssertEqual(request, AppControlRequest("capture_screen"))
            return .success(.object(["image": .string("aW1hZ2U="), "mimeType": .string("image/jpeg"), "width": .int(32)]))
        }
        let listing = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        XCTAssertTrue(listing.contains("whytap_capture_screen"))
        XCTAssertFalse(listing.contains("whytap_set_model"))
        let reply = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"whytap_capture_screen"}}"#))
        let json = try JSONDecoder().decode(AppControlValue.self, from: Data(reply.utf8))
        guard case .array(let content) = json.object?["result"]?.object?["content"] else { return XCTFail("Missing content") }
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1].object?["type"], .string("image"))
        XCTAssertEqual(content[1].object?["data"], .string("aW1hZ2U="))
        XCTAssertFalse(content[0].object?["text"]?.string?.contains("aW1hZ2U=") == true)
        XCTAssertNil(json.object?["result"]?.object?["structuredContent"], "Do not duplicate image bytes into text/context")
    }

    func testScreenAndSettingsToolsCannotCrossScopes() throws {
        for screenOnly in [true, false] {
            let server = AppControlMCPServer(screenOnly: screenOnly) { _ in XCTFail("Wrong scope"); return .success(.null) }
            let name = screenOnly ? "whytap_set_setting" : "whytap_capture_screen"
            let request: AppControlValue = .object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
                "params": .object(["name": .string(name)])])
            let reply = try XCTUnwrap(server.handle(line: String(decoding: try JSONEncoder().encode(request), as: UTF8.self)))
            XCTAssertTrue(reply.contains("Unknown tool"))
        }
    }

    private final class Client: CaseBrokerCalling {
        var requests: [CaseBrokerRequest] = []
        func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
            requests.append(request)
            return .appControl(.success(.object(["build": .string("test-build")])) )
        }
    }

    func test_stdio_handshake_and_tools_work_without_launching_app() throws {
        let server = AppControlMCPServer { _ in XCTFail("metadata must not contact the app"); return .success(.null) }
        let hello = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let json = try JSONDecoder().decode(AppControlValue.self, from: Data(hello.utf8))
        XCTAssertEqual(json.object?["result"]?.object?["protocolVersion"], .string("2025-06-18"))
        let listing = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        XCTAssertTrue(listing.contains("whytap_set_model"))
        XCTAssertFalse(listing.contains("case_list_keys"))
        XCTAssertFalse(listing.contains("resolveRun"))
    }

    func test_notifications_bad_ids_and_unknown_tools_never_invoke_app() {
        var calls = 0
        let server = AppControlMCPServer { _ in calls += 1; return .success(.null) }
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"whytap_set_setting"}}"#))
        for invalid in [
            #"{"jsonrpc":"2.0","id":true,"method":"tools/call","params":{"name":"whytap_set_setting"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"case_list_keys"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whytap_set_setting","arguments":[]}}"#,
            #"{"id":1,"method":"tools/call","params":{"name":"whytap_get_state"}}"#,
            String(repeating: "x", count: AppControlMCPServer.maxLineBytes + 1)
        ] { XCTAssertNotNil(server.handle(line: invalid)) }
        XCTAssertEqual(calls, 0)
    }

    func test_tools_send_only_namespaced_app_requests_and_return_structured_error() throws {
        let client = Client()
        let command = AppControlCommand(client: client)
        let server = AppControlMCPServer(call: command.call)
        let reply = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"whytap_get_state"}}"#))
        XCTAssertEqual(client.requests, [.appControl(AppControlRequest("get_state"))])
        XCTAssertTrue(reply.contains("structuredContent"))
        XCTAssertTrue(reply.contains("test-build"))
        let unavailable = AppControlMCPServer(call: AppControlCommand(client: nil).call)
        let error = try XCTUnwrap(unavailable.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whytap_get_state"}}"#))
        XCTAssertTrue(error.contains("\"isError\":true"))
    }

    // MARK: - To-do tools: an agent on any Mac adds meeting action items

    private final class TodoClient: CaseBrokerCalling {
        var requests: [CaseBrokerRequest] = []
        var running: Bool
        init(running: Bool) { self.running = running }
        func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
            guard running else { throw CaseBrokerClientError.unavailable }
            requests.append(request)
            return .appControl(.success(.object(["delivery": .string("app"), "added": .int(2)])))
        }
    }

    private func todoServer(_ client: TodoClient, file: URL) -> AppControlMCPServer {
        let todo = TodoCommand(client: client, fileURL: file)
        return AppControlMCPServer(todo: { todo.respond($0, $1) }, call: { _ in
            XCTFail("To-do must not use the launching app-control client"); return .success(.null)
        })
    }

    private func toolCall(_ server: AppControlMCPServer, _ name: String, _ arguments: AppControlValue) throws -> [String: AppControlValue] {
        let request: AppControlValue = .object(["jsonrpc": .string("2.0"), "id": .int(7), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": arguments])])
        let reply = try XCTUnwrap(server.handle(line: String(decoding: try JSONEncoder().encode(request), as: UTF8.self)))
        return try XCTUnwrap(JSONDecoder().decode(AppControlValue.self, from: Data(reply.utf8)).object?["result"]?.object)
    }

    func test_todo_tools_are_listed_with_batch_schema_and_meeting_guidance() throws {
        let server = AppControlMCPServer { _ in .success(.null) }
        let listing = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let tools = try JSONDecoder().decode(AppControlValue.self, from: Data(listing.utf8))
            .object?["result"]?.object?["tools"]?.array?.compactMap(\.object) ?? []
        let add = try XCTUnwrap(tools.first { $0["name"] == .string("whytap_todo_add") })
        let titles = add["inputSchema"]?.object?["properties"]?.object?["titles"]?.object
        XCTAssertEqual(titles?["maxItems"], .int(100))
        XCTAssertEqual(titles?["items"]?.object?["maxLength"], .int(500))
        XCTAssertEqual(add["annotations"]?.object?["readOnlyHint"], .bool(false))
        XCTAssertEqual(add["annotations"]?.object?["idempotentHint"], .bool(true), "Retrying never duplicates")
        XCTAssertNotNil(tools.first { $0["name"] == .string("whytap_todo_list") })
        let hello = try XCTUnwrap(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"initialize"}"#))
        XCTAssertTrue(hello.contains("whytap_todo_add"))
        XCTAssertTrue(hello.contains("Sidekey/Meetings"))
        XCTAssertFalse(try XCTUnwrap(AppControlMCPServer(screenOnly: true) { _ in .success(.null) }
            .handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)).contains("todo"))
    }

    func test_todo_add_reaches_running_app_without_launching_it() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("planner-v1.json")
        let client = TodoClient(running: true)
        let result = try toolCall(todoServer(client, file: file), "whytap_todo_add",
                                  .object(["titles": .array([.string(" Send deck\n"), .string("Call Anna")])]))
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["structuredContent"]?.object?["data"]?.object?["delivery"], .string("app"))
        XCTAssertEqual(client.requests, [.appControl(AppControlRequest("todo_add",
            arguments: ["titles": .array([.string("Send deck"), .string("Call Anna")])]))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_todo_add_with_closed_app_writes_file_and_retry_is_safe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = todoServer(TodoClient(running: false), file: directory.appendingPathComponent("planner-v1.json"))
        let titles: AppControlValue = .object(["titles": .array([.string("Draft brief"), .string("Book room")])])
        let first = try toolCall(server, "whytap_todo_add", titles)
        XCTAssertEqual(first["structuredContent"]?.object?["data"]?.object?["delivery"], .string("file"))
        XCTAssertEqual(first["structuredContent"]?.object?["data"]?.object?["added"], .int(2))
        let retry = try toolCall(server, "whytap_todo_add", titles)
        XCTAssertEqual(retry["structuredContent"]?.object?["data"]?.object?["added"], .int(0))
        XCTAssertEqual(retry["structuredContent"]?.object?["data"]?.object?["existing"], .int(2))
        let listed = try toolCall(server, "whytap_todo_list", .object([:]))
        XCTAssertEqual(listed["structuredContent"]?.object?["data"]?.object?["tasks"]?.array?.compactMap { $0.object?["title"]?.string },
                       ["Draft brief", "Book room"])
    }

    /// The largest advertised batch reaches TodoCommand through the real stdio
    /// reader: ASCII fits the app's socket, Cyrillic gets a clear batch_too_large.
    func test_largest_advertised_batch_is_not_a_parse_error() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("planner-v1.json")
        let server = todoServer(TodoClient(running: false), file: file)
        func line(_ character: String, escaped: Bool) throws -> String {
            let titles = (0..<100).map { "\($0) " + String(repeating: character, count: 496) }
            let request: AppControlValue = .object(["jsonrpc": .string("2.0"), "id": .int(9), "method": .string("tools/call"),
                "params": .object(["name": .string("whytap_todo_add"), "arguments": .object(["titles": .array(titles.map(AppControlValue.string))])])])
            let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            // Some hosts \u-escape every non-ASCII character.
            return escaped ? text.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "\\u%04x", $0.value) }.joined() : text
        }
        let ascii = try line("x", escaped: false)
        XCTAssertGreaterThan(ascii.utf8.count, 32_768)
        let cyrillic = try line("ж", escaped: true)
        XCTAssertGreaterThan(cyrillic.utf8.count, 250_000)
        for (input, expected) in [(ascii, "\"added\":100"), (cyrillic, "batch_too_large")] {
            let direct = try XCTUnwrap(server.handle(line: input))
            XCTAssertTrue(direct.contains(expected), String(direct.prefix(300)))
            var lines = [input][...]
            var replies: [String] = []
            let replied = DispatchSemaphore(value: 0)
            server.run(readLine: {
                if lines.isEmpty { XCTAssertEqual(replied.wait(timeout: .now() + 10), .success); return nil }
                return lines.popFirst()
            }, write: { replies.append($0); replied.signal() })
            XCTAssertTrue(replies.first?.contains(#""id":9"#) == true)
        }
    }

    /// `whytap app mcp` as the agent host starts it: the command wires the To-do tools.
    func test_app_mcp_command_serves_todo_through_the_non_launching_path() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("planner-v1.json")
        let launching = Client()
        let command = AppControlCommand(client: launching, todo: TodoCommand(client: TodoClient(running: false), fileURL: file))
        var lines = [#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whytap_todo_add","arguments":{"titles":["Follow up"]}}}"#][...]
        var replies: [String] = []
        let replied = DispatchSemaphore(value: 0)
        // Keep stdin open until the reply arrives: EOF cancels pending calls.
        XCTAssertEqual(command.run(args: ["mcp"], readLine: {
            if lines.isEmpty { XCTAssertEqual(replied.wait(timeout: .now() + 5), .success); return nil }
            return lines.popFirst()
        }, write: { replies.append($0); replied.signal() }), 0)
        XCTAssertTrue(launching.requests.isEmpty, "The launching client is never used for To-do")
        XCTAssertTrue(replies.first?.contains(#""delivery":"file""#) == true)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Follow up"))
    }

    func test_todo_add_rejects_bad_input_without_contacting_app_or_file() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("planner-v1.json")
        let client = TodoClient(running: true)
        let server = todoServer(client, file: file)
        let cases: [(AppControlValue, String)] = [
            (.object([:]), "invalid_arguments"),
            (.object(["titles": .string("one")]), "invalid_arguments"),
            (.object(["titles": .array([.string("ok"), .int(1)])]), "invalid_arguments"),
            (.object(["titles": .array([]) ]), "invalid_arguments"),
            (.object(["titles": .array([.string("ok"), .string("  ")])]), "empty_title"),
            (.object(["titles": .array([.string(String(repeating: "x", count: 501))])]), "title_too_long"),
            (.object(["titles": .array([.string("ok")]), "extra": .bool(true)]), "invalid_arguments")
        ]
        for (arguments, code) in cases {
            let result = try toolCall(server, "whytap_todo_add", arguments)
            XCTAssertEqual(result["isError"], .bool(true))
            XCTAssertEqual(result["structuredContent"]?.object?["data"]?.object?["code"], .string(code), "\(arguments)")
        }
        let badList = try toolCall(server, "whytap_todo_list", .object(["includeCompleted": .string("yes")]))
        XCTAssertEqual(badList["structuredContent"]?.object?["data"]?.object?["code"], .string("invalid_arguments"))
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // A server without the To-do path (an older wiring) reports unavailable instead of failing silently.
        let bare = AppControlMCPServer { _ in XCTFail("not routed to app control"); return .success(.null) }
        XCTAssertEqual(try toolCall(bare, "whytap_todo_add", .object(["titles": .array([.string("x")])]))["isError"], .bool(true))
    }

    func test_command_rejects_non_object_args_without_contacting_app() {
        let client = Client()
        let command = AppControlCommand(client: client)
        XCTAssertEqual(command.run(args: ["set-setting", "[]"], write: { _ in }), 2)
        XCTAssertEqual(command.run(args: ["run", "pwd"], write: { _ in }), 2)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func test_wire_roundtrip_does_not_confuse_booleans_integers_or_null() throws {
        let request = CaseBrokerRequest.appControl(AppControlRequest("set_setting", arguments: [
            "key": .string("autoHideIsland"), "value": .bool(false), "expected": .bool(true), "count": .int(1), "empty": .null
        ]))
        let bytes = try CaseBrokerCodec.encodeLine(request)
        XCTAssertEqual(try CaseBrokerCodec.decodeLine(CaseBrokerRequest.self, from: bytes), request)
    }

    func test_stdio_cancellation_is_read_while_a_tool_call_is_waiting() {
        let started = DispatchSemaphore(value: 0)
        let server = AppControlMCPServer(cancellableCall: { _, cancellation in
            started.signal()
            let deadline = Date().addingTimeInterval(2)
            while cancellation?.isCancelled != true && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertTrue(cancellation?.isCancelled == true)
            return .success(.null)
        })
        var index = 0
        var replies: [String] = []
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"whytap_set_model"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        ]
        server.run(readLine: {
            if index == 1 { XCTAssertEqual(started.wait(timeout: .now() + 2), .success) }
            guard index < lines.count else { return nil }
            defer { index += 1 }
            return lines[index]
        }, write: { replies.append($0) })
        XCTAssertEqual(replies.count, 1)
        XCTAssertTrue(replies.first?.contains("\"id\":2") == true)
    }

    func test_cancellation_before_connect_does_not_send_a_request() {
        let cancellation = AppControlCancellation()
        cancellation.cancel()
        let client = UnixSocketBrokerClient(socketURL: URL(fileURLWithPath: "/tmp/no-such-control-test-socket"))
        XCTAssertThrowsError(try client.send(.appControl(AppControlRequest("get_state")), cancellation: cancellation)) {
            XCTAssertEqual($0 as? CaseBrokerClientError, .protocolFailure)
        }
    }
}
