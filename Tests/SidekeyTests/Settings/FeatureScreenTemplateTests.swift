import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The shared parts every feature screen is made of: the template must say
/// the same things the Drop screen said before it was built from them.
@MainActor
final class FeatureScreenTemplateTests: XCTestCase {
    func testRequirementCounterSaysWhenNothingIsRequired() {
        let optional = FeatureCatalog.checks(for: .googleSearch, snapshot: FeatureSetupSnapshot(googleOn: true))
        XCTAssertFalse(optional.isEmpty)
        XCTAssertEqual(FeatureNeedsGroup.requiredSummary(optional), "Nothing is required")
        let drop = FeatureCatalog.checks(for: .drop, snapshot: FeatureSetupSnapshot())
        XCTAssertEqual(FeatureNeedsGroup.requiredSummary(drop), DropFeatureView.requiredSummary(drop))
    }

    func testSwitchCardSaysTheStatusInWordsForEachWayOfTurningOn() {
        let agent = FeatureCatalog.info(for: .agent)
        XCTAssertEqual(FeatureSwitchCard.statusWord(agent, .off), "Off")
        XCTAssertEqual(FeatureSwitchCard.statusWord(agent, .ready(note: nil)), "On · Ready")
        XCTAssertEqual(FeatureSwitchCard.statusWord(agent, .needsSetup([])), "On · Needs setup")
        let shots = FeatureCatalog.info(for: .screenshots)
        XCTAssertEqual(FeatureSwitchCard.statusWord(shots, .notSetUp([])), "Not set up")
        XCTAssertEqual(FeatureSwitchCard.statusWord(shots, .ready(note: nil)), "Ready")
        XCTAssertEqual(FeatureSwitchCard.statusWord(FeatureCatalog.info(for: .drop), .ready(note: nil)), "Always on")
        XCTAssertEqual(FeatureSwitchCard.subtitle(agent, isOn: false), "Turn it on to use it.")
        XCTAssertEqual(FeatureSwitchCard.subtitle(agent, isOn: true), "Turn it off if you don’t use it.")
    }

    func testShortcutDetailsFollowTheGestureAndNameNoKey() {
        var configuration = HotkeyConfiguration.defaults
        configuration.agentVoiceGesture = .hold
        XCTAssertEqual(FeatureShortcutsGroup.detail(for: .agentVoice, in: configuration), "Hold to speak; let go to send.")
        configuration.agentVoiceGesture = .tap
        XCTAssertEqual(FeatureShortcutsGroup.detail(for: .agentVoice, in: configuration),
                       "Press to start speaking, press again to send.")
        configuration.toolShortcuts[.screenshot] = nil
        XCTAssertTrue(FeatureShortcutsGroup.detail(for: .tool(.screenshot), in: configuration).hasPrefix("No shortcut yet."))
        // A key name would go wrong the moment the person rebinds it.
        for hotkey in FeatureCatalog.all.flatMap(\.hotkeys) {
            let detail = FeatureShortcutsGroup.detail(for: hotkey, in: configuration)
            for key in ["Space", "⌘", "⌥", "Command", "Option"] where hotkey != .dropVoice {
                XCTAssertFalse(detail.contains(key), "\(hotkey): \(detail)")
            }
        }
    }

    func testEveryFeatureSaysWhatItsClipShowsEvenBeforeTheClipIsMade() {
        for info in FeatureCatalog.all where info.place == .screen {
            XCTAssertFalse(info.clipCaption.isEmpty, "\(info.feature) has no clip caption")
        }
        XCTAssertNil(FeatureVideoStrip.url(for: FeatureCatalog.info(for: .drop)), "Drop's clip is not made yet")
    }

    func testDropScreenUsesTheTemplateAndKeepsItsPlaceForTheClip() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection(selectedTab: .features)
        selection.open(.drop)
        let bitmap = try FeaturesFixture.render(fixture.shell(selection: selection),
                                                size: NSSize(width: 960, height: 760), dark: false,
                                                to: FeaturesFixture.renderDirectory?
                                                    .appendingPathComponent("template-drop.png"))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }

    func testTemplateDrawsAFeatureWithASwitchWithoutAWindowOnScreen() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection(selectedTab: .features)
        let context = FeatureScreenContext(snapshot: fixture.snapshot, selection: selection, models: fixture.models,
                                           permissions: fixture.permissions, environment: fixture.environment)
        var on = false
        let screen = FeatureScreenView(feature: .googleSearch, context: context,
                                       isOn: Binding(get: { on }, set: { on = $0 })) { EmptyView() }
        for dark in [false, true] {
            try FeaturesFixture.render(screen, size: NSSize(width: 739, height: 760), dark: dark,
                                       to: FeaturesFixture.renderDirectory?
                                           .appendingPathComponent("template-google-\(dark ? "dark" : "light").png"))
        }
    }
}
