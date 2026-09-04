// Sources/Sidekey/Settings/SettingsModelsViewModel.swift
import Foundation

/// Abstracts the "can we reach the provider with this key/config" check so the
/// view model is testable without a network call.
protocol BYOKConnectionProbing {
    func probe() async -> Bool
}

enum BYOKConnectionStatus: Equatable {
    case idle
    case testing
    case ok
    case failed(String)
}

/// Presentation-only grouping for the "Smart processing LLM" segmented control.
/// The control shows two segments to match the STT control; the two BYOK
/// routes (`LLMIsolationLevel.yourKey` OpenRouter + `.custom` endpoint) collapse
/// into a single "Your key" segment whose sub-choice selects the concrete route.
enum LLMTopLevel: Hashable {
    case yourKey
    case local
}

@MainActor
final class SettingsModelsViewModel: ObservableObject {
    @Published var level: TranscriptionIsolationLevel
    @Published var provider: BYOKProvider
    @Published var selfHostedBaseURL: String
    @Published var selfHostedModel: String
    /// Selected realtime model for the current provider (picker value). For
    /// `selfHosted` the free-text `selfHostedModel` is used instead.
    @Published var selectedModel: String
    @Published var apiKeyInput: String
    @Published private(set) var connectionStatus: BYOKConnectionStatus = .idle
    @Published private(set) var approvedLevel: TranscriptionIsolationLevel
    @Published private(set) var localModelStatus: LocalTranscriptionModelStatus = .checking

    /// LLM route for smart text processing. `.yourKey` means direct OpenRouter
    /// with the user's key; `.custom` means a user-hosted OpenAI-compatible endpoint.
    @Published var llmLevel: LLMIsolationLevel
    /// Which BYOK sub-route the "Your key" segment last presented (`.yourKey` =
    /// OpenRouter, `.custom` = custom endpoint). The top segment merges both into
    /// one "Your key" tab; this remembers the user's pick so toggling away and
    /// back restores it. Hydrated from the persisted `llmLevel` (a stored
    /// `.custom` route reopens on Custom). WHY: three-segment Models parity.
    @Published private(set) var yourKeyLLMVariant: LLMIsolationLevel
    /// Editable OpenRouter model id. The UI suggests remote models, but any
    /// text is accepted so newly released models can be used immediately.
    @Published var openRouterModel: String
    @Published var openRouterAPIKeyInput: String
    @Published var customLLMBaseURL: String
    @Published var customLLMModel: String
    @Published var customLLMAPIKeyInput: String
    @Published private(set) var llmConnectionStatus: BYOKConnectionStatus = .idle
    /// Committed/active LLM level (persisted). Mirrors `approvedLevel` on the STT
    /// side; `.local` means the on-device LLM is currently connected.
    @Published private(set) var approvedLLMLevel: LLMIsolationLevel
    @Published private(set) var openRouterModels: [OpenRouterModelOption]
    @Published private(set) var customLLMModels: [OpenRouterModelOption]
    /// On-device MLX LLM download/readiness state (ROO-257). Mirrors
    /// `localModelStatus` for the STT local model.
    @Published private(set) var localLLMStatus: LocalLLMModelStatus = .checking

    /// Models offered in the picker for the current provider (empty for
    /// self-hosted, which is free-text).
    var models: [String] { provider.availableTranscriptionModels }

    var hasPendingLevelChange: Bool { level != approvedLevel }
    /// On-device STT is the active (committed) transcription provider.
    var isLocalConnected: Bool { approvedLevel == .local }
    /// On-device LLM is the active (committed) smart-processing provider.
    var isLocalLLMConnected: Bool { approvedLLMLevel == .local }

    private var prefs: SelfKeyPreferences
    private let keyStore: BYOKKeyStore
    /// (provider, apiKey, baseURL?, model) -> provider reachability probe.
    private let makeProbe: (BYOKProvider, String, String?, String) -> BYOKConnectionProbing
    private let localModelStore: any LocalTranscriptionModelManaging
    private let localLLMStore: any LocalLLMModelManaging
    private let llmKeyStore: any OpenRouterLLMKeyStoring
    private let customLLMKeyStore: any OpenRouterLLMKeyStoring
    private let openRouterClient: any OpenRouterLLMClienting
    /// Apple-Silicon capability gate (ROO-257 Stage 6). The on-device model
    /// stack (MLX LLM + FluidAudio diarizer/Parakeet) is Apple-Silicon-only;
    /// since the app ships a universal binary, this is a RUNTIME probe, not a
    /// compile-time `#if arch`. Injectable so tests can simulate Intel.
    private let isAppleSilicon: @MainActor () -> Bool

