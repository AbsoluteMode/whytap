import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Task 116: every feature a person would name is in Features, and each
/// screen holds that feature's settings. Display, History and Calendar were
/// island tiles only; Smart's output language lived only in the island, the
/// Agent's link keys only in Hotkeys, the calendars in General → Integrations.
// WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
@MainActor
final class EveryFeatureInFeaturesTests: XCTestCase {
    override func tearDown() async throws {
        CalendarAvailability.testOverride = nil
    }

    // MARK: The list

    func testDisplayHistoryAndCalendarAreFeaturesWithTheirOwnScreens() {
        for (feature, tool, name) in [(AppFeature.display, HoverTool.brightness, "Display"),
                                      (.history, .clipboard, "History"), (.calendar, .calendar, "Calendar")] {
            let info = FeatureCatalog.info(for: feature)
            XCTAssertEqual(info.name, name)
            XCTAssertEqual(info.place, .screen, "\(feature) has its own screen")
            XCTAssertEqual(info.activation, .islandTools([tool]))
            XCTAssertEqual(info.hotkeys, [.tool(tool)])
            XCTAssertEqual(feature.islandTool, tool, "the list shows the island tile's icon")
            XCTAssertFalse(info.about.isEmpty)
            XCTAssertFalse(info.line.isEmpty)
        }
        XCTAssertEqual(FeatureHotkey.tool(.brightness).label, "Open Display")
        XCTAssertEqual(FeatureHotkey.tool(.clipboard).label, "Open History")
        XCTAssertEqual(FeatureHotkey.tool(.calendar).label, "Open Calendar")
    }

    /// Every island tile that is a feature of its own (not a setting of Drop
    /// or Meeting Notes, not navigation) has a feature row.
    func testEveryIslandToolThatIsAFeatureIsListed() {
        let partsOfOtherFeatures: Set<HoverTool> = [.dropMode, .vocab, .filler, .inputLang, .outputLang,
                                                     .notes, .meetingRecord, .hotkeys, .quit, .settings, .help]
        for tool in HoverTool.allCases where !partsOfOtherFeatures.contains(tool) {
            XCTAssertNotNil(HoverFeatureView.feature(for: tool), "\(tool) has a feature in Features")
        }
    }

    func testDisplayAndHistoryAreReadyOnAFreshMac() {
        let fresh = FeatureSetupSnapshot()
        XCTAssertEqual(FeatureCatalog.status(for: .history, snapshot: fresh), .ready(note: nil))
        XCTAssertTrue(FeatureCatalog.requirements(for: .history, snapshot: fresh).isEmpty)
        // Brightness keys need Keyboard control; the slider does not.
        XCTAssertEqual(FeatureCatalog.status(for: .display, snapshot: fresh), .ready(note: nil))
        let keys = FeatureCatalog.checks(for: .display, snapshot: fresh)
        XCTAssertEqual(keys.map(\.requirement.kind), [.permission(.keyboard)])
        XCTAssertTrue(keys[0].requirement.optional)
        XCTAssertEqual(keys[0].action, .allow(.keyboard))
        XCTAssertEqual(FeatureCatalog.consequence(of: keys[0], for: .display, snapshot: fresh),
                       "Brightness keys need Keyboard control. The slider in the island works without it.")
        XCTAssertEqual(FeatureCatalog.summary([FeatureCatalog.status(for: .display, snapshot: fresh)]), "1 ready")
    }

    func testCalendarIsQuietUntilItShowsACalendar() {
        CalendarAvailability.testOverride = true
        var snapshot = FeatureSetupSnapshot()
        XCTAssertEqual(FeatureCatalog.status(for: .calendar, snapshot: snapshot), .notSetUp([]))
        snapshot.calendarConnected = true
        XCTAssertEqual(FeatureCatalog.status(for: .calendar, snapshot: snapshot), .ready(note: nil))
        // Closed as "Soon": never Ready, even with a saved connection.
        CalendarAvailability.testOverride = false
        XCTAssertEqual(FeatureCatalog.status(for: .calendar, snapshot: snapshot), .notSetUp([]))
    }

    func testCalendarShowsACalendarOnlyWhenTheCardDoesOrAnOldAccountIsLeft() {
        XCTAssertTrue(FeaturesEnvironment.calendarConnected(macAccess: .ready, hasAccounts: false))
        for access in [MacCalendarAccess.notAsked, .refused, .loading, .noCalendars] {
            XCTAssertFalse(FeaturesEnvironment.calendarConnected(macAccess: access, hasAccounts: false), "\(access)")
            XCTAssertTrue(FeaturesEnvironment.calendarConnected(macAccess: access, hasAccounts: true),
                          "an account an earlier build connected: \(access)")
        }
    }

    func testTheLiveSnapshotReadsCalendarsOfTheFixtureOnly() async throws {
        CalendarAvailability.testOverride = true
        let usual = try await FeaturesFixture(.usual)
        defer { usual.cleanUp() }
        XCTAssertTrue(usual.snapshot.calendarConnected)
        XCTAssertEqual(FeatureCatalog.status(for: .calendar, snapshot: usual.snapshot), .ready(note: nil))
        let fresh = try await FeaturesFixture(.freshInstall)
        defer { fresh.cleanUp() }
        XCTAssertFalse(fresh.snapshot.calendarConnected)
    }

    // MARK: Settings that were far from their feature

