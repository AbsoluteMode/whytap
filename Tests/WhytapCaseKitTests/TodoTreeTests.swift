import XCTest
@testable import WhytapCaseKit

/// To-do as a tree, the way an agent drives it through `whytap todo` while
/// Whytap is closed (the file path); the running-app path shares TodoRequest.
final class TodoTreeTests: XCTestCase {
    private final class Closed: CaseBrokerCalling {
        var reply: CaseBrokerResponse?
        var requests: [CaseBrokerRequest] = []
        func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
            requests.append(request)
            guard let reply else { throw CaseBrokerClientError.unavailable }
            return reply
        }
    }

    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("Planner/planner-v1.json") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-tree-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    private func run(_ args: [String], client: CaseBrokerCalling? = nil, stdin: [String] = []) -> (Int32, [String: AppControlValue]) {
        var lines = stdin[...]
        var output: [String] = []
        let status = TodoCommand(client: client ?? Closed(), fileURL: url)
            .run(args: args, readLine: { lines.popFirst() }, write: { output.append($0) })
        let data = output.last.flatMap { try? JSONDecoder().decode(AppControlResponse.self, from: Data($0.utf8)) }?.data.object
        return (status, data ?? [:])
    }

    private func list(all: Bool = false) -> [[String: AppControlValue]] {
        run(["list"] + (all ? ["--all"] : [])).1["tasks"]?.array?.compactMap(\.object) ?? []
    }

    private func id(_ title: String) -> String {
        list(all: true).first { $0["title"]?.string == title }?["id"]?.string ?? "missing"
    }

    private let meeting = #"""
        [{"title": "Исследовать клин", "children": [
            {"title": "Запустить проверку на последних 30 картах", "status": "готово, результаты отправил Свете в тг", "children": [
                {"title": "Согласовать план со Светой", "status": "жду фидбека Светы"}]}]}]
        """#

    func testMeetingTreeWithStatusesIsListedAsFoldersAndRetryAddsNothing() throws {
        let (status, added) = run(["add", "--json", meeting])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(added["delivery"], .string("file"))
        XCTAssertEqual(added["added"], .int(3))
        let rows = list()
        XCTAssertEqual(rows.compactMap { $0["title"]?.string },
                       ["Исследовать клин", "Запустить проверку на последних 30 картах", "Согласовать план со Светой"])
        XCTAssertEqual(rows.compactMap { $0["depth"] }, [.int(0), .int(1), .int(2)])
        XCTAssertEqual(rows[1]["parentID"], rows[0]["id"])
        XCTAssertEqual(rows[2]["status"], .string("жду фидбека Светы"))
        XCTAssertEqual(rows[0]["children"], .int(1))

        // The agent repeats the call with a newer status: no duplicates, status updated.
        let retry = run(["add", "--json", meeting.replacingOccurrences(of: "жду фидбека Светы", with: "Света ответила")]).1
        XCTAssertEqual(retry["added"], .int(0))
        XCTAssertEqual(retry["existing"], .int(3))
        XCTAssertEqual(list()[2]["status"], .string("Света ответила"))
        XCTAssertEqual(list().count, 3)
    }

    func testAddUnderParentFromStdinAndWithStatusFlag() throws {
        run(["add", "Исследовать клин"])
        let parent = String(id("Исследовать клин").prefix(8))
        XCTAssertEqual(run(["add", "--parent", parent, "-"], stdin: ["Собрать логи", "", "Сравнить с прошлой неделей"]).0, 0)
        XCTAssertEqual(run(["add", "--parent", parent, "--status", "в работе", "Написать вывод"]).0, 0)
        let rows = list()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.dropFirst().compactMap { $0["parentID"]?.string }), [id("Исследовать клин")])
        XCTAssertEqual(rows.last?["status"], .string("в работе"), "\(rows.map { ($0["title"], $0["status"], $0["createdAt"]) })")
    }

    func testClosingParentClosesChildrenAndReopenRestoresOnlyThose() throws {
        run(["add", "--json", meeting])
        run(["add", "--parent", id("Исследовать клин"), "Отдельно закрытая"])
        XCTAssertEqual(run(["done", id("Отдельно закрытая")]).0, 0)
        let closed = run(["done", id("Исследовать клин")]).1
        XCTAssertEqual(closed["affected"], .int(4))
        XCTAssertTrue(list().isEmpty, "Every child leaves with its parent")
        XCTAssertEqual(list(all: true).filter { $0["completed"] == .bool(true) }.count, 4)

        XCTAssertEqual(run(["reopen", id("Исследовать клин")]).0, 0)
        XCTAssertEqual(list().compactMap { $0["title"]?.string },
                       ["Исследовать клин", "Запустить проверку на последних 30 картах", "Согласовать план со Светой"],
                       "The subtask closed earlier on its own stays closed")

        run(["done", id("Исследовать клин")])
        XCTAssertEqual(run(["reopen", id("Согласовать план со Светой")]).0, 0)
        XCTAssertEqual(list().compactMap { $0["title"]?.string },
                       ["Исследовать клин", "Запустить проверку на последних 30 картах", "Согласовать план со Светой"],
                       "Reopening a subtask reopens its closed parents so it is visible")
    }

    func testSetEditsEveryFieldAndRefusesCyclesAndDepth() throws {
        run(["add", "--json", meeting])
        let root = id("Исследовать клин"), child = id("Запустить проверку на последних 30 картах")
        let leaf = id("Согласовать план со Светой")
        XCTAssertEqual(run(["set", child, "--title", "Проверка на 30 картах", "--status", "готово"]).0, 0)
        XCTAssertEqual(run(["set", leaf, "--no-status", "--top"]).0, 0)
        var rows = list()
        XCTAssertEqual(rows.first { $0["id"]?.string == child }?["title"], .string("Проверка на 30 картах"))
        XCTAssertEqual(rows.first { $0["id"]?.string == child }?["status"], .string("готово"))
        XCTAssertEqual(rows.first { $0["id"]?.string == leaf }?["parentID"], .null)
        XCTAssertEqual(rows.first { $0["id"]?.string == leaf }?["status"], .null)

        XCTAssertEqual(run(["set", root, "--parent", child]).1["code"], .string("invalid_parent"))
        XCTAssertEqual(run(["set", root, "--parent", root]).1["code"], .string("invalid_parent"))
        XCTAssertEqual(run(["set", "00000000", "--title", "x"]).1["code"], .string("not_found"))
        XCTAssertEqual(run(["set", root, "--status", String(repeating: "s", count: 301)]).0, 2)

        // Five levels are allowed, a sixth is refused, also when moving a subtree.
        var parent = root
        for level in 2...5 {
            let added = run(["add", "--parent", parent, "Level \(level)"])
            XCTAssertEqual(added.0, 0, "\(added.1)")
            parent = id("Level \(level)")
        }
        XCTAssertEqual(run(["add", "--parent", parent, "Level 6"]).1["code"], .string("too_deep"))
        XCTAssertEqual(run(["set", child, "--parent", parent]).1["code"], .string("too_deep"))
        run(["done", root])
        XCTAssertEqual(run(["add", "--parent", root, "Under closed"]).1["code"], .string("parent_completed"))
        rows = list(all: true)
        XCTAssertFalse(rows.contains { $0["title"] == .string("Level 6") || $0["title"] == .string("Under closed") })
    }

    func testInvalidRequestsTouchNeitherAppNorFile() throws {
        let client = Closed()
        client.reply = .appControl(.success(.null))
        let cases: [[String]] = [
            ["add", "--json", "{not json"],
            ["add", "--json", #"[{"title": "ok", "extra": 1}]"#],
            ["add", "--json", #"[{"title": "ok", "children": [{"title": "  "}]}]"#],
            ["add", "--json", #"[{"title":"1","children":[{"title":"2","children":[{"title":"3","children":[{"title":"4","children":[{"title":"5","children":[{"title":"6"}]}]}]}]}]}]"#],
            ["add", "--status", String(repeating: "s", count: 301), "Task"],
            ["set", "abcdefgh"],
            ["set", "abcdefgh", "--status", "x", "--no-status"],
            ["done"]
        ]
        for args in cases { XCTAssertEqual(run(args, client: client).0, 2, "\(args)") }
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFlatBatchStillUsesTitlesSoAnOlderRunningAppAcceptsIt() throws {
        let client = Closed()
        client.reply = .appControl(.success(.object(["delivery": .string("app")])))
        run(["add", "A", "B"], client: client)
        run(["add", "--parent", "abcdefgh", "C"], client: client)
        XCTAssertEqual(client.requests, [
            .appControl(AppControlRequest("todo_add", arguments: ["titles": .array([.string("A"), .string("B")])])),
            .appControl(AppControlRequest("todo_add", arguments: ["titles": .array([.string("C")]), "parentID": .string("abcdefgh")]))
        ])
        client.reply = .appControl(.failure("unknown_operation", "Unknown application-control operation."))
        let (status, data) = run(["done", "abcdefgh"], client: client)
        XCTAssertEqual(status, 1)
        XCTAssertEqual(data["code"], .string("unknown_operation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "An older app's refusal never falls back to the file")
    }

    func testOfflineEditsKeepUnknownFieldsAndStoredNumbers() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = UUID().uuidString
        let original = #"{"version":1,"events":[],"tasks":[{"id":"\#(first)","title":"Old","completed":false,"createdAt":783840123.456789,"future":"kept"}]}"#
        try Data(original.utf8).write(to: url)
        run(["add", "--parent", first, "Child"])
        run(["set", first, "--status", "в работе"])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try XCTUnwrap(saved["tasks"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["future"] as? String, "kept")
        XCTAssertEqual(rows[0]["createdAt"] as? Double, 783840123.456789)
        XCTAssertEqual(rows[0]["status"] as? String, "в работе")
        XCTAssertEqual(rows[1]["parentID"] as? String, first)
        run(["set", first, "--no-status"])
        let cleared = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil((cleared["tasks"] as? [[String: Any]])?[0]["status"])
    }

    func testArchiveValidatorRejectsBrokenTrees() {
        let a = UUID().uuidString, b = UUID().uuidString
        func archive(_ tasks: String) -> Data { Data(#"{"version":1,"events":[],"tasks":[\#(tasks)]}"#.utf8) }
        func task(_ id: String, _ extra: String = "") -> String {
            #"{"id":"\#(id)","title":"T","completed":false,"createdAt":1\#(extra)}"#
        }
        XCTAssertTrue(PlannerTodoFile.isValidArchive(archive(task(a) + "," + task(b, #","parentID":"\#(a)","status":"ok""#))))
        XCTAssertFalse(PlannerTodoFile.isValidArchive(archive(task(a, #","parentID":"\#(UUID().uuidString)""#))), "missing parent")
        XCTAssertFalse(PlannerTodoFile.isValidArchive(archive(task(a, #","parentID":"\#(b)""#) + "," + task(b, #","parentID":"\#(a)""#))), "cycle")
        XCTAssertFalse(PlannerTodoFile.isValidArchive(archive(task(a, #","parentID":"\#(a)""#))), "self parent")
        XCTAssertFalse(PlannerTodoFile.isValidArchive(archive(task(a, #","status":"  ""#))), "blank status")
        XCTAssertFalse(PlannerTodoFile.isValidArchive(archive(task(a, #","status":"\#(String(repeating: "s", count: 301))""#))))
        XCTAssertFalse(PlannerTodoFile.isValidArchive(archive(task(a, #","status":7"#))))
        let ids = (0..<6).map { _ in UUID().uuidString }
        let chain = ids.enumerated().map { index, id in task(id, index == 0 ? "" : #","parentID":"\#(ids[index - 1])""#) }
        XCTAssertTrue(PlannerTodoFile.isValidArchive(archive(chain.prefix(5).joined(separator: ","))))
        XCTAssertFalse(PlannerTodoFile.isValidArchive(archive(chain.joined(separator: ","))), "six levels")
    }
}