    /// BYOK ("Your key") is always available.
    var canUseYourKey: Bool { true }
    /// Local models are Apple-Silicon-only — the Core ML models do not run on
    /// Intel.
    var canUseLocal: Bool { isAppleSilicon() }
    /// A custom OpenAI-compatible LLM endpoint is always available.
    var canUseCustomLLM: Bool { true }
    /// The on-device LLM is Apple-Silicon-only — MLX requires Apple Silicon.
    var canUseLocalLLM: Bool { isAppleSilicon() }

    /// `true` when the local stack is blocked by hardware (Intel), so the UI
    /// can explain why "Local" is disabled. Drives the Apple-Silicon hint in
    /// the settings view.
    var localBlockedByHardware: Bool { !isAppleSilicon() }

    private static let customLLMModelFallback: [OpenRouterModelOption] = [
        OpenRouterModelOption(id: SelfKeyPreferences.defaultCustomLLMModel, name: "Custom model"),
    ]

    init(
        prefs: SelfKeyPreferences = .shared,
        keyStore: BYOKKeyStore = BYOKKeyStore(),
        llmKeyStore: any OpenRouterLLMKeyStoring = OpenRouterLLMKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = CustomLLMKeyStore(),
        openRouterClient: any OpenRouterLLMClienting = OpenRouterLLMClient(),
        localModelStore: any LocalTranscriptionModelManaging = LocalTranscriptionModelStore.shared,
        localLLMStore: any LocalLLMModelManaging = LocalLLMModelStore.shared,
        makeProbe: @escaping (BYOKProvider, String, String?, String) -> BYOKConnectionProbing = { provider, key, baseURL, model in
            BYOKProviderConnectionProbe(provider: provider, apiKey: key, baseURL: baseURL, model: model)
        },
        isAppleSilicon: @escaping @MainActor () -> Bool = { LocalModelSupport.isAppleSilicon }
    ) {
        self.prefs = prefs
        self.keyStore = keyStore
        self.llmKeyStore = llmKeyStore
        self.customLLMKeyStore = customLLMKeyStore
        self.openRouterClient = openRouterClient
        self.localModelStore = localModelStore
        self.localLLMStore = localLLMStore
        self.makeProbe = makeProbe
        self.isAppleSilicon = isAppleSilicon
        self.level = prefs.transcriptionLevel
        self.approvedLevel = prefs.transcriptionLevel
        self.provider = prefs.selectedProvider
        self.selfHostedBaseURL = prefs.selfHostedBaseURL ?? ""
        self.selfHostedModel = prefs.selfHostedModel
        self.selectedModel = prefs.transcriptionModel(for: prefs.selectedProvider)
        self.apiKeyInput = (try? keyStore.read(for: prefs.selectedProvider)) ?? ""
        self.llmLevel = prefs.llmLevel
        self.approvedLLMLevel = prefs.llmLevel
        // Remember the last BYOK sub-route so the merged "Your key" segment can
        // restore it. A persisted `.custom` route reopens on Custom; everything
        // else defaults the sub-choice to OpenRouter.
        self.yourKeyLLMVariant = prefs.llmLevel == .custom ? .custom : .yourKey
        self.openRouterModel = prefs.openRouterModel
        self.openRouterAPIKeyInput = (try? llmKeyStore.read()) ?? ""
        self.customLLMBaseURL = prefs.customLLMBaseURL ?? ""
        self.customLLMModel = prefs.customLLMModel
        self.customLLMAPIKeyInput = (try? customLLMKeyStore.read()) ?? ""
        self.openRouterModels = OpenRouterModelOption.fallback
        self.customLLMModels = Self.customLLMModelFallback
    }

