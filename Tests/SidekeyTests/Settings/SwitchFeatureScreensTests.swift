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
        environment.setAgent = { _ in AgentOtherSection.Problem.noModel.message }
        let agent = FeatureSwitchModel(feature: .agent, isOn: false, environment: environment)
        await agent.turn(true)?.value
        XCTAssertFalse(agent.isOn)
        XCTAssertFalse(agent.busy)
        XCTAssertEqual(agent.problem, "Choose an Agent model in API & Models.")

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
}
