import XCTest
import FluidAudio
import MLXLMCommon
@testable import Sidekey

@MainActor
final class SettingsModelsViewModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "models.vm.\(UUID().uuidString)")!
    }

    /// Builds a view model over isolated prefs. `isAppleSilicon` drives both
    /// the prefs defaults (a fresh install starts on the on-device level on
    /// Apple Silicon and on BYOK everywhere else) and the view model's
    /// hardware gate. Pass `transcriptionLevel` / `llmLevel` to start from a
    /// persisted route instead of the fresh-install default.
    private func makeVM(
        isAppleSilicon: Bool = true,
        transcriptionLevel: TranscriptionIsolationLevel? = nil,
        llmLevel: LLMIsolationLevel? = nil,
        probeSucceeds: Bool = true,
        keyStore: BYOKKeyStore = .inMemory(),
        llmKeyStore: any OpenRouterLLMKeyStoring = ModelsFakeOpenRouterKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = ModelsFakeOpenRouterKeyStore(),
        openRouterClient: any OpenRouterLLMClienting = ModelsFakeOpenRouterClient(),
        localModelStore: any LocalTranscriptionModelManaging = ModelsFakeLocalModelStore(),
        localLLMStore: any LocalLLMModelManaging = ModelsFakeLocalLLMStore(),
        makeProbe: ((BYOKProvider, String, String?, String) -> BYOKConnectionProbing)? = nil
    ) -> (SettingsModelsViewModel, SelfKeyPreferences) {
        let prefs = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: isAppleSilicon)
        if let transcriptionLevel { prefs.transcriptionLevel = transcriptionLevel }
        if let llmLevel { prefs.llmLevel = llmLevel }
        let probeFactory: (BYOKProvider, String, String?, String) -> BYOKConnectionProbing
        if let makeProbe {
            probeFactory = makeProbe
        } else {
            probeFactory = { _, _, _, _ in StubProbe(succeeds: probeSucceeds) }
        }
        let vm = SettingsModelsViewModel(
            prefs: prefs,
            keyStore: keyStore,
            llmKeyStore: llmKeyStore,
            customLLMKeyStore: customLLMKeyStore,
            openRouterClient: openRouterClient,
            localModelStore: localModelStore,
            localLLMStore: localLLMStore,
            makeProbe: probeFactory,
            isAppleSilicon: { isAppleSilicon }
        )
        return (vm, prefs)
    }

    /// Keys live in an in-memory store so the suite never reads, writes, or
    /// prompts for the user's real Keychain items.
    private func withInMemoryKeyStore(_ provider: BYOKProvider, _ body: (BYOKKeyStore) throws -> Void) rethrows {
        _ = provider
        try body(.inMemory())
    }

    // MARK: - Onboarding setup

    func testOnboardingPresentsBYOKWithoutChangingSavedRoutes() {
        let (vm, prefs) = makeVM()
        _ = OnboardingModelsController(models: vm)
        XCTAssertEqual(vm.level, .yourKey)
        XCTAssertEqual(vm.llmTopLevel, .yourKey)
        XCTAssertEqual(prefs.transcriptionLevel, .local)
        XCTAssertEqual(prefs.llmLevel, .local)
    }

    func testOnboardingDoesNotAdvanceWithMissingOrRejectedSpeechKey() async {
        let (vm, prefs) = makeVM(probeSucceeds: false)
        let controller = OnboardingModelsController(models: vm)
        let emptyResult = await controller.continueSetup()
        XCTAssertFalse(emptyResult)
        XCTAssertEqual(controller.stage, .speech)
        vm.apiKeyInput = "test-key"
        let rejectedResult = await controller.continueSetup()
        XCTAssertFalse(rejectedResult)
        XCTAssertEqual(controller.stage, .speech)
        XCTAssertEqual(prefs.transcriptionLevel, .local)
        XCTAssertFalse(controller.isSaving)
    }

    func testOnboardingSavesSpeechThenOptionalSmartKey() async throws {
        let speechStore = BYOKKeyStore.inMemory()
        let smartStore = ModelsFakeOpenRouterKeyStore()
        let (vm, prefs) = makeVM(keyStore: speechStore, llmKeyStore: smartStore)
        let controller = OnboardingModelsController(models: vm)
        vm.apiKeyInput = "test-speech-key"
        let speechResult = await controller.continueSetup()
        XCTAssertFalse(speechResult)
        XCTAssertEqual(controller.stage, .smart)
        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertEqual(try speechStore.read(for: .soniox), "test-speech-key")
        XCTAssertEqual(prefs.llmLevel, .local)

        let missingSmartResult = await controller.continueSetup()
        XCTAssertFalse(missingSmartResult)
        XCTAssertEqual(controller.stage, .smart)
        vm.openRouterAPIKeyInput = "test-smart-key"
        let smartResult = await controller.continueSetup()
        XCTAssertTrue(smartResult)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(smartStore.key, "test-smart-key")
    }

    func testOnboardingLocalAlternativeRequiresDownloadedModel() async {
        let store = ModelsFakeLocalModelStore()
        let (vm, prefs) = makeVM(localModelStore: store)
        let controller = OnboardingModelsController(models: vm)
        vm.selectLevel(.local)
        let missingResult = await controller.continueSetup()
        XCTAssertFalse(missingResult)
        XCTAssertEqual(controller.stage, .speech)
        await vm.downloadLocalModel()
        let readyResult = await controller.continueSetup()
        XCTAssertFalse(readyResult)
        XCTAssertEqual(controller.stage, .smart)
        XCTAssertEqual(prefs.transcriptionLevel, .local)
        controller.backToSpeech()
        XCTAssertEqual(controller.stage, .speech)
    }

    func testOnboardingLocalModelsDoNotRequireKeychainWrites() async {
        let smartStore = ModelsFakeOpenRouterKeyStore()
        smartStore.failWrites = true
        let (vm, _) = makeVM(
            keyStore: BYOKKeyStore(makeStore: { _ in ModelsFailingTokenStore() }),
            llmKeyStore: smartStore,
            localModelStore: ModelsFakeLocalModelStore(isReady: true),
            localLLMStore: ModelsFakeLocalLLMStore(isReady: true)
        )
        let controller = OnboardingModelsController(models: vm)
        vm.selectLevel(.local)
        _ = await controller.continueSetup()
        XCTAssertEqual(controller.stage, .smart)
        vm.openRouterAPIKeyInput = "unused-test-key"
        vm.selectLLMLevel(.local)
        let result = await controller.continueSetup()
        XCTAssertTrue(result)
    }

    func testOnboardingKeychainFailureDoesNotCommitSpeechRoute() async {
        let (vm, prefs) = makeVM(keyStore: BYOKKeyStore(makeStore: { _ in ModelsFailingTokenStore() }))
        let controller = OnboardingModelsController(models: vm)
        vm.apiKeyInput = "test-key"
        let result = await controller.continueSetup()
        XCTAssertFalse(result)
        XCTAssertEqual(controller.stage, .speech)
        XCTAssertEqual(prefs.transcriptionLevel, .local)
        XCTAssertEqual(vm.approvedLevel, .local)
        XCTAssertEqual(vm.connectionStatus, .failed("Could not save API key in Keychain"))
    }

    func testOnboardingKeychainFailureDoesNotCommitSmartRoute() async {
        let store = ModelsFakeOpenRouterKeyStore()
        store.failWrites = true
        let (vm, prefs) = makeVM(llmKeyStore: store)
        let controller = OnboardingModelsController(models: vm)
        vm.apiKeyInput = "test-key"
        _ = await controller.continueSetup()
        vm.openRouterAPIKeyInput = "test-smart-key"
        let result = await controller.continueSetup()
        XCTAssertFalse(result)
        XCTAssertEqual(controller.stage, .smart)
        XCTAssertEqual(prefs.llmLevel, .local)
        XCTAssertEqual(vm.approvedLLMLevel, .local)
        XCTAssertEqual(vm.llmConnectionStatus, .failed("Could not save API key in Keychain"))
    }

    // MARK: - Defaults

    func testFreshInstallDefaultsFollowHardware() {
        let (appleSilicon, _) = makeVM(isAppleSilicon: true)
        XCTAssertEqual(appleSilicon.level, .local)
        XCTAssertEqual(appleSilicon.approvedLevel, .local)
        XCTAssertEqual(appleSilicon.llmLevel, .local)
        XCTAssertEqual(appleSilicon.approvedLLMLevel, .local)
        // BYOK default is soniox now (OpenAI dropped from the picker).
        XCTAssertEqual(appleSilicon.provider, .soniox)
        XCTAssertEqual(appleSilicon.selfHostedModel, "gpt-4o-transcribe")

        let (intel, _) = makeVM(isAppleSilicon: false)
        XCTAssertEqual(intel.level, .yourKey)
        XCTAssertEqual(intel.approvedLevel, .yourKey)
        XCTAssertEqual(intel.llmLevel, .yourKey)
        XCTAssertEqual(intel.approvedLLMLevel, .yourKey)
    }

    func testSelectedModelLoadsProviderDefault() {
        let (vm, _) = makeVM()  // provider defaults to soniox
        XCTAssertEqual(vm.selectedModel, "stt-rt-v5")
    }

    func testProviderChangeLoadsThatProvidersModelAndList() {
        let (vm, _) = makeVM()
        vm.provider = .openAI
        vm.providerChanged()
        XCTAssertEqual(vm.selectedModel, "gpt-4o-transcribe")
        XCTAssertEqual(vm.models, ["gpt-4o-transcribe", "gpt-4o-mini-transcribe"])
    }

    func testSavePersistsSelectedModelPerProvider() {
        withInMemoryKeyStore(.openAI) { kc in
            let (vm, prefs) = makeVM(keyStore: kc)
            vm.provider = .openAI
            vm.selectedModel = "gpt-4o-mini-transcribe"
            vm.save()
            XCTAssertEqual(prefs.transcriptionModel(for: .openAI), "gpt-4o-mini-transcribe")
        }
    }

    // MARK: - STT level selection and save

    func testSelectingIsolationLevelDoesNotPersistUntilSaved() {
        let (vm, prefs) = makeVM()
        vm.selectLevel(.yourKey)

        XCTAssertEqual(vm.level, .yourKey)
        XCTAssertTrue(vm.hasPendingLevelChange)
        XCTAssertEqual(prefs.transcriptionLevel, .local)
    }

    func testSaveCurrentSelectionRequiresApiKeyAndKeepsLocalActive() async {
        let (vm, prefs) = makeVM()
        vm.selectLevel(.yourKey)
        vm.apiKeyInput = "   "

        await vm.saveCurrentSelection()

        XCTAssertEqual(prefs.transcriptionLevel, .local)
        XCTAssertTrue(vm.hasPendingLevelChange)
        XCTAssertEqual(vm.connectionStatus, .failed("Enter an API key"))
    }

    func testSaveCurrentSelectionRequiresSuccessfulValidation() async {
        let (vm, prefs) = makeVM(probeSucceeds: false)
        vm.selectLevel(.yourKey)
        vm.apiKeyInput = "sk-test"

        await vm.saveCurrentSelection()

        XCTAssertEqual(prefs.transcriptionLevel, .local)
        XCTAssertTrue(vm.hasPendingLevelChange)
        XCTAssertEqual(vm.connectionStatus, .failed("Could not reach provider"))
    }

    func testSaveCurrentSelectionPersistsYourKeyAfterValidation() async throws {
        let keyStore = BYOKKeyStore.inMemory()

        let (vm, prefs) = makeVM(keyStore: keyStore)
        vm.selectLevel(.yourKey)
        vm.provider = .openAI
        vm.apiKeyInput = "sk-approved"

        await vm.saveCurrentSelection()

        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertFalse(vm.hasPendingLevelChange)
        XCTAssertEqual(vm.connectionStatus, .ok)
        XCTAssertEqual(try keyStore.read(for: .openAI), "sk-approved")
    }

    func testSaveCurrentSelectionValidatesSelectedProviderAndModel() async {
        final class Capture {
            var provider: BYOKProvider?
            var model: String?
        }
        let capture = Capture()
        let keyStore = BYOKKeyStore.inMemory()

        let (vm, _) = makeVM(
            keyStore: keyStore,
            makeProbe: { provider, _, _, model in
                capture.provider = provider
                capture.model = model
                return StubProbe(succeeds: true)
            }
        )
        vm.selectLevel(.yourKey)
        vm.provider = .deepgram
        vm.selectedModel = "nova-3"
        vm.apiKeyInput = "dg-key"

        await vm.saveCurrentSelection()

        XCTAssertEqual(capture.provider, .deepgram)
        XCTAssertEqual(capture.model, "nova-3")
    }

    func testSaveKeyPersistsToKeychainAndPrefs() throws {
        try withInMemoryKeyStore(.openAI) { keyStore in
            let (vm, _) = makeVM(keyStore: keyStore)
            vm.level = .yourKey
            vm.provider = .openAI
            vm.apiKeyInput = "sk-abc"
            vm.save()
            XCTAssertEqual(try keyStore.read(for: .openAI), "sk-abc")
        }
    }

    func testTestConnectionSuccess() async {
        let (vm, _) = makeVM()
        vm.provider = .openAI
        vm.apiKeyInput = "sk-x"
        await vm.testConnection()
        XCTAssertEqual(vm.connectionStatus, .ok)
    }

    func testTestConnectionFailureWithoutKey() async {
        let (vm, _) = makeVM()
        vm.provider = .openAI
        vm.apiKeyInput = ""
        await vm.testConnection()
        if case .failed = vm.connectionStatus {} else { XCTFail("expected failed") }
    }

    // MARK: - Local STT model (on-device Parakeet)

    func testLocalLevelRequiresDownloadedModelBeforeSave() async {
        let (vm, prefs) = makeVM(transcriptionLevel: .yourKey)
        vm.selectLevel(.local)

        await vm.saveCurrentSelection()

        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertTrue(vm.hasPendingLevelChange)
        XCTAssertEqual(vm.localModelStatus, .notDownloaded)
        XCTAssertEqual(vm.connectionStatus, .failed(LocalModelMessaging.modelNotDownloaded))
    }

    func testSaveCurrentSelectionPersistsLocalWhenModelReady() async {
        let (vm, prefs) = makeVM(
            transcriptionLevel: .yourKey,
            localModelStore: ModelsFakeLocalModelStore(isReady: true)
        )
        vm.selectLevel(.local)

        await vm.saveCurrentSelection()

        XCTAssertEqual(prefs.transcriptionLevel, .local)
        XCTAssertFalse(vm.hasPendingLevelChange)
        XCTAssertEqual(vm.localModelStatus, .ready)
        XCTAssertEqual(vm.connectionStatus, .ok)
    }

    func testConnectLocalSTTMarksConnected() async {
        let (vm, _) = makeVM(
            transcriptionLevel: .yourKey,
            localModelStore: ModelsFakeLocalModelStore(isReady: true)
        )
        XCTAssertFalse(vm.isLocalConnected)
        vm.selectLevel(.local)

        await vm.saveCurrentSelection()

        XCTAssertTrue(vm.isLocalConnected)
    }

    func testDisconnectLocalSTTRevertsToYourKeyButKeepsPicker() async {
        let (vm, prefs) = makeVM(
            transcriptionLevel: .yourKey,
            localModelStore: ModelsFakeLocalModelStore(isReady: true)
        )
        vm.selectLevel(.local)
        await vm.saveCurrentSelection()
        XCTAssertTrue(vm.isLocalConnected)

        vm.disconnectLocal()

        XCTAssertFalse(vm.isLocalConnected)
        XCTAssertEqual(vm.approvedLevel, .yourKey)
        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        // Picker stays on local so the card remains visible (button flips to Connect).
        XCTAssertEqual(vm.level, .local)
    }

    func testDownloadLocalModelUpdatesReadyStatus() async {
        let store = ModelsFakeLocalModelStore(isReady: false)
        let (vm, _) = makeVM(localModelStore: store)

        await vm.downloadLocalModel()

        let downloadCalls = await store.downloadCalls
        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(vm.localModelStatus, .ready)
    }

    func testRefreshLocalModelStatusReportsInFlightDownload() async {
        let store = ModelsFakeLocalModelStore(statusOverride: .downloading(0.42))
        let (vm, _) = makeVM(localModelStore: store)

        await vm.refreshLocalModelStatus()

        XCTAssertEqual(vm.localModelStatus, .downloading(0.42))
    }

    func testDeleteLocalModelFallsBackFromActiveLocalToYourKey() async {
        let store = ModelsFakeLocalModelStore(isReady: true)
        let (vm, prefs) = makeVM(transcriptionLevel: .yourKey, localModelStore: store)
        vm.selectLevel(.local)
        await vm.saveCurrentSelection()
        XCTAssertEqual(prefs.transcriptionLevel, .local)

        await vm.deleteLocalModel()

        let deleteCalls = await store.deleteCalls
        XCTAssertEqual(deleteCalls, 1)
        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertEqual(vm.level, .yourKey)
        XCTAssertEqual(vm.approvedLevel, .yourKey)
        XCTAssertEqual(vm.localModelStatus, .notDownloaded)
    }

    // MARK: - LLM BYOK (OpenRouter)

    func testOpenRouterModelSuggestionsFilterAndKeepTypedCustomModel() {
        let models = [
            OpenRouterModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
            OpenRouterModelOption(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
            OpenRouterModelOption(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash"),
        ]

        let filtered = SettingsModelsViewModel.filteredOpenRouterModels(
            query: "claude",
            models: models,
            limit: 8
        )

        XCTAssertEqual(filtered.first, OpenRouterModelOption(id: "claude", name: "Custom model"))
        XCTAssertEqual(filtered.dropFirst().map(\.id), ["anthropic/claude-sonnet-4"])
    }

    func testOpenRouterModelSuggestionsBrowseFromSelectedModel() {
        let models = [
            OpenRouterModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
            OpenRouterModelOption(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
            OpenRouterModelOption(id: "google/gemini-3.5-pro", name: "Gemini 3.5 Pro"),
        ]

        let filtered = SettingsModelsViewModel.filteredOpenRouterModels(
            query: "openai/gpt-4o-mini",
            models: models,
            limit: 8
        )

        XCTAssertEqual(filtered.first?.id, "openai/gpt-4o-mini")
        XCTAssertTrue(filtered.contains { $0.id == "google/gemini-3.5-pro" })
    }

    func testOpenRouterFallbackSuggestionsStartWithExplicitModelNotAutoRouter() {
        let filtered = SettingsModelsViewModel.filteredOpenRouterModels(
            query: "",
            models: [],
            limit: 3
        )

        XCTAssertEqual(filtered.first?.id, "openai/gpt-4o-mini")
        XCTAssertFalse(filtered.prefix(3).contains { $0.id == "openrouter/auto" })
    }

    func testSaveCurrentLLMSelectionPersistsOpenRouterAfterValidation() async throws {
        let llmKeyStore = ModelsFakeOpenRouterKeyStore()
        let openRouter = ModelsFakeOpenRouterClient(models: [
            OpenRouterModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini")
        ])
        let (vm, prefs) = makeVM(llmKeyStore: llmKeyStore, openRouterClient: openRouter)

        vm.selectLLMLevel(.yourKey)
        vm.openRouterModel = "openai/gpt-4o-mini"
        vm.openRouterAPIKeyInput = "or-key"

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(prefs.openRouterModel, "openai/gpt-4o-mini")
        XCTAssertEqual(try llmKeyStore.read(), "or-key")
        XCTAssertEqual(vm.llmConnectionStatus, .ok)
        XCTAssertEqual(openRouter.lastListAPIKey, "or-key")
    }

    func testSaveCurrentLLMSelectionPersistsCustomEndpointAfterValidation() async throws {
        let customKeyStore = ModelsFakeOpenRouterKeyStore()
        let openRouter = ModelsFakeOpenRouterClient(models: [
            OpenRouterModelOption(id: "llama/local", name: "Llama Local")
        ])
        let (vm, prefs) = makeVM(customLLMKeyStore: customKeyStore, openRouterClient: openRouter)

        vm.selectLLMLevel(.custom)
        vm.customLLMBaseURL = " http://localhost:8000/v1 "
        vm.customLLMModel = "llama/local"
        vm.customLLMAPIKeyInput = "internal-key"

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .custom)
        XCTAssertEqual(prefs.customLLMBaseURL, "http://localhost:8000/v1")
        XCTAssertEqual(prefs.customLLMModel, "llama/local")
        XCTAssertEqual(try customKeyStore.read(), "internal-key")
        XCTAssertEqual(vm.llmConnectionStatus, .ok)
        XCTAssertEqual(openRouter.lastListEndpoint?.baseURL.absoluteString, "http://localhost:8000/v1")
        XCTAssertEqual(openRouter.lastListEndpoint?.apiKey, "internal-key")
        XCTAssertEqual(openRouter.lastListEndpoint?.requiresAPIKey, false)
    }

    func testCustomOpenAICompatibleLLMKeyIsOptional() async throws {
        let customKeyStore = ModelsFakeOpenRouterKeyStore()
        let openRouter = ModelsFakeOpenRouterClient(models: [
            OpenRouterModelOption(id: "llama/local", name: "Llama Local")
        ])
        let (vm, prefs) = makeVM(customLLMKeyStore: customKeyStore, openRouterClient: openRouter)

        vm.selectLLMLevel(.custom)
        vm.customLLMBaseURL = "http://localhost:8000/v1"
        vm.customLLMModel = "llama/local"
        vm.customLLMAPIKeyInput = "   "

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .custom)
        XCTAssertNil(try customKeyStore.read())
        XCTAssertNil(openRouter.lastListEndpoint?.apiKey)
        XCTAssertEqual(vm.llmConnectionStatus, .ok)
    }

    func testSavingLocalLLMDoesNotDeleteSavedOpenRouterKey() async throws {
        let llmKeyStore = ModelsFakeOpenRouterKeyStore()
        try llmKeyStore.save(key: "or-existing")
        let (vm, prefs) = makeVM(
            llmLevel: .yourKey,
            llmKeyStore: llmKeyStore,
            localLLMStore: ModelsFakeLocalLLMStore(isReady: true)
        )

        // An empty key field must never delete the stored key when the user
        // commits a different route.
        vm.openRouterAPIKeyInput = ""
        vm.selectLLMLevel(.local)
        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .local)
        XCTAssertEqual(try llmKeyStore.read(), "or-existing")
    }

    // MARK: - LLM top-segment <-> route mapping (two-segment "Your key" merge)

    func testLLMTopLevelMapsYourKeyAndCustomToYourKeySegment() {
        let (vm, _) = makeVM(llmLevel: .yourKey)
        // OpenRouter route presents under the "Your key" segment.
        XCTAssertEqual(vm.llmTopLevel, .yourKey)

        // Custom endpoint route also presents under "Your key".
        vm.llmLevel = .custom
        XCTAssertEqual(vm.llmTopLevel, .yourKey)

        vm.llmLevel = .local
        XCTAssertEqual(vm.llmTopLevel, .local)
    }

    func testSelectingYourKeyTopSegmentDefaultsToOpenRouterWhenNoPriorVariant() {
        let (vm, _) = makeVM()
        XCTAssertEqual(vm.llmLevel, .local)

        vm.selectLLMTopLevel(.yourKey)

        // Fresh user with no prior BYOK variant lands on OpenRouter.
        XCTAssertEqual(vm.llmLevel, .yourKey)
        XCTAssertEqual(vm.yourKeyLLMVariant, .yourKey)
    }

    func testSelectingYourKeyTopSegmentRestoresLastCustomVariant() {
        let (vm, _) = makeVM(llmLevel: .yourKey)
        // User picks Custom inside "Your key" ...
        vm.selectYourKeyLLMVariant(.custom)
        XCTAssertEqual(vm.llmLevel, .custom)
        XCTAssertEqual(vm.yourKeyLLMVariant, .custom)

        // ... switches the top segment away ...
        vm.selectLLMTopLevel(.local)
        XCTAssertEqual(vm.llmLevel, .local)

        // ... and back to "Your key": the Custom sub-variant is restored.
        vm.selectLLMTopLevel(.yourKey)
        XCTAssertEqual(vm.llmLevel, .custom)
        XCTAssertEqual(vm.yourKeyLLMVariant, .custom)
    }

    func testYourKeyLLMVariantHydratesFromPersistedCustomRoute() {
        let (vm, _) = makeVM(llmLevel: .custom)

        // Reopening the screen with a persisted Custom route shows "Your key"
        // with the Custom sub-variant active.
        XCTAssertEqual(vm.llmTopLevel, .yourKey)
        XCTAssertEqual(vm.yourKeyLLMVariant, .custom)
    }

    func testYourKeyTopSegmentIsNeverGated() {
        // Both BYOK sub-routes are always available, on any hardware.
        let (appleSilicon, _) = makeVM(isAppleSilicon: true)
        XCTAssertFalse(appleSilicon.isYourKeyLLMTopGated)
        let (intel, _) = makeVM(isAppleSilicon: false)
        XCTAssertFalse(intel.isYourKeyLLMTopGated)
    }

    // MARK: - Local LLM (on-device MLX, ROO-257 Stage 2)

    func testSelectingLocalLLMDoesNotPersistUntilSaved() {
        let (vm, prefs) = makeVM(llmLevel: .yourKey)
        vm.selectLLMLevel(.local)

        XCTAssertEqual(vm.llmLevel, .local)
        XCTAssertEqual(prefs.llmLevel, .yourKey)  // selection alone never persists
    }

    func testLocalLLMLevelRequiresDownloadedModelBeforeSave() async {
        let (vm, prefs) = makeVM(llmLevel: .yourKey, localLLMStore: ModelsFakeLocalLLMStore(isReady: false))
        vm.selectLLMLevel(.local)

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(vm.localLLMStatus, .notDownloaded)
        XCTAssertEqual(vm.llmConnectionStatus, .failed(LocalModelMessaging.modelNotDownloaded))
    }

    func testSaveCurrentLLMSelectionPersistsLocalWhenModelReady() async {
        let (vm, prefs) = makeVM(llmLevel: .yourKey, localLLMStore: ModelsFakeLocalLLMStore(isReady: true))
        vm.selectLLMLevel(.local)

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(prefs.llmLevel, .local)
        XCTAssertEqual(vm.localLLMStatus, .ready)
        XCTAssertEqual(vm.llmConnectionStatus, .ok)
    }

    func testConnectLLMLocalMarksConnected() async {
        let (vm, _) = makeVM(llmLevel: .yourKey, localLLMStore: ModelsFakeLocalLLMStore(isReady: true))
        XCTAssertFalse(vm.isLocalLLMConnected)
        vm.selectLLMLevel(.local)

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(vm.approvedLLMLevel, .local)
        XCTAssertTrue(vm.isLocalLLMConnected)
    }

    func testDisconnectLLMRevertsToYourKeyButKeepsPicker() async {
        let (vm, prefs) = makeVM(llmLevel: .yourKey, localLLMStore: ModelsFakeLocalLLMStore(isReady: true))
        vm.selectLLMLevel(.local)
        await vm.saveCurrentLLMSelection()
        XCTAssertTrue(vm.isLocalLLMConnected)

        vm.disconnectLLM()

        XCTAssertFalse(vm.isLocalLLMConnected)
        XCTAssertEqual(vm.approvedLLMLevel, .yourKey)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
        // Picker stays on local so the card remains visible (button flips to Connect).
        XCTAssertEqual(vm.llmLevel, .local)
    }

    func testDownloadLocalLLMModelUpdatesReadyStatus() async {
        let store = ModelsFakeLocalLLMStore(isReady: false)
        let (vm, _) = makeVM(localLLMStore: store)

        await vm.downloadLocalLLMModel()

        let downloadCalls = await store.downloadCalls
        XCTAssertEqual(downloadCalls, 1)
        XCTAssertEqual(vm.localLLMStatus, .ready)
    }

    func testRefreshLocalLLMStatusReportsInFlightDownload() async {
        let store = ModelsFakeLocalLLMStore(statusOverride: .downloading(0.42))
        let (vm, _) = makeVM(localLLMStore: store)

        await vm.refreshLocalLLMStatus()

        XCTAssertEqual(vm.localLLMStatus, .downloading(0.42))
    }

    func testDeleteLocalLLMModelFallsBackFromActiveLocalToYourKey() async {
        let store = ModelsFakeLocalLLMStore(isReady: true)
        let (vm, prefs) = makeVM(llmLevel: .yourKey, localLLMStore: store)
        vm.selectLLMLevel(.local)
        await vm.saveCurrentLLMSelection()
        XCTAssertEqual(prefs.llmLevel, .local)

        await vm.deleteLocalLLMModel()

        let deleteCalls = await store.deleteCalls
        XCTAssertEqual(deleteCalls, 1)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(vm.llmLevel, .yourKey)
        XCTAssertEqual(vm.localLLMStatus, .notDownloaded)
    }

    // MARK: - Apple-Silicon gate (ROO-257 Stage 6)

    private func makeVMWithSilicon(isAppleSilicon: Bool) -> (SettingsModelsViewModel, SelfKeyPreferences) {
        makeVM(
            isAppleSilicon: isAppleSilicon,
            localModelStore: ModelsFakeLocalModelStore(isReady: true),
            localLLMStore: ModelsFakeLocalLLMStore(isReady: true)
        )
    }

    func testIntelHidesLocalGateFlags() {
        let (vm, _) = makeVMWithSilicon(isAppleSilicon: false)
        XCTAssertFalse(vm.canUseLocal)
        XCTAssertFalse(vm.canUseLocalLLM)
        XCTAssertTrue(vm.localBlockedByHardware)
        // The BYOK routes are unaffected by the hardware gate.
        XCTAssertTrue(vm.canUseYourKey)
        XCTAssertTrue(vm.canUseCustomLLM)
    }

    func testAppleSiliconKeepsLocalGateFlags() {
        let (vm, _) = makeVMWithSilicon(isAppleSilicon: true)
        XCTAssertTrue(vm.canUseLocal)
        XCTAssertTrue(vm.canUseLocalLLM)
        XCTAssertFalse(vm.localBlockedByHardware)
        XCTAssertTrue(vm.canUseYourKey)
        XCTAssertTrue(vm.canUseCustomLLM)
    }

    func testIntelCannotSelectLocalSTTWithSiliconMessage() {
        let (vm, prefs) = makeVMWithSilicon(isAppleSilicon: false)
        vm.selectLevel(.local)

        XCTAssertEqual(vm.level, .yourKey)
        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertEqual(vm.connectionStatus, .failed(LocalModelMessaging.requiresAppleSilicon))
    }

    func testIntelCannotPersistLocalSTTEvenIfLevelForced() async {
        let (vm, prefs) = makeVMWithSilicon(isAppleSilicon: false)
        vm.level = .local  // bypass selectLevel to prove the save-side guard

        await vm.saveCurrentSelection()

        XCTAssertEqual(vm.level, .yourKey)
        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertEqual(vm.connectionStatus, .failed(LocalModelMessaging.requiresAppleSilicon))
    }

    func testIntelCannotSelectLocalLLMWithSiliconMessage() {
        let (vm, prefs) = makeVMWithSilicon(isAppleSilicon: false)
        vm.selectLLMLevel(.local)

        XCTAssertEqual(vm.llmLevel, .yourKey)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(vm.llmConnectionStatus, .failed(LocalModelMessaging.requiresAppleSilicon))
    }

    func testIntelCannotPersistLocalLLMEvenIfLevelForced() async {
        let (vm, prefs) = makeVMWithSilicon(isAppleSilicon: false)
        vm.llmLevel = .local  // bypass selectLLMLevel to prove the save-side guard

        await vm.saveCurrentLLMSelection()

        XCTAssertEqual(vm.llmLevel, .yourKey)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
        XCTAssertEqual(vm.llmConnectionStatus, .failed(LocalModelMessaging.requiresAppleSilicon))
    }

    func testOfflineDownloadSurfacesUnifiedMessage() async {
        let store = ModelsFakeLocalLLMStore(isReady: false, downloadError: URLError(.notConnectedToInternet))
        let (vm, _) = makeVM(localLLMStore: store)

        await vm.downloadLocalLLMModel()

        XCTAssertEqual(vm.llmConnectionStatus, .failed(LocalModelMessaging.offlineCannotDownload))
    }
}