    func selectLevel(_ level: TranscriptionIsolationLevel) {
        guard self.level != level else { return }
        // Hardware gate: the on-device model stack needs Apple Silicon. Surface
        // the reason and keep the selection on BYOK (nothing persisted).
        if let gateMessage = hardwareGateMessage(for: level) {
            self.level = .yourKey
            connectionStatus = .failed(gateMessage)
            return
        }
        self.level = level
        connectionStatus = .idle
        if level == .local {
            Task { await refreshLocalModelStatus() }
        }
    }

    func saveCurrentSelection() async {
        // Hardware gate (defence-in-depth): even if `level` ended up on a gated
        // value, the save never persists it.
        if let gateMessage = hardwareGateMessage(for: level) {
            level = .yourKey
            connectionStatus = .failed(gateMessage)
            return
        }
        switch level {
        case .yourKey:
            guard await validateBYOKConnection() else { return }
            persistSettings(committedLevel: .yourKey)
            approvedLevel = .yourKey
            connectionStatus = .ok
        case .local:
            guard await localModelStore.isModelReady() else {
                localModelStatus = .notDownloaded
                connectionStatus = .failed(LocalModelMessaging.modelNotDownloaded)
                return
            }
            persistSettings(committedLevel: .local)
            approvedLevel = .local
            localModelStatus = .ready
            connectionStatus = .ok
        }
    }

    func refreshLocalModelStatus() async {
        localModelStatus = await localModelStore.localModelStatus()
    }

