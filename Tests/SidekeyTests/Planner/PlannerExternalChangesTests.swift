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

    /// The app and the helper must agree on every archive: one refused by the
    /// app is never edited, and every edited one still loads in the app.
    func testHelperEditsExactlyTheArchivesTheAppLoads() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var event = PlannerEvent(title: "Review", start: Date(timeIntervalSinceReferenceDate: 10), end: Date(timeIntervalSinceReferenceDate: 20))
        event.meetingURL = URL(string: "https://example.com/j/1")
        var valid = PlannerStore.Archive()
        valid.tasks = [PlannerTask(title: "Ok")]
        valid.events = [event]
        let task = #"{"id":"\#(UUID().uuidString)","title":"Ok","completed":false,"createdAt":1}"#
        let refused = Self.refusedArchives(task: task)
        for json in refused + [String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)] {
            let original = Data(json.utf8)
            try original.write(to: url)
            let appLoads = (try? PlannerStore.decodeArchive(original)) != nil
            XCTAssertEqual(PlannerTodoFile.isValidArchive(original), appLoads, json)
            if appLoads {
                _ = try PlannerTodoFile.addOffline(["From agent"], to: url)
                let after = try PlannerStore.decodeArchive(Data(contentsOf: url))
                XCTAssertEqual(after.events, valid.events)
                XCTAssertEqual(after.tasks.map(\.title), ["Ok", "From agent"])
            } else {
                XCTAssertThrowsError(try PlannerTodoFile.addOffline(["From agent"], to: url), json)
                XCTAssertEqual(try Data(contentsOf: url), original, json)
            }
        }
        XCTAssertEqual(refused.filter { (try? PlannerStore.decodeArchive(Data($0.utf8))) == nil }.count, refused.count,
                       "Every refused sample is refused by the app itself")
    }

    private static func refusedArchives(task: String) -> [String] {
        let id = UUID().uuidString
        let event = { (fields: String) in
            #"{"version":1,"tasks":[],"events":[{"id":"\#(id)","title":"Call","start":1,"end":2,"allDay":false,"location":"","notes":"","timeZoneIdentifier":"UTC"\#(fields)}]}"#
        }
        return [
            #"{"version":1,"tasks":[\#(task)],"events":[1]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"   ","completed":false,"createdAt":1}],"events":[]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"Ok","completed":true,"createdAt":1,"completedAt":"yesterday"}],"events":[]}"#,
            #"{"version":1,"tasks":[{"id":"\#(id)","title":"Ok","completed":false}],"events":[]}"#,
            #"{"version":1,"tasks":[\#(task)]}"#,
            #"{"version":1.5,"tasks":[],"events":[]}"#,
            event(#","meetingURL":"http://example.com""#),
            event(#","meetingURL":"https://user:pw@example.com""#),
            event("").replacingOccurrences(of: #","timeZoneIdentifier":"UTC""#, with: ""),
        ]
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

    /// Agents reach To-do while the screen is locked only if the app's own file
    /// opens then. A file saved by builds up to 2.2.22 is migrated on its first read.
    // WHY: .project-docs/decisions/2026-11-04-todo-locked-screen.md
    func testStoreKeepsArchiveReadableWhileTheScreenIsLocked() throws {
        let store = PlannerStore(url: url)
        XCTAssertTrue(store.saveTask(PlannerTask(title: "Mine")))
        guard let saved = protection(url) else { throw XCTSkip("This volume has no data protection classes") }
        XCTAssertEqual(saved, .completeUntilFirstUserAuthentication)

        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        XCTAssertEqual(protection(url), .completeUnlessOpen, "As an earlier build left it")
        let relaunched = PlannerStore(url: url)
        XCTAssertEqual(relaunched.archive.tasks.map(\.title), ["Mine"])
        XCTAssertEqual(protection(url), .completeUntilFirstUserAuthentication)
    }

    private func protection(_ url: URL) -> FileProtectionType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
    }
}