/// Minimal probe stub the test injects.
final class StubProbe: BYOKConnectionProbing {
    let succeeds: Bool
    init(succeeds: Bool) { self.succeeds = succeeds }
    func probe() async -> Bool { succeeds }
}

private final class ModelsFakeOpenRouterClient: OpenRouterLLMClienting {
    var models: [OpenRouterModelOption]
    private(set) var lastListEndpoint: OpenAICompatibleLLMEndpoint?
    var lastListAPIKey: String? { lastListEndpoint?.apiKey }

    init(models: [OpenRouterModelOption] = OpenRouterModelOption.fallback) {
        self.models = models
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        lastListEndpoint = endpoint
        return models
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        "unused"
    }
}

private final class ModelsFakeOpenRouterKeyStore: OpenRouterLLMKeyStoring {
    var key: String?
    var failWrites = false

    func save(key: String) throws {
        if failWrites { throw NSError(domain: "TestKeychain", code: 1) }
        self.key = key
    }

    func read() throws -> String? {
        key
    }

    func delete() throws {
        key = nil
    }
}

private actor ModelsFakeLocalModelStore: LocalTranscriptionModelManaging {
    var ready: Bool
    var statusOverride: LocalTranscriptionModelStatus?
    private(set) var downloadCalls = 0
    private(set) var deleteCalls = 0

    init(isReady: Bool = false, statusOverride: LocalTranscriptionModelStatus? = nil) {
        self.ready = isReady
        self.statusOverride = statusOverride
    }

    func localModelStatus() async -> LocalTranscriptionModelStatus {
        if let statusOverride { return statusOverride }
        return ready ? .ready : .notDownloaded
    }

    func isModelReady() async -> Bool {
        ready
    }

    func downloadModel(progress: (@Sendable (Double) -> Void)?) async throws {
        downloadCalls += 1
        progress?(0.35)
        ready = true
        statusOverride = nil
        progress?(1.0)
    }

    func deleteModel() async throws {
        deleteCalls += 1
        ready = false
        statusOverride = nil
    }

    func loadManager() async throws -> AsrManager {
        throw LocalTranscriptionModelError.modelNotDownloaded
    }

    func modelDirectory() async -> URL {
        URL(fileURLWithPath: "/tmp/sidekey-local-model-test", isDirectory: true)
    }

    func evict() async {}
}

