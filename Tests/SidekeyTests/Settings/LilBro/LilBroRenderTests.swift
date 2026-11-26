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
                            mascot: Bool = true, remote: LilBroBrain? = nil, answers: Bool = true) -> LilBroController {
        let preferences = LilBroPreferences(defaults: fixture.defaults)
        preferences.mascotVisible = mascot
        preferences.answersFromWhytap = answers
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
        // Details on request: the points and the place he opened.
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

    /// Answers turned off: a question gets only the card that turns them on
    /// and sends it; no scripted answer, no suggestions.
    func test_answers_off_he_shows_only_turn_on_and_ask() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection, answers: false)
        try await render(fixture, selection, lilBro, name: "answers-off-light") {
            lilBro.toggleFromSidebar()
            lilBro.ask("как изменить хоткей рекорда")
            await self.until { lilBro.bubble == .full && !lilBro.isBusy }
        }
        XCTAssertEqual(lilBro.turns.last?.reply, .answersOff)
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

    func test_offline_he_says_answers_are_unavailable_and_offers_try_again() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = controller(fixture, selection, remote: Offline(), answers: false)
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
}