    func watchLocalModelStatus() async {
        while !Task.isCancelled {
            await refreshLocalModelStatus()
            guard localModelStatus.isDownloading else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func downloadLocalModel() async {
        connectionStatus = .idle
        localModelStatus = await localModelStore.localModelStatus()
        if !localModelStatus.isDownloading {
            localModelStatus = .downloading(0)
        }
        do {
            try await localModelStore.downloadModel { [weak self] fraction in
                Task { @MainActor in
                    self?.localModelStatus = .downloading(fraction)
                }
            }
            localModelStatus = await localModelStore.localModelStatus()
        } catch {
            localModelStatus = await localModelStore.localModelStatus()
            connectionStatus = .failed(Self.downloadFailureMessage(for: error))
        }
    }

    func deleteLocalModel() async {
        do {
            try await localModelStore.deleteModel()
            localModelStatus = .notDownloaded
            connectionStatus = .idle
            if approvedLevel == .local || level == .local {
                level = .yourKey
                persistSettings(committedLevel: .yourKey)
                approvedLevel = .yourKey
            }
        } catch {
            localModelStatus = .failed("Delete failed")
            connectionStatus = .failed("Delete failed")
        }
    }

    /// Disconnect the on-device STT model: revert the active level to BYOK but
    /// keep the picker on `.local` so the card stays visible (the button flips
    /// back to "Connect"). One-tap toggle, no extra confirmation.
    func disconnectLocal() {
        persistSettings(committedLevel: .yourKey)
        approvedLevel = .yourKey
        connectionStatus = .idle
    }

    /// Gate copy for a blocked level, else `nil`. `.local` requires Apple
    /// Silicon; `.yourKey` is always allowed.
    private func hardwareGateMessage(for level: TranscriptionIsolationLevel) -> String? {
        switch level {
        case .yourKey: return nil
        case .local: return canUseLocal ? nil : LocalModelMessaging.requiresAppleSilicon
        }
    }

    /// The merged top-segment value for the current concrete `llmLevel`. Both
    /// BYOK routes (`.yourKey` / `.custom`) map to `.yourKey`.
    var llmTopLevel: LLMTopLevel {
        switch llmLevel {
        case .yourKey, .custom: return .yourKey
        case .local: return .local
        }
    }

    /// `true` when neither BYOK sub-route is available, so the merged "Your
    /// key" top segment should be disabled. Both are always available today.
    var isYourKeyLLMTopGated: Bool { !(canUseYourKey || canUseCustomLLM) }

    /// Pick the merged top segment. `.local` maps straight to the concrete
    /// level; `.yourKey` resolves to the remembered BYOK sub-route (OpenRouter
    /// by default, Custom if the user last used it).
    func selectLLMTopLevel(_ top: LLMTopLevel) {
        switch top {
        case .local:
            selectLLMLevel(.local)
        case .yourKey:
            selectLLMLevel(yourKeyLLMVariant)
        }
    }

    /// Pick the BYOK sub-route inside the "Your key" segment and remember it so
    /// re-entering the segment restores this choice. `variant` must be `.yourKey`
    /// or `.custom`; other values are ignored (the segment never produces them).
    func selectYourKeyLLMVariant(_ variant: LLMIsolationLevel) {
        guard variant == .yourKey || variant == .custom else { return }
        yourKeyLLMVariant = variant
        selectLLMLevel(variant)
    }

    func selectLLMLevel(_ level: LLMIsolationLevel) {
        // Keep the remembered BYOK sub-route in sync whenever a concrete BYOK
        // route is chosen by any path (segment, sub-control, or restore).
        if level == .yourKey || level == .custom { yourKeyLLMVariant = level }
        guard llmLevel != level else { return }
        if let gateMessage = llmHardwareGateMessage(for: level) {
            llmLevel = .yourKey
            llmConnectionStatus = .failed(gateMessage)
            return
        }
        llmLevel = level
        llmConnectionStatus = .idle
        if level == .local {
            Task { await refreshLocalLLMStatus() }
        }
    }

    func saveCurrentLLMSelection() async {
        if let gateMessage = llmHardwareGateMessage(for: llmLevel) {
            llmLevel = .yourKey
            llmConnectionStatus = .failed(gateMessage)
            return
        }
        switch llmLevel {
        case .yourKey:
            guard await validateOpenRouterConnection() else { return }
            persistLLMSettings(committedLevel: .yourKey)
            approvedLLMLevel = .yourKey
            llmConnectionStatus = .ok
        case .custom:
            guard await validateCustomLLMConnection() else { return }
            persistLLMSettings(committedLevel: .custom)
            approvedLLMLevel = .custom
            llmConnectionStatus = .ok
        case .local:
            guard await localLLMStore.isModelReady() else {
                localLLMStatus = .notDownloaded
                llmConnectionStatus = .failed(LocalModelMessaging.modelNotDownloaded)
                return
            }
            persistLLMSettings(committedLevel: .local)
            approvedLLMLevel = .local
            localLLMStatus = .ready
            llmConnectionStatus = .ok
        }
    }

    /// Disconnect the on-device LLM: revert the active level to OpenRouter BYOK
    /// but keep the picker on `.local` so the card stays visible (the button
    /// flips back to "Connect"). One-tap toggle, no extra confirmation.
    func disconnectLLM() {
        persistLLMSettings(committedLevel: .yourKey)
        approvedLLMLevel = .yourKey
        llmConnectionStatus = .idle
    }

    func saveLLM() {
        persistLLMSettings(committedLevel: prefs.llmLevel)
    }

    func testLLMConnection() async {
        switch llmLevel {
        case .yourKey:
            _ = await validateOpenRouterConnection()
        case .custom:
            _ = await validateCustomLLMConnection()
        case .local:
            await refreshLocalLLMStatus()
        }
    }

    // MARK: - Local LLM model lifecycle (mirrors the STT local model)

    func refreshLocalLLMStatus() async {
        localLLMStatus = await localLLMStore.localModelStatus()
    }

    func watchLocalLLMStatus() async {
        while !Task.isCancelled {
            await refreshLocalLLMStatus()
            guard localLLMStatus.isDownloading else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func downloadLocalLLMModel() async {
        llmConnectionStatus = .idle
        localLLMStatus = await localLLMStore.localModelStatus()
        if !localLLMStatus.isDownloading {
            localLLMStatus = .downloading(0)
        }
        do {
            try await localLLMStore.downloadModel { [weak self] fraction in
                Task { @MainActor in
                    self?.localLLMStatus = .downloading(fraction)
                }
            }
            localLLMStatus = await localLLMStore.localModelStatus()
        } catch {
            localLLMStatus = await localLLMStore.localModelStatus()
            llmConnectionStatus = .failed(Self.downloadFailureMessage(for: error))
        }
    }

    /// Map a model-download failure to user copy. An offline error gets the
    /// unified "you're offline" message shared with Drop/meetings; any other
    /// failure falls back to a generic message. Note that once downloaded,
    /// inference runs fully offline — only the one-time fetch needs the network.
    static func downloadFailureMessage(for error: Error) -> String {
        if isOfflineError(error) {
            return LocalModelMessaging.offlineCannotDownload
        }
        return "Download failed"
    }

    private static func isOfflineError(_ error: Error) -> Bool {
        let urlError = (error as? URLError) ?? (error as NSError).underlyingURLError
        switch urlError?.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotConnectToHost, .cannotFindHost, .dataNotAllowed,
             .timedOut:
            return true
        default:
            return false
        }
    }

    func deleteLocalLLMModel() async {
        do {
            try await localLLMStore.deleteModel()
            localLLMStatus = .notDownloaded
            llmConnectionStatus = .idle
            if prefs.llmLevel == .local || llmLevel == .local {
                llmLevel = .yourKey
                persistLLMSettings(committedLevel: .yourKey)
                approvedLLMLevel = .yourKey
            }
        } catch {
            localLLMStatus = .failed("Delete failed")
            llmConnectionStatus = .failed("Delete failed")
        }
    }

    func loadOpenRouterModelsIfNeeded() async {
        guard openRouterModels == OpenRouterModelOption.fallback else { return }
        await refreshOpenRouterModels(silent: true)
    }

    func refreshOpenRouterModels() async {
        await refreshOpenRouterModels(silent: false)
    }

    func loadCustomLLMModelsIfNeeded() async {
        guard customLLMModels == Self.customLLMModelFallback else { return }
        await refreshCustomLLMModels(silent: true)
    }

    func refreshCustomLLMModels() async {
        await refreshCustomLLMModels(silent: false)
    }

    var openRouterModelSuggestions: [OpenRouterModelOption] {
        Self.filteredOpenRouterModels(query: openRouterModel, models: openRouterModels, limit: .max)
    }

    var customLLMModelSuggestions: [OpenRouterModelOption] {
        Self.filteredOpenRouterModels(query: customLLMModel, models: customLLMModels, limit: .max)
    }

    static func filteredOpenRouterModels(
        query: String,
        models: [OpenRouterModelOption],
        limit: Int
    ) -> [OpenRouterModelOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = models.isEmpty ? OpenRouterModelOption.fallback : models
        let selected: [OpenRouterModelOption]
        if trimmed.isEmpty {
            selected = Array(pool.prefix(limit))
        } else if let exact = pool.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            let remaining = pool.filter { $0.id != exact.id }
            selected = [exact] + Array(remaining.prefix(max(0, limit - 1)))
        } else {
            let q = trimmed.lowercased()
            let scored = pool.compactMap { option -> (Int, OpenRouterModelOption)? in
                let id = option.id.lowercased()
                let name = option.name.lowercased()
                if id == q { return (0, option) }
                if id.hasPrefix(q) { return (1, option) }
                if name.hasPrefix(q) { return (2, option) }
                if id.contains(q) { return (3, option) }
                if name.contains(q) { return (4, option) }
                return nil
            }
            selected = scored
                .sorted { lhs, rhs in
                    lhs.0 == rhs.0 ? lhs.1.id < rhs.1.id : lhs.0 < rhs.0
                }
                .prefix(limit)
                .map(\.1)
        }

        guard !trimmed.isEmpty, !selected.contains(where: { $0.id == trimmed }) else {
            return selected
        }
        return [OpenRouterModelOption(id: trimmed, name: "Custom model")] + selected
    }

    /// Reload the key + model fields when the provider selection changes.
    func providerChanged() {
        apiKeyInput = (try? keyStore.read(for: provider)) ?? ""
        selectedModel = prefs.transcriptionModel(for: provider)
        connectionStatus = .idle
    }

    func save() {
        persistSettings(committedLevel: approvedLevel)
    }

    private func persistSettings(committedLevel: TranscriptionIsolationLevel) {
        prefs.transcriptionLevel = committedLevel
        prefs.selectedProvider = provider
        let trimmedBaseURL = selfHostedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSelfHostedModel = selfHostedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.selfHostedBaseURL = trimmedBaseURL.isEmpty ? nil : trimmedBaseURL
        prefs.selfHostedModel = trimmedSelfHostedModel.isEmpty ? SelfKeyPreferences.defaultModel : trimmedSelfHostedModel
        // Self-hosted persists via `selfHostedModel` above; every other provider
        // stores its picker selection per-provider.
        if provider != .selfHosted { prefs.setTranscriptionModel(selectedModel, for: provider) }
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try? keyStore.delete(for: provider) }
        else { try? keyStore.save(key: trimmed, for: provider) }
    }

    private func persistLLMSettings(committedLevel: LLMIsolationLevel) {
        prefs.llmLevel = committedLevel
        prefs.openRouterModel = openRouterModel
        prefs.customLLMBaseURL = customLLMBaseURL
        prefs.customLLMModel = customLLMModel
        let trimmed = openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { try? llmKeyStore.save(key: trimmed) }
        let trimmedCustomKey = customLLMAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustomKey.isEmpty { try? customLLMKeyStore.save(key: trimmedCustomKey) }
    }

    func testConnection() async {
        _ = await validateBYOKConnection()
    }

    private func validateBYOKConnection() async -> Bool {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setConnectionFailure("Enter an API key")
            return false
        }
        let trimmedBaseURL = selfHostedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .selfHosted, trimmedBaseURL.isEmpty {
            setConnectionFailure("Enter a base URL")
            return false
        }
        connectionStatus = .testing
        let baseURL = provider == .selfHosted ? trimmedBaseURL : nil
        let rawModel = provider == .selfHosted ? selfHostedModel : selectedModel
        let trimmedModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = trimmedModel.isEmpty ? SelfKeyPreferences.defaultModel : trimmedModel
        let ok = await makeProbe(provider, key, baseURL, model).probe()
        if ok {
            connectionStatus = .ok
        } else {
            setConnectionFailure("Could not reach provider")
        }
        return ok
    }

