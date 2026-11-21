import AppKit
import SwiftUI
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
            confirm: { _, title in asked?(title); return answer },
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

    func testInvalidIDsCannotBeDeleted() {
        let store = makeStore()
        XCTAssertThrowsError(try store.deleteDashboard(id: "../servers"))
        XCTAssertThrowsError(try store.deleteDashboard(id: ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MonitorRemovedDashboards.url(root: root).path))
    }

    // MARK: - Server status, deleted like every other board

    private final class SSHCalls { var servers: [String] = [] }

    private func writeServers() throws -> Data {
        let json = #"{"refreshSeconds":15,"servers":[{"id":"sferyx","name":"Sferyx server","group":"Sferyx","sshTarget":"sferyx"}]}"#
        let data = Data(json.utf8)
        try data.write(to: root.appendingPathComponent("servers.json"))
        return data
    }

    private func serverStore(_ calls: SSHCalls) -> MonitorStore {
        let store = MonitorStore(root: root, collector: { server in
            await MainActor.run { calls.servers.append(server.id) }
            throw CancellationError()
        })
        store.reloadFiles()
        return store
    }

    func testDeletingServerStatusStopsConnectingAndKeepsServersJSON() async throws {
        let servers = try writeServers()
        try writeDashboard("openai-usage", title: "OpenAI")
        let calls = SSHCalls()
        let store = serverStore(calls)
        await store.refreshServers()
        XCTAssertEqual(calls.servers, ["sferyx"], "listed Server status polls its servers")
        XCTAssertFalse(store.serverStatusRemoved)

        var askedTitle: String?
        let outcome = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: true, asked: { askedTitle = $0 }))
            .delete(id: MonitorStore.serverStatusID, title: "Server status")

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(askedTitle, "Server status")
        XCTAssertTrue(store.serverStatusRemoved)
        XCTAssertTrue(store.readings.isEmpty)
        await store.refreshServers()
        XCTAssertEqual(calls.servers, ["sferyx"], "no SSH after delete")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("servers.json")), servers)
        XCTAssertEqual(store.dashboards.map(\.id), ["openai-usage"], "other boards stay")
        XCTAssertEqual(try MonitorRemovedDashboards.load(root: root).ids, ["server-status"])

        // Relaunch: still deleted, still no SSH.
        let relaunched = serverStore(calls)
        XCTAssertTrue(relaunched.serverStatusRemoved)
        await relaunched.refreshServers()
        XCTAssertEqual(calls.servers, ["sferyx"])

        // A second surface that still listed it gets alreadyGone.
        let second = await MonitorDashboardDeletion(store: relaunched, prompts: prompts(answer: true))
            .delete(id: MonitorStore.serverStatusID, title: "Server status")
        XCTAssertEqual(second, .alreadyGone)
    }

    func testCancelKeepsServerStatus() async throws {
        _ = try writeServers()
        let store = serverStore(SSHCalls())
        let outcome = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: false))
            .delete(id: MonitorStore.serverStatusID, title: "Server status")
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(store.serverStatusRemoved)
        XCTAssertEqual(store.readings.map(\.server.id), ["sferyx"])
    }

    func testRestoredServerStatusConnectsAgain() async throws {
        _ = try writeServers()
        try MonitorRemovedDashboards(ids: ["server-status", "openai-usage"]).save(root: root)
        let calls = SSHCalls()
        let store = serverStore(calls)
        await store.refreshServers()
        XCTAssertEqual(calls.servers, [])

        // customize.py restore-dashboard server-status takes the ID off the list.
        try MonitorRemovedDashboards(ids: ["openai-usage"]).save(root: root)
        store.reloadFiles()
        XCTAssertFalse(store.serverStatusRemoved)
        await store.refreshServers()
        XCTAssertEqual(calls.servers, ["sferyx"])
    }

    /// The builder's reproducer (queue ticket 315): a poll paused before SSH,
    /// as during a credential lookup, must not connect after Delete.
    func testDeletionCancelsAPollStillPreparingItsConnection() async throws {
        _ = try writeServers()
        let began = XCTestExpectation(description: "poll reached authentication before SSH")
        let release = AsyncStream<Void>.makeStream()
        let contacted = Counter()
        let store = MonitorStore(root: root) { _ in
            began.fulfill()
            for await _ in release.stream { break }
            try Task.checkCancellation()
            await MainActor.run { contacted.value += 1 }
            throw CancellationError()
        }
        store.reloadFiles()
        let poll = Task { await store.refreshServers() }
        await fulfillment(of: [began], timeout: 2)

        let outcome = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: true))
            .delete(id: MonitorStore.serverStatusID, title: "Server status")
        XCTAssertEqual(outcome, .deleted)
        release.continuation.yield(())
        release.continuation.finish()
        await poll.value

        XCTAssertEqual(contacted.value, 0, "confirmed deletion must stop a poll still preparing its connection")
        XCTAssertTrue(store.readings.isEmpty)
    }

    /// Builder's reproducer: an unreadable list may hide a deletion, so it
    /// pauses polling, in the running store and after relaunch.
    func testUnreadableListPausesServerPollingUntilItCanBeRead() async throws {
        _ = try writeServers()
        let calls = SSHCalls()
        let store = serverStore(calls)
        _ = await MonitorDashboardDeletion(store: store, prompts: prompts(answer: true))
            .delete(id: MonitorStore.serverStatusID, title: "Server status")
        try Data("invalid".utf8).write(to: MonitorRemovedDashboards.url(root: root), options: .atomic)

        store.reloadFiles()
        XCTAssertNotNil(store.dashboardError)
        XCTAssertNotNil(store.serverError, "Server status says it is paused")
        await store.refreshServers()
        XCTAssertEqual(calls.servers, [])

        let relaunched = serverStore(calls)
        XCTAssertNotNil(relaunched.dashboardError)
        XCTAssertNotNil(relaunched.serverError)
        await relaunched.refreshServers()
        XCTAssertEqual(calls.servers, [], "a fresh store does not poll while removal state is unknown")

        // Fixed list without server-status: polling resumes.
        try MonitorRemovedDashboards().save(root: root)
        relaunched.reloadFiles()
        XCTAssertNil(relaunched.serverError)
        await relaunched.refreshServers()
        XCTAssertEqual(calls.servers, ["sferyx"])
    }

    func testDeletingOpenServerStatusReturnsToThePicker() {
        XCTAssertNil(MonitorHoverPanel.selection(afterDeleting: MonitorStore.serverStatusID, outcome: .deleted,
                                                 selectedID: MonitorStore.serverStatusID))
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
        XCTAssertFalse(source.contains("onDelete: nil"), "every board, Server status included, has an ×")
        XCTAssertTrue(source.contains("delete(id: MonitorStore.serverStatusID"))
        XCTAssertGreaterThan(MonitorHoverPanel.scrollerGutter, 0)
    }

    func testCrossShowsHoverPressAndFocusOnlyWhileEnabled() {
        typealias Look = MonitorPickerControlAppearance
        let idle = Look.deleteCross(hovered: false, pressed: false, focused: false, enabled: true)
        let hover = Look.deleteCross(hovered: true, pressed: false, focused: false, enabled: true)
        let press = Look.deleteCross(hovered: true, pressed: true, focused: false, enabled: true)
        let focus = Look.deleteCross(hovered: false, pressed: false, focused: true, enabled: true)
        XCTAssertEqual(idle.fill, 0)
        XCTAssertGreaterThan(hover.fill, idle.fill)
        XCTAssertGreaterThan(hover.symbol, idle.symbol)
        XCTAssertGreaterThan(press.fill, hover.fill)
        XCTAssertGreaterThan(focus.focusRing, 0)
        XCTAssertEqual(idle.focusRing, 0)

        // A delete in progress disables the ×; the pointer may still be on it.
        let disabled = Look.deleteCross(hovered: false, pressed: false, focused: false, enabled: false)
        for hovered in [false, true] { for pressed in [false, true] { for focused in [false, true] {
            XCTAssertEqual(Look.deleteCross(hovered: hovered, pressed: pressed, focused: focused, enabled: false),
                           disabled)
        } } }
        XCTAssertEqual(disabled.fill, 0)
        XCTAssertLessThan(disabled.symbol, idle.symbol, "disabled reads dimmer than resting")
    }

    func testRowShowsHoverPressAndFocusWithoutAChevron() {
        typealias Look = MonitorPickerControlAppearance
        let idle = Look.row(hovered: false, pressed: false, focused: false, enabled: true)
        let hover = Look.row(hovered: true, pressed: false, focused: false, enabled: true)
        let press = Look.row(hovered: true, pressed: true, focused: false, enabled: true)
        let focus = Look.row(hovered: false, pressed: false, focused: true, enabled: true)
        XCTAssertGreaterThan(hover.fill, idle.fill)
        XCTAssertGreaterThan(press.fill, hover.fill)
        XCTAssertGreaterThan(focus.focusRing, 0)
        XCTAssertEqual(Look.row(hovered: true, pressed: true, focused: true, enabled: false),
                       Look.row(hovered: false, pressed: false, focused: false, enabled: false))
    }

    /// The builder's offscreen probe: a × disabled under the pointer drew the
    /// hovered surface. Rendered pixels must match a resting disabled ×.
    func testRenderedCrossDisabledUnderThePointerLooksDisabled() throws {
        let enabled = try render(MonitorDashboardDeleteButton(title: "Fixture", action: {}))
        let enabledHover = try render(MonitorDashboardDeleteButton(title: "Fixture", initiallyHovered: true, action: {}))
        let disabled = try render(MonitorDashboardDeleteButton(title: "Fixture", action: {}).disabled(true))
        let disabledHover = try render(MonitorDashboardDeleteButton(title: "Fixture", initiallyHovered: true,
                                                                   action: {}).disabled(true))
        XCTAssertGreaterThan(changedPixels(enabled, enabledHover), 100, "hover is visible")
        XCTAssertGreaterThan(changedPixels(enabled, disabled), 0, "disabled is visible")
        XCTAssertEqual(changedPixels(disabled, disabledHover), 0)
    }

    func testRenderedRowHoverIsVisible() throws {
        func row(_ hovered: Bool) -> some View {
            MonitorDashboardRowButton(title: "Fixture", initiallyHovered: hovered, action: {}) {
                Text("Fixture").padding(10)
            }
        }
        XCTAssertGreaterThan(changedPixels(try render(row(false), size: 120), try render(row(true), size: 120)), 100)
    }

    private func render<V: View>(_ view: V, size: CGFloat = 40) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.padding(8).frame(width: size, height: 40)
            .background(Color(white: 0.12)).environment(\.colorScheme, .dark))
        let bounds = NSRect(x: 0, y: 0, width: size, height: 40)
        let panel = NSPanel(contentRect: bounds.offsetBy(dx: -20_000, dy: -20_000),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        host.frame = bounds
        host.appearance = NSAppearance(named: .darkAqua)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertFalse(panel.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        panel.contentView = nil
        panel.close()
        return bitmap
    }

    private func changedPixels(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Int {
        var changed = 0
        for y in 0..<min(first.pixelsHigh, second.pixelsHigh) {
            for x in 0..<min(first.pixelsWide, second.pixelsWide)
            where first.colorAt(x: x, y: y) != second.colorAt(x: x, y: y) {
                changed += 1
            }
        }
        return changed
    }

    // MARK: - Confirmation

    func testConfirmationPutsCancelFirstAndDeleteHasNoKey() {
        let alert = MonitorDashboardDeletionAlerts.makeConfirmation(id: "anthropic-budget", title: "Anthropic")

        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Delete"])
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertTrue(alert.messageText.contains("Anthropic"))
        XCTAssertTrue(alert.informativeText.contains("collector"))

        let servers = MonitorDashboardDeletionAlerts.makeConfirmation(id: "server-status", title: "Server status")
        XCTAssertEqual(servers.buttons.map(\.title), ["Cancel", "Delete"])
        XCTAssertTrue(servers.messageText.contains("Server status"))
        XCTAssertTrue(servers.informativeText.contains("servers.json is not touched"))
        XCTAssertFalse(servers.informativeText.contains("collector"))
    }
}
