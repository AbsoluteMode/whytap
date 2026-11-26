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
        preferences.answersFromWhytap = false
        return LilBroController(selection: selection, preferences: preferences,
                                remote: remote ?? Offline(), reduceMotion: { true },
                                sleep: { _ in await Task.yield() })
    }

    private struct Offline: LilBroBrain {
        func reply(to question: LilBroQuestion) async -> LilBroReply { .offline }
    }

    private func render(_ fixture: FeaturesFixture, _ selection: SettingsWindowSelection,
                        _ lilBro: LilBroController, name: String, dark: Bool = false,
                        size: NSSize = NSSize(width: 960, height: 560),
                        before: (() async -> Void)? = nil) async throws {
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
        // Details on request: the place he opened and what to ask next.
        try await render(fixture, selection, lilBro, name: "answer-more-light") {
            lilBro.showMore = true
        }
        XCTAssertEqual(lilBro.bubble, .full)
    }

    /// Answers already on: the greeting has ⋯, so they can be turned off
    /// before a question is sent.
    func test_with_answers_on_the_greeting_offers_turning_them_off() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        lilBro.turnOnAnswers()
        try await render(fixture, selection, lilBro, name: "greeting-answers-on-light") {
            lilBro.toggleFromSidebar()
        }
        XCTAssertFalse(lilBro.showsBalloon)
        XCTAssertTrue(lilBro.answersFromWhytap)
        lilBro.turnOffAnswers()
        XCTAssertFalse(lilBro.answersFromWhytap)
    }

    /// A question this Mac did not understand: only the card that sends it
    /// to whytap.ai, no "I only know Settings by name", no suggestions.
    func test_not_understood_he_shows_only_turn_on_and_ask() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        try await render(fixture, selection, lilBro, name: "unknown-light") {
            lilBro.toggleFromSidebar()
            lilBro.ask("как изменить хоткей рекорда")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertEqual(lilBro.turns.last?.reply?.isUnknown, true)
        XCTAssertTrue(lilBro.turnOnAsks)
        XCTAssertNil(selection.shownFeature, "nothing opened")
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

    func test_answers_on_but_offline_he_offers_try_again_and_the_closest_page() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        try await render(fixture, selection, lilBro, name: "offer-light") {
            lilBro.toggleFromSidebar()
            // The greeting's small link: the whole disclosure, on request.
            lilBro.askToTurnOnAnswers()
        }
        XCTAssertTrue(lilBro.consentShown)
        XCTAssertFalse(lilBro.answersFromWhytap, "the link only shows the disclosure")
        lilBro.turnOnAnswers()
        try await render(fixture, selection, lilBro, name: "offline-light") {
            lilBro.ask("how do I dictate")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertEqual(lilBro.turns.last?.reply, .offline)
        XCTAssertNil(selection.shownFeature, "offline changes nothing")
    }

    func test_on_drop_the_real_needs_row_reports_its_step_and_he_asks_before_pressing() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection)
        try await render(fixture, selection, lilBro, name: "press-light") {
            lilBro.toggleFromSidebar()
            lilBro.ask("Set up dictation")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertEqual(selection.shownFeature, .drop)
        let step = try XCTUnwrap(lilBro.proposal, "a fresh Mac has a required Drop step")
        XCTAssertFalse(step.optional)
        XCTAssertNotNil(lilBro.map.spots[.need(step.id)], "the row he would press reports itself")
        XCTAssertNil(lilBro.turns.last?.pressed, "nothing pressed without a yes")
    }
}