    private func validateOpenRouterConnection() async -> Bool {
        let key = openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            llmConnectionStatus = .failed("Enter an OpenRouter API key")
            return false
        }
        let model = openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            llmConnectionStatus = .failed("Enter an OpenRouter model ID")
            return false
        }
        llmConnectionStatus = .testing
        do {
            let models = try await openRouterClient.listModels(apiKey: key)
            mergeOpenRouterModels(models)
            llmConnectionStatus = .ok
            return true
        } catch {
            llmConnectionStatus = .failed("Could not reach OpenRouter")
            return false
        }
    }

    private func validateCustomLLMConnection() async -> Bool {
        let rawBaseURL = customLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBaseURL.isEmpty else {
            llmConnectionStatus = .failed("Enter a custom LLM Base URL")
            return false
        }
        guard let baseURL = Self.normalizedCustomLLMBaseURL(rawBaseURL) else {
            llmConnectionStatus = .failed("Enter a valid Base URL")
            return false
        }
        let model = customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            llmConnectionStatus = .failed("Enter a custom LLM model ID")
            return false
        }

        llmConnectionStatus = .testing
        do {
            let key = customLLMAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = OpenAICompatibleLLMEndpoint.custom(
                baseURL: baseURL,
                apiKey: key.isEmpty ? nil : key
            )
            let models = try await openRouterClient.listModels(endpoint: endpoint)
            mergeCustomLLMModels(models)
            llmConnectionStatus = .ok
            return true
        } catch {
            llmConnectionStatus = .failed("Could not reach custom LLM")
            return false
        }
    }

    private func refreshOpenRouterModels(silent: Bool) async {
        do {
            let key = openRouterAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let models = try await openRouterClient.listModels(apiKey: key.isEmpty ? nil : key)
            mergeOpenRouterModels(models)
        } catch {
            if !silent {
                llmConnectionStatus = .failed("Could not load models")
            }
        }
    }

    private func refreshCustomLLMModels(silent: Bool) async {
        let rawBaseURL = customLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = Self.normalizedCustomLLMBaseURL(rawBaseURL) else {
            if !silent {
                llmConnectionStatus = rawBaseURL.isEmpty
                    ? .failed("Enter a custom LLM Base URL")
                    : .failed("Enter a valid Base URL")
            }
            return
        }

        do {
            let key = customLLMAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = OpenAICompatibleLLMEndpoint.custom(
                baseURL: baseURL,
                apiKey: key.isEmpty ? nil : key
            )
            let models = try await openRouterClient.listModels(endpoint: endpoint)
            mergeCustomLLMModels(models)
        } catch {
            if !silent {
                llmConnectionStatus = .failed("Could not load models")
            }
        }
    }

    private func mergeOpenRouterModels(_ models: [OpenRouterModelOption]) {
        guard !models.isEmpty else { return }
        var seen = Set<String>()
        let merged = (models + OpenRouterModelOption.fallback).filter { option in
            guard !seen.contains(option.id) else { return false }
            seen.insert(option.id)
            return true
        }
        openRouterModels = merged
    }

    private func mergeCustomLLMModels(_ models: [OpenRouterModelOption]) {
        guard !models.isEmpty else { return }
        var seen = Set<String>()
        let merged = (models + Self.customLLMModelFallback).filter { option in
            guard !seen.contains(option.id) else { return false }
            seen.insert(option.id)
            return true
        }
        customLLMModels = merged
    }

    private func setConnectionFailure(_ message: String) {
        connectionStatus = .failed(message)
    }

    private func llmHardwareGateMessage(for level: LLMIsolationLevel) -> String? {
        switch level {
        case .yourKey, .custom:
            return nil
        case .local:
            return canUseLocalLLM ? nil : LocalModelMessaging.requiresAppleSilicon
        }
    }

    private static func normalizedCustomLLMBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            return nil
        }
        return url
    }
}

