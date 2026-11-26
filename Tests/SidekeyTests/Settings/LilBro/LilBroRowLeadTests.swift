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
            if lilBro.turns.last?.opened != row.title { failures.append("\(place): not said opened") }
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
