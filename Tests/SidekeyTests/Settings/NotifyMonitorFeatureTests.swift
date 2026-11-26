import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Settings -> Features -> Notify and Monitor, as a person uses them: open
/// the screen, copy the prompt for their coding agent, and see what the agent
/// connected appear. The prompt is checked against what the app really reads:
/// a manifest and a snapshot written the way it says are accepted.
@MainActor
final class NotifyMonitorFeatureTests: XCTestCase {
    private func fixture(_ state: FeaturesFixture.State = .usual) async throws -> FeaturesFixture {
        let fixture = try await FeaturesFixture(state)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        return fixture
    }

    // MARK: - Opening and status

    func testNotifyAndMonitorOpenTheirOwnScreens() {
        for feature in [AppFeature.notify, .monitor] {
            let selection = SettingsWindowSelection(selectedTab: .other)
            selection.open(feature)
            XCTAssertEqual(selection.selectedTab, .features)
            XCTAssertEqual(selection.shownFeature, feature)
        }
    }

    func testNothingConnectedIsQuietAndCountsNowhere() async throws {
        let snapshot = try await fixture(.freshInstall).snapshot
        for feature in [AppFeature.notify, .monitor] {
            let status = FeatureCatalog.status(for: feature, snapshot: snapshot)
            XCTAssertEqual(status.word, "Not set up")
            XCTAssertTrue(status.missing.isEmpty, "Nothing is asked of the person")
        }
        XCTAssertEqual(FeatureCatalog.summary([FeatureCatalog.status(for: .notify, snapshot: snapshot)]), "0 ready")
    }

    func testAConnectedSourceOrDashboardMakesItReady() {
        var snapshot = FeatureSetupSnapshot()
        snapshot.notifySources = 1
        snapshot.monitorDashboards = 2
        XCTAssertEqual(FeatureCatalog.status(for: .notify, snapshot: snapshot), .ready(note: nil))
        XCTAssertEqual(FeatureCatalog.status(for: .monitor, snapshot: snapshot), .ready(note: nil))
    }

    // MARK: - Copy prompt

