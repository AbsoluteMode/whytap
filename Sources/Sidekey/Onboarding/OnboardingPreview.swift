import AppKit
import CoreText
import FluidAudio
import Foundation

/// The whole onboarding as a standalone window, outside Whytap, to look at
/// after each change (`scripts/onboarding-preview.sh`).
///
/// Isolated from the app: its settings live in their own defaults suite,
/// emptied at every start and quit (never `com.rootwise.sidekey`); keys stay
/// in memory (no Keychain); key checks, catalogs, model probes and the Tavily
/// check are answered here without a network request; a word in the key
/// picks the answer ("bad": refused, "credit": out of credit, "noaccess": no
/// speech access, "offline": no answer; shorter than 16 characters fails the
/// shape check before any request); Allow only pretends macOS granted it; the speech model
/// "download" is a timer; Try Drop has a Simulate button. No hotkeys, event
/// taps, stores or island are started.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
public enum OnboardingPreview {
    private static var session: OnboardingPreviewSession?
    private static var controller: OnboardingJourneyWindowController?

    /// `resources` is the checkout's Resources folder: its fonts and provider
    /// logos stand in for the app bundle's.
    public static func run(resources: URL?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = menu()
        if let resources {
            registerFonts(in: resources.appendingPathComponent("Fonts", isDirectory: true))
            ProviderBrandIconAsset.setResourceDirectoryForTesting(resources.appendingPathComponent("UsefulLinkIcons", isDirectory: true))
        }
        let session = OnboardingPreviewSession()
        let controller = OnboardingJourneyWindowController(model: session.model) {
            session.clear()
            NSApp.terminate(nil)
        }
        self.session = session
        self.controller = controller
        controller.show()
        app.run()
    }

