import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Lil Bro in the real Settings window, drawn offscreen: he finds his entry
/// and the cards from what the views report, and his balloon stays inside
/// the window. Review images go to WHYTAP_SETTINGS_FEATURES_RENDER_DIR.
@MainActor
final class LilBroRenderTests: XCTestCase {
    private func controller(_ fixture: FeaturesFixture, _ selection: SettingsWindowSelection,
                            mascot: Bool = true, remote: LilBroBrain? = nil) -> LilBroController {
        let preferences = LilBroPreferences(defaults: fixture.defaults)
        preferences.mascotVisible = mascot
        return LilBroController(selection: selection, preferences: preferences,
                                remote: remote ?? LilBroFixedBrain(), reduceMotion: { true },
                                sleep: { _ in await Task.yield() })
    }

    private struct Offline: LilBroBrain {
        func reply(to question: LilBroQuestion) async -> LilBroReply { .offline }
    }

    private func render(_ fixture: FeaturesFixture, _ selection: SettingsWindowSelection,
                        _ lilBro: LilBroController, name: String, dark: Bool = false,
                        size: NSSize = NSSize(width: 960, height: 560),
                        before: (() async -> Void)? = nil,
                        after: ((NSView) async throws -> Void)? = nil) async throws {
        let host = NSHostingView(rootView: fixture.shell(selection: selection, lilBro: lilBro)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        if let before { await before() }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertFalse(window.isVisible)
        if let after { try await after(host) }
        if let directory = FeaturesFixture.renderDirectory {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("lilbro-\(name).png"))
        }
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            await Task.yield()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(condition())
    }

