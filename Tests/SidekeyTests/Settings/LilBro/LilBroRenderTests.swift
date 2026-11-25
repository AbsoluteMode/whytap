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
                            mascot: Bool = true) -> LilBroController {
        let preferences = LilBroPreferences(defaults: fixture.defaults)
        preferences.mascotVisible = mascot
        return LilBroController(selection: selection, preferences: preferences, reduceMotion: { true },
                                sleep: { _ in await Task.yield() })
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
}
