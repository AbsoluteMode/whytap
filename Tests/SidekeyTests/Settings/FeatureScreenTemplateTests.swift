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

    func testStartingAnotherShortcutReleasesTheFirstRecorder() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let recording = HotkeyRecordingSession<FeatureHotkey>()
        let text = FeatureShortcutEditor(hotkey: .agentText, preferences: fixture.hotkeys, recording: recording)
        let voice = FeatureShortcutEditor(hotkey: .agentVoice, preferences: fixture.hotkeys, recording: recording)
        defer { recording.stop() }

        text.startRecording(monitorsEvents: false)
        voice.startRecording(monitorsEvents: false)
        XCTAssertFalse(text.isRecording)
        XCTAssertTrue(voice.isRecording)
        text.cancel()
        XCTAssertEqual(recording.target, .agentVoice)
        XCTAssertTrue(AppState.shared.hotkeyRecordingActive)
        voice.cancel()
        XCTAssertFalse(AppState.shared.hotkeyRecordingActive)
    }

    func testBundledVideoRowRendersEnabledAndDisabled() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let bundle = try XCTUnwrap(Bundle(url: resources))
        let info = FeatureCatalog.info(for: .googleSearch)
        XCTAssertNotNil(FeatureVideoStrip.url(for: info, in: bundle))

        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            let size = NSSize(width: 680, height: 80)
            let strip = FeatureVideoStrip(info: info, bundle: bundle)
                .padding(12)
                .frame(width: size.width, height: size.height)
            let directory = FeaturesFixture.renderDirectory
            let enabled = try FeaturesFixture.render(strip, size: size, dark: dark,
                                                      to: directory?.appendingPathComponent("video-ready-\(appearance).png"))
            let disabled = try FeaturesFixture.render(strip.disabled(true), size: size, dark: dark,
                                                       to: directory?.appendingPathComponent("video-disabled-\(appearance).png"))
            XCTAssertNotEqual(try XCTUnwrap(enabled.tiffRepresentation), try XCTUnwrap(disabled.tiffRepresentation))
        }
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
