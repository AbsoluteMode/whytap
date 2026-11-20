import XCTest
@testable import Sidekey

@MainActor
final class RetiredMeetingFeatureTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "retired-meeting-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testOldRoutesCannotBeUsedAndRetirementPreservesOtherRoutes() throws {
        let defaults = defaults()
        let route = FeatureRoute(account: .openRouter, model: "fixture/model", provider: "fixture/endpoint")
        let previous = AIRoutingState(
            routes: ["meetingAssistant": route, "meetingAssistantAudio": route,
                     "meetingNotes": route, "agent": route, "futureFeature": route],
            migratedRoutes: ["meetingAssistant": route, "meetingAssistantAudio": route, "meetingNotes": route],
            servers: [], migrationVersion: 4
        )
        try defaults.set(JSONEncoder().encode(previous), forKey: AIRoutingStore.defaultsKey)
        let routing = AIRoutingStore(defaults: defaults)
        for feature in [AIFeature.retiredMeetingText, .retiredMeetingAudio] {
            XCTAssertNil(routing.route(for: feature))
            XCTAssertNil(routing.migratedRoute(for: feature))
            routing.setRoute(route, for: feature)
            for kind in AIProviderKind.allCases {
                XCTAssertNil(feature.modelUse(on: kind))
                XCTAssertNil(ModelRegistry.recommended(for: feature, kind: kind))
            }
        }
        routing.retireMeetingRoutesIfNeeded()
        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(reloaded.state.routes, ["meetingNotes": route, "agent": route, "futureFeature": route])
        XCTAssertEqual(reloaded.state.migratedRoutes, ["meetingNotes": route])
        let once = defaults.data(forKey: AIRoutingStore.defaultsKey)
        reloaded.retireMeetingRoutesIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), once)
        // An old backup restored later goes through the same removal.
        try defaults.set(JSONEncoder().encode(previous), forKey: AIRoutingStore.defaultsKey)
        let restored = AIRoutingStore(defaults: defaults)
        restored.retireMeetingRoutesIfNeeded()
        XCTAssertEqual(restored.state.routes, reloaded.state.routes)
    }

    func testPartialOldRoutingDocumentIsNotOverwrittenAtLaunch() throws {
        let defaults = defaults()
        let raw = Data(#"{"routes":{"meetingAssistant":{"account":"openRouter","model":"fixture"},"future":{"account":"unknown-provider","model":"fixture"}},"migratedRoutes":{},"servers":[],"migrationVersion":4}"#.utf8)
        defaults.set(raw, forKey: AIRoutingStore.defaultsKey)
        let routing = AIRoutingStore(defaults: defaults)
        routing.retireMeetingRoutesIfNeeded()
        XCTAssertNil(routing.route(for: .retiredMeetingText))
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), raw)
    }

    func testOldTileShortcutAndLinkDoNotRestoreTheTool() {
        let defaults = defaults()
        defaults.set(["notes", "meetingAssistant", "meetingRecord", "settings"], forKey: HoverLayoutStore.defaultsKey)
        defaults.set(["meetingAssistant": HotkeyShortcut.combo(.optionD).rawValue,
                      "notes": HotkeyShortcut.combo(.optionFive).rawValue],
                     forKey: HotkeyPreferences.toolShortcutsDefaultsKey)
        XCTAssertEqual(HoverLayoutStore(defaults: defaults).slots, [.notes, .meetingRecord, .settings])
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).toolShortcuts, [.notes: .combo(.optionFive)])
        XCTAssertEqual(WhytapLink.request(for: URL(string: "whytap://tool/meetingAssistant")!), .show(.island))
        XCTAssertEqual(WhytapLink.request(for: URL(string: "whytap://hotkey/meetingAssistant?keys=option+d")!),
                       .show(.settings(.tab(.hotkeys))))
    }

    func testHistoricalCostsRemainReadableAfterReopeningTheStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = AIUsageStore(url: url)
        let date = Date(timeIntervalSince1970: 1_000)
        for raw in ["meetingAssistant", "meetingAssistantAudio", "meetingNotes"] {
            let feature = try JSONDecoder().decode(AIFeature.self, from: JSONEncoder().encode(raw))
            try await store.insert(AIUsageEvent(createdAt: date,
                context: .init(feature: feature, account: .openRouter, model: "fixture/model"),
                currency: .usd, amount: 0.01, basis: .reported))
        }
        let rows = try await AIUsageStore(url: url).events(from: date, to: date.addingTimeInterval(1))
        XCTAssertEqual(Set(rows.map { $0.context.feature.rawValue }), ["meetingAssistant", "meetingAssistantAudio", "meetingNotes"])
        XCTAssertEqual(AIUsageTotal(events: rows, currency: .usd).text, "$0.03")
    }

    func testRetiredResearchAudioCleanupKeepsNotesAndProjectFiles() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let research = parent.appendingPathComponent("retired-captures")
        let session = research.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data([1]).write(to: session.appendingPathComponent("mixed.pcm"))
        let note = parent.appendingPathComponent("note.md")
        try Data("fixture note".utf8).write(to: note)
        RetiredMeetingCaptureCleanup.run(root: research)
        RetiredMeetingCaptureCleanup.run(root: research)
        XCTAssertFalse(FileManager.default.fileExists(atPath: research.path))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "fixture note")
    }
}
