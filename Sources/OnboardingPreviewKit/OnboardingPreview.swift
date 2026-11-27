import AppKit
import CoreText
import FluidAudio
import Foundation
// The fakes live outside the app's module: only the preview and the tests
// link this target, so no fake catalog, key check or permission can reach a
// Whytap build (the owner, REV 56).
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@testable import Sidekey

/// The whole onboarding as a standalone window, outside Whytap, to look at
/// after each change (`scripts/onboarding-preview.sh`).
///
/// Isolated from the app: its settings live in their own defaults suite,
/// emptied at every start and quit (never `com.rootwise.sidekey`); keys stay
/// in memory (no Keychain); key checks, catalogs and model probes
/// are answered here without a network request; a word in the key
/// picks the answer ("bad": refused, "credit": out of credit, "noaccess": no
/// speech access, "offline": no answer; shorter than 16 characters fails the
/// shape check before any request); the first Allow on an access step comes
/// back without the switch on (Not on yet), Allow again or Open System
/// Settings pretends macOS granted it; the speech model
/// "download" is a timer; on Try Drop, holding the person's Drop shortcut in this window
/// (Space by default) makes a pretend take (OnboardingPreviewDrop). No
/// hotkeys, event taps, stores or island are started.
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
    private let simulated: System
    /// The preview's "Ask for system audio" went to its simulation, not Core Audio.
    var askedSystemAudio: Bool { simulated.askedSystemAudio }
    private let defaults: UserDefaults
    private let suiteName: String
    private let directory: URL

    /// Granted permissions, as the fake system reports them.
    private final class System {
        var accessibility = false
        var microphone = false
        var screen = false
        /// macOS's microphone dialog was answered Don't Allow.
        var microphoneRefused = false
        weak var permissions: PermissionsSettingsViewModel?
        /// Multiplies the simulated System Settings delays (tests pass less than 1).
        var pace: Double = 1

        var snapshot: PermissionsHelper.Snapshot {
            .init(accessibilityGranted: accessibility,
                  microphoneStatus: microphone ? .authorized : microphoneRefused ? .denied : .notDetermined)
        }

        /// The person came back from System Settings (the app's own
        /// didBecomeActive check).
        var returned: () -> Void = {}
        private var asked: Set<String> = []

        /// The first ask of an access step comes back with the switch still
        /// off, so the calm Not on yet line shows; the next ask grants.
        /// "Ask for system audio" was pressed; the preview asks no hardware.
        var askedSystemAudio = false

        @MainActor func ask(_ step: String, _ change: @escaping (System) -> Void) {
            guard asked.insert(step).inserted else { return grant(change) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6 * pace) { [weak self] in
                if step == "microphone" { self?.microphoneRefused = true }
                self?.returned()
            }
        }

        /// macOS "answers" a moment later, so Waiting for macOS shows.
        @MainActor func grant(_ change: @escaping (System) -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 * pace) { [weak self] in
                guard let self else { return }
                change(self)
                self.permissions?.refresh(restartRecoveryPolling: false)
            }
        }
    }

    /// `pace` multiplies every delay the preview's fakes add so a person can
    /// watch the states (key checks, System Settings, the model download). Tests pass a small value; the order of events stays.
    init(suiteName: String = OnboardingPreviewSession.suiteName,
         dwellWait: ((TimeInterval) async -> Void)? = nil,
         pace: Double = 1) {
        self.suiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("whytap-onboarding-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = directory.appendingPathComponent("catalogs.json")
        // OpenRouter's public list is cached, as on a Mac that has opened a
        // picker: direct Anthropic and OpenAI models show its list prices.
        let cached = [ProviderAccount.openRouter.storageID:
                        CatalogSnapshot(models: OnboardingPreviewProviders.openRouter, fetchedAt: Date())]
        try? ((try? JSONEncoder().encode(cached)) ?? Data("{}".utf8)).write(to: catalogURL)

        let tokens = OnboardingPreviewTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { OnboardingPreviewTokenStore(account: $0, box: tokens) })
        let routing = AIRoutingStore(defaults: defaults)
        let providers = OnboardingPreviewProviders(pace: pace)
        let speechModel = OnboardingPreviewSpeechModel(pace: pace)
        let readiness = OnDeviceSpeechReadiness { speechModel.isPresent }
        let models = APIAndModelsViewModel(
            routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: providers),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            keyChecker: providers, probe: providers, serverModelChecker: providers, endpoints: providers,
            inputLanguage: { nil }, onDevice: readiness)

        let system = System()
        system.pace = pace
        simulated = system
        let permissions = PermissionsSettingsViewModel(
            onComplete: {}, autoComplete: false,
            snapshotProvider: { system.snapshot }, screenRecordingAccessProvider: { system.screen },
            screenRecordingRequester: {}, accessibilityRequester: { system.ask("keyboard") { $0.accessibility = true } },
            openAccessibilitySettings: { system.grant { $0.accessibility = true } },
            usesProtectionOverridePane: { false },
            openScreenRecordingSettings: {}, runtimeRefresh: { _, _ in })
        system.permissions = permissions
        let screenRecording = ScreenRecordingAccess(isGranted: { system.screen },
                                                    request: { await MainActor.run { system.ask("screen") { $0.screen = true } } })

        model = OnboardingJourneyModel(
            models: models, permissions: permissions,
            onDevice: OnDeviceSpeechModelController(store: speechModel),
            dropSpeech: OnboardingDropSpeech(routing: routing, keys: keys, onDevice: readiness, mode: { .fast }),
            supportsOnDevice: true, // The preview includes its own simulated speech download on every host.
            preferences: PrivacyPreferences(defaults: defaults),
            screenRecording: screenRecording,
            openScreenRecordingSettings: { system.grant { $0.screen = true } },
            defaultsChanges: NotificationCenter(),
            dwellWait: dwellWait,
            hotkeys: HotkeyPreferences(defaults: defaults),
            toolbox: HoverLayoutStore(defaults: defaults),
            agentEnabled: { UserPreferencesCache(defaults: defaults).currentAgentEnabled },
            requests: OnboardingPermissionRequests(
                keyboard: { system.ask("keyboard") { $0.accessibility = true } },
                microphone: { system.ask("microphone") { $0.microphone = true } },
                inputMonitoring: { system.ask("input") { _ in } },
                openSettings: { step in
                    switch step {
                    case .keyboard: system.grant { $0.accessibility = true }
                    case .microphone: system.grant { $0.microphone = true }
                    case .screenRecording: system.grant { $0.screen = true }
                    default: break
                    }
                }),
            dropStandIn: OnboardingPreviewDrop(),
            isPreview: true,
            // OpenAI speech is shown here already; the app waits for its model.
            offersOpenAISpeech: true,
            // Simulated like every other permission here: no Core Audio tap.
            systemAudioProbe: { await MainActor.run { system.askedSystemAudio = true } },
            tryQuiet: OnboardingJourneyModel.tryQuiet * pace)
        let model = self.model
        system.returned = { [weak model] in model?.recheckPermissions() }
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
struct OnboardingPreviewProviders: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching,
                                   ServerModelChecking {
    /// Multiplies the simulated answer delays (tests pass less than 1).
    var pace: Double = 1

    /// A server's model check: a name containing "bad" is refused, "offline"
    /// gets no answer, any other passes.
    func check(_ model: String, kind: ServerModel.Kind, on server: ServerEndpoint, apiKey: String?) async -> ServerModelCheckResult {
        try? await Task.sleep(for: .milliseconds(500 * pace))
        let name = model.lowercased()
        if name.contains("offline") { return .unreachable("\(server.name) didn't answer. Is it running?") }
        if name.contains("bad") { return .failed("\(server.name) has no model named \(model)") }
        return .passed
    }

    static func refuses(_ key: String?) -> Bool { key?.lowercased().contains("bad") == true }

    static func answer(_ key: String?) -> KeyStatus {
        let key = key?.lowercased() ?? ""
        if key.contains("bad") { return .rejected(.invalidKey) }
        if key.contains("credit") { return .rejected(.outOfCredit) }
        if key.contains("noaccess") { return .rejected(.missingSpeechPermission) }
        if key.contains("offline") { return .unreachable }
        return .valid
    }

    /// The providers' catalogs as they looked on 2026-11-22 (IDs, ages and
    /// OpenRouter list prices), so the key steps' model choice looks real.
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        switch account.kind {
        case .anthropic: return Self.anthropic
        case .openAI: return Self.openAI
        case .openRouter: return Self.openRouter
        default: return []
        }
    }

    private static func model(_ id: String, daysAgo: Double, uses: Set<ModelUse> = [.chat, .chatWithTools],
                              price: (Double, Double)? = nil) -> CatalogModel {
        var model = CatalogModel(id: id, uses: uses, contextLength: 400_000, supportsTools: !uses.isDisjoint(with: [.chatWithTools]))
        model.catalogDate = Date().addingTimeInterval(-daysAgo * 86_400)
        model.tokenPrice = price.flatMap {
            CatalogTokenPrice(promptPerToken: Decimal($0.0) / 1_000_000, completionPerToken: Decimal($0.1) / 1_000_000)
        }
        return model
    }

    static let anthropic = [
        model("claude-fable-5-2", daysAgo: 12), model("claude-haiku-5-5", daysAgo: 45),
        model("claude-sonnet-5-5", daysAgo: 55), model("claude-opus-5-5", daysAgo: 61),
        model("claude-fable-5-1", daysAgo: 86), model("claude-opus-4-5-20251101", daysAgo: 380),
    ]

    static let openAI = [
        model("gpt-live-1.1", daysAgo: 3), model("gpt-6.2-sol", daysAgo: 18), model("gpt-6.2-astra", daysAgo: 21),
        model("gpt-6.1-terra", daysAgo: 38), model("gpt-6.1-sol", daysAgo: 54), model("gpt-6-luna", daysAgo: 67),
        model("gpt-6-astra", daysAgo: 82), model("gpt-5.6-terra", daysAgo: 150), model("gpt-5.5-2026-04-23", daysAgo: 210),
        model("gpt-live-transcribe", daysAgo: 115, uses: [.realtimeSTT]),
        model("gpt-transcribe", daysAgo: 115, uses: [.asyncSTT, .realtimeSTT]),
        model("gpt-realtime-whisper", daysAgo: 196, uses: [.realtimeSTT]),
    ]

    static let openRouter = [
        model("anthropic/claude-fable-5.2", daysAgo: 12, price: (8, 40)),
        model("anthropic/claude-opus-5.5", daysAgo: 60, price: (4, 20)),
        model("anthropic/claude-sonnet-5.5", daysAgo: 55, price: (2, 10)),
        model("anthropic/claude-haiku-5.5", daysAgo: 45, price: (0.1, 0.5)),
        model("openai/gpt-6.2-astra", daysAgo: 3, price: (8, 40)),
        model("openai/gpt-6.2-sol", daysAgo: 3, price: (2, 10)),
        model("openai/gpt-6.1-terra", daysAgo: 25, price: (1, 5)),
        model("openai/gpt-6.1-sol", daysAgo: 52, price: (2, 10)),
        model("openai/gpt-6-luna", daysAgo: 58, price: (0.1, 0.5)),
        model("openai/gpt-6-astra", daysAgo: 77, price: (10, 50)),
        model("google/gemini-3.8-pro", daysAgo: 20, price: (2.5, 15)),
        model("google/gemini-3.8-flash", daysAgo: 20, price: (0.3, 2.5)),
        model("deepseek/deepseek-v4", daysAgo: 30, price: (0.3, 1.2)),
    ]

    func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
        try? await Task.sleep(nanoseconds: UInt64(700_000_000 * pace))
        return Self.answer(apiKey)
    }

    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
}

/// The speech model "download": a short timer, nothing on disk.
final class OnboardingPreviewSpeechModel: OnDeviceSpeechModelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var present = false
    private let pace: Double
    init(pace: Double = 1) { self.pace = pace }
    var isPresent: Bool { lock.withLock { present } }

    func status() async -> OnDeviceSpeechModelStatus { isPresent ? .ready : .notDownloaded }

    func download(progress: (@Sendable (Double) -> Void)?) async throws {
        for step in 1...24 {
            try await Task.sleep(nanoseconds: UInt64(110_000_000 * pace))
            progress?(Double(step) / 24)
        }
        lock.withLock { present = true }
    }

    func delete() async throws { lock.withLock { present = false } }
    func acquire() async throws -> AsrManager { throw OnDeviceSpeechError.modelNotDownloaded }
    func release() async {}
}