    func testTheAgentsLinkKeysAreOnItsScreenAndSavedWhereHotkeysSavesThem() throws {
        let agent = FeatureCatalog.info(for: .agent).hotkeys
        XCTAssertEqual(agent, [.agentText, .agentVoice, .agentClose,
                               .agentLinkInsert, .agentLinkOpen, .agentLinkNext, .agentLinkPrevious])
        let defaults = HotkeyConfiguration.defaults
        XCTAssertEqual(FeatureHotkey.agentLinkInsert.shortcut(in: defaults), defaults.usefulLinksInsertShortcut)
        XCTAssertEqual(FeatureHotkey.agentLinkOpen.shortcut(in: defaults), defaults.usefulLinksOpenShortcut)
        XCTAssertEqual(FeatureHotkey.agentLinkNext.shortcut(in: defaults), defaults.usefulLinksNextShortcut)
        XCTAssertEqual(FeatureHotkey.agentLinkPrevious.shortcut(in: defaults), defaults.usefulLinksPreviousShortcut)
        for hotkey in [FeatureHotkey.agentLinkInsert, .agentLinkOpen, .agentLinkNext, .agentLinkPrevious] {
            XCTAssertEqual(hotkey.gesture(in: defaults), .tap)
            XCTAssertFalse(hotkey.isVoice)
            XCTAssertFalse(hotkey.allowsGestureSwitch(in: defaults))
            XCTAssertTrue(FeatureShortcutsGroup.detail(for: hotkey, in: defaults).hasPrefix("While an answer shows links"))
        }

        let suite = "every-feature-links-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let preferences = HotkeyPreferences(defaults: store)
        let editor = FeatureShortcutEditor(hotkey: .agentLinkOpen, preferences: preferences)
        let free = HotkeyShortcut.combo(.leftArrow)
        // Left arrow is Paste's: refused, nothing changes.
        editor.record(free)
        XCTAssertFalse(editor.conflicts.isEmpty, "a key another link action uses is not saved")
        XCTAssertEqual(preferences.configuration.usefulLinksOpenShortcut, defaults.usefulLinksOpenShortcut)
        // Move Paste away first, then Open can take the left arrow.
        FeatureShortcutEditor(hotkey: .agentLinkInsert, preferences: preferences)
            .record(.combo(.optionFive))
        editor.record(free)
        XCTAssertTrue(editor.conflicts.isEmpty)
        XCTAssertEqual(preferences.configuration.usefulLinksOpenShortcut, free, "saved where Hotkeys keeps it")
        XCTAssertEqual(HotkeyPreferences(defaults: store).configuration.usefulLinksOpenShortcut, free, "and stored")
    }

    func testDropsOutputLanguageSaysItIsSmarts() {
        XCTAssertEqual(DropFeatureView.writesInSubtitle(mode: .smart),
                       "Smart writes what you said in this language. As spoken keeps your own.")
        XCTAssertEqual(DropFeatureView.writesInSubtitle(mode: .fast),
                       "Used in Smart mode. Fast types the language you spoke.")
    }

    // MARK: The way in

    func testHoverLeadsEachToolToItsFeature() {
        XCTAssertEqual(HoverFeatureView.feature(for: .brightness), .display)
        XCTAssertEqual(HoverFeatureView.feature(for: .clipboard), .history)
        XCTAssertEqual(HoverFeatureView.feature(for: .calendar), .calendar)
        XCTAssertEqual(HoverFeatureView.feature(for: .tasks), .todo)
        XCTAssertEqual(HoverFeatureView.feature(for: .caseVault), .caseVault)
        XCTAssertEqual(HoverFeatureView.feature(for: .subtitles), .translateSubtitles)
        XCTAssertNil(HoverFeatureView.feature(for: .quit))
    }

    /// Settings → Features → Display → Extra: two clicks from the list.
    func testEveryNewScreenOpensFromTheList() {
        for feature in [AppFeature.display, .history, .calendar] {
            let selection = SettingsWindowSelection(selectedTab: .features)
            selection.open(feature)
            XCTAssertEqual(selection.selectedTab, .features)
            XCTAssertEqual(selection.shownFeature, feature)
        }
    }

    func testRenderTheNewScreens() async throws {
        CalendarAvailability.testOverride = true
        let directory = FeaturesFixture.renderDirectory
        for state in [FeaturesFixture.State.usual, .freshInstall] {
            let fixture = try await FeaturesFixture(state)
            defer { fixture.cleanUp() }
            for feature in [AppFeature.display, .history, .calendar, .drop, .agent] {
                for dark in [false, true] {
                    let selection = SettingsWindowSelection(selectedTab: .features)
                    selection.open(feature)
                    let name = "\(feature.rawValue)-\(state == .usual ? "usual" : "fresh")-\(dark ? "dark" : "light").png"
                    try FeaturesFixture.render(fixture.shell(selection: selection),
                                               size: NSSize(width: 960, height: dark ? 560 : 1100), dark: dark,
                                               to: directory?.appendingPathComponent(name))
                }
            }
            let list = SettingsWindowSelection(selectedTab: .features)
            try FeaturesFixture.render(fixture.shell(selection: list), size: NSSize(width: 960, height: 900), dark: false,
                                       to: directory?.appendingPathComponent("features-list-\(state == .usual ? "usual" : "fresh").png"))
        }
    }
}
