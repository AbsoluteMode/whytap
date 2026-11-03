import Combine
import XCTest
import WhytapCaseKit
@testable import Sidekey

/// Agents adding tasks while Whytap runs (app-control) or is closed (file),
/// combined with the user's own edits in To-do.
@MainActor
final class PlannerExternalChangesTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("Planner/planner-v1.json") }
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("planner-external-" + UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testFileAddWhileAppRunsSurvivesTheNextUISave() throws {
        let store = PlannerStore(url: url)
        let mine = PlannerTask(title: "Mine")
        XCTAssertTrue(store.saveTask(mine))
        _ = try PlannerTodoFile.addOffline(["From agent"], to: url)
        var completed = mine
        completed.completed = true
        XCTAssertTrue(store.saveTask(completed), "The user's toggle in To-do")
        let saved = try PlannerStore.decodeArchive(Data(contentsOf: url))
        XCTAssertEqual(saved.tasks.map(\.title), ["Mine", "From agent"])
        XCTAssertEqual(saved.tasks.first?.completed, true)
        XCTAssertNotNil(saved.tasks.first?.completedAt)
        XCTAssertEqual(store.archive, saved)
    }

    func testOfflineAddKeepsEveryExistingFieldDecodable() throws {
        let store = PlannerStore(url: url)
        var done = PlannerTask(title: "Old", createdAt: Date(timeIntervalSinceReferenceDate: 783_840_123.456789))
        done.completed = true
        XCTAssertTrue(store.saveTask(done, now: Date(timeIntervalSinceReferenceDate: 783_850_000.987654)))
        var event = PlannerEvent(title: "Review", start: Date(timeIntervalSinceReferenceDate: 783_900_000.25),
                                 end: Date(timeIntervalSinceReferenceDate: 783_903_600.75))
        event.meetingURL = URL(string: "https://example.com/j/1?pwd=a/b")
        event.notes = "Ünïcode \"quotes\" / slashes"
        XCTAssertTrue(store.saveEvent(event))
        let before = store.archive

        let response = try PlannerTodoFile.addOffline(["Новая задача"], to: url)
        XCTAssertEqual(response.object?["added"], .int(1))
        let after = try PlannerStore.decodeArchive(Data(contentsOf: url))
        XCTAssertEqual(Array(after.tasks.prefix(1)), before.tasks)
        XCTAssertEqual(after.events, before.events)
        XCTAssertEqual(after.tasks.last?.title, "Новая задача")
        XCTAssertEqual(after.tasks.last?.completed, false)
        XCTAssertEqual(PlannerStore(url: url).archive, after, "A fresh launch reads the helper's file")
    }

    func testBatchAddIsValidatedAndIdempotent() throws {
        let store = PlannerStore(url: url)
        XCTAssertThrowsError(try store.addTasks(["Fine", String(repeating: "x", count: 501)])) {
            XCTAssertEqual(($0 as? PlannerTodoFile.Failure)?.code, "title_too_long")
        }
        XCTAssertThrowsError(try store.addTasks(["Fine", " \n "])) {
            XCTAssertEqual(($0 as? PlannerTodoFile.Failure)?.code, "empty_title")
        }
        XCTAssertTrue(store.archive.tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Rejected batches write nothing")

        let first = try store.addTasks(["A", "B", "A"])
        XCTAssertEqual(first.map(\.isNew), [true, true, false])
        XCTAssertEqual(first[0].id, first[2].id)
        let retry = try store.addTasks(["A", "B"])
        XCTAssertEqual(retry.map(\.isNew), [false, false])
        XCTAssertEqual(retry.map(\.id), Array(first.prefix(2)).map(\.id))
        XCTAssertEqual(PlannerStore(url: url).archive.tasks.map(\.title), ["A", "B"])
    }

    func testExternallyBrokenFileBlocksWritesAndRetryRecovers() throws {
        let store = PlannerStore(url: url)
        XCTAssertTrue(store.saveTask(PlannerTask(title: "Visible")))
        let broken = Data("{\"version\":1,\"tasks\":[{".utf8)
        try broken.write(to: url)
        XCTAssertFalse(store.saveTask(PlannerTask(title: "Would overwrite")))
        XCTAssertThrowsError(try store.addTasks(["Agent task"])) {
            XCTAssertEqual(($0 as? PlannerTodoFile.Failure)?.code, "planner_unreadable")
        }
        XCTAssertEqual(try Data(contentsOf: url), broken, "Never overwrite a file we cannot read")
        XCTAssertEqual(store.archive.tasks.map(\.title), ["Visible"], "The last good list stays on screen")
        XCTAssertFalse(store.canWrite)

        var fixed = PlannerStore.Archive()
        fixed.tasks = [PlannerTask(title: "Restored")]
        try JSONEncoder().encode(fixed).write(to: url)
        store.refreshFromDisk()
        XCTAssertTrue(store.canWrite)
        XCTAssertEqual(store.archive.tasks.map(\.title), ["Restored"])
    }

    func testOpeningToDoShowsTasksAddedWhileClosed() throws {
        let store = PlannerStore(url: url)
        let model = TodoHoverModel(store: store)
        _ = try PlannerTodoFile.addOffline(["Added by agent"], to: url)
        model.begin()
        XCTAssertEqual(model.tasks.map(\.title), ["Added by agent"])
    }

    func testWatchingStorePublishesExternalAddWithoutSaving() throws {
        let store = PlannerStore(url: url, observesExternalChanges: true)
        let seen = expectation(description: "external task published")
        let subscription = store.$archive.sink { if $0.tasks.contains(where: { $0.title == "Live" }) { seen.fulfill() } }
        defer { subscription.cancel() }
        _ = try PlannerTodoFile.addOffline(["Live"], to: url)
        wait(for: [seen], timeout: 3)
    }

    func testAppControlAddAndListConfirmFromSavedState() async throws {
        let store = PlannerStore(url: url)
        XCTAssertTrue(store.saveTask(PlannerTask(title: "Earlier")))
        let controller = AppControlController(planner: { store })
        let added = await controller.handle(AppControlRequest("todo_add", arguments: [
            "titles": .array([.string("Call Anna"), .string("Earlier")])]))
        XCTAssertTrue(added.ok)
        XCTAssertEqual(added.data.object?["delivery"], .string("app"))
        XCTAssertEqual(added.data.object?["added"], .int(1))
        XCTAssertEqual(added.data.object?["existing"], .int(1))
        XCTAssertEqual(added.data.object?["activeCount"], .int(2))
        XCTAssertEqual(try PlannerStore.decodeArchive(Data(contentsOf: url)).tasks.map(\.title), ["Earlier", "Call Anna"])

        let listed = await controller.handle(AppControlRequest("todo_list"))
        XCTAssertEqual(listed.data.object?["tasks"]?.array?.compactMap { $0.object?["title"]?.string }, ["Earlier", "Call Anna"])

        for bad: [String: AppControlValue] in [["titles": .array([.int(1)])], ["titles": .string("x")], ["title": .array([])]] {
            let response = await controller.handle(AppControlRequest("todo_add", arguments: bad))
            XCTAssertEqual(response.data.object?["code"], .string("invalid_arguments"))
        }
        let tooLong = await controller.handle(AppControlRequest("todo_add", arguments: [
            "titles": .array([.string(String(repeating: "x", count: 501))])]))
        XCTAssertEqual(tooLong.data.object?["code"], .string("title_too_long"))
        XCTAssertEqual(store.archive.tasks.count, 2)
    }
}
