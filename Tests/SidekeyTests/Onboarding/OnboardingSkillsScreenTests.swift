import XCTest

final class OnboardingSkillsScreenTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/Onboarding/OnboardingSkillsScreen.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_pageHasSkillsTitleAndKillswitchCopy() throws {
        let s = try source()
        XCTAssertTrue(s.contains("Skills"), "header title present")
        XCTAssertTrue(
            s.contains("Off by default — nothing runs in the background until you switch it on."),
            "killswitch subtitle present verbatim")
    }

    func test_threeCapabilityTabsDeclared() throws {
        let s = try source()
        XCTAssertTrue(s.contains("case agent"), "agent tab")
        XCTAssertTrue(s.contains("case meetings"), "meetings tab")
        XCTAssertTrue(s.contains("case google"), "google tab")
        XCTAssertTrue(s.contains("CaseIterable"), "tabs enumerable for the segmented bar")
    }

    func test_togglesUseInjectedCallbackNotCacheOrNetwork() throws {
        let s = try source()
        XCTAssertTrue(s.contains("onToggle"), "flips go through the injected closure")
        XCTAssertFalse(s.contains("UserPreferencesCache"), "screen must not touch the cache directly")
        XCTAssertFalse(s.contains("URLSession"), "screen must not touch the network directly")
    }

    func test_togglesDefaultOff() throws {
        let s = try source()
        XCTAssertTrue(s.contains("initialAgentEnabled"), "agent seed param")
        XCTAssertTrue(s.contains("initialMeetingsEnabled"), "meetings seed param")
        XCTAssertTrue(s.contains("initialGoogleEnabled"), "google seed param")
    }

    func test_agentDetailEmbedsConnectPane() throws {
        let s = try source()
        XCTAssertTrue(s.contains("OnboardingAgentConnectPane"), "agent detail embeds the Connect pane")
        XCTAssertTrue(s.contains("agentSurface"), "pane is driven by the injected agent surface")
        XCTAssertTrue(s.contains("selectedFeature == .agent"), "pane shown for the selected Agent feature")
        XCTAssertTrue(s.contains("onConnected"), "Connect flips the Agent capability on")
    }

    func test_masterDetailLayout() throws {
        let s = try source()
        XCTAssertTrue(s.contains("featureCard"), "left-hand vertical feature cards")
        XCTAssertTrue(s.contains("detailPanel"), "right-hand detail panel")
        XCTAssertTrue(s.contains("selectedFeature"), "card selection drives the detail")
        XCTAssertTrue(s.contains("connectButton"), "Connect action lives in the detail panel")
    }

    func test_meetingsGoogleShowcaseHowItWorks() throws {
        let s = try source()
        XCTAssertTrue(s.contains("howItWorks"), "Meetings/Google carry how-it-works steps")
        XCTAssertTrue(s.contains("Take notes"), "Meetings nudge visual present")
    }

    func test_connectPaneExtracted_andTryScreenReusesIt() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/Onboarding")
        let pane = try String(contentsOf: dir.appendingPathComponent("OnboardingAgentConnectPane.swift"), encoding: .utf8)
        XCTAssertTrue(pane.contains("struct OnboardingAgentConnectPane"), "reusable pane exists")
        XCTAssertTrue(pane.contains("providerButton") || pane.contains("providerToggle"), "provider chooser moved in")
        XCTAssertTrue(pane.contains("SETUP"), "checklist moved in")
        XCTAssertTrue(pane.contains("Connect"), "connect CTA moved in")
        // Regression: the setup-checklist kickoff used to live in the Try-Agent
        // screen's `.onAppear`. The pane must self-start it (`surface.start()`
        // on appear) or the Skills page shows a forever-spinning 0/4 checklist.
        XCTAssertTrue(pane.contains(".onAppear { surface.start() }"),
                      "pane self-starts the brew/node/CLI/signed-in probes on appear")

        let tryScreen = try String(contentsOf: dir.appendingPathComponent("OnboardingAgentTryScreen.swift"), encoding: .utf8)
        XCTAssertTrue(tryScreen.contains("OnboardingAgentConnectPane"), "Try-Agent reuses the extracted pane")
    }

    func test_flowRoutesThroughSkillsNotTryAgent() throws {
        let flow = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/Onboarding/OnboardingFlowView.swift"), encoding: .utf8)
        XCTAssertTrue(flow.contains("case .skills:"), "flow renders the Skills screen")
        XCTAssertTrue(flow.contains("OnboardingSkillsScreen("), "Skills screen instantiated")
        XCTAssertTrue(flow.contains("advance(to: .skills)"), "active flow routes into Skills")
        XCTAssertTrue(flow.contains("onCapabilityToggle"), "toggle closure threaded through the flow")
    }

    func test_hostToggleClosureWritesCacheAndPersists() throws {
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("onCapabilityToggle"), "host builds the toggle closure")
        XCTAssertTrue(app.contains("setAgentEnabled"), "agent flips write the cache")
        XCTAssertTrue(app.contains("setMeetingsEnabled"), "meetings flips write the cache")
        XCTAssertTrue(app.contains("setGoogleEnabled"), "google flips write the cache")
    }

    func test_superAssistantIsShowcaseNotPicker() throws {
        let s = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/Onboarding/OnboardingSuperAssistantScreen.swift"), encoding: .utf8)
        XCTAssertFalse(s.contains("replaceEditableSlots"), "showcase must not write the hover panel")
        XCTAssertFalse(s.contains("func checkbox"), "no selection-checkbox control in a passive showcase")
        XCTAssertFalse(s.contains("@State private var selected"), "no selection state in a passive showcase")
        XCTAssertTrue(s.contains("showcase"), "passive gallery, not a picker")
    }
}
