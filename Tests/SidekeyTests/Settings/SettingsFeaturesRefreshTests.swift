import Combine
import XCTest
@testable import Sidekey

/// Settings -> Features stays quiet while nothing it shows changes. Its
/// snapshot reads every provider key on the main thread; a Notify registry
/// reread every 2 s used to rebuild it each time, and the whole app,
/// the island's dictation wing included, stalled for ~0.6 s every few seconds.
// WHY: .project-docs/decisions/2026-11-25-settings-features-refresh.md
@MainActor
final class SettingsFeaturesRefreshTests: XCTestCase {
    private func fixture() async throws -> FeaturesFixture {
        let fixture = try await FeaturesFixture(.usual)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        return fixture
    }

    private func source(_ id: String, enabled: Bool = false) -> NotifyScript {
        NotifyScript(id: id, name: id, command: ["/usr/bin/true"], enabled: enabled, intervalSeconds: 86400)
    }

    private func writeDashboard(_ id: String, in fixture: FeaturesFixture) throws {
        let dashboards = fixture.monitor.root.appendingPathComponent("dashboards", isDirectory: true)
        try FileManager.default.createDirectory(at: dashboards, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let snapshot = """
        {"id":"\(id)","title":"\(id)","systemImage":"shippingbox","updatedAt":"\(stamp)",
         "staleAfterSeconds":120,"widgets":[{"id":"ok","kind":"status","title":"Production","value":"Healthy"}]}
        """
        try Data(snapshot.utf8).write(to: dashboards.appendingPathComponent("\(id).json"))
    }

    func testRereadingTheSameSourcesAndDashboardsDoesNotRebuildTheSnapshot() async throws {
        let fixture = try await fixture()
        var rebuilds = 0
        let watch = fixture.environment.snapshotCountChanges.sink { rebuilds += 1 }
        defer { watch.cancel() }

        XCTAssertEqual(rebuilds, 0, "Opening the screen is not a change")
        fixture.notifySupervisor.reconcile([source("builds")])
        XCTAssertEqual(rebuilds, 1, "A connected source counts at once")

        for _ in 0..<5 {
            fixture.notifySupervisor.reconcile([source("builds")])
            fixture.monitor.reloadFiles()
        }
        XCTAssertEqual(rebuilds, 1, "Rereading unchanged sources and dashboards rebuilds nothing")

        try writeDashboard("deploys", in: fixture)
        fixture.monitor.reloadFiles()
        XCTAssertEqual(rebuilds, 2, "A new dashboard counts at once")
        XCTAssertEqual(fixture.snapshot.monitorDashboards, 1)

        fixture.notifySupervisor.reconcile([])
        XCTAssertEqual(rebuilds, 3, "A removed source counts at once")
        XCTAssertEqual(fixture.snapshot.notifySources, 0)
    }

    func testTheSupervisorDoesNotRepublishAnUnchangedRegistry() async throws {
        let fixture = try await fixture()
        let supervisor = fixture.notifySupervisor
        supervisor.reconcile([source("builds"), source("mail")])
        var published = 0
        let watch = supervisor.$sources.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }

        supervisor.reconcile([source("builds"), source("mail")])
        XCTAssertEqual(published, 0)

        var renamed = source("mail")
        renamed.name = "Inbox"
        supervisor.reconcile([source("builds"), renamed])
        XCTAssertEqual(published, 1, "A changed manifest is still shown")
        XCTAssertEqual(supervisor.sources.map(\.script.name), ["builds", "Inbox"])
    }

    /// The running app: the supervisor rereads its folder every 2 s while a
    /// source is installed. Settings must not hear from it in between.
    func testARunningSupervisorWithAnInstalledSourceStaysQuietBetweenRereads() async throws {
        let fixture = try await fixture()
        let supervisor = fixture.notifySupervisor
        let sources = fixture.environment.notifyRoot.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let manifest = ##"{"id":"builds","name":"Build results","command":["/usr/bin/true"],"enabled":false,"intervalSeconds":86400}"##
        try Data(manifest.utf8).write(to: sources.appendingPathComponent("builds.json"))

        supervisor.start()
        for _ in 0..<200 where supervisor.sources.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(supervisor.sources.map(\.id), ["builds"])

        var rebuilds = 0
        var errors = 0
        let watch = fixture.environment.snapshotCountChanges.sink { rebuilds += 1 }
        let errorWatch = supervisor.$error.dropFirst().sink { _ in errors += 1 }
        defer { watch.cancel(); errorWatch.cancel() }
        var sourcePublishes = 0
        let sourceWatch = supervisor.$sources.dropFirst().sink { _ in sourcePublishes += 1 }
        defer { sourceWatch.cancel() }

        // Longer than one reread interval (2 s).
        try await Task.sleep(for: .milliseconds(2600))
        XCTAssertEqual(sourcePublishes, 0, "An unchanged folder is not republished")
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(rebuilds, 0, "Settings' snapshot is not rebuilt")
    }
}