/// Production provider-aware probe used before a BYOK isolation-level change is
/// approved. Provider protocols differ: OpenAI has an immediate server frame;
/// Deepgram/ElevenLabs/Soniox may stay quiet until audio, so a short open
/// socket with no provider error is treated as a successful key/config check.
struct BYOKProviderConnectionProbe: BYOKConnectionProbing {
    let provider: BYOKProvider
    let apiKey: String
    let baseURL: String?
    let model: String

    func probe() async -> Bool {
        switch provider {
        case .openAI, .selfHosted:
            return await OpenAIRealtimeProbe(apiKey: apiKey, baseURL: baseURL, model: model).probe()
        case .deepgram:
            var request = URLRequest(url: DeepgramRealtimeURL.make(model: model, language: nil, terms: []))
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
            return await BYOKWebSocketProbe(request: request).probe()
        case .soniox:
            let request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
            let config: [String: Any] = [
                "api_key": apiKey,
                "model": model,
                "audio_format": "pcm_s16le",
                "sample_rate": 16_000,
                "num_channels": 1,
                "enable_endpoint_detection": false,
            ]
            let data = try? JSONSerialization.data(withJSONObject: config)
            let initialText = data.map { String(decoding: $0, as: UTF8.self) }
            return await BYOKWebSocketProbe(request: request, initialText: initialText).probe()
        case .elevenLabs:
            var request = URLRequest(url: ElevenLabsRealtimeURL.make(model: model, language: nil, terms: []))
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            return await BYOKWebSocketProbe(request: request).probe()
        }
    }
}

