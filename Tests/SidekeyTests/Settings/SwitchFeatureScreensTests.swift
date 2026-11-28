import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The screens of the Agent, Meeting Notes and Google search: where their
/// rows and links lead, what their switches write, and how they draw.
@MainActor
final class SwitchFeatureScreensTests: XCTestCase {
    private func fixture(_ state: FeaturesFixture.State) async throws -> FeaturesFixture {
        let fixture = try await FeaturesFixture(state)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        return fixture
    }

    func testRowsOpenTheirOwnScreensInsideFeatures() {
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        for feature in [AppFeature.agent, .meetings, .googleSearch] {
            selection.open(feature)
            XCTAssertEqual(selection.selectedTab, .features)
            XCTAssertEqual(selection.shownFeature, feature)
        }
    }

    func testTheOldAgentsLinkAndTheSetupPromptOpenTheAgentScreen() throws {
        let url = try XCTUnwrap(URL(string: "whytap://settings/agentMode"))
        XCTAssertEqual(WhytapLink.request(for: url), .show(.settings(.tab(.agentMode))))
        let selection = SettingsWindowSelection(selectedTab: .agentMode)
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .agent)
    }

    func testMeetingsAndGoogleSwitchesWriteTheirFlagAtOnce() async throws {
        let fixture = try await fixture(.freshInstall)
        var written: [String] = []
        var environment = fixture.environment
        environment.setMeetings = { written.append("meetings \($0)") }
        environment.setGoogle = { written.append("google \($0)") }
        let meetings = FeatureSwitchModel(feature: .meetings, isOn: false, environment: environment)
        meetings.turn(true)
        XCTAssertTrue(meetings.isOn)
        let google = FeatureSwitchModel(feature: .googleSearch, isOn: true, environment: environment)
        google.turn(false)
        XCTAssertFalse(google.isOn)
        XCTAssertEqual(written, ["meetings true", "google false"])
    }

    func testAgentSwitchStaysOffAndSaysWhyWhenItCannotConnect() async throws {
        let fixture = try await fixture(.freshInstall)
        var environment = fixture.environment
        environment.setAgent = { _ in AgentOtherSection.Problem.noHarness.message }
        let agent = FeatureSwitchModel(feature: .agent, isOn: false, environment: environment)
        await agent.turn(true)?.value
        XCTAssertFalse(agent.isOn)
        XCTAssertFalse(agent.busy)
        XCTAssertEqual(agent.problem, "Choose Claude Code or Codex under Harness in Keys & models → Models.")

        environment.setAgent = { _ in nil }
        let connected = FeatureSwitchModel(feature: .agent, isOn: false, environment: environment)
        await connected.turn(true)?.value
        XCTAssertTrue(connected.isOn)
        XCTAssertNil(connected.problem)
    }

    func testAFlagChangedElsewhereShowsUnlessTheAgentIsConnecting() async throws {
        let fixture = try await fixture(.freshInstall)
        let model = FeatureSwitchModel(feature: .meetings, isOn: false, environment: fixture.environment)
        model.follow(true)
        XCTAssertTrue(model.isOn)
    }

    func testAnAgentTurnedOnElsewhereDropsTheOldReason() async throws {
        let fixture = try await fixture(.freshInstall)
        var environment = fixture.environment
        environment.setAgent = { _ in AgentOtherSection.Problem.noHarness.message }
        let agent = FeatureSwitchModel(feature: .agent, isOn: false, environment: environment)
        await agent.turn(true)?.value
        XCTAssertNotNil(agent.problem)
        agent.follow(true)
        XCTAssertTrue(agent.isOn)
        XCTAssertNil(agent.problem, "The Agent is on: “choose a model” no longer applies")
    }

    /// Google search's shortcuts were never saved: a change on the screen
    /// (or in Hotkeys) was lost at once and never reached the key monitor.
    func testGoogleShortcutsAndToggleAreSavedAndSurviveAReload() async throws {
        let fixture = try await fixture(.freshInstall)
        let text = FeatureShortcutEditor(hotkey: .googleText, preferences: fixture.hotkeys)
        text.record(.combo(.optionPeriod))
        XCTAssertNil(text.notice)
        let voice = FeatureShortcutEditor(hotkey: .googleVoice, preferences: fixture.hotkeys)
        voice.record(.modifier(.rightCommand))
        voice.setGesture(.tap)
        XCTAssertEqual(fixture.hotkeys.configuration.googleSearchTextShortcut, .combo(.optionPeriod))
        XCTAssertEqual(fixture.hotkeys.configuration.googleSearchVoiceGesture, .tap)

        let reloaded = HotkeyPreferences(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.configuration.googleSearchTextShortcut, .combo(.optionPeriod))
        XCTAssertEqual(reloaded.configuration.googleSearchVoiceShortcut, voice.configuration.googleSearchVoiceShortcut)
        XCTAssertEqual(reloaded.configuration.googleSearchVoiceGesture, .tap)

        fixture.hotkeys.resetToDefaults()
        XCTAssertEqual(fixture.hotkeys.configuration.googleSearchTextShortcut,
                       HotkeyConfiguration.defaults.googleSearchTextShortcut)
        XCTAssertEqual(HotkeyPreferences(defaults: fixture.defaults).configuration.googleSearchVoiceGesture, .hold)
    }

    /// A saved and reloaded Google combo reaches the key monitor's real
    /// registration plan and fires Google's callbacks, not the Agent's.
    func testSavedGoogleCombosRegisterAndFireGoogleSearch() async throws {
        let fixture = try await fixture(.usual)
        var draft = fixture.hotkeys.configuration
        draft.agentTextShortcut = .combo(.optionFour)
        draft.googleSearchTextShortcut = .combo(.optionD)
        draft.googleSearchVoiceShortcut = .combo(.optionPeriod)
        draft.googleSearchVoiceGesture = .tap
        XCTAssertTrue(draft.conflicts.isEmpty)
        try fixture.hotkeys.apply(draft)
        let loaded = HotkeyPreferences(defaults: fixture.defaults).configuration

        let planned = RightCmdGestureMonitor.plannedCombosForTesting(for: loaded)
        let agent = try XCTUnwrap(planned.first { $0.combo == .optionFour })
        XCTAssertFalse(agent.google)
        XCTAssertEqual(agent.tapAction, .text)
        let text = try XCTUnwrap(planned.first { $0.combo == .optionD }, "Google text combo must register")
        XCTAssertTrue(text.google)
        XCTAssertEqual(text.tapAction, .text)
        XCTAssertEqual(text.hotKeyIDValue, CarbonHotkeyMonitor.googleTextHotKeyID)
        let voice = try XCTUnwrap(planned.first { $0.combo == .optionPeriod }, "Google voice combo must register")
        XCTAssertTrue(voice.google)
        XCTAssertEqual(voice.tapAction, .voice)
        XCTAssertFalse(voice.holdEnabled)
        XCTAssertEqual(voice.hotKeyIDValue, CarbonHotkeyMonitor.googleVoiceHotKeyID)
        XCTAssertEqual(Set(planned.map(\.hotKeyIDValue)).count, planned.count, "Every registration has its own id")

        var fired: [String] = []
        for combo in [HotkeyTapCombo.optionFour, .optionD, .optionPeriod] {
            RightCmdGestureMonitor.tapPlannedComboForTesting(
                combo, in: loaded,
                agentText: { fired.append("agent text") }, agentVoice: { fired.append("agent voice") },
                googleText: { fired.append("google text") }, googleVoice: { fired.append("google voice") })
        }
        XCTAssertEqual(fired, ["agent text", "google text", "google voice"])

        var hold = loaded
        hold.googleSearchVoiceGesture = .hold
        XCTAssertEqual(RightCmdGestureMonitor.plannedCombosForTesting(for: hold)
            .first { $0.combo == .optionPeriod }?.holdEnabled, true)
    }

    /// Every edit reaches the live monitor through the controller's real
    /// subscription, including a one-field change (the Google gesture alone)
    /// and a one-field reload from settings sync.
    func testShortcutEditsReachTheLiveMonitorThroughTheController() async throws {
        let fixture = try await fixture(.usual)
        let preferences = fixture.hotkeys
        let monitor = RightCmdGestureMonitor()
        let agent = AgentController(gestureMonitor: monitor)
        agent.bindHotkeyPreferencesIfSupported(preferences)
        XCTAssertEqual(monitor.configurationForTesting, preferences.configuration)

        var edited = preferences.configuration
        edited.googleSearchTextShortcut = .combo(.optionD)
        try preferences.apply(edited)
        XCTAssertEqual(monitor.configurationForTesting, preferences.configuration)
        edited.googleSearchVoiceShortcut = .combo(.optionPeriod)
        try preferences.apply(edited)
        XCTAssertEqual(monitor.configurationForTesting, preferences.configuration)
        edited.googleSearchVoiceGesture = .tap
        try preferences.apply(edited)
        XCTAssertEqual(preferences.configuration.googleSearchVoiceGesture, .tap)
        XCTAssertEqual(monitor.configurationForTesting.googleSearchVoiceGesture, .tap)
        XCTAssertEqual(monitor.configurationForTesting, preferences.configuration)
        edited.agentTextShortcut = .combo(.optionFour)
        try preferences.apply(edited)
        XCTAssertEqual(monitor.configurationForTesting.agentTextShortcut, .combo(.optionFour))
        XCTAssertEqual(monitor.configurationForTesting, preferences.configuration)

        // Settings sync writes one field and reloads.
        let elsewhere = HotkeyPreferences(defaults: fixture.defaults)
        var synced = elsewhere.configuration
        synced.googleSearchVoiceGesture = .hold
        try elsewhere.apply(synced)
        preferences.reloadFromDefaults()
        XCTAssertEqual(monitor.configurationForTesting.googleSearchVoiceGesture, .hold)
        XCTAssertEqual(monitor.configurationForTesting, preferences.configuration)

        preferences.resetToDefaults()
        XCTAssertEqual(monitor.configurationForTesting, preferences.configuration)
        XCTAssertEqual(monitor.configurationForTesting.googleSearchTextShortcut, .modifier(.rightOption))
        XCTAssertFalse(RightCmdGestureMonitor.plannedCombosForTesting(for: monitor.configurationForTesting)
            .contains { $0.google })
        withExtendedLifetime(agent) {}
    }

    /// The default Right Option split stays on the modifier path: no Google
    /// combo is registered for it.
    func testDefaultGoogleRightOptionRegistersNoCombo() {
        let planned = RightCmdGestureMonitor.plannedCombosForTesting(for: HotkeyConfiguration.defaults)
        XCTAssertFalse(planned.contains { $0.google })
        XCTAssertEqual(HotkeyConfiguration.defaults.googleSearchTextShortcut, .modifier(.rightOption))
        XCTAssertEqual(HotkeyConfiguration.defaults.googleSearchVoiceShortcut, .modifier(.rightOption))
    }

    func testMeetingNotesLeadsToTheNotes() {
        let selection = SettingsWindowSelection()
        selection.open(.meetings)
        selection.select(.notes)
        XCTAssertEqual(selection.selectedTab, .notes)
    }

    func testRenderTheThreeScreensInTheSettingsWindow() async throws {
        let directory = FeaturesFixture.renderDirectory
        for state in [FeaturesFixture.State.freshInstall, .usual] {
            let fixture = try await fixture(state)
            for feature in [AppFeature.agent, .meetings, .googleSearch] {
                for dark in [false, true] {
                    let selection = SettingsWindowSelection(selectedTab: .features)
                    selection.open(feature)
                    let name = "\(feature.rawValue)-\(state == .usual ? "usual" : "fresh")-\(dark ? "dark" : "light").png"
                    try FeaturesFixture.render(fixture.shell(selection: selection),
                                               size: NSSize(width: 960, height: dark ? 560 : 900), dark: dark,
                                               to: directory?.appendingPathComponent(name))
                }
            }
        }
    }

    // MARK: - The switch and the harness
    // WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md

    func testAgentSwitchNeedsAHarnessAndOffKeepsIt() {
        let suite = "harness-switch-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentProviderStore(defaults: defaults)
        var toggled: [Bool] = []
        XCTAssertEqual(AgentOtherSection.turn(true, store: store) { toggled.append($0) }, .noHarness)
        XCTAssertEqual(toggled, [], "never turns on without a harness")
        store.markConnected(.codex)
        XCTAssertNil(AgentOtherSection.turn(true, store: store) { toggled.append($0) })
        XCTAssertNil(AgentOtherSection.turn(false, store: store) { toggled.append($0) })
        XCTAssertEqual(toggled, [true, false])
        XCTAssertEqual(store.activeProvider, .codex, "turning the Agent off keeps the harness")
        XCTAssertTrue(AgentOtherSection.isOn(enabled: true, activeProvider: .claude))
        XCTAssertFalse(AgentOtherSection.isOn(enabled: true, activeProvider: .native), "the native agent no longer counts")
        XCTAssertFalse(AgentOtherSection.isOn(enabled: false, activeProvider: .codex))
    }
}