private actor ModelsFakeLocalLLMStore: LocalLLMModelManaging {
    var ready: Bool
    var statusOverride: LocalLLMModelStatus?
    private(set) var downloadCalls = 0
    private(set) var deleteCalls = 0
    private let downloadError: Error?

    init(
        isReady: Bool = false,
        statusOverride: LocalLLMModelStatus? = nil,
        downloadError: Error? = nil
    ) {
        self.ready = isReady
        self.statusOverride = statusOverride
        self.downloadError = downloadError
    }

    func localModelStatus() async -> LocalLLMModelStatus {
        if let statusOverride { return statusOverride }
        return ready ? .ready : .notDownloaded
    }

    func isModelReady() async -> Bool {
        ready
    }

    func downloadModel(progress: (@Sendable (Double) -> Void)?) async throws {
        downloadCalls += 1
        if let downloadError {
            throw downloadError
        }
        progress?(0.35)
        ready = true
        statusOverride = nil
        progress?(1.0)
    }

    func deleteModel() async throws {
        deleteCalls += 1
        ready = false
        statusOverride = nil
    }

    func loadContainer() async throws -> ModelContainer {
        throw LocalLLMModelError.modelNotDownloaded
    }

    func modelDirectory() async -> URL {
        URL(fileURLWithPath: "/tmp/sidekey-local-llm-test", isDirectory: true)
    }

    func evict() async {}
}

private struct ModelsFailingTokenStore: TokenStore {
    func read() throws -> String? { nil }
    func save(_ token: String) throws { throw NSError(domain: "TestKeychain", code: 1) }
    func delete() throws { throw NSError(domain: "TestKeychain", code: 1) }
}