    func test_he_stands_on_his_entry_and_the_window_is_his_map() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        try await render(fixture, selection, lilBro, name: "home-light")
        let home = try XCTUnwrap(lilBro.map.home, "the sidebar entry reports itself")
        XCTAssertEqual(lilBro.map.bounds.origin, .zero, "the layer and the rows share coordinates")
        XCTAssertTrue(lilBro.placed)
        XCTAssertEqual(lilBro.feet.y, home.minY + 1)
        XCTAssertNotNil(lilBro.map.visible(.tab(.features)))
        XCTAssertNotNil(lilBro.map.visible(.feature(.drop)))
        XCTAssertFalse(lilBro.map.platforms.isEmpty, "the Features card is a block")
    }

    func test_caught_he_greets_with_questions() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        try await render(fixture, selection, lilBro, name: "greeting-light") {
            lilBro.catchHim()
            await self.until { lilBro.bubble == .full }
        }
        try await render(fixture, selection, lilBro, name: "greeting-dark", dark: true)
    }

    func test_asked_he_opens_drop_and_says_so() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        try await render(fixture, selection, lilBro, name: "answer-light") {
            lilBro.catchHim()
            await self.until { lilBro.bubble == .full }
            lilBro.ask("how do I dictate")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertEqual(selection.shownFeature, .drop)
        XCTAssertEqual(lilBro.turns.last?.opened, "Drop")
        // Details on request: the points and the place he opened.
        try await render(fixture, selection, lilBro, name: "answer-more-light") {
            lilBro.showMore = true
        }
        XCTAssertEqual(lilBro.bubble, .full)
    }

    /// REV 13: answers always come from whytap.ai. The greeting's ⋯ only
    /// hides the little guy or closes; there is no switch and no card that
    /// turns answers on.
    func test_the_greeting_has_no_answers_switch() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        try await render(fixture, selection, lilBro, name: "greeting-options-light") {
            lilBro.toggleFromSidebar()
        }
        XCTAssertFalse(lilBro.showsBalloon, "before a question only the greeting and the field")
    }

    func test_hidden_he_answers_from_the_sidebar_entry() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection, mascot: false)
        try await render(fixture, selection, lilBro, name: "hidden-dark", dark: true) {
            lilBro.toggleFromSidebar()
        }
        XCTAssertEqual(lilBro.bubble, .full)
    }

    func test_offline_he_says_answers_are_unavailable_and_offers_try_again() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection, remote: Offline())
        try await render(fixture, selection, lilBro, name: "offline-light") {
            lilBro.toggleFromSidebar()
            lilBro.ask("how do I dictate")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertEqual(lilBro.turns.last?.reply, .offline)
        XCTAssertNil(selection.shownFeature, "offline changes nothing")
    }

    /// REV 10: a question answered in words stays in the balloon; nothing
    /// opens and there is no step to press.
    func test_a_question_answered_in_words_stays_in_the_balloon() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let words = LilBroFixedBrain(reply: .answer(LilBroAnswer(
            paragraphs: ["Yes. With the free model on this Mac, Drop works without the internet."])))
        let lilBro = controller(fixture, selection, remote: words)
        try await render(fixture, selection, lilBro, name: "words-light") {
            lilBro.toggleFromSidebar()
            lilBro.ask("does dictation work offline")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertNil(selection.shownFeature, "nothing opened")
        XCTAssertNil(lilBro.turns.last?.opened)
    }

    /// REV 12, the maintainer's own question: asked in Russian how to set a
    /// hotkey that starts a meeting, he opens Hotkeys, scrolls to Meeting
    /// record and outlines that row, not only the tab.
    func test_asked_for_the_meeting_hotkey_he_leads_to_the_meeting_record_row() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let record = try XCTUnwrap(LilBroRow.named("hotkeys.meetingRecord"))
        let model = LilBroFixedBrain(reply: .answer(LilBroAnswer(
            paragraphs: ["Запись встречи по хоткею — строка Meeting record во вкладке Hotkeys: нажмите на неё и запишите сочетание."],
            destination: .row(record))))
        for (name, mascot) in [("row-light", true), ("row-hidden-light", false)] {
            selection.select(.features)
            let lilBro = controller(fixture, selection, mascot: mascot, remote: model)
            try await render(fixture, selection, lilBro, name: name) {
                lilBro.toggleFromSidebar()
                lilBro.ask("Как мне поставить хоткей, чтобы meeting запускался по хоткею?")
                await self.until { lilBro.bubble == .full && !lilBro.isBusy }
            }
            XCTAssertEqual(selection.selectedTab, .hotkeys, name)
            XCTAssertEqual(selection.focusedRow, record.id, name)
            let row = try XCTUnwrap(lilBro.map.visible(.row(record.id)), "the row is scrolled into view: \(name)")
            XCTAssertEqual(lilBro.target, row, "the row itself is outlined: \(name)")
            XCTAssertEqual(lilBro.turns.last?.opened, "Meeting record")
            if mascot { XCTAssertEqual(lilBro.feet.y, row.minY + 1, accuracy: 2, "he stands on that row") }
            lilBro.close()
            XCTAssertNil(selection.focusedRow, "closing clears the lead")
        }
    }

    /// A row far down the tab is scrolled to.
    func test_a_row_below_the_fold_is_scrolled_into_view() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let close = try XCTUnwrap(LilBroRow.named("hotkeys.agentClose"))
        let lilBro = controller(fixture, selection, remote: LilBroFixedBrain(reply: .answer(LilBroAnswer(
            paragraphs: ["Agent close is the row for that."], destination: .row(close)))))
        try await render(fixture, selection, lilBro, name: "row-scrolled-light", size: NSSize(width: 960, height: 520)) {
            lilBro.toggleFromSidebar()
            lilBro.ask("how do I change the shortcut that closes the agent")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertNotNil(lilBro.map.visible(.row(close.id)))
        XCTAssertEqual(lilBro.target, lilBro.map.visible(.row(close.id)))
    }

    /// Builder review of #493 (ticket 627), in the real window without the
    /// little guy: the outline is the row's own place, and choosing another
    /// tab ends it. (Scrolling away and back is covered in
    /// LilBroControllerTests through the same map updates.)
    func test_without_him_the_row_outline_is_the_row_and_ends_with_the_tab() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let record = try XCTUnwrap(LilBroRow.named("hotkeys.meetingRecord"))
        let lilBro = controller(fixture, selection, mascot: false, remote: LilBroFixedBrain(reply: .answer(LilBroAnswer(
            paragraphs: ["Meeting record."], destination: .row(record)))))
        try await render(fixture, selection, lilBro, name: "row-follow-light", before: {
            lilBro.toggleFromSidebar()
            lilBro.ask("how do I set a hotkey to start a meeting")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }, after: { host in
            XCTAssertEqual(lilBro.target, lilBro.map.visible(.row(record.id)))
            selection.select(.other)
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            XCTAssertNil(lilBro.target, "another tab ends it")
            XCTAssertNil(selection.focusedRow)
            XCTAssertNil(lilBro.leadRow)
        })
    }
}
