import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Settings -> Features -> Drop: the first job of a newcomer, "set up
/// dictation", done on one screen: the shortcut and Hold or Toggle changed
/// in place, the free model chosen in place, and honest words about what is
/// missing.
@MainActor
final class DropFeatureTests: XCTestCase {
    private func fixture(_ state: FeaturesFixture.State, dropMode: TranscriptionMode = .fast,
                         onDevice: OnDeviceSpeechModelStatus? = nil) async throws -> FeaturesFixture {
        let fixture = try await FeaturesFixture(state, dropMode: dropMode, onDevice: onDevice)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        return fixture
    }

    private func editor(_ fixture: FeaturesFixture) -> FeatureShortcutEditor {
        FeatureShortcutEditor(hotkey: .dropVoice, preferences: fixture.hotkeys)
    }

    // MARK: - Opening

    func testDropRowOpensItsOwnScreenInsideFeatures() {
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        selection.open(.drop)
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .drop)
    }

    // MARK: - Shortcut changed in place

    func testRecordingANewKeySavesItAtOnce() async throws {
        let fixture = try await fixture(.usual)
        let editor = editor(fixture)
        XCTAssertEqual(fixture.hotkeys.configuration.dropVoiceShortcut, .holdSpace)

        editor.startRecording(monitorsEvents: false)
        XCTAssertTrue(editor.isRecording)
        editor.record(.combo(.optionD))

        XCTAssertFalse(editor.isRecording, "A saved shortcut ends the recording")
        XCTAssertEqual(fixture.hotkeys.configuration.dropVoiceShortcut, .combo(.optionD))
        XCTAssertEqual(HotkeyPreferences(defaults: fixture.defaults).configuration.dropVoiceShortcut, .combo(.optionD),
                       "It is stored, not only shown")
        XCTAssertNil(editor.notice)
    }

    func testAKeyAnotherActionUsesIsNotSavedAndRecordingStaysOpen() async throws {
        let fixture = try await fixture(.usual)
        let editor = editor(fixture)
        editor.startRecording(monitorsEvents: false)
        // ⌥M is Meeting Notes' shortcut by default.
        editor.record(fixture.hotkeys.configuration.meetingRecordShortcut)

        XCTAssertEqual(fixture.hotkeys.configuration.dropVoiceShortcut, .holdSpace, "Nothing was saved")
        XCTAssertTrue(editor.isRecording, "Another key can be pressed straight away")
        XCTAssertNotNil(editor.notice)

        editor.record(.combo(.optionD))
        XCTAssertEqual(fixture.hotkeys.configuration.dropVoiceShortcut, .combo(.optionD))
        XCTAssertNil(editor.notice)
        XCTAssertFalse(editor.isRecording)
    }

    func testCancelLeavesTheShortcutAsItWas() async throws {
        let fixture = try await fixture(.usual)
        let editor = editor(fixture)
        editor.startRecording(monitorsEvents: false)
        editor.cancel()
        XCTAssertFalse(editor.isRecording)
        XCTAssertFalse(AppState.shared.hotkeyRecordingActive)
        XCTAssertEqual(fixture.hotkeys.configuration.dropVoiceShortcut, .holdSpace)
    }

    func testSpaceIsHoldOnlyAndAnotherKeyCanBeToggle() async throws {
        let fixture = try await fixture(.usual)
        let editor = editor(fixture)
        XCTAssertFalse(editor.canSwitchGesture, "A tap of Space is typing a space")
        editor.setGesture(.tap)
        XCTAssertEqual(editor.gesture, .hold)

        // Right Option belongs to Google search: taking it is a conflict.
        editor.record(.modifier(.rightOption))
        XCTAssertNotNil(editor.notice)
        XCTAssertEqual(fixture.hotkeys.configuration.dropVoiceShortcut, .holdSpace)

        editor.record(.combo(.optionD))
        XCTAssertTrue(editor.canSwitchGesture)
        editor.setGesture(.tap)
        XCTAssertEqual(editor.gesture, .tap)
        XCTAssertEqual(fixture.hotkeys.configuration.dropVoiceGesture, .tap)

        // Back to Space: the stored Toggle must not survive on a hold-only key.
        editor.record(.holdSpace)
        XCTAssertEqual(editor.gesture, .hold)
    }

    func testOnlyDropMayTakeSpaceAsAHoldKey() {
        var configuration = HotkeyConfiguration.defaults
        XCTAssertFalse(FeatureHotkey.agentClose.assign(.holdSpace, in: &configuration))
        XCTAssertEqual(configuration, .defaults)
        XCTAssertTrue(FeatureHotkey.dropVoice.assign(.holdSpace, in: &configuration))
    }

    func testLeadAndShortcutLineFollowAReboundKey() async throws {
        let fixture = try await fixture(.usual)
        let editor = editor(fixture)
        editor.record(.combo(.optionD))
        editor.setGesture(.tap)
        XCTAssertTrue(FeatureCatalog.dropAbout(gesture: editor.gesture).contains("Press the shortcut"))
        XCTAssertEqual(editor.contents, HotkeyShortcut.combo(.optionD).contents)
    }

    // MARK: - The free model, in place

    func testChoosingTheLocalModelMakesDropReady() async throws {
        let fixture = try await fixture(.usual)
        fixture.routing.setRoute(nil, for: .dropFast)
        fixture.models.onDeviceModelChanged()
        XCTAssertFalse(FeatureCatalog.status(for: .drop, snapshot: fixture.snapshot).isReady)

        XCTAssertTrue(fixture.models.useOnDeviceModel(for: .dropFast))

        XCTAssertEqual(fixture.routing.route(for: .dropFast)?.account, .thisMac)
        XCTAssertEqual(FeatureCatalog.status(for: .drop, snapshot: fixture.snapshot), .ready(note: nil))
    }

    func testChoosingItForDropOffersNothingForOtherFeatures() async throws {
        let fixture = try await fixture(.usual)
        fixture.routing.setRoute(nil, for: .dropFast)
        fixture.models.useOnDeviceModel(for: .dropFast)
        XCTAssertNil(fixture.models.proposal, "No Assign window appears later in API & Models")
        XCTAssertNil(fixture.routing.route(for: .meetings), "Other features are left as they were")
    }

    func testLocalModelIsNotAssignedWhenItIsNotOnThisMacOrCannotServe() async throws {
        let fresh = try await fixture(.freshInstall)
        XCTAssertFalse(fresh.models.useOnDeviceModel(for: .dropFast))
        XCTAssertNil(fresh.routing.route(for: .dropFast))

        let usual = try await fixture(.usual)
        XCTAssertFalse(usual.models.useOnDeviceModel(for: .dropSmartCleanup), "A speech model is no text model")
        XCTAssertNil(usual.routing.route(for: .dropSmartCleanup))
    }

    // MARK: - Words on the screen

    func testNeedsBoxSaysWhatDoesNotWorkAndHowManyMore() async throws {
        let snapshot = try await fixture(.freshInstall).snapshot
        let missing = FeatureCatalog.status(for: .drop, snapshot: snapshot).missing
        XCTAssertEqual(
            FeatureNeedsBox.text(consequence: FeatureCatalog.consequence(of: missing[0], for: .drop), more: missing.count - 1),
            "Drop can’t type what you say until it has a speech-to-text model. 2 more below.")
        XCTAssertEqual(FeatureNeedsBox.buttonTitle(.downloadOnDeviceModel(.dropFast), modelSize: "about 470 MB"),
                       "Download the free model · 470 MB")
        XCTAssertEqual(FeatureNeedsBox.text(consequence: "x.", more: 0), "x.")
    }

    func testRequirementCounterCountsOnlyRequiredSteps() async throws {
        let fresh = FeatureCatalog.checks(for: .drop, snapshot: try await fixture(.freshInstall).snapshot)
        XCTAssertEqual(DropFeatureView.requiredSummary(fresh), "0 of 4 required")
        let usual = FeatureCatalog.checks(for: .drop, snapshot: try await fixture(.usual).snapshot)
        XCTAssertEqual(DropFeatureView.requiredSummary(usual), "All required are set")
        let smart = FeatureCatalog.checks(for: .drop, snapshot: try await fixture(.usual, dropMode: .smart).snapshot)
        XCTAssertEqual(DropFeatureView.requiredSummary(smart), "3 of 5 required",
                       "Fast's model is optional in Smart and is not counted")
    }

    func testRowButtonsAreShortAndDoneStatesAreWords() {
        typealias Row = FeatureRequirementRow<EmptyView>
        XCTAssertEqual(Row.rowTitle(.allow(.keyboard)), "Allow")
        XCTAssertEqual(Row.rowTitle(.restartWhytap), "Restart Whytap")
        XCTAssertEqual(Row.rowTitle(.downloadOnDeviceModel(.dropFast)), "Download free model")
        XCTAssertEqual(Row.doneWord(.permission(.microphone)), "Allowed")
        XCTAssertEqual(Row.doneWord(.dropShortcut), "Heard")
        XCTAssertEqual(Row.downloadText(0), "Starting the download…")
        XCTAssertEqual(Row.downloadText(0.42), "Downloading… 42%")
    }

    // MARK: - Offscreen pictures

    private func screen(_ fixture: FeaturesFixture, editor: FeatureShortcutEditor? = nil) -> some View {
        let selection = SettingsWindowSelection()
        selection.open(.drop)
        return HStack(spacing: 0) {
            DropFeatureView(snapshot: fixture.snapshot, selection: selection, models: fixture.models,
                            permissions: fixture.permissions, environment: fixture.environment,
                            shortcutEditor: editor)
        }
        .background(MacSettingsTheme.bgContent)
    }

    /// Drop's screen inside the whole Settings window, in the smallest and a
    /// larger size, both themes, a usual Mac and a fresh install. Saves
    /// review images when WHYTAP_SETTINGS_FEATURES_RENDER_DIR is set.
    func testRenderDropScreenInTheSettingsWindow() async throws {
        let directory = FeaturesFixture.renderDirectory
        for (name, state) in [("usual", FeaturesFixture.State.usual), ("fresh", .freshInstall)] {
            let fixture = try await fixture(state)
            for dark in [false, true] {
                for size in [NSSize(width: 960, height: 560), NSSize(width: 1280, height: 760)] {
                    let selection = SettingsWindowSelection()
                    selection.open(.drop)
                    try FeaturesFixture.render(
                        fixture.shell(selection: selection), size: size, dark: dark,
                        to: directory?.appendingPathComponent(
                            "drop-\(name)-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                }
            }
        }
    }

    /// The whole screen without the window's height, so every block can be
    /// read in one picture, and the states a window shot does not reach.
    func testRenderDropScreenStates() async throws {
        let directory = FeaturesFixture.renderDirectory
        let pane = NSSize(width: 960 - SettingsSidebarStyle.width - 1, height: 1180)
        func save(_ name: String, _ fixture: FeaturesFixture, editor: FeatureShortcutEditor? = nil,
                  dark: Bool = false) throws {
            try FeaturesFixture.render(screen(fixture, editor: editor), size: pane, dark: dark,
                                       to: directory?.appendingPathComponent("drop-full-\(name).png"))
        }
        try save("usual-light", try await fixture(.usual))
        try save("usual-dark", try await fixture(.usual), dark: true)
        try save("fresh-light", try await fixture(.freshInstall))
        try save("fresh-dark", try await fixture(.freshInstall), dark: true)
        try save("fresh-intel-light", try await fixture(.freshIntel))
        try save("downloading-light", try await fixture(.freshInstall, onDevice: .downloading(0.42)))
        try save("smart-light", try await fixture(.usual, dropMode: .smart))

        let recording = try await fixture(.usual)
        let editor = editor(recording)
        editor.startRecording(monitorsEvents: false)
        defer { editor.cancel() }
        try save("recording-shortcut-dark", recording, editor: editor, dark: true)

        let rebound = try await fixture(.usual)
        let reboundEditor = self.editor(rebound)
        reboundEditor.record(.combo(.optionD))
        reboundEditor.setGesture(.tap)
        try save("rebound-toggle-light", rebound, editor: reboundEditor)
    }
}
