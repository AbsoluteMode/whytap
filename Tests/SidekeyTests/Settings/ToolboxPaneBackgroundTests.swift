import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Toolbox tool panes that embed an island panel used to draw it on a dark
/// card, so Vocab looked unlike Display or Drop Mode. They now sit on the
/// Settings background and follow its light or dark appearance.
// WHY: .project-docs/decisions/2026-11-20-toolbox-system-background.md
@MainActor
final class ToolboxPaneBackgroundTests: XCTestCase {
    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(path), encoding: .utf8)
    }

    func test_embedded_panes_have_no_dark_card_or_forced_dark_scheme() throws {
        let toolbox = try source("Sources/Sidekey/Settings/ToolboxSettingsView.swift")
        XCTAssertFalse(toolbox.contains("#1C1C1E"), "no pane draws its own dark card")
        XCTAssertFalse(toolbox.contains(".environment(\\.colorScheme, .dark)"))
        XCTAssertFalse(try source("Sources/Sidekey/DynamicIsland/NotifyHoverPanel.swift")
            .contains(".environment(\\.colorScheme, .dark)"))
    }

    /// A hardcoded white in a panel Settings embeds is invisible on the light
    /// Settings background. The island is unaffected: its window is dark and
    /// `IslandInk` is white there.
    func test_embedded_panels_use_the_adaptive_ink_not_hardcoded_white() throws {
        for path in [
            "Sources/Sidekey/DynamicIsland/IslandVocabularyEditorPanel.swift",
            "Sources/Sidekey/DynamicIsland/IslandFillerEditorPanel.swift",
            "Sources/Sidekey/DynamicIsland/IslandCaseVaultPanel.swift",
            "Sources/Sidekey/DynamicIsland/NotifyHoverPanel.swift",
            "Sources/Sidekey/Monitor/MonitorHoverPanel.swift",
            "Sources/Sidekey/History/HistoryHoverView.swift",
        ] {
            let text = try source(path)
            for forbidden in [".white", "NSColor(white: 1", "Color.black", "Color(red: 0.12"] {
                XCTAssertFalse(text.contains(forbidden), "\(path) still has \(forbidden)")
            }
        }
        let island = try source("Sources/Sidekey/DynamicIsland/IslandView.swift")
        let start = try XCTUnwrap(island.range(of: "struct IslandLanguagePickerPanel"))
        let end = try XCTUnwrap(island.range(of: "struct IslandDetachedHoverPanelBackground"))
        XCTAssertFalse(island[start.lowerBound..<end.lowerBound].contains("Color.white"))
    }

    /// Review finding: a notification without a link was a disabled button,
    /// and on light Settings its title fell to 3.37:1 and its body to 1.71:1.
    func test_an_unlinked_notification_is_a_static_readable_row_on_light_settings() throws {
        let notify = try source("Sources/Sidekey/DynamicIsland/NotifyHoverPanel.swift")
        XCTAssertTrue(notify.contains("if event.canActivate || colorScheme == .dark {"))
        let row = try XCTUnwrap(notify.range(of: "private func historyRow("))
        let label = try XCTUnwrap(notify.range(of: "private func historyRowLabel("))
        let body = notify[row.lowerBound..<label.lowerBound]
        XCTAssertTrue(body.contains("historyRowLabel(event)\n            }"), "the light inactive row is the bare label")
        XCTAssertTrue(body.contains("Button(\"Copy text\")"), "Copy stays on every row")
    }

    func test_the_ink_is_white_in_the_dark_island_and_dark_on_light_settings() throws {
        func resolved(_ name: NSAppearance.Name) throws -> NSColor {
            var color: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                color = IslandInk.ns.usingColorSpace(.sRGB)
            }
            return try XCTUnwrap(color)
        }
        let dark = try resolved(.darkAqua)
        XCTAssertEqual(dark.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(dark.blueComponent, 1, accuracy: 0.001)
        let light = try resolved(.aqua)
        XCTAssertLessThan(light.redComponent, 0.2)
        XCTAssertLessThan(light.greenComponent, 0.2)
    }

    /// Review images: each embedded pane on the Settings background in both
    /// appearances, plus the island's own dark look for comparison.
    func testOffscreenPaneRenders() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_TOOLBOX_PANE_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_TOOLBOX_PANE_RENDER_DIR for Toolbox pane review images")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = "ToolboxPaneBackgroundTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }

        let vocab = IslandVocabularyViewModel(vocabulary: VocabularyCache(defaults: defaults))
        for term in ["exodia", "tikhub", "sferyx", "lokate", "whytap"] {
            vocab.query = term
            await vocab.submitCurrentQuery()
        }
        let filler = IslandFillerViewModel(store: FillerTermsStore(defaults: defaults))
        for term in ["um", "you know", "like"] {
            filler.query = term
            filler.submitCurrentQuery()
        }

        // Notify and History with rows: the builder measured 1.04:1 for a
        // Notify title on light Settings while the rows kept a dark fill.
        let notifyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: notifyRoot) }
        let hub = LocalNotificationHub(directory: notifyRoot)
        let meetings = MeetingReadyNotifications(defaults: defaults, hub: hub)
        for (index, title) in ["Build finished", "Meeting notes are ready"].enumerated() {
            _ = await hub.receive(LocalNotificationEvent(
                id: "render-\(index)", source: "render", sourceName: "Render", title: title,
                body: "Synthetic body text for the review image.",
                // One row with an action and one without: both must be readable.
                link: index == 0 ? URL(string: "https://example.com/build") : nil,
                timestamp: Date(timeIntervalSinceNow: -Double(index + 1) * 600)))
        }
        let supervisor = NotifyScriptSupervisor(directory: notifyRoot, hub: hub)
        func notify(_ sources: Bool) -> AnyView {
            AnyView(NotifyHoverPanel(hub: hub, supervisor: supervisor, meetingNotifications: meetings,
                                     showsBackButton: false, showsSources: sources, onBack: {}))
        }
        let cards: [HistoryStripCard] = (1...3).map {
            .drop(.init(id: Int64($0), createdAt: Date(timeIntervalSinceNow: -Double($0) * 300),
                        formattedText: "Synthetic dictation number \($0) for the review image.", targetApp: "Notes"))
        }
        let history = AnyView(HistoryHoverView(
            mode: .constant(.drop), cards: cards, targetAppName: nil, onSelectMode: { _ in },
            onCopy: { _ in }, onPreviewAnchorChange: { _, _ in }, onPaste: { _ in },
            allowsKeyboardPaste: false))

        let panes: [(String, AnyView)] = [
            ("notify-history", notify(false)),
            ("notify-sources", notify(true)),
            ("history", history),
            ("vocab", AnyView(IslandVocabularyEditorPanel(viewModel: vocab))),
            ("filler", AnyView(IslandFillerEditorPanel(viewModel: filler))),
            ("input-language", AnyView(IslandLanguagePickerPanel(
                selectedLanguage: AppLanguage.find(code: "ru"), onSelectLanguage: { _ in }))),
        ]
        for (pane, view) in panes {
            for dark in [false, true] {
                let content = view.settingsIslandPreview()
                    .frame(width: 320, height: 188)
                    .padding(16)
                    .background(MacSettingsTheme.fieldBg)
                let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(x: 0, y: 0, width: 352, height: 220)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 352, height: 220),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                host.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("toolbox-\(pane)-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }
}
