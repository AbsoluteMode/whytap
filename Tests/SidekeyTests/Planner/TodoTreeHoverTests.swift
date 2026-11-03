import AppKit
import SwiftUI
import XCTest
import WhytapCaseKit
@testable import Sidekey

/// The To-do tree as the user and an agent use it together while Whytap runs.
@MainActor
final class TodoTreeHoverTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("Planner/planner-v1.json") }
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("todo-tree-hover-" + UUID().uuidString)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func meeting(_ controller: AppControlController) async throws -> [String: AppControlValue] {
        let response = await controller.handle(AppControlRequest("todo_add", arguments: ["tasks": .array([
            .object(["title": .string("Исследовать клин"), "children": .array([
                .object(["title": .string("Запустить проверку на последних 30 картах"),
                         "status": .string("готово, результаты отправил Свете в тг"),
                         "children": .array([.object(["title": .string("Согласовать план со Светой"),
                                                      "status": .string("жду фидбека Светы")])])])])])])]))
        XCTAssertTrue(response.ok, "\(response)")
        return try XCTUnwrap(response.data.object)
    }

    func testAgentTreeShowsAsFoldersAndCollapseHidesSubtasks() async throws {
        let store = PlannerStore(url: url)
        let controller = AppControlController(planner: { store })
        let added = try await meeting(controller)
        XCTAssertEqual(added["delivery"], .string("app"))
        XCTAssertEqual(added["added"], .int(3))

        let model = TodoHoverModel(store: store)
        model.begin()
        XCTAssertEqual(model.rows.map(\.task.title),
                       ["Исследовать клин", "Запустить проверку на последних 30 картах", "Согласовать план со Светой"])
        XCTAssertEqual(model.rows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(model.rows.map(\.childCount), [1, 1, 0])
        XCTAssertEqual(model.rows[2].task.status, "жду фидбека Светы")

        model.toggleCollapsed(model.rows[0].id)
        XCTAssertEqual(model.rows.map(\.task.title), ["Исследовать клин"])
        model.toggleCollapsed(model.rows[0].id)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(PlannerStore(url: url).archive.tasks.map(\.node), store.archive.tasks.map(\.node),
                       "A fresh launch reads the same tree")
    }

    func testClosingFolderClosesSubtasksAndOneClickUndoesIt() async throws {
        let store = PlannerStore(url: url)
        _ = try await meeting(AppControlController(planner: { store }))
        let model = TodoHoverModel(store: store)
        model.begin()
        let root = model.rows[0].id
        model.toggle(root, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(store.archive.tasks.allSatisfy(\.completed))
        XCTAssertEqual(model.rows.count, 3, "Struck through until the panel closes")
        model.toggle(root)
        XCTAssertTrue(store.archive.tasks.allSatisfy { !$0.completed })
        model.toggle(root)
        model.end(); model.begin()
        XCTAssertTrue(model.rows.isEmpty, "All subtasks leave with their parent")
        model.showingHistory = true
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows.first { $0.task.title == "Согласовать план со Светой" }?.parentTitle,
                       "Запустить проверку на последних 30 картах")
    }

    func testInlineSubtaskStatusAndRenameWithValidation() throws {
        let store = PlannerStore(url: url)
        let model = TodoHoverModel(store: store)
        model.begin()
        model.draft = "Исследовать клин"; XCTAssertTrue(model.submit())
        let root = try XCTUnwrap(model.rows.first?.id)

        model.beginEditing(.subtask(parent: root))
        model.editor?.text = "Запустить проверку"
        XCTAssertTrue(model.commitEditor())
        XCTAssertNil(model.editor)
        let child = try XCTUnwrap(model.rows.last)
        XCTAssertEqual(child.depth, 1)
        XCTAssertEqual(model.lastAddedID, child.id)

        model.beginEditing(.status(child.id))
        model.editor?.text = String(repeating: "s", count: 301)
        XCTAssertFalse(model.commitEditor())
        XCTAssertNotNil(model.validationMessage, "The rejected status stays editable with an explanation")
        model.editor?.text = "готово, результаты отправил Свете в тг"
        XCTAssertTrue(model.commitEditor())
        XCTAssertEqual(store.archive.tasks.last?.status, "готово, результаты отправил Свете в тг")

        model.beginEditing(.status(child.id))
        XCTAssertEqual(model.editor?.text, "готово, результаты отправил Свете в тг")
        model.editor?.text = "  "
        XCTAssertTrue(model.commitEditor())
        XCTAssertNil(store.archive.tasks.last?.status, "An empty status clears it")

        model.beginEditing(.title(root))
        model.editor?.text = "  "
        XCTAssertFalse(model.commitEditor())
        model.editor?.text = "Исследовать клин v2"
        XCTAssertTrue(model.commitEditor())
        XCTAssertEqual(model.rows.first?.task.title, "Исследовать клин v2")

        model.beginEditing(.subtask(parent: root))
        model.editor?.text = ""
        XCTAssertTrue(model.commitEditor(), "Return in an empty subtask field just closes it")
        XCTAssertEqual(store.archive.tasks.count, 2)
    }

    func testAgentUpdateWhileUserWatchesAndFieldErrors() async throws {
        let store = PlannerStore(url: url)
        let controller = AppControlController(planner: { store })
        _ = try await meeting(controller)
        let leaf = try XCTUnwrap(store.archive.tasks.first { $0.title == "Согласовать план со Светой" })
        let prefix = String(leaf.id.uuidString.prefix(8))
        let updated = await controller.handle(AppControlRequest("todo_update", arguments: [
            "id": .string(prefix), "status": .string("Света ответила, план ок"), "completed": .bool(true)]))
        XCTAssertTrue(updated.ok, "\(updated)")
        XCTAssertEqual(updated.data.object?["delivery"], .string("app"))
        XCTAssertEqual(store.archive.tasks.first { $0.id == leaf.id }?.status, "Света ответила, план ок")
        XCTAssertEqual(store.archive.tasks.first { $0.id == leaf.id }?.completed, true)

        let moved = await controller.handle(AppControlRequest("todo_update", arguments: ["id": .string(prefix), "parentID": .null]))
        XCTAssertTrue(moved.ok)
        XCTAssertNil(store.archive.tasks.first { $0.id == leaf.id }?.parentID)

        let root = try XCTUnwrap(store.archive.tasks.first { $0.parentID == nil && $0.title == "Исследовать клин" })
        let child = try XCTUnwrap(store.archive.tasks.first { $0.parentID == root.id })
        for (arguments, code): ([String: AppControlValue], String) in [
            (["id": .string(root.id.uuidString), "parentID": .string(child.id.uuidString)], "invalid_parent"),
            (["id": .string(root.id.uuidString)], "invalid_arguments"),
            (["id": .string("zzzzzzzz"), "title": .string("x")], "not_found"),
            (["id": .string(root.id.uuidString), "completed": .string("yes")], "invalid_arguments")
        ] {
            let response = await controller.handle(AppControlRequest("todo_update", arguments: arguments))
            XCTAssertEqual(response.data.object?["code"], .string(code), "\(arguments)")
        }
        let listed = await controller.handle(AppControlRequest("todo_list"))
        XCTAssertEqual(listed.data.object?["tasks"]?.array?.compactMap { $0.object?["depth"] }, [.int(0), .int(1)])
    }

    func testAppRefusesBrokenTreeFileAndOlderShapeStillLoads() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let a = UUID().uuidString, b = UUID().uuidString
        let cycle = #"{"version":1,"events":[],"tasks":[{"id":"\#(a)","title":"A","completed":false,"createdAt":1,"parentID":"\#(b)"},{"id":"\#(b)","title":"B","completed":false,"createdAt":2,"parentID":"\#(a)"}]}"#
        try Data(cycle.utf8).write(to: url)
        let store = PlannerStore(url: url)
        XCTAssertFalse(store.canWrite)
        XCTAssertThrowsError(try store.editTasks { _ in })
        XCTAssertEqual(try Data(contentsOf: url), Data(cycle.utf8))

        let flat = #"{"version":1,"events":[],"tasks":[{"id":"\#(a)","title":"A","completed":false,"createdAt":1}]}"#
        try Data(flat.utf8).write(to: url)
        store.reload()
        XCTAssertTrue(store.canWrite)
        XCTAssertNil(store.archive.tasks.first?.parentID)
        XCTAssertTrue(store.saveTask(try XCTUnwrap(store.archive.tasks.first)))
        let saved = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertFalse(saved.contains("parentID") || saved.contains("\"status\""), "Flat tasks keep the old file shape")
    }

    func testOffscreenTreeFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTap_TODO_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTap_TODO_RENDER_DIR for synthetic offscreen To-do tree fixtures")
        }
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = PlannerStore(url: url)
        _ = try await meeting(AppControlController(planner: { store }))
        _ = try store.addTasks(["Купить кофе", "Ответить на письмо"])
        for width: CGFloat in [310, 360] {
            for name in ["tree", "editing", "collapsed"] {
                let model = TodoHoverModel(store: store)
                model.begin()
                if name == "editing", let child = model.rows.first(where: { $0.depth == 1 }) {
                    model.beginEditing(.status(child.id)); model.editor?.text = "готово, результаты отправил Свете в тг"
                }
                if name == "collapsed", let root = model.rows.first { model.toggleCollapsed(root.id) }
                let host = NSHostingView(rootView: TodoHoverView(model: model, onBack: {})
                    .background(Color(white: 0.12)).environment(\.colorScheme, .dark))
                let size = NSSize(width: width, height: TodoHoverView.contentHeight)
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                host.frame = NSRect(origin: .zero, size: size); window.contentView = host
                try await Task.sleep(for: .milliseconds(60))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("tree-\(name)-\(Int(width)).png"))
                XCTAssertFalse(window.isVisible || window.isKeyWindow)
                window.contentView = nil; window.close()
            }
        }
    }
}
