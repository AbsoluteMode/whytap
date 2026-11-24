import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Settings -> Features: the list a newcomer lands on, read from the same
/// view models the older tabs use, and where each row leads.
@MainActor
final class SettingsFeaturesTests: XCTestCase {
    private func fixture(_ state: FeaturesFixture.State, dropMode: TranscriptionMode = .fast,
                         onDevice: OnDeviceSpeechModelStatus? = nil) async throws -> FeaturesFixture {
        let fixture = try await FeaturesFixture(state, dropMode: dropMode, onDevice: onDevice)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        return fixture
    }

    // MARK: - The Mac as the list reads it

    func testFreshInstallListsDropAsTheOnlyThingToSetUp() async throws {
        let snapshot = try await fixture(.freshInstall).snapshot
        let statuses = AppFeature.allCases.map { FeatureCatalog.status(for: $0, snapshot: snapshot) }
        XCTAssertEqual(statuses.map(\.word), ["Needs setup", "Off", "Off", "Off", "Not set up", "Not set up",
                        "Ready", "Not set up", "Not set up"])
        XCTAssertEqual(statuses[0].reason, "No speech-to-text model +2")
        XCTAssertEqual(statuses[0].missing.first?.action, .downloadOnDeviceModel(.dropFast))
        XCTAssertEqual(FeatureCatalog.summary(statuses), "1 ready · 1 needs setup")
    }

    func testIntelMacWithoutKeysIsAskedForAKey() async throws {
        let snapshot = try await fixture(.freshIntel).snapshot
        XCTAssertEqual(snapshot.onDevice, .unsupported)
        XCTAssertEqual(FeatureCatalog.status(for: .drop, snapshot: snapshot).missing.first?.action, .addKey(.dropFast))
    }

    func testUsualMacReadsLikeTheMockup() async throws {
        let snapshot = try await fixture(.usual).snapshot
        XCTAssertEqual(FeatureCatalog.status(for: .drop, snapshot: snapshot), .ready(note: nil))
        XCTAssertEqual(FeatureCatalog.status(for: .agent, snapshot: snapshot).word, "Needs setup")
        XCTAssertEqual(FeatureCatalog.status(for: .agent, snapshot: snapshot).reason, "No text model")
        XCTAssertEqual(FeatureCatalog.status(for: .meetings, snapshot: snapshot), .off)
        XCTAssertEqual(FeatureCatalog.status(for: .googleSearch, snapshot: snapshot), .ready(note: nil))
        XCTAssertEqual(FeatureCatalog.status(for: .screenshots, snapshot: snapshot).word, "Not set up")
    }

    func testDownloadedModelNotChosenYetIsOfferedForDrop() async throws {
        let snapshot = try await fixture(.freshInstall, onDevice: .ready).snapshot
        XCTAssertEqual(FeatureCatalog.status(for: .drop, snapshot: snapshot).missing.first?.action,
                       .useOnDeviceModel(.dropFast))
    }

    func testSmartModeAsksForItsOwnModels() async throws {
        let snapshot = try await fixture(.usual, dropMode: .smart).snapshot
        XCTAssertEqual(FeatureCatalog.status(for: .drop, snapshot: snapshot).missing.map(\.requirement.id),
                       ["model.dropSmart", "model.dropSmartCleanup"])
    }

    func testSnapshotFollowsTheModelRouteTheOlderTabShows() async throws {
        let fixture = try await fixture(.usual)
        XCTAssertEqual(fixture.snapshot.modelStatus(.dropFast), fixture.models.rows.first { $0.feature == .dropFast }?.status)
        fixture.routing.setRoute(nil, for: .dropFast)
        fixture.models.onDeviceModelChanged()
        XCTAssertEqual(fixture.snapshot.modelStatus(.dropFast), .notSet)
    }

    // MARK: - Navigation

    func testSettingsOpensOnFeatures() {
        XCTAssertEqual(SettingsWindowTab.allCases.first, .features)
        XCTAssertEqual(SettingsWindowTab.defaultAvailable, .features)
        XCTAssertEqual(SettingsWindowSelection().selectedTab, .features)
        XCTAssertEqual(SettingsWindowTab.features.title, "Features")
    }

    func testOlderTabsKeepTheirIdentifiersAndStayInTheSidebar() {
        XCTAssertEqual(SettingsWindowTab.allCases.map(\.rawValue),
                       ["features", "apiAndModels", "hotkeys", "permissions", "notes", "agentMode", "toolbox",
                        "notifications", "integrations", "backup", "other"])
        XCTAssertEqual(SettingsWindowTab.availableCases.count, 10)
    }

    func testFeaturesLinkOpensTheFeaturesTab() throws {
        let url = try XCTUnwrap(URL(string: "whytap://settings/features"))
        XCTAssertEqual(WhytapLink.request(for: url), .show(.settings(.tab(.features))))
        XCTAssertEqual(WhytapLink.destination(for: HoverTool.settings), .settings(.tab(.features)))
    }

    func testARowWithoutItsOwnScreenOpensItsPresentPlace() {
        let selection = SettingsWindowSelection()
        selection.open(.agent)
        XCTAssertEqual(selection.selectedTab, .other)
        XCTAssertEqual(selection.highlightedTarget, .tab(.agentMode), "The Agent group is marked for a moment")

        selection.open(.meetings)
        XCTAssertEqual(selection.selectedTab, .other)

        selection.open(.translateSubtitles)
        XCTAssertEqual(selection.selectedTab, .toolbox)
        XCTAssertEqual(selection.focusedTool, .translate)

        selection.open(.screenshots)
        XCTAssertEqual(selection.focusedTool, .screenshot)
    }

