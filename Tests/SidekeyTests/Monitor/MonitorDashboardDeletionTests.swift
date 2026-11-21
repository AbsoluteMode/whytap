import XCTest
@testable import Sidekey

/// Deleting a custom Monitor dashboard, from the user's side: Delete… on a
/// board, the confirmation, and what Monitor lists afterwards, also after a
/// relaunch and while the board's collector keeps rewriting its snapshot.
@MainActor
final class MonitorDashboardDeletionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("monitor-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dashboards, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var dashboards: URL { root.appendingPathComponent("dashboards", isDirectory: true) }

    private func writeDashboard(_ id: String, title: String, file: String? = nil) throws {
        let json = #"{"id":"\#(id)","title":"\#(title)","widgets":[{"id":"w","kind":"metric","title":"Value","value":"1"}]}"#
        try Data(json.utf8).write(to: dashboards.appendingPathComponent(file ?? "\(id).json"))
    }

    private func makeStore() -> MonitorStore {
        let store = MonitorStore(root: root, collector: { _ in throw CancellationError() })
        store.reloadFiles()
        return store
    }

    private final class Counter { var value = 0 }

    private func prompts(answer: Bool, failures: Counter? = nil,
                         asked: ((String) -> Void)? = nil) -> MonitorDashboardDeletionPrompts {
        MonitorDashboardDeletionPrompts(
            confirm: { title in asked?(title); return answer },
            reportFailure: { failures?.value += 1 })
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dashboards.appendingPathComponent(name).path)
    }

    // MARK: - Scenarios

    func testDeletingOneOfSeveralBoardsRemovesOnlyThatBoard() async throws {
        try writeDashboard("anthropic-budget", title: "Anthropic")
        try writeDashboard("openai-usage", title: "OpenAI")
        try writeDashboard("try-usage", title: "Try")
        // The user's collector and server configuration live next to the boards.
        let collector = root.appendingPathComponent("collectors/anthropic-budget", isDirectory: true)
        try FileManager.default.createDirectory(at: collector, withIntermediateDirectories: true)
        try Data("print(1)\n".utf8).write(to: collector.appendingPathComponent("collect.py"))
        try Data(#"{"servers":[]}"#.utf8).write(to: root.appendingPathComponent("servers.json"))

        let store = makeStore()
        let board = try XCTUnwrap(store.dashboards.first { $0.id == "openai-usage" })
        var askedTitle: String?
        let outcome = await MonitorDashboardDeletion(
            store: store, prompts: prompts(answer: true, asked: { askedTitle = $0 })).delete(board)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(askedTitle, "OpenAI")
        XCTAssertEqual(store.dashboards.map(\.id), ["anthropic-budget", "try-usage"])
        XCTAssertFalse(exists("openai-usage.json"))
        XCTAssertTrue(exists("anthropic-budget.json"))
        XCTAssertTrue(exists("try-usage.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: collector.appendingPathComponent("collect.py").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("servers.json").path))
        XCTAssertNil(store.dashboardError)
    }

    func testCancelKeepsEverything() async throws {
        try writeDashboard("anthropic-budget", title: "Anthropic")
        try writeDashboard("openai-usage", title: "OpenAI")
        let store = makeStore()
        let board = try XCTUnwrap(store.dashboards.first)

        let outcome = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: false)).delete(board)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(outcome.removesDashboard)
        XCTAssertEqual(store.dashboards.count, 2)
        XCTAssertTrue(exists("anthropic-budget.json"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MonitorRemovedDashboards.url(root: root).path))
    }

    func testDeletedBoardStaysGoneAfterRelaunchAndCollectorRewrite() async throws {
        try writeDashboard("anthropic-budget", title: "Anthropic")
        try writeDashboard("openai-usage", title: "OpenAI")
        let store = makeStore()
        let board = try XCTUnwrap(store.dashboards.first { $0.id == "anthropic-budget" })
        _ = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: true)).delete(board)

        // Relaunch: a new store over the same Monitor folder.
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.dashboards.map(\.id), ["openai-usage"])

        // The collector runs again and rewrites its snapshot (any file name).
        try writeDashboard("anthropic-budget", title: "Anthropic", file: "anthropic-budget.json")
        relaunched.reloadFiles()
        store.reloadFiles()
        XCTAssertEqual(relaunched.dashboards.map(\.id), ["openai-usage"])
        XCTAssertEqual(store.dashboards.map(\.id), ["openai-usage"])
        XCTAssertNil(relaunched.dashboardError, "a hidden board is not reported as a broken file")
    }

    func testDeletingTheOpenBoardReturnsToThePicker() {
        XCTAssertNil(MonitorHoverPanel.selection(afterDeleting: "openai-usage", outcome: .deleted,
                                                 selectedID: "openai-usage"))
        XCTAssertNil(MonitorHoverPanel.selection(afterDeleting: "openai-usage", outcome: .alreadyGone,
                                                 selectedID: "openai-usage"))
        XCTAssertEqual(MonitorHoverPanel.selection(afterDeleting: "openai-usage", outcome: .cancelled,
                                                   selectedID: "openai-usage"), "openai-usage")
        XCTAssertEqual(MonitorHoverPanel.selection(afterDeleting: "openai-usage", outcome: .failed,
                                                   selectedID: "openai-usage"), "openai-usage")
        XCTAssertNil(MonitorHoverPanel.selection(afterDeleting: "openai-usage", outcome: .deleted,
                                                 selectedID: nil))
    }

    func testOpenBoardDeletedFromAnotherSurfaceIsAlreadyGone() async throws {
        try writeDashboard("anthropic-budget", title: "Anthropic")
        let island = makeStore()
        let toolbox = makeStore()
        let board = try XCTUnwrap(toolbox.dashboards.first)

        let first = await MonitorDashboardDeletion(store: island, prompts: prompts(answer: true)).delete(board)
        let second = await MonitorDashboardDeletion(store: toolbox, prompts: prompts(answer: true)).delete(board)
        XCTAssertEqual(first, .deleted)
        XCTAssertEqual(second, .alreadyGone)
        XCTAssertTrue(toolbox.dashboards.isEmpty)
    }

    func testDuplicateCopiesOfTheBoardAreAllRemoved() async throws {
        try writeDashboard("anthropic-budget", title: "Anthropic", file: "a.json")
        try writeDashboard("anthropic-budget", title: "Anthropic", file: "b.json")
        let store = makeStore()
        let board = try XCTUnwrap(store.dashboards.first)

        let outcome = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: true)).delete(board)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(exists("a.json"))
        XCTAssertFalse(exists("b.json"))
        XCTAssertNil(store.dashboardError)
    }

    func testUnreadableRemovedListFailsWithoutDeletingAndShowsEveryBoard() async throws {
        try writeDashboard("anthropic-budget", title: "Anthropic")
        try Data("not json".utf8).write(to: MonitorRemovedDashboards.url(root: root))
        let store = makeStore()
        XCTAssertEqual(store.dashboards.map(\.id), ["anthropic-budget"])
        XCTAssertNotNil(store.dashboardError)
        let board = try XCTUnwrap(store.dashboards.first)
        let failures = Counter()

        let outcome = await MonitorDashboardDeletion(
            store: store, prompts: prompts(answer: true, failures: failures)).delete(board)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(failures.value, 1)
        XCTAssertTrue(exists("anthropic-budget.json"))
        XCTAssertEqual(try String(contentsOf: MonitorRemovedDashboards.url(root: root), encoding: .utf8), "not json")
    }

    func testServerStatusAndInvalidIDsCannotBeDeleted() {
        let store = makeStore()
        XCTAssertThrowsError(try store.deleteDashboard(id: "server-status"))
        XCTAssertThrowsError(try store.deleteDashboard(id: "../servers"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MonitorRemovedDashboards.url(root: root).path))
    }

    func testRemovedListIsPrivateAndRoundTrips() throws {
        var list = MonitorRemovedDashboards()
        list.insert("anthropic-budget")
        try list.save(root: root)
        let file = MonitorRemovedDashboards.url(root: root)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try MonitorRemovedDashboards.load(root: root), list)
        XCTAssertEqual(MonitorRemovedDashboards.fileName, "removed-dashboards.json")
    }

    func testDeleteWaitsForTheInstallerLockAndFailsCleanlyWhenItIsHeld() async throws {
        try writeDashboard("anthropic-budget", title: "Anthropic")
        let store = makeStore()
        store.removedListLockTimeout = 0.1
        let board = try XCTUnwrap(store.dashboards.first)

        // customize.py install-dashboard holds the same flock while it edits the list.
        let lockPath = root.appendingPathComponent(MonitorRemovedDashboards.lockFileName).path
        let installer = open(lockPath, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(installer, 0)
        XCTAssertEqual(flock(installer, LOCK_EX | LOCK_NB), 0)
        let failures = Counter()
        let blocked = await MonitorDashboardDeletion(
            store: store, prompts: prompts(answer: true, failures: failures)).delete(board)
        XCTAssertEqual(blocked, .failed)
        XCTAssertEqual(failures.value, 1)
        XCTAssertTrue(exists("anthropic-budget.json"), "nothing is removed while the list is busy")
        XCTAssertEqual(store.dashboards.map(\.id), ["anthropic-budget"])

        close(installer)
        let outcome = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: true)).delete(board)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(try MonitorRemovedDashboards.load(root: root).ids, ["anthropic-budget"])
    }

    func testDeleteKeepsIDsAnotherWriterSavedBefore() async throws {
        try writeDashboard("openai-usage", title: "OpenAI")
        // Saved by another Monitor surface or the installer before this delete.
        try MonitorRemovedDashboards(ids: ["anthropic-budget"]).save(root: root)
        let store = makeStore()
        let board = try XCTUnwrap(store.dashboards.first)

        _ = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: true)).delete(board)

        XCTAssertEqual(try MonitorRemovedDashboards.load(root: root).ids, ["anthropic-budget", "openai-usage"])
    }

    // MARK: - Picker

    /// The island has no right-click interactions: a custom board's row has an
    /// ×, rows have no chevron, and the scroller sits beside the cards.
    func testPickerDeletesWithACrossNotAContextMenu() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/Monitor/MonitorHoverPanel.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(source.contains(".contextMenu"))
        XCTAssertFalse(source.contains("chevron.right"))
        XCTAssertTrue(source.contains("MonitorDashboardDeleteButton(title:"))
        XCTAssertTrue(source.contains("onDelete: nil"), "Server status gets no ×")
        XCTAssertGreaterThan(MonitorHoverPanel.scrollerGutter, 0)
    }

    // MARK: - Confirmation

    func testConfirmationPutsCancelFirstAndDeleteHasNoKey() {
        let alert = MonitorDashboardDeletionAlerts.makeConfirmation(title: "Anthropic")

        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Delete"])
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertTrue(alert.messageText.contains("Anthropic"))
        XCTAssertTrue(alert.informativeText.contains("collector"))
    }
}
