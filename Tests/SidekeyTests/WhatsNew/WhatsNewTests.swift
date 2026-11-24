import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// What a person sees after an update, by scenario. No window opens: the
/// presenter's `display` is replaced, and pictures are drawn offscreen.
/// WHY: .project-docs/decisions/2026-11-24-whats-new-window.md
@MainActor
final class WhatsNewTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suite = "WhatsNewTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    private func item(_ title: String) -> WhatsNewItem { WhatsNewItem(title: title, body: "What it does now.") }

    private func release(_ version: String, _ titles: String...) -> WhatsNewRelease {
        WhatsNewRelease(version: version, items: titles.map(item))
    }

    /// 2.2.26 and 2.2.28 changed something for the person, 2.2.27 was
    /// internal only, 2.2.29 is not out yet.
    private var catalog: WhatsNewCatalog {
        WhatsNewCatalog(releases: [release("2.2.26", "History pastes several rows"), release("2.2.27"),
                                   release("2.2.28", "Calendar is open", "Models in two picks"),
                                   release("2.2.29", "Not released")])
    }

    /// One launch of `version`; returns what the window was asked to show.
    private func launch(_ version: String, firstLaunch: Bool = false,
                        catalog: WhatsNewCatalog? = nil) -> WhatsNewPresenter.Request? {
        let presenter = WhatsNewPresenter(catalog: catalog ?? self.catalog, currentVersion: version)
        var shown: WhatsNewPresenter.Request?
        presenter.display = { shown = $0 }
        presenter.presentAfterLaunch(isFirstLaunch: firstLaunch, defaults: defaults)
        return shown
    }

    // MARK: - Scenarios

    func testAnUpdateWithChangesShowsThemOnceWithoutTakingTheKeyboard() throws {
        XCTAssertNil(launch("2.2.27"), "2.2.27 has nothing for the person")
        let shown = try XCTUnwrap(launch("2.2.28"))
        XCTAssertEqual(shown.releases.map(\.version), ["2.2.28"])
        XCTAssertEqual(shown.releases.first?.items.map(\.title), ["Calendar is open", "Models in two picks"])
        XCTAssertFalse(shown.activates, "after an update the window does not take the keyboard")
        XCTAssertNil(launch("2.2.28"), "the next launch of the same version shows nothing")
        XCTAssertNil(launch("2.2.28"))
    }

    func testAnUpdateWithNothingForThePersonShowsNothing() {
        XCTAssertNil(launch("2.2.26", firstLaunch: true))
        XCTAssertNil(launch("2.2.27"), "internal changes only")
        XCTAssertEqual(defaults.string(forKey: WhatsNewLaunch.seenVersionKey), "2.2.27", "and the version is remembered")
        XCTAssertNil(launch("2.2.27"))
    }

    func testAFirstInstallShowsNothingAndTheNextUpdateDoes() throws {
        XCTAssertNil(launch("2.2.28", firstLaunch: true), "a new Mac gets the onboarding")
        XCTAssertNil(launch("2.2.28", firstLaunch: true), "the onboarding continued after a relaunch")
        XCTAssertNil(launch("2.2.28"), "the same version after the onboarding")
        XCTAssertEqual(try XCTUnwrap(launch("2.2.29")).releases.map(\.version), ["2.2.29"])
    }

    func testSkippedVersionsAreListedNewestFirstWithTheVersionThePersonHad() throws {
        XCTAssertNil(launch("2.2.25"))
        let shown = try XCTUnwrap(launch("2.2.28"))
        XCTAssertEqual(shown.releases.map(\.version), ["2.2.28", "2.2.26"],
                       "the internal 2.2.27 and the unreleased 2.2.29 are left out")
        XCTAssertEqual(shown.since, "2.2.25")
        XCTAssertNil(launch("2.2.28"))
    }

    func testAMacFromBeforeThisWindowSeesTheRunningVersionOnly() throws {
        // Updated from a version that remembered nothing: no way to know
        // how far back it was, so only the running version is listed.
        let shown = try XCTUnwrap(launch("2.2.28"))
        XCTAssertEqual(shown.releases.map(\.version), ["2.2.28"])
        XCTAssertNil(shown.since)
        defaults.removeObject(forKey: WhatsNewLaunch.seenVersionKey)
        XCTAssertNil(launch("2.2.27"), "nothing remembered and nothing for this version")
    }

    func testARollbackShowsNothing() {
        XCTAssertNotNil(launch("2.2.28"))
        XCTAssertNil(launch("2.2.26"), "an older build after a newer one")
        XCTAssertNil(launch("0.0.0-dev"), "a developer build")
    }

    func testABuildWithoutNotesOrWithDamagedNotesShowsNothing() throws {
        XCTAssertNil(launch("2.2.25", catalog: .empty))
        XCTAssertNil(launch("2.2.28", catalog: .empty), "no list in the build: silent")
        XCTAssertEqual(defaults.string(forKey: WhatsNewLaunch.seenVersionKey), "2.2.28")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try XCTUnwrap(Bundle(path: folder.path))
        XCTAssertEqual(WhatsNewCatalog.bundled(in: bundle), .empty, "no file")
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("WhatsNew.json"))
        XCTAssertEqual(WhatsNewCatalog.bundled(in: bundle), .empty, "a damaged file")
        XCTAssertNil(WhatsNewCatalog.decode(Data(#"{"releases":[{"version":"1.0"}]}"#.utf8)), "a release without its items")

        let presenter = WhatsNewPresenter(catalog: .empty, currentVersion: "2.2.28")
        presenter.display = { _ in XCTFail("nothing to show") }
        presenter.presentHistory()
        XCTAssertTrue(presenter.history.isEmpty)
    }

    func testSettingsOpensTheListWithEarlierReleasesAndTakesTheKeyboard() throws {
        let presenter = WhatsNewPresenter(catalog: catalog, currentVersion: "2.2.28")
        var shown: WhatsNewPresenter.Request?
        presenter.display = { shown = $0 }
        presenter.presentHistory()
        let request = try XCTUnwrap(shown)
        XCTAssertEqual(request.releases.map(\.version), ["2.2.28", "2.2.26"])
        XCTAssertTrue(request.activates)
        XCTAssertNil(defaults.string(forKey: WhatsNewLaunch.seenVersionKey), "looking at the list remembers nothing")
    }

    func testVersionsCompareByTheirNumbers() {
        XCTAssertLessThan(WhatsNewVersion("2.2.9"), WhatsNewVersion("2.2.27"))
        XCTAssertLessThan(WhatsNewVersion("2.2.27"), WhatsNewVersion("2.3"))
        XCTAssertEqual(WhatsNewVersion("2.3"), WhatsNewVersion("2.3.0"))
        XCTAssertLessThan(WhatsNewVersion("0.0.0-dev"), WhatsNewVersion("0.0.1"))
        XCTAssertEqual(WhatsNewVersion("Unknown version"), WhatsNewVersion("0"))
    }

    // MARK: - The bundled list

    /// The list that ships: short, in plain words, and every clip, symbol
    /// and Settings link it names exists in this build.
    func testTheBundledListFitsTheWindowAndNamesRealThings() throws {
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("WhatsNew.json"))
        let catalog = try XCTUnwrap(WhatsNewCatalog.decode(data))
        XCTAssertFalse(catalog.releases.isEmpty)
        XCTAssertEqual(Set(catalog.releases.map(\.version)).count, catalog.releases.count, "one entry per version")
        let videos = try XCTUnwrap(Bundle(url: Self.resources))
        for release in catalog.releases {
            XCTAssertLessThanOrEqual(release.items.count, WhatsNewCatalog.maxItems, release.version)
            XCTAssertFalse(WhatsNewVersion(release.version).parts.isEmpty, release.version)
            for item in release.items {
                XCTAssertFalse(item.title.isEmpty)
                XCTAssertLessThanOrEqual(item.title.count, WhatsNewCatalog.maxTitleLength, item.title)
                XCTAssertLessThanOrEqual(item.body.count, WhatsNewCatalog.maxBodyLength, item.title)
                XCTAssertFalse(item.title.contains("#") || item.body.contains("PR "), "written for a person: \(item.title)")
                if let symbol = item.symbol {
                    XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
                }
                if let video = item.video {
                    XCTAssertNotNil(try XCTUnwrap(item.featureVideo, video).url(in: videos), "\(video) is bundled")
                }
                if let link = item.link {
                    XCTAssertTrue(try XCTUnwrap(link.tab, link.settings).isAvailable, link.settings)
                    XCTAssertFalse(link.title.isEmpty)
                }
            }
        }
        let script = try String(contentsOf: Self.resources.deletingLastPathComponent()
            .appendingPathComponent("scripts/whats-new.py"), encoding: .utf8)
        for limit in ["MAX_ITEMS = \(WhatsNewCatalog.maxItems)", "MAX_TITLE = \(WhatsNewCatalog.maxTitleLength)",
                      "MAX_BODY = \(WhatsNewCatalog.maxBodyLength)"] {
            XCTAssertTrue(script.contains(limit), "the release check has the same limit: \(limit)")
        }
    }

    /// Both packaging scripts copy the list into the app, and the launch
    /// asks after the onboarding decision.
    func testTheListIsPackagedAndAskedForAtLaunch() throws {
        let root = Self.resources.deletingLastPathComponent()
        for script in ["scripts/build-dmg.sh", "scripts/dev-run.sh"] {
            let text = try String(contentsOf: root.appendingPathComponent(script), encoding: .utf8)
            XCTAssertTrue(text.contains("Resources/WhatsNew.json"), script)
        }
        let delegate = try String(contentsOf: root.appendingPathComponent("Sources/Sidekey/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(delegate.contains("WhatsNewPresenter.shared.presentAfterLaunch(isFirstLaunch: opensOnboarding, defaults: .standard)"))
        let release = try String(contentsOf: root.appendingPathComponent("scripts/user-release.sh"), encoding: .utf8)
        XCTAssertTrue(release.contains("whats-new.py\" check \"$SHORT_VERSION\""), "a release without its entry does not start")
    }

    // MARK: - The window, offscreen

    func testTheWindowFitsOneReleaseAndScrollsMany() throws {
        try useRepositoryResources()
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("WhatsNew.json"))
        let bundled = try XCTUnwrap(WhatsNewCatalog.decode(data))
        for release in bundled.releases where !release.items.isEmpty {
            let request = WhatsNewPresenter.Request(releases: [release], since: nil, activates: false)
            XCTAssertLessThanOrEqual(WhatsNewWindowController.naturalHeight(of: request), WhatsNewView.maxHeight,
                                     "\(release.version) shows whole, without scrolling")
        }
        let many = (1...6).map { release("3.0.\($0)", "One", "Two", "Three", "Four", "Five") }
        let long = WhatsNewPresenter.Request(releases: many, since: "3.0.0", activates: false)
        XCTAssertGreaterThan(WhatsNewWindowController.naturalHeight(of: long), WhatsNewView.maxHeight)
        var closed = false
        let controller = WhatsNewWindowController(request: long, onLink: { _ in }, onClosed: { closed = true })
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height,
                       WhatsNewWindowController.height(natural: 5_000, screen: NSScreen.main?.visibleFrame.height), accuracy: 1)
        XCTAssertEqual(WhatsNewWindowController.height(natural: 500, screen: 900), 500, "as tall as its list")
        XCTAssertEqual(WhatsNewWindowController.height(natural: 5_000, screen: 1_200), WhatsNewView.maxHeight)
        XCTAssertEqual(WhatsNewWindowController.height(natural: 5_000, screen: 700), 640, "a small screen keeps a margin")
        XCTAssertFalse(window.isVisible, "building the window shows nothing")
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        controller.close()
        XCTAssertTrue(closed)
    }

    func testTheVersionInSettingsIsAButtonOnlyWithSomethingToShow() {
        func cursorViews(in view: NSView) -> Int {
            let own = String(reflecting: type(of: view)).hasSuffix("SettingsFooterLinkCursor.CursorView")
                && !view.bounds.isEmpty ? 1 : 0
            return own + view.subviews.reduce(0) { $0 + cursorViews(in: $1) }
        }
        func links(_ presenter: WhatsNewPresenter?) -> Int {
            let host = NSHostingView(rootView: SettingsProjectFooter(identity: .current, whatsNew: presenter))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            return cursorViews(in: host)
        }
        XCTAssertEqual(links(nil), 2, "the Whytap and GitHub links")
        XCTAssertEqual(links(WhatsNewPresenter(catalog: .empty, currentVersion: "2.2.28")), 2, "no notes: plain text")
        XCTAssertEqual(links(WhatsNewPresenter(catalog: catalog, currentVersion: "2.2.28")), 3, "the version opens the list")
    }

    private func useRepositoryResources() throws {
        for font in ["InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
            CTFontManagerRegisterFontsForURL(Self.resources.appendingPathComponent("Fonts/\(font).ttf") as CFURL, .process, nil)
        }
        let saved = FeatureVideo.resourceBundle
        FeatureVideo.resourceBundle = try XCTUnwrap(Bundle(url: Self.resources))
        addTeardownBlock { FeatureVideo.resourceBundle = saved }
    }

    /// Offscreen pictures for review, written only when
    /// `WHYTAP_WHATSNEW_RENDER_DIR` is set: the shipped 2.2.27 list and a
    /// jump over several releases, light and dark, with the window's shape
    /// drawn around the content.
    func testRenderReviewPictures() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_WHATSNEW_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_WHATSNEW_RENDER_DIR to save offscreen review images")
        }
        try useRepositoryResources()
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: Self.resources.appendingPathComponent("WhatsNew.json"))
        let bundled = try XCTUnwrap(WhatsNewCatalog.decode(data))
        let current = try XCTUnwrap(bundled.releases.first { $0.version == "2.2.27" })
        let skipped = [
            WhatsNewRelease(version: "2.2.28", items: [
                WhatsNewItem(title: "What’s new after every update",
                             body: "This window: a short list of what changed for you, once per update.",
                             symbol: "sparkles"),
            ]),
            current,
            WhatsNewRelease(version: "2.2.26", items: [
                WhatsNewItem(title: "Dictation on this Mac",
                             body: "Drop can run without a key: one downloaded speech model, nothing leaves the Mac.",
                             symbol: "desktopcomputer"),
                WhatsNewItem(title: "Update from Settings",
                             body: "An update you closed in the island stays one click away next to the version.",
                             symbol: "arrow.down.circle"),
            ]),
        ]
        var plain = current.items
        plain[0].video = nil
        let cases: [(String, WhatsNewPresenter.Request)] = [
            ("2.2.27", .init(releases: [current], since: nil, activates: false)),
            ("2.2.27-no-clip", .init(releases: [WhatsNewRelease(version: current.version, items: plain)],
                                     since: nil, activates: false)),
            ("skipped-2.2.25-to-2.2.28", .init(releases: skipped, since: "2.2.25", activates: false)),
        ]
        for (name, request) in cases {
            let natural = WhatsNewWindowController.naturalHeight(of: request)
            let size = NSSize(width: WhatsNewView.width, height: min(natural, WhatsNewView.maxHeight))
            for dark in [false, true] {
                let content = WhatsNewView(releases: request.releases, since: request.since,
                                           scrolls: natural > WhatsNewView.maxHeight, playsVideo: false)
                    .frame(width: size.width, height: size.height)
                try await render(content, size: size, dark: dark,
                                 to: directory.appendingPathComponent("whats-new-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func render<V: View>(_ content: V, size: NSSize, dark: Bool, to url: URL) async throws {
        let margin: CGFloat = 48
        let framed = content
            .overlay(alignment: .topLeading) {
                // The window's own close button, drawn for the picture.
                Circle().fill(Color(red: 1, green: 0.376, blue: 0.345)).frame(width: 12, height: 12).padding(.leading, 10).padding(.top, 9)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.55 : 0.22), radius: 22, x: 0, y: 12)
            .padding(margin)
            .background(dark ? Color(white: 0.09) : Color(white: 0.84))
            .environment(\.colorScheme, dark ? .dark : .light)
        let full = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let host = NSHostingView(rootView: framed)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: full)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: full.width, height: full.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        // The clip's still frame loads off the main thread.
        try await Task.sleep(for: .milliseconds(1_200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
    }
}
