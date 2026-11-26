import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Builder ticket 651, point 3: the other way, as Lil Bro leads. For every
/// catalog row, one at a time, in a normal 960×560 window: the person is on
/// another screen, asks, and the answer names that row. After the real lead
/// the row is the focused one, on its own screen, visible in the pane and
/// outlined. Rows below the fold, under Advanced, in another part of Keys &
/// models, in a Toolbox tool's pane or behind Backup's Restore are each
/// checked on their own.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 15, builder ticket 651)
@MainActor
final class LilBroRowLeadTests: XCTestCase {
    private final class Brain: LilBroBrain {
        var reply: LilBroReply = .offline
        func reply(to question: LilBroQuestion) async -> LilBroReply { reply }
    }

    private func settle(_ host: NSView, rounds: Int = 3) {
        for _ in 0..<rounds {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        }
    }

    /// The Settings window, 960×560, off screen.
    private func window(_ fixture: FeaturesFixture, _ selection: SettingsWindowSelection,
                        _ lilBro: LilBroController, backup: BackupViewModel? = nil) -> (NSWindow, NSView) {
        let size = NSSize(width: 960, height: 560)
        let host = NSHostingView(rootView: fixture.shell(selection: selection, lilBro: lilBro, backup: backup)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host, rounds: 6)
        return (window, host)
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 where !condition() {
            await Task.yield()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    func test_he_leads_to_each_row_in_a_normal_window_and_outlines_it() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let root = fixture.files.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let (backup, backupDefaults, suite) = LilBroBackupFixture.model(root: root)
        defer { backupDefaults.removePersistentDomain(forName: suite) }
        await backup.stopAndWait()
        LilBroBackupFixture.backedUp(backup, backupDefaults)

        let selection = SettingsWindowSelection()
        let brain = Brain()
        let preferences = LilBroPreferences(defaults: fixture.defaults)
        preferences.mascotVisible = true
        let lilBro = LilBroController(selection: selection, preferences: preferences, remote: brain,
                                      reduceMotion: { true }, sleep: { _ in await Task.yield() })
        let (window, host) = window(fixture, selection, lilBro, backup: backup)
        defer { window.contentView = nil; window.close() }
        lilBro.toggleFromSidebar()
        settle(host)

        var failures: [String] = []
        for row in LilBroRow.catalog {
            if row.id == "apiAndModels.onThisMac", !OnDeviceSpeechModelStore.isSupportedHost { continue }
            // Somewhere else first, as a fresh question finds the window.
            let start: SettingsWindowTab = row.tab.resolved == .hotkeys ? .permissions : .hotkeys
            selection.select(start)
            settle(host)
            brain.reply = .answer(LilBroAnswer(paragraphs: ["That is \(row.title)."], destination: .row(row)))
            lilBro.ask("where is \(row.title)?")
            guard await wait({ lilBro.bubble == .full && !lilBro.isBusy }) else {
                failures.append("\(row.id): no answer"); continue
            }
            settle(host)
            // Case, Notify and Monitor are not opened for the person: All
            // tools is (builder ticket 658, `LilBroLeadRouteTests`).
            let said = row.tool?.paneActsOnOpen == true ? "All tools: click \(row.title) there to open it" : row.title
            let row = row.tool?.paneActsOnOpen == true ? try XCTUnwrap(LilBroRow.named("toolbox.allTools")) : row
            let place = "\(row.id) (\(row.screen) · \(row.title))"
            guard selection.focusedRow == row.id else {
                failures.append("\(place): not focused (on \(selection.lilBroScreen))"); continue
            }
            guard row.isShown(on: selection.lilBroScreen) else {
                failures.append("\(place): on \(selection.lilBroScreen)"); continue
            }
            guard let rect = lilBro.map.visible(.row(row.id)) else {
                failures.append("\(place): not visible in the pane"); continue
            }
            if lilBro.target != rect { failures.append("\(place): not outlined"); continue }
            if lilBro.turns.last?.opened != said { failures.append("\(place): not said opened") }
        }
        XCTAssertEqual(failures, [], "rows Lil Bro could not lead to and outline in a 960×560 window")
    }

    /// Builder ticket 651: the person picks another part of the screen while
    /// he runs to a row there (another Keys & models section, another
    /// Toolbox tool): he presses nothing, their choice stays and nothing is
    /// outlined or said opened.
    func test_the_persons_own_section_or_tool_choice_during_his_run_stays() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let cases: [(row: String, start: (SettingsWindowSelection) -> Void, theirs: (SettingsWindowSelection) -> Void,
                     check: (SettingsWindowSelection) -> Bool)] = [
            ("apiAndModels.apiKeys", { $0.select(.apiAndModels) }, { $0.apiSection = .costs },
             { $0.selectedTab == .apiAndModels && $0.apiSection == .costs }),
            ("toolbox.filler", { $0.focus(.vocab) }, { $0.toolboxTool = .clipboard },
             { $0.selectedTab == .toolbox && $0.toolboxTool == .clipboard }),
        ]
        for item in cases {
            let row = try XCTUnwrap(LilBroRow.named(item.row))
            let selection = SettingsWindowSelection()
            item.start(selection)
            var clicked = false
            let preferences = LilBroPreferences(defaults: fixture.defaults)
            preferences.mascotVisible = true
            let brain = Brain()
            brain.reply = .answer(LilBroAnswer(paragraphs: ["Here."], destination: .row(row)))
            let lilBro = LilBroController(selection: selection, preferences: preferences, remote: brain,
                                          reduceMotion: { false }, sleep: { _ in
                                              // Their click lands while he is on his way.
                                              if !clicked, selection.focusedRow == nil { clicked = true; item.theirs(selection) }
                                              await Task.yield()
                                          })
            let (window, host) = window(fixture, selection, lilBro)
            defer { window.contentView = nil; window.close() }
            lilBro.toggleFromSidebar()
            settle(host)
            clicked = false
            lilBro.ask("where is \(row.title)?")
            let answered = await wait { lilBro.bubble == .full && !lilBro.isBusy }
            XCTAssertTrue(answered, item.row)
            settle(host)
            XCTAssertTrue(clicked, "they clicked during his run: \(item.row)")
            XCTAssertTrue(item.check(selection), "their choice stays: \(item.row) → \(selection.lilBroScreen)")
            XCTAssertNil(selection.focusedRow, item.row)
            XCTAssertNil(lilBro.target, item.row)
            XCTAssertNil(lilBro.turns.last?.opened, item.row)
        }
    }
}

