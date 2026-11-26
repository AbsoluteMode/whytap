import AppKit
import AVFoundation
import FluidAudio
import SwiftUI
import XCTest
@testable import Sidekey

/// A Mac in a chosen state for the Features screens: temporary routing and
/// key stores, fixed permissions, a frozen on-device model status. No real
/// credentials, permission requests, downloads or network.
@MainActor
struct FeaturesFixture {
    enum State {
        /// First launch on Apple Silicon: no key, no model, nothing allowed.
        case freshInstall
        /// The same, on an Intel Mac that cannot run the local model.
        case freshIntel
        /// Dictation works on the local model; the Agent is on without a model;
        /// Google search is on; Meeting Notes are off.
        case usual
    }

    private struct NoModel: Error {}

    private actor FixedStore: OnDeviceSpeechModelManaging {
        let fixed: OnDeviceSpeechModelStatus
        init(_ status: OnDeviceSpeechModelStatus) { fixed = status }
        func status() -> OnDeviceSpeechModelStatus { fixed }
        func download(progress: (@Sendable (Double) -> Void)?) async throws {}
        func delete() async throws {}
        func acquire() async throws -> AsrManager { throw NoModel() }
        func release() {}
    }

    private struct Offline: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] { [] }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
    }

    let defaults: UserDefaults
    let routing: AIRoutingStore
    let models: APIAndModelsViewModel
    let permissions: PermissionsSettingsViewModel
    let agent: AgentModeViewModel
    let hotkeys: HotkeyPreferences
    let environment: FeaturesEnvironment
    /// Hover, Notify and Monitor read only these: a layout in the test's own
    /// defaults, Notify and Monitor folders in a temporary directory, and a
    /// clipboard that is a box, never the user's pasteboard.
    let hoverStore: HoverLayoutStore
    let notifySupervisor: NotifyScriptSupervisor
    let monitor: MonitorStore
    let files: URL
    let clipboard = CopiedText()
    private let suite: String
    private let previousShortcut: DropHotkeyStatus
    private let catalogURL: URL

    init(_ state: State, dropMode: TranscriptionMode = .fast,
         onDevice status: OnDeviceSpeechModelStatus? = nil) async throws {
        suite = "Features-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        try Data("{}".utf8).write(to: catalogURL)
        let offline = Offline()
        routing = AIRoutingStore(defaults: defaults)
        let keyStatuses = KeyStatusStore(defaults: defaults)
        let usual = state == .usual
        let modelStatus = status ?? (usual ? .ready : .notDownloaded)
        if usual {
            let local = ModelRegistry.onDeviceSpeechModel
            for feature in [AIFeature.dropFast, .voiceSearch] {
                routing.setRoute(FeatureRoute(account: .thisMac, model: local), for: feature)
            }
            keyStatuses.set(.valid, for: .thisMac, at: Date())
        }
        let box = InMemoryTokenStore.Box()
        models = APIAndModelsViewModel(
            routing: routing,
            keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) }),
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: offline),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: keyStatuses,
            keyChecker: offline, probe: offline, endpoints: offline, inputLanguage: { nil },
            onDevice: modelStatus == .ready ? .ready : .unavailable)

        // The view model copies the shortcut status when it is made.
        // It also follows later changes, so the shared value is put back only
        // in `cleanUp`.
        previousShortcut = AppState.shared.dropHotkeyStatus
        AppState.shared.dropHotkeyStatus = usual ? .ready : .accessibilityRequired
        permissions = PermissionsSettingsViewModel(
            onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: usual, microphoneStatus: usual ? .authorized : .notDetermined) },
            screenRecordingAccessProvider: { false },
            screenRecordingRequester: {},
            accessibilityRequester: {},
            openAccessibilitySettings: {},
            usesProtectionOverridePane: { false },
            openScreenRecordingSettings: {},
            launchGrants: .init(snapshot: .init(accessibilityGranted: usual,
                                                microphoneStatus: usual ? .authorized : .notDetermined),
                                screenRecording: false),
            openInputMonitoringSettings: {},
            relaunch: { nil },
            runtimeRefresh: { _, _ in })

        agent = AgentModeViewModel(store: AgentProviderStore(defaults: defaults),
                                   probe: { _ in .notInstalled }, notify: { _ in })
        hotkeys = HotkeyPreferences(defaults: defaults)
        let controller = OnDeviceSpeechModelController(store: FixedStore(modelStatus))
        await controller.refresh()
        files = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let notifyRoot = files.appendingPathComponent("notifications", isDirectory: true)
        let hub = LocalNotificationHub(directory: notifyRoot)
        hub.setSuspended(true)
        hoverStore = HoverLayoutStore(defaults: defaults)
        notifySupervisor = NotifyScriptSupervisor(directory: notifyRoot, hub: hub)
        monitor = MonitorStore(root: files.appendingPathComponent("Monitor", isDirectory: true),
                               collector: { _ in throw CancellationError() })
        let clipboard = clipboard
        environment = FeaturesEnvironment(
            dropMode: { dropMode },
            volumeDuck: VolumeDuckConfig(defaults: defaults),
            autoStop: DropAutoStopPreferences(defaults: defaults),
            agentOn: { usual }, meetingsOn: { false }, googleOn: { usual },
            supportsOnDevice: state != .freshIntel,
            onDevice: controller,
            hotkeys: hotkeys,
            hoverStore: hoverStore,
            notifySupervisor: notifySupervisor,
            meetingNotifications: MeetingReadyNotifications(defaults: defaults, hub: hub),
            notificationSounds: NotificationSoundSettings(defaults: defaults),
            monitor: monitor,
            notifyRoot: notifyRoot,
            copyText: { clipboard.texts.append($0) })
    }

    func cleanUp() {
        AppState.shared.dropHotkeyStatus = previousShortcut
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: catalogURL)
        notifySupervisor.stop()
        try? FileManager.default.removeItem(at: files)
    }

    var snapshot: FeatureSetupSnapshot {
        .live(models: models, permissions: permissions, environment: environment)
    }

    /// What Copy prompt put on the clipboard, in order.
    final class CopiedText {
        var texts: [String] = []
    }

    /// The whole Settings shell on `tab`.
    /// Lil Bro's answers from whytap.ai are on by default; fixtures keep
    /// them off so no test reaches the network.
    private func offlinePreferences() -> LilBroPreferences {
        let preferences = LilBroPreferences(defaults: defaults)
        preferences.answersFromWhytap = false
        return preferences
    }

    func shell(selection: SettingsWindowSelection, lilBro: LilBroController? = nil) -> SettingsWindowView {
        SettingsWindowView(
            permissionsViewModel: permissions, apiAndModelsViewModel: models,
            selection: selection, agentModeViewModel: agent,
            otherVolumeDuckConfig: VolumeDuckConfig(defaults: defaults),
            privacyPreferences: PrivacyPreferences(defaults: defaults),
            featuresEnvironment: environment,
            lilBro: lilBro ?? LilBroController(selection: selection,
                                               preferences: offlinePreferences(),
                                               reduceMotion: { true }))
    }

    /// Draws `view` in a window that never reaches the screen and returns the
    /// hosting view with its bitmap.
    @discardableResult
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL? = nil,
                                settle: TimeInterval = 0.25,
                                file: StaticString = #filePath, line: UInt = #line) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: settle))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.height, size.height, "The view must not grow beyond the window", file: file, line: line)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), file: file, line: line)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let url {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line).write(to: url)
        }
        XCTAssertFalse(window.isVisible, file: file, line: line)
        XCTAssertFalse(window.isKeyWindow, file: file, line: line)
        return bitmap
    }

    /// Where review images go; nil when the run should not save any.
    static var renderDirectory: URL? {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_SETTINGS_FEATURES_RENDER_DIR"] else { return nil }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
