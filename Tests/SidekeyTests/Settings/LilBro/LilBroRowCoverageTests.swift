import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// REV 14–15: Lil Bro's map has every row of every Settings screen. Each tab,
/// each part of Keys & models, each Toolbox tool's pane and each feature's
/// own screen is drawn in the real Settings window, in a fresh and a usual
/// Mac, with Advanced open, with each kind of key form open and with
/// Backup's state-dependent cards on screen. Every row it draws (`MacRow`,
/// `HotkeySettingRow`, `ConcreteSettingPicker`, the cards tagged
/// `lilBroCatalogRow`) must be in `LilBroRow.catalog`, unless it is one of a
/// list of data rows (`lilBroItems`), and every control that reports itself
/// must sit in such a row. Native controls that cannot report are held to
/// the same rule by `LilBroNativeControlSourceTests`. A new setting without
/// its catalog line fails here.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 14, REV 15, builder ticket 651)
@MainActor
final class LilBroRowCoverageTests: XCTestCase {
    private final class Seen {
        var rows: Set<LilBroSeenRow> = []
        var controls: Set<LilBroSeenControl> = []
        /// Screens that drew at least one row of the catalog.
        var screensWithRows: Set<String> = []
    }

    private struct Screen {
        let name: String
        let open: (SettingsWindowSelection) -> Void
    }

    /// The screens of the Settings window, as `SettingsWindowSelection`
    /// opens them and `lilBroScreen` names them.
    private static var screens: [Screen] {
        let tabs = SettingsWindowTab.availableCases.filter {
            $0.featureScreen == nil && ![.notes, .apiAndModels, .toolbox].contains($0)
        }
        let features = AppFeature.allCases.filter {
            $0 == .drop || FeatureCatalog.info(for: $0).place == .screen
        }
        let advanced = LilBroRow.named("apiAndModels.dropFast")!
        return tabs.map { tab in Screen(name: tab.rawValue) { $0.select(tab) } }
            + APIAndModelsSection.allCases.map { section in
                Screen(name: "apiAndModels/\(section.lilBroKey)") { $0.select(.apiAndModels); $0.apiSection = section }
            }
            // Advanced open: the per-feature rows.
            + [Screen(name: "apiAndModels/models") { $0.focus(advanced) }]
            + [Screen(name: "toolbox") { $0.select(.toolbox) }]
            + HoverTool.allCases.map { tool in Screen(name: "toolbox/\(tool.rawValue)") { $0.focus(tool) } }
            + features.map { feature in Screen(name: "features/\(feature.rawValue)") { $0.open(feature) } }
    }

    /// Draws `view` tall enough that nothing is cut off and collects what
    /// its rows and controls report.
    private func collect<V: View>(_ view: V, into seen: Seen, size: NSSize = NSSize(width: 960, height: 2400)) {
        let root = view
            .environment(\.colorScheme, .light)
            .onPreferenceChange(LilBroSeenRowsKey.self) { rows in
                seen.rows.formUnion(rows)
                for row in rows where row.id != nil { seen.screensWithRows.insert(row.screen) }
            }
            .onPreferenceChange(LilBroSeenControlsKey.self) { seen.controls.formUnion($0) }
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

    private func draw(_ state: FeaturesFixture.State, into seen: Seen) async throws {
        let fixture = try await FeaturesFixture(state)
        defer { fixture.cleanUp() }
        for screen in Self.screens {
            let selection = SettingsWindowSelection()
            screen.open(selection)
            XCTAssertEqual(selection.lilBroScreen, screen.name, "opened as named")
            collect(fixture.shell(selection: selection), into: seen)
        }
        // Each kind of key form open under API keys.
        let targets: [ProviderKeyTiles.Target] = [.provider(.openAI), .provider(.anthropic), .provider(.soniox), .tavily]
        for target in targets {
            collect(APIAndModelsView(viewModel: fixture.models, focusedFeature: .constant(nil), initialSection: .keys,
                                     initiallyExpandedKey: target)
                .environment(\.lilBroScreen, "apiAndModels/keys"), into: seen)
        }
        // Backup as a Mac that backed up, with the restore card and the
        // recovery code open; then with every result and follow-up at once.
        let root = fixture.files.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let (restoring, restoringDefaults, suiteA) = LilBroBackupFixture.model(root: root.appendingPathComponent("a"))
        let (finished, finishedDefaults, suiteB) = LilBroBackupFixture.model(root: root.appendingPathComponent("b"))
        defer {
            restoringDefaults.removePersistentDomain(forName: suiteA)
            finishedDefaults.removePersistentDomain(forName: suiteB)
        }
        await restoring.stopAndWait()
        await finished.stopAndWait()
        LilBroBackupFixture.backedUp(restoring, restoringDefaults)
        restoring.recoveryCode = "TEST-CODE-ONLY"
        LilBroBackupFixture.everything(finished, finishedDefaults)
        let restore = try XCTUnwrap(LilBroRow.named("backup.restoreFromCode"))
        for (model, focus) in [(restoring, true), (finished, false)] {
            let selection = SettingsWindowSelection()
            if focus { selection.focus(restore) } else { selection.select(.backup) }
            collect(fixture.shell(selection: selection, backup: model), into: seen)
        }
    }

    func test_every_settings_row_and_control_is_on_lil_bros_map() async throws {
        let seen = Seen()
        for state in [FeaturesFixture.State.freshInstall, .usual] {
            try await draw(state, into: seen)
        }
        XCTAssertFalse(seen.rows.isEmpty, "the screens draw their rows")

        let missing = seen.rows.filter { $0.id == nil && !$0.item }
            .map { "\($0.screen) · \($0.title)" }.sorted()
        XCTAssertEqual(missing, [], "rows not in LilBroRow.catalog (add a row(...) line, or lilBroItems() for data rows)")

        let loose = seen.controls.filter { !$0.inRow }.map { "\($0.screen) · \($0.label)" }.sorted()
        XCTAssertEqual(loose, [], "controls outside a row Lil Bro can lead to")

        // Features home is the list of features: each opens its own screen,
        // where Lil Bro leads with the feature (not a row).
        let empty = Set(Self.screens.map(\.name)).subtracting(seen.screensWithRows)
            .subtracting([SettingsWindowTab.features.rawValue]).sorted()
        XCTAssertEqual(empty, [], "every screen has a row Lil Bro can lead to")

        let drawn = Set(seen.rows.compactMap(\.id))
        let notDrawn = LilBroRow.catalog.map(\.id).filter { !drawn.contains($0) }
            .filter { $0 != "apiAndModels.onThisMac" || OnDeviceSpeechModelStore.isSupportedHost }
        XCTAssertEqual(notDrawn, [], "catalog rows no screen draws")
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
