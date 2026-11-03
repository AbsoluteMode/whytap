import XCTest
@testable import WhytapCaseKit

/// `whytap todo` as an agent uses it: app running (socket answers), app closed
/// (nothing listens), an exchange that breaks midway, and bad input.
final class TodoCommandTests: XCTestCase {
    private final class Client: CaseBrokerCalling {
        var requests: [CaseBrokerRequest] = []
        var answer: () throws -> CaseBrokerResponse
        init(_ answer: @escaping () throws -> CaseBrokerResponse) { self.answer = answer }
        func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
            requests.append(request)
            return try answer()
        }
    }

    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("Planner/planner-v1.json") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-cli-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func run(_ args: [String], client: CaseBrokerCalling?, stdin: [String] = []) -> (Int32, AppControlResponse?) {
        var lines = stdin[...]
        var output: [String] = []
        let status = TodoCommand(client: client, fileURL: url)
            .run(args: args, readLine: { lines.popFirst() }, write: { output.append($0) })
        let response = output.last.flatMap { try? JSONDecoder().decode(AppControlResponse.self, from: Data($0.utf8)) }
        return (status, response)
    }

    private var closedApp: Client { Client { throw CaseBrokerClientError.unavailable } }

    private func tasks(_ response: AppControlResponse?) -> [[String: AppControlValue]] {
        response?.data.object?["tasks"]?.array?.compactMap(\.object) ?? []
    }

    func testRunningAppReceivesNormalizedBatchAndFileIsUntouched() throws {
        let client = Client { .appControl(.success(.object(["delivery": .string("app"), "added": .int(2)]))) }
        let (status, response) = run(["add", "  Call Anna \n", "Send\nthe deck"], client: client)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(response?.data.object?["delivery"], .string("app"))
        XCTAssertEqual(client.requests, [.appControl(AppControlRequest("todo_add",
            arguments: ["titles": .array([.string("Call Anna"), .string("Send the deck")])]))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "A running app is the only writer")
    }

    func testClosedAppWritesFileAndRetryDoesNotDuplicate() throws {
        let (status, response) = run(["add", "Draft brief", "Book room"], client: closedApp)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(response?.data.object?["delivery"], .string("file"))
        XCTAssertEqual(response?.data.object?["added"], .int(2))
        let firstIDs = tasks(response).map { $0["id"] }

        let (retryStatus, retry) = run(["add", "Draft brief", "Book room", "New one"], client: closedApp)
        XCTAssertEqual(retryStatus, 0)
        XCTAssertEqual(retry?.data.object?["added"], .int(1))
        XCTAssertEqual(retry?.data.object?["existing"], .int(2))
        XCTAssertEqual(Array(tasks(retry).prefix(2)).map { $0["id"] }, firstIDs, "Existing tasks keep their IDs")
        XCTAssertEqual(retry?.data.object?["activeCount"], .int(3))

        let (_, listing) = run(["list"], client: closedApp)
        XCTAssertEqual(tasks(listing).compactMap { $0["title"]?.string }, ["Draft brief", "Book room", "New one"])
    }

    func testStdinBatchSkipsBlankLines() {
        let (status, response) = run(["add", "-"], client: closedApp, stdin: ["First", "", "   ", "Second"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(tasks(response).compactMap { $0["title"]?.string }, ["First", "Second"])
    }

    func testInvalidTitlesRejectWholeBatchWithoutContactingApp() {
        let client = closedApp
        for titles in [["Fine", "   "], ["Fine", String(repeating: "x", count: 501)], []] {
            let (status, response) = run(["add"] + (titles.isEmpty ? ["-"] : titles), client: client)
            XCTAssertEqual(status, 2)
            XCTAssertFalse(response?.ok ?? true)
        }
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(run(["add", String(repeating: "é", count: 500)], client: client).0, 0, "500 characters is allowed")
    }

    func testOversizedBatchIsRejectedBeforeSending() {
        let client = closedApp
        let titles = (0..<100).map { "\($0) " + String(repeating: "ж", count: 490) }
        let (status, response) = run(["add"] + titles, client: client)
        XCTAssertEqual(status, 2)
        XCTAssertEqual(response?.data.object?["code"], .string("batch_too_large"))
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(run(["add"] + titles.prefix(40), client: client).0, 0, "A smaller batch fits")
    }

    func testBrokenExchangeIsUnconfirmedAndNeverFallsBackToFile() {
        let (status, response) = run(["add", "Maybe sent"], client: Client { throw CaseBrokerClientError.protocolFailure })
        XCTAssertEqual(status, 1)
        XCTAssertEqual(response?.data.object?["code"], .string("unconfirmed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOlderRunningAppErrorIsReportedWithoutFileWrite() {
        let client = Client { .appControl(.failure("unknown_operation", "Unknown application-control operation.")) }
        let (status, response) = run(["add", "Task"], client: client)
        XCTAssertEqual(status, 1)
        XCTAssertEqual(response?.data.object?["code"], .string("unknown_operation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBrokenFileIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for original in [Data("{\"version\":1,\"tasks\":[".utf8), Data(#"{"version":2,"tasks":[],"events":[]}"#.utf8)] {
            try original.write(to: url)
            let (status, response) = run(["add", "Task"], client: closedApp)
            XCTAssertEqual(status, 1)
            XCTAssertEqual(response?.data.object?["code"], .string("planner_unreadable"))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    /// Archives the app refuses must not be edited or listed by the helper either.
    func testArchivesTheAppRefusesAreLeftByteIdentical() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let task = #"{"id":"\#(UUID().uuidString)","title":"Ok","completed":false,"createdAt":1}"#
        for json in Self.refusedArchives(task: task) {
            let original = Data(json.utf8)
            try original.write(to: url)
            for args in [["add", "Task"], ["list"]] {
                let (status, response) = run(args, client: closedApp)
                XCTAssertEqual(status, 1, json)
                XCTAssertEqual(response?.data.object?["code"], .string("planner_unreadable"), json)
            }
            XCTAssertEqual(try Data(contentsOf: url), original, json)
        }
    }

    /// Each one valid JSON that PlannerStore.decodeArchive rejects.
    static func refusedArchives(task: String) -> [String] {
        let id = UUID().uuidString
        let event = { (fields: String) in
            #"{"version":1,"tasks":[],"events":[{"id":"\#(id)","title":"Call","start":1,"end":2,"allDay":false,"location":"","notes":"","timeZoneIdentifier":"UTC"\#(fields)}]}"#
        }
        return [
            #"{"version":1,"tasks":[\#(task)],"events":[1]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"   ","completed":false,"createdAt":1}],"events":[]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"Ok","completed":true,"createdAt":1,"completedAt":"yesterday"}],"events":[]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"\#(String(repeating: "x", count: 501))","completed":false,"createdAt":1}],"events":[]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"Ok","completed":false}],"events":[]}"#,
            #"{"version":1,"tasks":[\#(task)]}"#,
            #"{"tasks":[],"events":[]}"#,
            #"{"version":1.5,"tasks":[],"events":[]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"A","completed":false,"createdAt":1},{"id":"\#(id)","title":"B","completed":false,"createdAt":1}],"events":[]}"#,
            event(#","meetingURL":"http://example.com""#),
            event(#","meetingURL":"https://user:pw@example.com""#),
            event(#","end":0"#).replacingOccurrences(of: #""end":2,"#, with: ""),
            event("").replacingOccurrences(of: #","timeZoneIdentifier":"UTC""#, with: ""),
            event(#","notes":"\#(String(repeating: "n", count: 20_001))""#).replacingOccurrences(of: #""notes":"","#, with: ""),
        ]
    }

    func testListHidesCompletedUnlessAll() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let done = UUID(), open = UUID()
        let archive: [String: Any] = ["version": 1, "events": [], "tasks": [
            ["id": done.uuidString, "title": "Done", "completed": true, "createdAt": 10.5, "completedAt": 20.0],
            ["id": open.uuidString, "title": "Open", "completed": false, "createdAt": 11.0]]]
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        XCTAssertEqual(tasks(run(["list"], client: closedApp).1).compactMap { $0["title"]?.string }, ["Open"])
        XCTAssertEqual(tasks(run(["list", "--all"], client: closedApp).1).compactMap { $0["title"]?.string }, ["Done", "Open"])
        // A completed task does not block adding the same title again.
        XCTAssertEqual(run(["add", "Done"], client: closedApp).1?.data.object?["added"], .int(1))
    }

    func testUsageErrors() {
        for args in [[], ["add"], ["list", "--bogus"], ["remove", "x"]] {
            XCTAssertEqual(run(args, client: closedApp).0, 2)
        }
        XCTAssertEqual(run(["add", "x"], client: nil).0, 1, "Outside the app bundle the helper refuses")
    }

    func testLockSerializesWriters() throws {
        try PlannerTodoFile.withLock(for: url, timeout: 0.1) {
            XCTAssertThrowsError(try PlannerTodoFile.withLock(for: url, timeout: 0.05) {}) {
                XCTAssertEqual(($0 as? PlannerTodoFile.Failure)?.code, "busy")
            }
        }
        XCTAssertNoThrow(try PlannerTodoFile.withLock(for: url, timeout: 0.05) {})
    }
}
