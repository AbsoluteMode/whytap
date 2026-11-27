import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Review images of the real Settings shell. No app launch, real credentials,
/// permission requests, capture, or network; routing and mutable fixture stores are temporary.
@MainActor
final class NativeSettingsRenderTests: XCTestCase {
    func testExistingWindowFollowsAppearanceWithoutRebuildingRoot() throws {
        let root = SidekeyAuroraWindow(title: "Settings", followsSystemAppearance: true) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for dark in [false, true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let pixel = try XCTUnwrap(bitmap.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))
            if dark { XCTAssertLessThan(pixel.redComponent, 0.3) }
            else { XCTAssertGreaterThan(pixel.redComponent, 0.8) }
        }
        XCTAssertFalse(window.isVisible)
    }

    private struct Offline: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] { [] }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
    }

    func testRenderSettingsInBothAppearances() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_NATIVE_SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_NATIVE_SETTINGS_RENDER_DIR to save offscreen review images")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "NativeSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: catalogURL) }
        try Data("{}".utf8).write(to: catalogURL)
        let offline = Offline()
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("fixture-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: routing)))
        let models = APIAndModelsViewModel(routing: routing,
            keys: keys,
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: offline),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            keyChecker: offline, probe: offline, endpoints: offline, inputLanguage: { "ru" })
        let permissions = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false)
        for dark in [false, true] {
            for width in [960.0, 1280.0] {
                for tab in [SettingsWindowTab.other, .apiAndModels] {
                    let selection = SettingsWindowSelection(selectedTab: tab)
                    let shell = SettingsWindowView(permissionsViewModel: permissions, apiAndModelsViewModel: models,
                        selection: selection,
                        otherVolumeDuckConfig: VolumeDuckConfig(defaults: defaults),
                        otherMeetingsEnabled: { true }, privacyPreferences: PrivacyPreferences(defaults: defaults))
                    try render(shell, size: NSSize(width: width, height: width == 960 ? 560 : 760), dark: dark,
                               to: directory.appendingPathComponent("\(tab.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
            let controls = VStack(alignment: .leading, spacing: 18) {
                MacGroupTitle(title: "Переключатели · Switches")
                MacCard {
                    MacRow(title: "Meeting Notes", subtitle: "Detect calls, record, and summarize.") {
                        MacSwitch(isOn: .constant(true), label: "Meeting Notes")
                    }
                    MacRowSeparator()
                    MacRow(title: "Защита снимков экрана", subtitle: "Длинное пояснение переносится и остаётся читаемым в обеих темах.") {
                        MacSwitch(isOn: .constant(false), label: "Защита снимков экрана")
                    }
                    MacRowSeparator()
                    MacRow(title: "Unavailable", subtitle: "Disabled controls retain their current state.") {
                        MacSwitch(isOn: .constant(true), isEnabled: false)
                    }
                }
                MacField(placeholder: "API key", text: .constant(""))
                MacPopup(items: [.init(value: 0, label: "Automatic — Main display")], selection: .constant(0))
                MacSegmented(items: [.init(value: 0, label: "Your key"), .init(value: 1, label: "Server")], selection: .constant(0))
                MacButton(title: "Save & connect", style: .primary, action: {})
            }.padding(24).background(MacSettingsTheme.bgContent)
            try render(controls, size: NSSize(width: 520, height: 440), dark: dark,
                       to: directory.appendingPathComponent("controls-\(dark ? "dark" : "light").png"))
            try render(APIHintsView(onAddKey: {}, onClose: {}), size: NSSize(width: 700, height: 700), dark: dark,
                       to: directory.appendingPathComponent("api-hints-\(dark ? "dark" : "light").png"))
            let note = MeetingProtocol(name: "План обновления", description: "Новая тема настроек и проверка доступности.",
                tasks: [MeetingTask(id: "fixture", task: "Проверить светлую тему", assignee: "Maxim", deadline: "Friday", comment: "Проверить переключатели и клавиатуру")],
                decisions: [MeetingProtocolItem(id: "decision", text: "Следовать теме macOS", comment: nil)],
                other: [], sectionHeaders: ["Задачи", "Решения"])
            try render(MeetingProtocolView(note: note).background(MacSettingsTheme.bgContent),
                       size: NSSize(width: 700, height: 560), dark: dark,
                       to: directory.appendingPathComponent("meeting-protocol-\(dark ? "dark" : "light").png"))
            let blocks = MeetingNoteMarkdownParser.parse("# Meeting notes\n\nA readable paragraph in both appearances.\n\n- Проверить переключатели\n- [x] Светлая тема\n\n---\n\n## Transcription\n\nSpeaker: A long sentence remains readable.")
            try render(MeetingNoteView(blocks: blocks).background(MacSettingsTheme.bgContent),
                       size: NSSize(width: 700, height: 560), dark: dark,
                       to: directory.appendingPathComponent("meeting-note-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        host.layoutSubtreeIfNeeded()
        if view is SettingsWindowView {
            XCTAssertEqual(host.bounds.height, size.height, "Settings must not silently grow beyond the requested window size")
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            let sidebar = try XCTUnwrap(scrollViews(in: host).first {
                let rect = $0.convert($0.bounds, to: host)
                return rect.minX < SettingsSidebarStyle.width && rect.width <= SettingsSidebarStyle.width
            })
            let document = try XCTUnwrap(sidebar.documentView)
            XCTAssertLessThanOrEqual(document.frame.height, sidebar.contentView.bounds.height + 1,
                                     "Every Settings section must fit without scrolling, including at minimum height")
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testRenderScreenshotPermissionStates() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_NATIVE_SETTINGS_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_NATIVE_SETTINGS_RENDER_DIR to save offscreen review images")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states = [
            (name: "allowed", keyboard: true, microphone: true, screen: true),
            (name: "not-allowed", keyboard: false, microphone: false, screen: false),
            (name: "mixed", keyboard: true, microphone: false, screen: true)
        ]
        for state in states {
            let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
                snapshotProvider: { .init(accessibilityGranted: state.keyboard, microphoneStatus: state.microphone ? .authorized : .denied) },
                screenRecordingAccessProvider: { state.screen }, screenRecordingRequester: {},
                runtimeRefresh: { _, _ in })
            for dark in [false, true] {
                // Content widths in the existing 960 pt minimum and 1280 pt Settings shell.
                for width in [739.0, 1059.0] {
                    try render(SettingsPermissionsView(viewModel: model).background(MacSettingsTheme.bgContent),
                               size: NSSize(width: width, height: 560), dark: dark,
                               to: directory.appendingPathComponent("permissions-\(state.name)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
    }
}
