import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// REV 14: Lil Bro's map has every row of every Settings screen. Each tab and
/// each feature's own screen is drawn in the real Settings window; every row
/// it draws (`MacRow`, `HotkeySettingRow`, `ConcreteSettingPicker`) must be in
/// `LilBroRow.catalog`, unless it is one of a list of data rows
/// (`lilBroItems`), and every switch, pop-up or segmented control must sit in
/// such a row. A new setting without its catalog line fails here.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 14)
@MainActor
final class LilBroRowCoverageTests: XCTestCase {
    private final class Seen {
        var rows: Set<LilBroSeenRow> = []
        var controls: Set<LilBroSeenControl> = []
    }

    /// The screens of the Settings window, as `SettingsWindowSelection`
    /// opens them: every tab, every feature's own screen and every Toolbox
    /// tool's pane.
    private static var screens: [(name: String, open: (SettingsWindowSelection) -> Void)] {
        let tabs = SettingsWindowTab.availableCases.filter { $0.featureScreen == nil && $0 != .notes }
        let features = AppFeature.allCases.filter {
            $0 == .drop || FeatureCatalog.info(for: $0).place == .screen
        }
        return tabs.map { tab in (tab.rawValue, { $0.select(tab) }) }
            + features.map { feature in ("features/\(feature.rawValue)", { $0.open(feature) }) }
            + HoverTool.allCases.map { tool in (SettingsWindowTab.toolbox.rawValue, { $0.focus(tool) }) }
    }

    /// Rows only a state the fixture cannot make shows: Backup's switches
    /// appear once a backup exists or sync was turned on.
    private static let drawnOnlyLater: Set<String> = ["backup.automaticBackup", "backup.syncSettings"]

    private func draw(_ state: FeaturesFixture.State,
                      screens given: [(name: String, open: (SettingsWindowSelection) -> Void)]? = nil,
                      focused: ((SettingsWindowSelection) -> String?)? = nil) async throws -> Seen {
        let fixture = try await FeaturesFixture(state)
        defer { fixture.cleanUp() }
        let seen = Seen()
        for screen in given ?? Self.screens {
            let selection = SettingsWindowSelection()
            screen.open(selection)
            if focused == nil { XCTAssertEqual(selection.lilBroScreen, screen.name, "opened as named") }
            let root = fixture.shell(selection: selection)
                .environment(\.colorScheme, .light)
                .onPreferenceChange(LilBroSeenRowsKey.self) { seen.rows.formUnion($0) }
                .onPreferenceChange(LilBroSeenControlsKey.self) { seen.controls.formUnion($0) }
            // Tall, so nothing is cut off; rows below the fold still report.
            let size = NSSize(width: 960, height: 2400)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            window.contentView = nil
            window.close()
        }
        return seen
    }

    func test_every_settings_row_and_control_is_on_lil_bros_map() async throws {
        var rows: Set<LilBroSeenRow> = []
        var controls: Set<LilBroSeenControl> = []
        for state in [FeaturesFixture.State.freshInstall, .usual] {
            let seen = try await draw(state)
            rows.formUnion(seen.rows)
            controls.formUnion(seen.controls)
        }
        XCTAssertFalse(rows.isEmpty, "the screens draw their rows")

        let missing = rows.filter { $0.id == nil && !$0.item }
            .map { "\($0.screen) · \($0.title)" }.sorted()
        XCTAssertEqual(missing, [], "rows not in LilBroRow.catalog (add a row(...) line, or lilBroItems() for data rows)")

        let loose = controls.filter { !$0.inRow }.map { "\($0.screen) · \($0.label)" }.sorted()
        XCTAssertEqual(loose, [], "controls outside a row Lil Bro can lead to")

    }

    /// The other way, as Lil Bro leads: every listed row, focused the way he
    /// focuses it, is drawn on its screen under its id.
    func test_every_catalog_row_is_drawn_when_he_leads_to_it() async throws {
        let rows = LilBroRow.catalog.filter { !Self.drawnOnlyLater.contains($0.id) }
        let screens = rows.map { row in (name: row.screen, open: { (selection: SettingsWindowSelection) in
            selection.focus(row)
        }) }
        let seen = try await draw(.usual, screens: screens, focused: { $0.focusedRow })
        let drawn = Set(seen.rows.compactMap(\.id))
        let unseen = rows.filter { !drawn.contains($0.id) }.map { "\($0.id) (\($0.screen) · \($0.title))" }
        XCTAssertEqual(unseen, [], "catalog rows not drawn when focused")
    }

    func test_catalog_ids_and_places_are_unique() {
        let ids = LilBroRow.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
        let places = LilBroRow.catalog.map { "\($0.screen)|\($0.title)" }
        XCTAssertEqual(Set(places).count, places.count, "one entry per row on a screen")
        for row in LilBroRow.catalog {
            XCTAssertTrue(row.id.hasPrefix((row.feature?.rawValue ?? row.tab.rawValue) + "."), row.id)
            XCTAssertFalse(row.about.isEmpty, row.id)
            XCTAssertEqual(LilBroRow.at(screen: row.screen, title: row.title), row)
        }
    }
}
