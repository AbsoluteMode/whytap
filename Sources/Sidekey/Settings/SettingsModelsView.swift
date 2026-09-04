import SwiftUI

@MainActor
struct SettingsModelsView: View {
    @ObservedObject var viewModel: SettingsModelsViewModel

    /// Canonical user-facing name for the user-supplied OpenAI-compatible
    /// self-hosted endpoint. Shared by the STT "Your key" provider list and
    /// the LLM "Your key" variant list so both panels read identically.
    static let selfHostedProviderName = "Self-hosted (OpenAI-compatible)"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                transcribeSection
                llmSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Transcription

    private var transcribeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Processing")
            MacSegmented(
                items: [
                    .init(value: .local, label: "Local"),
                    .init(value: .yourKey, label: "Your key"),
                ],
                selection: Binding(
                    get: { viewModel.level },
                    set: { viewModel.selectLevel($0) }
                ),
                disabledValues: gatedLevels
            )
            if viewModel.localBlockedByHardware {
                appleSiliconHint.padding(.top, 10)
            }
            levelDescription.padding(.top, 8)

            Group {
                switch viewModel.level {
                case .yourKey: yourKeyConfig
                case .local: localConfig
                }
            }
            .padding(.top, 16)
        }
    }

    /// Isolation levels this Mac cannot use (Intel: no on-device models).
    private var gatedLevels: Set<TranscriptionIsolationLevel> {
        var set: Set<TranscriptionIsolationLevel> = []
        if !viewModel.canUseLocal { set.insert(.local) }
        return set
    }

    /// Shown when the host is Intel: the on-device model stack (MLX + Core ML)
    /// is Apple-Silicon-only, so "Local" is disabled with a clear reason.
    private var appleSiliconHint: some View {
        MacBanner(
            tone: .info,
            systemImage: "cpu",
            text: LocalModelMessaging.requiresAppleSilicon
        )
    }

    @ViewBuilder
    private var levelDescription: some View {
        switch viewModel.level {
        case .yourKey:
            EmptyView()
        case .local:
            caption("Audio is transcribed on this Mac after a one-time model download.")
        }
    }

    // MARK: - Your-key level (BYOK, direct to provider)

    @ViewBuilder
    private var yourKeyConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Transcription goes straight to the provider with your key. Nothing passes through any Whytap server."
            )

            VStack(alignment: .leading, spacing: 0) {
                MacGroupTitle(
                    title: "Provider",
                    trailing: "\(providerName(viewModel.provider)) · \(activeModelLabel)"
                )
                VStack(spacing: 8) {
                    ForEach(BYOKProvider.selectable, id: \.self) { provider in
                        if provider == viewModel.provider {
                            expandedProviderCard(provider)
                        } else {
                            collapsedProviderRow(provider)
                        }
                    }
                }
            }
        }
    }

    private var activeModelLabel: String {
        viewModel.provider == .selfHosted
            ? (viewModel.selfHostedModel.isEmpty ? "model" : viewModel.selfHostedModel)
            : viewModel.selectedModel
    }

    private func collapsedProviderRow(_ provider: BYOKProvider) -> some View {
        MacCard {
            Button {
                guard viewModel.provider != provider else { return }
                viewModel.provider = provider
                viewModel.providerChanged()
            } label: {
                MacRow(
                    title: providerName(provider),
                    leading: { byokProviderBrandIcon(provider) }
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func expandedProviderCard(_ provider: BYOKProvider) -> some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    byokProviderBrandIcon(provider)
                    Text(providerName(provider))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    MacPill(text: "Active", tone: .blue)
                    Spacer()
                }

                fieldLabel("Model")
                modelField(provider)

                if provider == .selfHosted {
                    fieldLabel("Base URL")
                    MacField(placeholder: "https://…", text: $viewModel.selfHostedBaseURL)
                }

                fieldLabel("API key")
                MacField(
                    placeholder: provider == .openAI ? "sk-…" : "API key",
                    text: $viewModel.apiKeyInput,
                    isSecure: true,
                    monospaced: true
                )

                HStack(spacing: 10) {
                    MacButton(
                        title: "Save",
                        style: .primary,
                        isEnabled: viewModel.connectionStatus != .testing
                    ) {
                        Task { await viewModel.saveCurrentSelection() }
                    }
                    if provider == .openAI || provider == .selfHosted {
                        MacButton(title: "Test connection", style: .default) {
                            Task { await viewModel.testConnection() }
                        }
                    }
                    connectionStatus
                }
                .padding(.top, 2)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func modelField(_ provider: BYOKProvider) -> some View {
        if provider == .selfHosted {
            MacField(placeholder: "gpt-4o-transcribe", text: $viewModel.selfHostedModel)
        } else if viewModel.models.count > 1 {
            MacPopup(
                items: viewModel.models.map { .init(value: $0, label: $0) },
                selection: Binding(
                    get: { viewModel.selectedModel },
                    set: { viewModel.selectedModel = $0 }
                )
            )
        } else {
            // Single fixed model for this provider — show it as text, not an
            // illusory one-option dropdown (Deepgram / Soniox / ElevenLabs each
            // offer exactly one realtime model).
            Text(viewModel.models.first ?? viewModel.selectedModel)
                .font(.system(size: 13))
                .foregroundStyle(MacSettingsTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch viewModel.connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small).padding(.leading, 4)
        case .ok:
            MacPill(text: "Connected", tone: .green, showsDot: true)
        case .failed(let msg):
            MacPill(text: msg, tone: .red)
        }
    }

    // MARK: - Local level (on-device ASR)

    private var localConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Drop transcription runs entirely on this Mac. After the one-time model download, recording and inference work offline."
            )

            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        LocalParakeetModelIcon()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parakeet TDT v3")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(MacSettingsTheme.text)
                            Text("Multilingual Core ML ASR")
                                .font(.system(size: 11))
                                .foregroundStyle(MacSettingsTheme.text2)
                        }
                        Spacer()
                        localModelStatusPill
                    }

                    HStack(spacing: 10) {
                        LocalConnectControl(
                            phase: localConnectPhase,
                            isBusy: viewModel.connectionStatus == .testing,
                            onDownload: { Task { await viewModel.downloadLocalModel() } },
                            onConnect: { Task { await viewModel.saveCurrentSelection() } },
                            onDisconnect: { viewModel.disconnectLocal() }
                        )
                        if case .ready = viewModel.localModelStatus {
                            MacButton(title: "Delete model", style: .danger) {
                                Task { await viewModel.deleteLocalModel() }
                            }
                        }
                        if case .failed(let message) = viewModel.connectionStatus {
                            MacPill(text: message, tone: .red)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
        .task { await viewModel.watchLocalModelStatus() }
    }

    @ViewBuilder
    private var localModelStatusPill: some View {
        switch viewModel.localModelStatus {
        case .checking:
            ProgressView().controlSize(.small)
        case .notDownloaded:
            MacPill(text: "Not downloaded", tone: .neutral)
        case .downloading(let fraction):
            MacPill(text: "Downloading \(Int(fraction * 100))%", tone: .blue)
        case .ready:
            if viewModel.isLocalConnected {
                MacPill(text: "Connected", tone: .green, showsDot: true)
            } else {
                MacPill(text: "Ready", tone: .neutral)
            }
        case .failed(let message):
            MacPill(text: message, tone: .red)
        }
    }

    private var localConnectPhase: LocalConnectControl.Phase {
        switch viewModel.localModelStatus {
        case .downloading(let fraction):
            return .downloading(fraction)
        case .ready:
            return viewModel.isLocalConnected ? .connected : .connect
        default:
            return .download
        }
    }

    private struct LocalParakeetModelIcon: View {
        var body: some View {
            Canvas { context, size in
                context.scaleBy(x: size.width / 100, y: size.height / 100)

                // 1. Tail
                var tail = Path()
                tail.move(to: CGPoint(x: 62, y: 74))
                tail.addLine(to: CGPoint(x: 90, y: 90))
                tail.addLine(to: CGPoint(x: 74, y: 95))
                tail.addLine(to: CGPoint(x: 66, y: 84))
                tail.closeSubpath()
                context.fill(tail, with: .color(Color(hexCSS: "#4F8310")))

                // 2. Body (ellipse rotated 16° around its center)
                let bodyEllipse = Path(ellipseIn: CGRect(x: 31, y: 29, width: 50, height: 58))
                let body = bodyEllipse.applying(
                    CGAffineTransform(translationX: 56, y: 58)
                        .rotated(by: 16 * .pi / 180)
                        .translatedBy(x: -56, y: -58)
                )
                context.fill(body, with: .color(Color(hexCSS: "#76B900")))

                // 3. Light belly
                var belly = Path()
                belly.move(to: CGPoint(x: 41, y: 54))
                belly.addQuadCurve(to: CGPoint(x: 62, y: 82), control: CGPoint(x: 43, y: 78))
                belly.addQuadCurve(to: CGPoint(x: 40, y: 74), control: CGPoint(x: 49, y: 85))
                belly.addQuadCurve(to: CGPoint(x: 41, y: 54), control: CGPoint(x: 35, y: 63))
                belly.closeSubpath()
                context.fill(belly, with: .color(Color(hexCSS: "#97CE33")))

                // 4. Wing
                var wing = Path()
                wing.move(to: CGPoint(x: 54, y: 42))
                wing.addQuadCurve(to: CGPoint(x: 78, y: 72), control: CGPoint(x: 76, y: 46))
                wing.addQuadCurve(to: CGPoint(x: 60, y: 79), control: CGPoint(x: 73, y: 81))
                wing.addQuadCurve(to: CGPoint(x: 51, y: 47), control: CGPoint(x: 49, y: 64))
                wing.closeSubpath()
                context.fill(wing, with: .color(Color(hexCSS: "#5C9610")))

                // 5. Feather line 1
                var feather1 = Path()
                feather1.move(to: CGPoint(x: 58, y: 50))
                feather1.addQuadCurve(to: CGPoint(x: 70, y: 70), control: CGPoint(x: 68, y: 54))
                context.stroke(
                    feather1,
                    with: .color(Color(hexCSS: "#46760B")),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )

                // 6. Feather line 2
                var feather2 = Path()
                feather2.move(to: CGPoint(x: 53, y: 52))
                feather2.addQuadCurve(to: CGPoint(x: 61, y: 74), control: CGPoint(x: 60, y: 58))
                context.stroke(
                    feather2,
                    with: .color(Color(hexCSS: "#46760B").opacity(0.8)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )

                // 7. Head
                let head = Path(ellipseIn: CGRect(x: 19, y: 11, width: 38, height: 38))
                context.fill(head, with: .color(Color(hexCSS: "#E7D63E")))

                // 8. Beak
                var beak = Path()
                beak.move(to: CGPoint(x: 28, y: 27))
                beak.addQuadCurve(to: CGPoint(x: 7, y: 39), control: CGPoint(x: 9, y: 28))
                beak.addQuadCurve(to: CGPoint(x: 13, y: 44), control: CGPoint(x: 6.5, y: 45))
                beak.addQuadCurve(to: CGPoint(x: 22, y: 36), control: CGPoint(x: 14, y: 37))
                beak.addQuadCurve(to: CGPoint(x: 28, y: 33), control: CGPoint(x: 26, y: 35))
                beak.closeSubpath()
                context.fill(beak, with: .color(Color(hexCSS: "#54606E")))

                // 9. Eye
                let eye = Path(ellipseIn: CGRect(x: 28.8, y: 22.8, width: 8.4, height: 8.4))
                context.fill(eye, with: .color(Color(hexCSS: "#222831")))

                // 10. Eye highlight
                let highlight = Path(ellipseIn: CGRect(x: 33.0, y: 24.2, width: 2.8, height: 2.8))
                context.fill(highlight, with: .color(Color(hexCSS: "#FFFFFF")))
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
        }
    }

    /// Official Qwen brand mark for the on-device LLM card. Rendered in full
    /// color from the bundled `qwen.pdf` — unlike `ProviderBrandIcon`, whose
    /// asset path forces `isTemplate = true` and would flatten the logo's
    /// purple gradient into a single tint.
    private struct LocalLLMQwenIcon: View {
        var body: some View {
            Group {
                if let image = LocalLLMQwenIcon.brandImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text2)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
        }

        /// Loaded once and cached. Color preserved by leaving `isTemplate`
        /// false (the default) so the gradient survives.
        private static let brandImage: NSImage? = {
            guard let url = Bundle.main.url(
                forResource: "qwen",
                withExtension: "pdf",
                subdirectory: "UsefulLinkIcons"
            ) ?? Bundle.main.url(forResource: "qwen", withExtension: "pdf") else {
                return nil
            }
            let image = NSImage(contentsOf: url)
            image?.isTemplate = false
            return image
        }()
    }

    // MARK: - LLM section

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(
                title: "Smart processing LLM",
                trailing: llmTrailingTitle
            )
            MacSegmented(
                items: [
                    .init(value: .local, label: "Local"),
                    .init(value: .yourKey, label: "Your key"),
                ],
                selection: Binding(
                    get: { viewModel.llmTopLevel },
                    set: { viewModel.selectLLMTopLevel($0) }
                ),
                disabledValues: gatedLLMTopLevels
            )
            if viewModel.localBlockedByHardware {
                appleSiliconHint.padding(.top, 10)
            }

            Group {
                switch viewModel.llmTopLevel {
                case .yourKey:
                    yourKeyLLMConfig
                case .local:
                    localLLMConfig
                }
            }
            .padding(.top, 16)
        }
    }

    /// Top-segment values this Mac cannot use (Intel: no on-device LLM). The
    /// merged "Your key" segment is disabled only when both BYOK sub-routes
    /// are gated.
    private var gatedLLMTopLevels: Set<LLMTopLevel> {
        var set: Set<LLMTopLevel> = []
        if viewModel.isYourKeyLLMTopGated { set.insert(.yourKey) }
        if !viewModel.canUseLocalLLM { set.insert(.local) }
        return set
    }

    /// "Your key" sub-panel: a provider-card list (OpenRouter / Self-hosted)
    /// matching the STT "Your key" panel — collapsed rows with a chevron expand
    /// into the active route's config card. The active card reuses the existing
    /// `openRouterConfig` / `customLLMConfig` panels unchanged.
    @ViewBuilder
    private var yourKeyLLMConfig: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(
                title: "Provider",
                trailing: llmVariantName(viewModel.yourKeyLLMVariant)
            )
            VStack(spacing: 8) {
                ForEach(llmYourKeyVariants, id: \.self) { variant in
                    if variant == viewModel.yourKeyLLMVariant {
                        expandedLLMVariantCard(variant)
                    } else {
                        collapsedLLMVariantRow(variant)
                    }
                }
            }
        }
    }

    /// The two BYOK LLM sub-routes, in display order (OpenRouter first).
    private var llmYourKeyVariants: [LLMIsolationLevel] { [.yourKey, .custom] }

    private func llmVariantName(_ variant: LLMIsolationLevel) -> String {
        variant == .custom ? Self.selfHostedProviderName : "OpenRouter"
    }

    @ViewBuilder
    private func llmVariantBrandIcon(_ variant: LLMIsolationLevel) -> some View {
        if variant == .custom {
            ProviderBrandIcon(systemName: "server.rack")
        } else {
            ProviderBrandIcon(assetName: "openrouter")
        }
    }

    private func collapsedLLMVariantRow(_ variant: LLMIsolationLevel) -> some View {
        MacCard {
            Button {
                guard viewModel.yourKeyLLMVariant != variant else { return }
                viewModel.selectYourKeyLLMVariant(variant)
            } label: {
                MacRow(
                    title: llmVariantName(variant),
                    leading: { llmVariantBrandIcon(variant) }
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func expandedLLMVariantCard(_ variant: LLMIsolationLevel) -> some View {
        if variant == .custom {
            customLLMConfig
        } else {
            openRouterConfig
        }
    }

    // MARK: - Local LLM level (on-device MLX)

    private var localLLMConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Drop cleanup and meeting notes run entirely on this Mac. After the one-time model download, inference works offline."
            )

            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        LocalLLMQwenIcon()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Qwen3 4B Instruct")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(MacSettingsTheme.text)
                            Text("On-device MLX 4-bit LLM")
                                .font(.system(size: 11))
                                .foregroundStyle(MacSettingsTheme.text2)
                        }
                        Spacer()
                        localLLMStatusPill
                    }

                    HStack(spacing: 10) {
                        LocalConnectControl(
                            phase: localLLMConnectPhase,
                            isBusy: viewModel.llmConnectionStatus == .testing,
                            onDownload: { Task { await viewModel.downloadLocalLLMModel() } },
                            onConnect: { Task { await viewModel.saveCurrentLLMSelection() } },
                            onDisconnect: { viewModel.disconnectLLM() }
                        )
                        if case .ready = viewModel.localLLMStatus {
                            MacButton(title: "Delete model", style: .danger) {
                                Task { await viewModel.deleteLocalLLMModel() }
                            }
                        }
                        if case .failed(let message) = viewModel.llmConnectionStatus {
                            MacPill(text: message, tone: .red)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
        .task { await viewModel.watchLocalLLMStatus() }
    }

    @ViewBuilder
    private var localLLMStatusPill: some View {
        switch viewModel.localLLMStatus {
        case .checking:
            ProgressView().controlSize(.small)
        case .notDownloaded:
            MacPill(text: "Not downloaded", tone: .neutral)
        case .downloading(let fraction):
            MacPill(text: "Downloading \(Int(fraction * 100))%", tone: .blue)
        case .ready:
            if viewModel.isLocalLLMConnected {
                MacPill(text: "Connected", tone: .green, showsDot: true)
            } else {
                MacPill(text: "Ready", tone: .neutral)
            }
        case .failed(let message):
            MacPill(text: message, tone: .red)
        }
    }

    private var localLLMConnectPhase: LocalConnectControl.Phase {
        switch viewModel.localLLMStatus {
        case .downloading(let fraction):
            return .downloading(fraction)
        case .ready:
            return viewModel.isLocalLLMConnected ? .connected : .connect
        default:
            return .download
        }
    }

    private var openRouterConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Drop cleanup and meeting notes go straight to OpenRouter with your key. Agent Mode still uses the provider selected on the Agent tab."
            )

            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProviderBrandIcon(assetName: "openrouter")
                        Text("OpenRouter direct")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MacSettingsTheme.text)
                        MacPill(text: "Route active", tone: .blue)
                        Spacer()
                    }

                    openRouterRouteStatus

                    fieldLabel("OpenRouter model ID")
                    LLMModelSearchField(
                        placeholder: "openai/gpt-4o-mini",
                        text: $viewModel.openRouterModel,
                        suggestions: viewModel.openRouterModelSuggestions
                    )
                    .task { await viewModel.loadOpenRouterModelsIfNeeded() }

                    caption("The provider prefix is part of the OpenRouter model id, for example openai/…, anthropic/…, or google/….")

                    if usingOpenRouterAuto {
                        MacBanner(
                            tone: .info,
                            systemImage: "arrow.triangle.branch",
                            text: "Auto Router lets OpenRouter choose the concrete model. Pick a specific model id when you want predictable provider names."
                        )
                    }

                    fieldLabel("OpenRouter API key")
                    MacField(
                        placeholder: "sk-or-v1-…",
                        text: $viewModel.openRouterAPIKeyInput,
                        isSecure: true,
                        monospaced: true
                    )

                    HStack(spacing: 10) {
                        MacButton(
                            title: "Save",
                            style: .primary,
                            isEnabled: viewModel.llmConnectionStatus != .testing
                        ) {
                            Task { await viewModel.saveCurrentLLMSelection() }
                        }
                        MacButton(title: "Test OpenRouter", style: .default) {
                            Task { await viewModel.testLLMConnection() }
                        }
                        MacButton(title: "Refresh list", style: .default) {
                            Task { await viewModel.refreshOpenRouterModels() }
                        }
                        llmConnectionStatus
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
    }

    private var customLLMConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacBanner(
                tone: .privacy,
                systemImage: "lock.shield",
                text: "Drop cleanup and meeting notes go straight to your OpenAI-compatible endpoint. Agent Mode still uses the provider selected on the Agent tab."
            )

            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ProviderBrandIcon(systemName: "server.rack")
                        Text(Self.selfHostedProviderName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MacSettingsTheme.text)
                        MacPill(text: "Route active", tone: .blue)
                        Spacer()
                    }

                    customLLMRouteStatus

                    fieldLabel("Base URL")
                    MacField(
                        placeholder: "http://localhost:8000/v1",
                        text: $viewModel.customLLMBaseURL,
                        monospaced: true
                    )

                    caption("Use the OpenAI-compatible API root, usually ending with /v1 for vLLM, LiteLLM, Ollama, or an internal gateway.")

                    fieldLabel("Model ID")
                    LLMModelSearchField(
                        placeholder: "local-model",
                        text: $viewModel.customLLMModel,
                        suggestions: viewModel.customLLMModelSuggestions
                    )
                    .task { await viewModel.loadCustomLLMModelsIfNeeded() }

                    fieldLabel("API key")
                    MacField(
                        placeholder: "Bearer token, optional",
                        text: $viewModel.customLLMAPIKeyInput,
                        isSecure: true,
                        monospaced: true
                    )

                    HStack(spacing: 10) {
                        MacButton(
                            title: "Save",
                            style: .primary,
                            isEnabled: viewModel.llmConnectionStatus != .testing
                        ) {
                            Task { await viewModel.saveCurrentLLMSelection() }
                        }
                        MacButton(title: "Test endpoint", style: .default) {
                            Task { await viewModel.testLLMConnection() }
                        }
                        MacButton(title: "Refresh list", style: .default) {
                            Task { await viewModel.refreshCustomLLMModels() }
                        }
                        llmConnectionStatus
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var llmConnectionStatus: some View {
        switch viewModel.llmConnectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small).padding(.leading, 4)
        case .ok:
            MacPill(text: "LLM route OK", tone: .green, showsDot: true)
        case .failed(let msg):
            MacPill(text: msg, tone: .red)
        }
    }

    // MARK: - Helpers

    private var llmTrailingTitle: String {
        switch viewModel.llmLevel {
        case .yourKey:
            return "Route: OpenRouter direct"
        case .custom:
            return "Route: Self-hosted"
        case .local:
            return "Route: On-device"
        }
    }

    private var currentOpenRouterModelID: String {
        let trimmed = viewModel.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SelfKeyPreferences.defaultOpenRouterModel : trimmed
    }

    private var currentCustomLLMBaseURL: String {
        let trimmed = viewModel.customLLMBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Not set" : trimmed
    }

    private var currentCustomLLMModelID: String {
        let trimmed = viewModel.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? SelfKeyPreferences.defaultCustomLLMModel : trimmed
    }

    private var usingOpenRouterAuto: Bool {
        currentOpenRouterModelID == "openrouter/auto"
    }

    private var openRouterRouteStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            llmFactRow(title: "Used for", value: "Drop cleanup + meeting notes")
            llmFactRow(title: "Route", value: "OpenRouter /chat/completions")
            llmFactRow(title: "Selected model", value: currentOpenRouterModelID, monospaced: true)
        }
        .padding(10)
        .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var customLLMRouteStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            llmFactRow(title: "Used for", value: "Drop cleanup + meeting notes")
            llmFactRow(title: "Route", value: "OpenAI-compatible /chat/completions")
            llmFactRow(title: "Base URL", value: currentCustomLLMBaseURL, monospaced: true)
            llmFactRow(title: "Selected model", value: currentCustomLLMModelID, monospaced: true)
        }
        .padding(10)
        .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }

    private func llmFactRow(title: String, value: String, monospaced: Bool = false) -> some View {
        let valueFont = monospaced
            ? Font.system(size: 12, weight: .medium, design: .monospaced)
            : Font.system(size: 12, weight: .medium)

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text2)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(valueFont)
                .foregroundStyle(MacSettingsTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func providerName(_ provider: BYOKProvider) -> String {
        switch provider {
        case .openAI: return "OpenAI"
        case .selfHosted: return Self.selfHostedProviderName
        case .deepgram: return "Deepgram"
        case .soniox: return "Soniox"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    @ViewBuilder
    private func byokProviderBrandIcon(_ provider: BYOKProvider) -> some View {
        if let assetName = byokProviderBrandAssetName(provider) {
            ProviderBrandIcon(assetName: assetName)
        } else {
            ProviderBrandIcon(systemName: "server.rack")
        }
    }

    private func byokProviderBrandAssetName(_ provider: BYOKProvider) -> String? {
        switch provider {
        case .openAI: return "openai"
        case .selfHosted: return nil
        case .deepgram: return "deepgram"
        case .soniox: return "soniox"
        case .elevenLabs: return "elevenlabs"
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(MacSettingsTheme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MacSettingsTheme.text2)
            .textCase(.uppercase)
            .kerning(0.4)
    }

}

private struct LLMModelSearchField: View {
    let placeholder: String
    @Binding var text: String
    let suggestions: [OpenRouterModelOption]

    private static let suggestionsMaxHeight: CGFloat = 220

    @FocusState private var focused: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(MacSettingsTheme.text)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            focused ? MacSettingsTheme.accent.opacity(0.6) : Color.white.opacity(0.12),
                            lineWidth: focused ? 2 : 0.5
                        )
                )
                .onTapGesture { expanded = true }
                .onSubmit { expanded = false }
                .onChange(of: focused) { _, isFocused in
                    expanded = isFocused
                }
                .onChange(of: text) { _, _ in
                    if focused { expanded = true }
                }

            if expanded && !suggestions.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, option in
                            if idx > 0 { MacRowSeparator() }
                            Button {
                                text = option.id
                                expanded = false
                                focused = false
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.id)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(MacSettingsTheme.text)
                                            .lineLimit(1)
                                        if option.name != option.id {
                                            Text(option.name)
                                                .font(.system(size: 11))
                                                .foregroundStyle(MacSettingsTheme.text2)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if option.id == text {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(MacSettingsTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: Self.suggestionsMaxHeight)
                .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
            }
        }
    }
}

/// Single state-machine control for an on-device model card:
/// Download → Downloading% → Connect → Connected (hover reveals Disconnect).
/// Replaces the old separate "Use Local" button + "Connected" status pill so the
/// whole connect flow lives on one button (ROO-257).
private struct LocalConnectControl: View {
    enum Phase: Equatable {
        case download
        case downloading(Double)
        case connect
        case connected
    }

    let phase: Phase
    let isBusy: Bool
    let onDownload: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        switch phase {
        case .download:
            MacButton(title: "Download", style: .primary, isEnabled: !isBusy, action: onDownload)
        case .downloading(let fraction):
            MacButton(
                title: "Downloading \(Int(fraction * 100))%",
                style: .default,
                isEnabled: false,
                action: {}
            )
        case .connect:
            MacButton(title: "Connect", style: .primary, isEnabled: !isBusy, action: onConnect)
        case .connected:
            // The "Connected" status is shown by the card's status pill on the
            // right, so the button itself is just the action — "Disconnect".
            MacButton(title: "Disconnect", style: .default, isEnabled: !isBusy, action: onDisconnect)
        }
    }
}