/// Builder ticket 658: the rows a person presses on the way, a manual
/// change that comes back to where it was, and the Toolbox panes that act
/// as they open.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (builder ticket 658)
@MainActor
final class LilBroLeadRouteTests: XCTestCase {
    private final class Brain: LilBroBrain {
        var reply: LilBroReply = .offline
        func reply(to question: LilBroQuestion) async -> LilBroReply { reply }
    }

    private func controller(_ selection: SettingsWindowSelection, _ defaults: UserDefaults,
                            brain: LilBroBrain? = nil, reduceMotion: Bool = true,
                            sleep: @escaping (Double) async -> Void = { _ in await Task.yield() }) -> LilBroController {
        let preferences = LilBroPreferences(defaults: defaults)
        preferences.mascotVisible = true
        return LilBroController(selection: selection, preferences: preferences, remote: brain ?? Brain(),
                                reduceMotion: { reduceMotion }, sleep: sleep)
    }

    /// From another tab he presses the sidebar row, then the section's tab
    /// or the tool's tile; from inside the tab only the second.
    func test_from_another_tab_he_presses_the_sidebar_row_then_the_part() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LilBroRoute-\(UUID().uuidString)"))
        let cases: [(id: String, home: SettingsWindowTab)] = [
            ("apiAndModels.apiKeys", .apiAndModels), ("apiAndModels.onThisMac", .apiAndModels),
            ("apiAndModels.costs", .apiAndModels), ("apiAndModels.apiHints", .apiAndModels),
            ("toolbox.filler", .features), ("toolbox.brightness", .features),
        ]
        for item in cases {
            let row = try XCTUnwrap(LilBroRow.named(item.id))
            for start in [SettingsWindowTab.hotkeys, row.tab.resolved] {
                let selection = SettingsWindowSelection(selectedTab: start)
                let guide = controller(selection, defaults)
                let expected: [LilBroSpot] = start == .hotkeys ? [.tab(item.home), .part(row.screen)] : [.part(row.screen)]
                let stops = guide.stops(for: .row(row))
                XCTAssertEqual(stops.map(\.spot), expected, "\(start) → \(item.id)")
                stops.forEach { $0.press() }
                XCTAssertTrue(row.isShown(on: selection.lilBroScreen), "\(start) → \(item.id): \(selection.lilBroScreen)")
            }
        }
        // Models is where Keys & models opens: the sidebar row is enough.
        let models = try XCTUnwrap(LilBroRow.named("apiAndModels.dropFast"))
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        XCTAssertEqual(controller(selection, defaults).stops(for: .row(models)).map(\.spot), [.tab(.apiAndModels)])
        // Backup opens from General.
        let backup = try XCTUnwrap(LilBroRow.catalog.first { $0.tab == .backup })
        XCTAssertEqual(controller(selection, defaults).stops(for: .row(backup)).map(\.spot), [.tab(.other)])
    }

    /// The person goes elsewhere and back, more than once, while he runs and
    /// punches: their last choice stays, nothing is focused, outlined or
    /// said opened.
    func test_a_change_away_and_back_during_his_run_or_punch_ends_the_lead() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LilBroRoute-\(UUID().uuidString)"))
        let cases: [(id: String, start: (SettingsWindowSelection) -> Void, away: (SettingsWindowSelection) -> Void,
                     back: (SettingsWindowSelection) -> Void, ends: String)] = [
            ("apiAndModels.apiKeys", { $0.select(.apiAndModels) }, { $0.apiSection = .costs },
             { $0.apiSection = .models }, "apiAndModels/models"),
            ("toolbox.filler", { $0.focus(.vocab) }, { $0.toolboxTool = .clipboard },
             { $0.toolboxTool = .vocab }, "toolbox/vocab"),
            ("apiAndModels.costs", { $0.select(.hotkeys) }, { $0.select(.permissions) },
             { $0.select(.hotkeys) }, "hotkeys"),
        ]
        // The person's clicks land on the first wait, during the run, or on
        // a later one, during the punch.
        for item in cases {
            for at in [1, 3, 5] {
                let row = try XCTUnwrap(LilBroRow.named(item.id))
                let selection = SettingsWindowSelection()
                item.start(selection)
                var waits = 0
                let brain = Brain()
                brain.reply = .answer(LilBroAnswer(paragraphs: ["Here."], destination: .row(row)))
                let guide = controller(selection, defaults, brain: brain, reduceMotion: false) { _ in
                    waits += 1
                    if waits == at {
                        item.away(selection); item.back(selection)
                        item.away(selection); item.back(selection)
                    }
                    await Task.yield()
                }
                let box = CGRect(x: 260, y: 150, width: 180, height: 40)
                guide.update(bounds: CGRect(x: 0, y: 0, width: 960, height: 560))
                guide.update(spots: [.home: CGRect(x: 18, y: 470, width: 160, height: 45),
                                     .pane: CGRect(x: 210, y: 30, width: 750, height: 500),
                                     .tab(.apiAndModels): CGRect(x: 18, y: 120, width: 160, height: 30),
                                     .part(row.screen): CGRect(x: 245, y: 60, width: 135, height: 35),
                                     .row(item.id): box])
                guide.update(blocks: [box])
                guide.ask("Where is this setting?")
                for _ in 0..<4000 where guide.isBusy { await Task.yield() }
                let label = "\(item.id), clicks on wait \(at)"
                XCTAssertGreaterThanOrEqual(waits, at, label)
                XCTAssertFalse(guide.isBusy, label)
                XCTAssertEqual(selection.lilBroScreen, item.ends, label)
                XCTAssertNil(selection.focusedRow, label)
                XCTAssertNil(guide.target, label)
                XCTAssertNil(guide.turns.last?.opened, label)
            }
        }
    }

    /// Asked where Case, Notify or Monitor is, he outlines All tools and
    /// opens none of them: no Touch ID request, no notice marked read, no
    /// server polled until the person clicks the tool themselves.
    func test_case_notify_and_monitor_open_only_when_the_person_clicks_them() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let event = LocalNotificationEvent(id: "lilbro-658", source: "test", sourceName: "Test",
                                           title: "Unread", body: "", link: nil, timestamp: Date())
        _ = await fixture.notifyHub.receive(event)
        XCTAssertEqual(fixture.notifyHub.unreadCount, 1)
        let monitorRoot = fixture.files.appendingPathComponent("Monitor", isDirectory: true)
        try FileManager.default.createDirectory(at: monitorRoot, withIntermediateDirectories: true)
        try Data(#"{"servers":[{"id":"t","name":"T","group":"T","sshTarget":"not-a-real-connection"}]}"#.utf8)
            .write(to: monitorRoot.appendingPathComponent("servers.json"))

        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        let brain = Brain()
        let guide = controller(selection, fixture.defaults, brain: brain)
        let size = NSSize(width: 960, height: 560)
        let host = NSHostingView(rootView: fixture.shell(selection: selection, lilBro: guide)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle(_ seconds: TimeInterval = 0.2) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        guide.toggleFromSidebar()
        settle()

        for tool in [HoverTool.caseVault, .notifs, .monitor] {
            let row = try XCTUnwrap(LilBroRow.catalog.first { $0.tool == tool && $0.id == "toolbox.\(tool.rawValue)" })
            selection.select(.hotkeys)
            settle()
            brain.reply = .answer(LilBroAnswer(paragraphs: ["It is \(row.title)."], destination: .row(row)))
            guide.ask("where is \(row.title)?")
            for _ in 0..<600 where guide.isBusy || guide.bubble != .full {
                await Task.yield()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            settle(0.5)
            XCTAssertEqual(selection.lilBroScreen, "toolbox", "\(tool): Toolbox, no pane opened")
            XCTAssertEqual(selection.focusedRow, "toolbox.allTools", "\(tool)")
            XCTAssertNotNil(guide.target, "\(tool): All tools outlined")
            XCTAssertEqual(guide.turns.last?.opened, "All tools: click \(row.title) there to open it")
        }
        try await Task.sleep(for: .milliseconds(300))
        settle()
        XCTAssertEqual(fixture.caseAuthenticator.calls, 0, "no Touch ID request")
        let notices = LocalNotificationHub(directory: fixture.files.appendingPathComponent("notifications"))
        await notices.load()
        XCTAssertEqual(notices.unreadCount, 1, "no notice marked read")
        XCTAssertEqual(fixture.monitorCalls.count, 0, "no server polled")

        // The person clicks Case: now, and only now, it asks.
        selection.focus(.caseVault)
        settle(0.6)
        try await Task.sleep(for: .milliseconds(300))
        settle()
        XCTAssertEqual(fixture.caseAuthenticator.calls, 1, "Case asks once the person opens it")
        selection.focus(.notifs)
        settle(0.6)
        let read = LocalNotificationHub(directory: fixture.files.appendingPathComponent("notifications"))
        await read.load()
        XCTAssertEqual(read.unreadCount, 0, "Notify marks notices read once the person opens it")
        selection.focus(.monitor)
        for _ in 0..<40 where fixture.monitorCalls.count == 0 {
            try await Task.sleep(for: .milliseconds(50))
            settle(0.01)
        }
        XCTAssertGreaterThan(fixture.monitorCalls.count, 0, "Monitor polls once the person opens it")
    }
}