    func testSidebarFeaturesRowReturnsToTheList() {
        let selection = SettingsWindowSelection()
        selection.shownFeature = .drop
        selection.select(.hotkeys)
        XCTAssertEqual(selection.shownFeature, .drop, "Leaving and coming back by a link keeps the screen")
        selection.select(.features)
        XCTAssertNil(selection.shownFeature)
    }

    // MARK: - Rows

    func testRowAccessibilitySaysStatusReasonAndWhatTheFeatureDoes() async throws {
        let snapshot = try await fixture(.freshInstall).snapshot
        let info = FeatureCatalog.info(for: .drop)
        let value = FeatureListRow.accessibilityValue(info: info, status: FeatureCatalog.status(for: .drop, snapshot: snapshot))
        XCTAssertTrue(value.hasPrefix("Needs setup. No speech-to-text model +2. Dictation."), value)
        let unused = FeatureListRow.accessibilityValue(info: FeatureCatalog.info(for: .screenshots),
                                                       status: FeatureCatalog.status(for: .screenshots, snapshot: snapshot))
        XCTAssertTrue(unused.hasPrefix("Not set up. Allow Screen Recording."), unused)
    }

    // MARK: - Offscreen pictures

    /// The start screen in the smallest and a larger window, both themes, a
    /// usual Mac and a fresh install. Saves review images when
    /// WHYTAP_SETTINGS_FEATURES_RENDER_DIR is set; the layout checks always run.
    func testRenderFeaturesStartScreen() async throws {
        let directory = FeaturesFixture.renderDirectory
        for (name, state) in [("usual", FeaturesFixture.State.usual), ("fresh", .freshInstall)] {
            let fixture = try await fixture(state)
            for dark in [false, true] {
                for size in [NSSize(width: 960, height: 560), NSSize(width: 1280, height: 760)] {
                    let selection = SettingsWindowSelection()
                    XCTAssertEqual(selection.selectedTab, .features)
                    let url = directory?.appendingPathComponent(
                        "features-\(name)-\(dark ? "dark" : "light")-\(Int(size.width)).png")
                    let bitmap = try FeaturesFixture.render(fixture.shell(selection: selection), size: size,
                                                            dark: dark, to: url)
                    // The content pane is drawn in the theme's own surface,
                    // not left blank.
                    let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 12, y: bitmap.pixelsHigh / 2)?
                        .usingColorSpace(.sRGB))
                    if dark { XCTAssertLessThan(pixel.redComponent, 0.35) } else { XCTAssertGreaterThan(pixel.redComponent, 0.8) }
                }
            }
        }
    }

    /// Eleven sections and the pinned footer still fit the smallest window
    /// without scrolling the sidebar.
    func testSidebarWithFeaturesFitsTheMinimumWindow() async throws {
        let fixture = try await fixture(.usual)
        let host = NSHostingView(rootView: fixture.shell(selection: SettingsWindowSelection()))
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 560)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 960, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        host.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let sidebar = try XCTUnwrap(scrollViews(in: host).first {
            let rect = $0.convert($0.bounds, to: host)
            return rect.minX < SettingsSidebarStyle.width && rect.width <= SettingsSidebarStyle.width
        })
        let document = try XCTUnwrap(sidebar.documentView)
        XCTAssertLessThanOrEqual(document.frame.height, sidebar.contentView.bounds.height + 1)
    }

    /// "Choose a model" needs a model that would work: not the selected one,
    /// not one the feature can't use, not under a refused key.
    func testAnAlternativeModelMustBeUsableUnderAWorkingKey() {
        func option(_ model: String, selected: Bool = false, state: PickerOptionState = .verified) -> PickerOption {
            PickerOption(model: model, state: state, isSelected: selected, hint: nil)
        }
        let onlyCurrent = PickerSection(account: .openRouter, title: "OpenRouter",
                                        options: [option("a", selected: true)], refreshFailed: false)
        XCTAssertFalse(FeatureSetupSnapshot.hasAlternative(in: [onlyCurrent]))
        let refused = PickerSection(account: .openRouter, title: "OpenRouter",
                                    options: [option("a", selected: true), option("b")], refreshFailed: false,
                                    keyProblem: "Key refused")
        XCTAssertFalse(FeatureSetupSnapshot.hasAlternative(in: [refused]), "same refused key cannot fix it")
        let unusable = PickerSection(account: .openRouter, title: "OpenRouter",
                                     options: [option("b", state: .notSupported(reason: "No audio"))], refreshFailed: false)
        XCTAssertFalse(FeatureSetupSnapshot.hasAlternative(in: [unusable]))
        let other = PickerSection(account: .openRouter, title: "OpenRouter",
                                  options: [option("b", state: .new)], refreshFailed: false)
        XCTAssertTrue(FeatureSetupSnapshot.hasAlternative(in: [refused, other]))
        let server = PickerSection(account: .server(UUID()), title: "My server", options: [], refreshFailed: false,
                                   acceptsModelName: true)
        XCTAssertTrue(FeatureSetupSnapshot.hasAlternative(in: [server]))
    }
}