    private static func registerFonts(in directory: URL) {
        for name in ["InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
            let url = directory.appendingPathComponent("\(name).ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Quit, and Edit so ⌘V pastes into the key fields.
    private static func menu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Onboarding Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

/// The isolated stores and fakes behind one preview run.
@MainActor
final class OnboardingPreviewSession {
    static let suiteName = "ai.whytap.onboarding-preview"

    let model: OnboardingJourneyModel
    private let defaults: UserDefaults
    private let suiteName: String
    private let directory: URL

    /// Granted permissions, as the fake system reports them.
    private final class System {
        var accessibility = false
        var microphone = false
        var screen = false
        weak var permissions: PermissionsSettingsViewModel?

        var snapshot: PermissionsHelper.Snapshot {
            .init(accessibilityGranted: accessibility, microphoneStatus: microphone ? .authorized : .notDetermined)
        }

        /// macOS "answers" a moment later, so Waiting for macOS shows.
        @MainActor func grant(_ change: @escaping (System) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                change(self)
                self.permissions?.refresh(restartRecoveryPolling: false)
            }
        }
    }

    init(suiteName: String = OnboardingPreviewSession.suiteName) {
        self.suiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("whytap-onboarding-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = directory.appendingPathComponent("catalogs.json")
        try? Data("{}".utf8).write(to: catalogURL)

        let tokens = OnboardingPreviewTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { OnboardingPreviewTokenStore(account: $0, box: tokens) })
        let routing = AIRoutingStore(defaults: defaults)
        let providers = OnboardingPreviewProviders()
        let speechModel = OnboardingPreviewSpeechModel()
        let readiness = OnDeviceSpeechReadiness { speechModel.isPresent }
        let models = APIAndModelsViewModel(
            routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: providers),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            keyChecker: providers, probe: providers, endpoints: providers, inputLanguage: { nil }, onDevice: readiness)

        let system = System()
        let permissions = PermissionsSettingsViewModel(
            onComplete: {}, autoComplete: false,
            snapshotProvider: { system.snapshot }, screenRecordingAccessProvider: { system.screen },
            screenRecordingRequester: {}, accessibilityRequester: { system.grant { $0.accessibility = true } },
            openAccessibilitySettings: { system.grant { $0.accessibility = true } },
            openScreenRecordingSettings: {}, runtimeRefresh: { _, _ in })
        system.permissions = permissions
        let screenRecording = ScreenRecordingAccess(isGranted: { system.screen },
                                                    request: { await MainActor.run { system.grant { $0.screen = true } } })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingPreviewURLProtocol.self]
        let tavily = TavilySettings(keys: keys, search: TavilySearch(http: NativeAgentHTTP(session: URLSession(configuration: configuration))))

        model = OnboardingJourneyModel(
            models: models, permissions: permissions,
            onDevice: OnDeviceSpeechModelController(store: speechModel),
            dropSpeech: OnboardingDropSpeech(routing: routing, keys: keys, onDevice: readiness, mode: { .fast }),
            preferences: PrivacyPreferences(defaults: defaults),
            screenRecording: screenRecording,
            openScreenRecordingSettings: { system.grant { $0.screen = true } },
            defaultsChanges: NotificationCenter(),
            tavily: tavily,
            hotkeys: HotkeyPreferences(defaults: defaults),
            toolbox: HoverLayoutStore(defaults: defaults),
            agentEnabled: { UserPreferencesCache(defaults: defaults).currentAgentEnabled },
            requests: OnboardingPermissionRequests(
                keyboard: { system.grant { $0.accessibility = true } },
                microphone: { system.grant { $0.microphone = true } },
                inputMonitoring: { system.grant { _ in } }),
            isPreview: true)
    }

    /// Nothing of the run stays behind.
    func clear() {
        model.stop()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Keys of one preview run, in memory only.
final class OnboardingPreviewTokenStore: TokenStore, @unchecked Sendable {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func with<T>(_ body: (inout [String: String]) -> T) -> T { lock.withLock { body(&values) } }
    }

    private let account: String
    private let box: Box

    init(account: String, box: Box) {
        self.account = account
        self.box = box
    }

    func save(_ token: String) throws { box.with { $0[account] = token } }
    func read() throws -> String? { box.with { $0[account] } }
    func delete() throws { box.with { $0[account] = nil } }
}

/// Offline answers for key checks, catalogs, probes and OpenRouter endpoints.
struct OnboardingPreviewProviders: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
    static func refuses(_ key: String?) -> Bool { key?.lowercased().contains("bad") == true }

    static func answer(_ key: String?) -> KeyStatus {
        let key = key?.lowercased() ?? ""
        if key.contains("bad") { return .rejected(.invalidKey) }
        if key.contains("credit") { return .rejected(.outOfCredit) }
        if key.contains("noaccess") { return .rejected(.missingSpeechPermission) }
        if key.contains("offline") { return .unreachable }
        return .valid
    }

    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        func model(_ id: String, daysAgo: Double) -> CatalogModel {
            var model = CatalogModel(id: id, uses: [.chat, .chatWithTools], contextLength: 400_000, supportsTools: true)
            model.catalogDate = Date().addingTimeInterval(-daysAgo * 86_400)
            return model
        }
        switch account.kind {
        case .anthropic: return [model(ModelRegistry.anthropicAgentModel, daysAgo: 30)]
        case .openAI: return [model("gpt-5.6", daysAgo: 10), model("gpt-5.5", daysAgo: 90)]
        default: return []
        }
    }

    func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
        try? await Task.sleep(nanoseconds: 700_000_000)
        return Self.answer(apiKey)
    }

    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
}

/// The speech model "download": a short timer, nothing on disk.
final class OnboardingPreviewSpeechModel: OnDeviceSpeechModelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var present = false
    var isPresent: Bool { lock.withLock { present } }

    func status() async -> OnDeviceSpeechModelStatus { isPresent ? .ready : .notDownloaded }

    func download(progress: (@Sendable (Double) -> Void)?) async throws {
        for step in 1...24 {
            try await Task.sleep(nanoseconds: 110_000_000)
            progress?(Double(step) / 24)
        }
        lock.withLock { present = true }
    }

    func delete() async throws { lock.withLock { present = false } }
    func acquire() async throws -> AsrManager { throw OnDeviceSpeechError.modelNotDownloaded }
    func release() async {}
}

/// Answers every request of the preview's own URLSession locally: the
/// Tavily usage check passes, or is refused for a key containing "bad".
final class OnboardingPreviewURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let refused = OnboardingPreviewProviders.refuses(request.value(forHTTPHeaderField: "Authorization"))
        let body = Data((refused ? #"{"detail":{"error":"Unauthorized: invalid API key"}}"# : "{}").utf8)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://preview.invalid")!,
                                       statusCode: refused ? 401 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