private struct BYOKWebSocketProbe: BYOKConnectionProbing {
    let request: URLRequest
    var initialText: String?
    var timeoutNanoseconds: UInt64 = 3_000_000_000

    func probe() async -> Bool {
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        if let initialText {
            do {
                try await task.send(.string(initialText))
            } catch {
                return false
            }
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        return !Self.isProviderError(text)
                    case .data:
                        return true
                    @unknown default:
                        return false
                    }
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func isProviderError(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return text.localizedCaseInsensitiveContains("error")
        }
        if let type = obj["type"] as? String, type.localizedCaseInsensitiveContains("error") {
            return true
        }
        if let messageType = obj["message_type"] as? String,
           messageType.localizedCaseInsensitiveContains("error") {
            return true
        }
        return obj["error"] != nil
    }
}

/// Production connection probe: opens the realtime WebSocket and reads the
/// first server frame. OpenAI sends `session.created` immediately on connect;
/// an auth/endpoint failure surfaces as a receive error or an `error` event.
/// Raced against a timeout so the check ALWAYS resolves (never hangs the UI).
/// `model` is unused here — connectivity + auth are validated by the handshake
/// alone, before any transcription config is sent.
struct OpenAIRealtimeProbe: BYOKConnectionProbing {
    let apiKey: String
    let baseURL: String?
    let model: String

    func probe() async -> Bool {
        var request = URLRequest(url: BYOKRealtimeURL.openAIRealtime(baseURL: baseURL))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let message = try await task.receive()
                    if case .string(let s) = message,
                       let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                       (obj["type"] as? String) == "error" {
                        return false
                    }
                    return true  // any non-error frame (e.g. session.created) → reachable
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return false  // timeout → unreachable
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
