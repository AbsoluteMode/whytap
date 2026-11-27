import AppKit
import EventKit
import SwiftUI
import Vision
import XCTest
@testable import Sidekey

/// Regressions the builder found on PR #506 (queue ticket 667): Calendar said
/// Ready with access taken back or no calendars, and the open Drop screen kept
/// an old "Language Drop writes in" after the island changed it.
// WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
@MainActor
final class FeaturesRelocationRegressionTests: XCTestCase {
    func testCalendarStatusReflectsPermissionAndCalendarAvailabilityFromFeaturesHome() async throws {
        let oldAvailability = CalendarAvailability.testOverride
        CalendarAvailability.testOverride = true
        defer { CalendarAvailability.testOverride = oldAvailability }
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        var authorization: EKAuthorizationStatus = .denied
        let calendar = CalendarFeed(id: "apple:fixture", accountID: nil, remoteID: "fixture",
                                    title: "Fixture", provider: .apple)
        var localCalendars: [CalendarFeed] = []
        var prompts = 0
        var eventReads = 0
        let connections = CalendarConnections(defaults: fixture.defaults,
            oauth: CalendarOAuthClient(storage: PlannerMemoryCredentials()),
            apple: AppleCalendarAccess(status: { authorization },
                request: { prompts += 1; return false },
                read: { _ in eventReads += 1; return ([], []) },
                list: { localCalendars }))
        var environment = fixture.environment
        environment.calendarConnections = connections

        func status() -> FeatureStatus {
            let snapshot = FeatureSetupSnapshot.live(models: fixture.models, permissions: fixture.permissions,
                                                     environment: environment)
            return FeatureCatalog.status(for: .calendar, snapshot: snapshot)
        }
        let selection = SettingsWindowSelection(selectedTab: .features)
        try withMounted(SettingsFeaturesView(selection: selection, models: fixture.models,
                                              permissions: fixture.permissions, environment: environment)) { _ in
            XCTAssertEqual(status(), .notSetUp([]), "Saved preference, permission revoked before opening Features")
            connections.prepareMacCalendars()
            XCTAssertEqual(connections.macAccess, .refused)
            XCTAssertEqual(status(), .notSetUp([]), "Revoked permission explicitly sampled")
            authorization = .fullAccess
            connections.prepareMacCalendars()
            XCTAssertEqual(connections.macAccess, .noCalendars)
            XCTAssertEqual(status(), .notSetUp([]), "Granted access with zero calendars")
            localCalendars = [calendar]
            connections.prepareMacCalendars()
            XCTAssertEqual(connections.macAccess, .ready)
            XCTAssertEqual(status(), .ready(note: nil), "Granted access with one calendar")
            localCalendars = []
            connections.prepareMacCalendars()
            XCTAssertEqual(status(), .notSetUp([]), "Last calendar removed")
            XCTAssertEqual(prompts, 0)
            XCTAssertEqual(eventReads, 0)
        }
    }

    func testOpenDropScreenTracksOutputLanguageChangedElsewhere() async throws {
        let fixture = try await FeaturesFixture(.usual, dropMode: .smart)
        defer { fixture.cleanUp() }
        let prefs = PrivacyPreferences(defaults: fixture.defaults)
        let french = try XCTUnwrap(AppLanguage.find(code: "fr"))
        let german = try XCTUnwrap(AppLanguage.find(code: "de"))
        prefs.targetLanguage = french
        var environment = fixture.environment
        environment.targetLanguage = { prefs.targetLanguage }
        environment.setTargetLanguage = { prefs.targetLanguage = $0 }
        let selection = SettingsWindowSelection(selectedTab: .features)
        selection.open(.drop)

        try withMounted(DropFeatureView(snapshot: fixture.snapshot, selection: selection, models: fixture.models,
                    permissions: fixture.permissions, environment: environment)) { read in
            let initial = try read()
            XCTAssertTrue(initial.contains("Language Drop writes in"), "Missing row: \(initial)")
            XCTAssertTrue(initial.components(separatedBy: " | ").contains(french.displayName), "Wrong initial value: \(initial)")
            for language in [german, nil] as [AppLanguage?] {
                prefs.targetLanguage = language
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: fixture.defaults)
                let text = try read()
                let expected = language?.displayName ?? "As spoken"
                XCTAssertTrue(text.components(separatedBy: " | ").contains(expected), "Expected the picker to show \(expected)")
                XCTAssertFalse(text.components(separatedBy: " | ").contains(french.displayName), "Displayed the previous value \(french.displayName)")
            }
        }
    }

    private func withMounted<V: View>(_ view: V, check: (() throws -> String) throws -> Void) throws {
        let size = NSSize(width: 960, height: 1400)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func layout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            host.layoutSubtreeIfNeeded()
        }
        layout()
        try check {
            layout()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
        }
        XCTAssertFalse(window.isVisible)
    }
}