    func testCopyPromptPutsThePromptOnTheClipboardAndSaysSoForAMoment() async throws {
        let fixture = try await fixture()
        let copier = PromptCopier(copy: fixture.environment.copyText, shownFor: .milliseconds(50))
        let prompt = CodingAgentPrompt.notify(root: fixture.environment.notifyRoot)
        copier.copy(prompt)
        XCTAssertEqual(fixture.clipboard.texts, [prompt])
        XCTAssertTrue(copier.copied)
        for _ in 0..<100 where copier.copied { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(copier.copied, "The button reads Copy prompt again")

        copier.copy(prompt)
        copier.cancel()
        XCTAssertFalse(copier.copied, "Leaving the screen resets it")
        XCTAssertEqual(fixture.clipboard.texts.count, 2, "A second click copies again")
    }

    func testThePromptNamesEveryAgentItIsForAndEachHasItsMark() throws {
        XCTAssertEqual(CodingAgent.allCases.map(\.name), ["Claude Code", "Codex", "Cursor", "Antigravity"])
        XCTAssertEqual(CodingAgent.names, "Claude Code, Codex, Cursor or Antigravity")
        let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/UsefulLinkIcons")
        for agent in CodingAgent.allCases {
            let url = icons.appendingPathComponent(agent.assetName + ".pdf")
            XCTAssertNotNil(NSImage(contentsOf: url), "\(agent.name) has a bundled mark")
        }
    }

    func testNotifyPromptPointsToThisMacsFolderAndTheRulesTheAppEnforces() async throws {
        let fixture = try await fixture()
        let root = fixture.environment.notifyRoot
        let prompt = CodingAgentPrompt.notify(root: root)
        XCTAssertTrue(prompt.contains(root.appendingPathComponent("README.md").path), "The guide the app writes")
        XCTAssertTrue(prompt.contains(root.appendingPathComponent("sources").path + "/<id>.json"))
        XCTAssertTrue(prompt.contains(root.appendingPathComponent("history.json").path), "How delivery is verified")
        for scheme in ["https", "http", "tg", "slack", "linear", "github", "mailto", "codex://threads/",
                       "claude://code/continue?session=local_"] {
            XCTAssertTrue(prompt.contains(scheme), "Link \(scheme) is allowed by ScriptNotification")
        }
        XCTAssertTrue(prompt.contains("Keychain"))
        XCTAssertTrue(prompt.contains("Do not send messages to other people"))
        XCTAssertTrue(prompt.contains("Settings → Features → Notify"))
        XCTAssertFalse(prompt.contains("~/"), "Real paths, not a home placeholder")

        // The live prompt follows this build's own folder.
        XCTAssertTrue(CodingAgentPrompt.notify(root: NotifyPaths.root).contains(BuildConfig.bundleID + "/notifications"))
    }

    func testASourceWrittenTheWayThePromptSaysIsAccepted() async throws {
        let fixture = try await fixture()
        let sources = fixture.environment.notifyRoot.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let manifest = ##"{"id":"builds","name":"Build results","command":["/usr/bin/true"],"intervalSeconds":86400,"tint":"#F2A03B","logo":"hammer.fill","duration":8}"##
        try Data(manifest.utf8).write(to: sources.appendingPathComponent("builds.json"))
        let (scripts, invalid) = try NotifyRegistry.read(sources)
        XCTAssertEqual(scripts.map(\.id), ["builds"])
        XCTAssertTrue(invalid.isEmpty)

        // One flushed JSON object per line, as the prompt says.
        var decoder = NotifyLineDecoder()
        let line = #"{"id":"setup-1","title":"Build passed","link":"https://example.com/build/1"}"# + "\n"
        let payloads = decoder.append(Data(line.utf8))
        XCTAssertEqual(payloads.count, 1)
        let payload = try XCTUnwrap(try? payloads.first?.get())
        let event = try LocalNotificationEvent.make(payload, script: scripts[0])
        XCTAssertEqual(event.title, "Build passed")
        XCTAssertNotNil(event.link)
    }

    func testMonitorPromptPointsToThisMacsFolderAndTheSnapshotContract() async throws {
        let fixture = try await fixture()
        let root = fixture.monitor.root
        let prompt = CodingAgentPrompt.monitor(root: root)
        XCTAssertTrue(prompt.contains(root.appendingPathComponent("dashboards").path + "/<id>.json"))
        XCTAssertTrue(prompt.contains(root.appendingPathComponent("servers.json").path))
        XCTAssertTrue(prompt.contains("\"server-status\" is reserved"))
        for kind in ["metric", "progress", "status", "text", "chart"] {
            XCTAssertNotNil(MonitorWidgetKind(rawValue: kind))
            XCTAssertTrue(prompt.contains(kind))
        }
        XCTAssertTrue(prompt.contains("never as zero"))
        XCTAssertTrue(prompt.contains("hover the notch → Monitor"))
        XCTAssertTrue(CodingAgentPrompt.monitor(root: MonitorPaths.root).contains(BuildConfig.bundleID + "/Monitor/dashboards"))
    }

    // MARK: - What the agent connected shows up

    func testADashboardWrittenTheWayThePromptSaysAppearsAndMakesMonitorReady() async throws {
        let fixture = try await fixture()
        let dashboards = fixture.monitor.root.appendingPathComponent("dashboards", isDirectory: true)
        try FileManager.default.createDirectory(at: dashboards, withIntermediateDirectories: true)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let snapshot = """
        {"id":"deploys","title":"Deploys","subtitle":"Last release","systemImage":"shippingbox","updatedAt":"\(stamp)",
         "staleAfterSeconds":120,"widgets":[{"id":"ok","kind":"status","title":"Production","value":"Healthy"},
         {"id":"p","kind":"chart","title":"Latency","points":[{"label":"1","value":12.5}]}]}
        """
        let temporary = dashboards.appendingPathComponent(".deploys.json.tmp")
        try Data(snapshot.utf8).write(to: temporary)
        try FileManager.default.moveItem(at: temporary, to: dashboards.appendingPathComponent("deploys.json"))

        XCTAssertEqual(FeatureCatalog.status(for: .monitor, snapshot: fixture.snapshot).word, "Not set up")
        fixture.monitor.reloadFiles()
        XCTAssertNil(fixture.monitor.dashboardError)
        XCTAssertEqual(FeatureCatalog.status(for: .monitor, snapshot: fixture.snapshot), .ready(note: nil))
        let rows = MonitorFeatureView.rows(dashboards: fixture.monitor.dashboards, serverStatusListed: false,
                                           serverError: nil, now: now)
        XCTAssertEqual(rows.map(\.title), ["Deploys"])
        XCTAssertEqual(rows.first?.state, "Up to date")
        XCTAssertEqual(MonitorFeatureView.rows(dashboards: fixture.monitor.dashboards, serverStatusListed: false,
                                               serverError: nil, now: now.addingTimeInterval(600)).first?.state,
                       "Not updated lately")
    }

    func testServerStatusIsListedOnlyOnceServersAreSetUpAndSettingsNeverPollsThem() async throws {
        let fixture = try await fixture()
        try FileManager.default.createDirectory(at: fixture.monitor.root, withIntermediateDirectories: true)
        fixture.monitor.reloadFiles()
        XCTAssertFalse(fixture.monitor.serverStatusListed)
        let servers = #"{"servers":[{"id":"web","name":"Web","group":"Prod","sshTarget":"web-alias"}]}"#
        try Data(servers.utf8).write(to: fixture.monitor.root.appendingPathComponent("servers.json"))
        fixture.monitor.reloadFiles()
        XCTAssertTrue(fixture.monitor.serverStatusListed)
        XCTAssertEqual(fixture.snapshot.monitorDashboards, 1)
        let rows = MonitorFeatureView.rows(dashboards: [], serverStatusListed: true, serverError: nil, now: Date())
        XCTAssertEqual(rows.map(\.title), ["Server status"])
        XCTAssertTrue(fixture.monitor.readings.allSatisfy { $0.metrics == nil }, "Reading files connects to nothing")
        try Data("invalid JSON".utf8).write(to: fixture.monitor.root.appendingPathComponent("servers.json"))
        fixture.monitor.reloadFiles()
        XCTAssertTrue(fixture.monitor.serverStatusListed, "Show the setup problem on the screen")
        XCTAssertNotNil(fixture.monitor.serverError)
        XCTAssertEqual(FeatureCatalog.status(for: .monitor, snapshot: fixture.snapshot).word, "Not set up")
    }

    // MARK: - Looks

    func testScreensRenderEmptyAndConnectedInBothAppearances() async throws {
        let fixture = try await fixture()
        // The agents' marks as the packaged app draws them.
        let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/UsefulLinkIcons")
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(icons)
        defer {
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
            ProviderBrandIconAsset.clearCacheForTesting()
        }
        let selection = SettingsWindowSelection()
        for feature in [AppFeature.notify, .monitor] {
            selection.open(feature)
            for dark in [false, true] {
                try FeaturesFixture.render(
                    fixture.shell(selection: selection), size: NSSize(width: 960, height: 720), dark: dark,
                    to: FeaturesFixture.renderDirectory?.appendingPathComponent(
                        "\(feature.rawValue)-empty-\(dark ? "dark" : "light").png"))
            }
        }
        let dashboards = fixture.monitor.root.appendingPathComponent("dashboards", isDirectory: true)
        try FileManager.default.createDirectory(at: dashboards, withIntermediateDirectories: true)
        let snapshot = #"{"id":"queue","title":"Build queue","subtitle":"Whytap builder","widgets":[{"id":"n","kind":"metric","title":"Waiting","value":"2"}]}"#
        try Data(snapshot.utf8).write(to: dashboards.appendingPathComponent("queue.json"))
        fixture.monitor.reloadFiles()
        try FeaturesFixture.render(
            MonitorFeatureView(selection: selection, environment: fixture.environment)
                .background(MacSettingsTheme.bgContent),
            size: NSSize(width: 760, height: 900), dark: false,
            to: FeaturesFixture.renderDirectory?.appendingPathComponent("monitor-connected-light.png"))
    }
}
