import SwiftUI

@MainActor
struct AgentModeView: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var settings: AgentSettingsStore
    @ObservedObject var store: AgentProviderStore
    private let agentEnabledProvider: () -> Bool
    private let onAgentToggle: (Bool) -> Void
    @State private var agentEnabled: Bool
    @State private var codexConfig = CodexConfigSnapshot()
    @State private var claudeCatalog = ClaudeModelCatalog()
    @StateObject private var claudeSetup = AgentSetupChecklistViewModel(probes: .claude())
    @StateObject private var codexSetup = AgentSetupChecklistViewModel(probes: .codex())

    /// Reading the model list from the (large) claude binary takes ~1-2s; the
    /// binary does not change mid-session, so cache the result for the process.
    private static var cachedCatalog: ClaudeModelCatalog?

    init(
        viewModel: AgentModeViewModel,
        settings: AgentSettingsStore,
        store: AgentProviderStore,
        agentEnabled: @escaping () -> Bool,
        onAgentToggle: @escaping (Bool) -> Void
    ) {
        self.viewModel = viewModel
        self.settings = settings
        self.store = store
        self.agentEnabledProvider = agentEnabled
        self.onAgentToggle = onAgentToggle
        _agentEnabled = State(initialValue: agentEnabled())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                capabilitySection
                skipPermissionNotice
                claudeSection
                codexSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            codexConfig = CodexConfigReader().read()
            await loadClaudeCatalog()
        }
        .onAppear {
            agentEnabled = agentEnabledProvider()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)
        ) { _ in
            agentEnabled = agentEnabledProvider()
        }
    }

    /// Derive the Claude model list from the located binary, off the main thread
    /// (the scan blocks ~1-2s), then publish it. Cached per process.
    private func loadClaudeCatalog() async {
        if let cached = Self.cachedCatalog { claudeCatalog = cached; return }
        let catalog = await Task.detached {
            let binary = ClaudeBinaryLocator().locate()
            return ClaudeModelCatalogReader().read(binary: binary)
        }.value
        Self.cachedCatalog = catalog
        claudeCatalog = catalog
    }

    private var header: some View {
        Text("Whytap is the voice. The brain is your own agent CLI, running on your machine under your login — your subscription, your MCP servers, your memory. Connect one; choosing another replaces the active agent.")
            .font(.system(size: 12))
            .foregroundStyle(MacSettingsTheme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var capabilitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Agent")
            MacCard {
                MacRow(
                    title: "Use Agent shortcuts",
                    subtitle: agentEnabled
                        ? "Right Command is ready for text and voice requests."
                        : "Turn this on to use Agent with Right Command."
                ) {
                    MacSwitch(isOn: Binding(
                        get: { agentEnabled },
                        set: { newValue in
                            agentEnabled = newValue
                            onAgentToggle(newValue)
                        }
                    ))
                }
            }
        }
    }

    /// Skip-permission disclosure. While we test, both CLIs run with all
    /// approval prompts bypassed AND no sandbox (Claude Code `--permission-mode
    /// bypassPermissions`, Codex `--dangerously-bypass-approvals-and-sandbox`),
    /// so the agent acts with full machine access without asking. Surfaced
    /// here, at connect time, so the user knows what they are granting. (A
    /// future in-island approval bar will reintroduce per-call approval.)
    private var skipPermissionNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "bolt.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text2)
            Text("Skip-permission mode: the agent auto-approves and runs every action — edits, commands, MCP tools — without asking, with full access to your machine (no sandbox). Connect only an agent you trust.")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Connect Claude Code")
            MacCard {
                providerRow(.claude, "Claude Code")
                // Setup guide while not connected; hidden once active. Connect
                // stays enabled regardless — the probe is the source of truth,
                // the checklist only guides.
                if store.activeProvider != .claude {
                    MacRowSeparator()
                    AgentSetupGuideView(content: .claude, checklist: claudeSetup)
                }
            }
            if store.activeProvider == .claude {
                AgentControlsClaude(settings: settings, catalog: claudeCatalog)
                    .padding(.top, 10)
            }
        }
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Connect Codex")
            MacCard {
                providerRow(.codex, "Codex")
                if store.activeProvider != .codex {
                    MacRowSeparator()
                    AgentSetupGuideView(content: .codex, checklist: codexSetup)
                }
            }
            if store.activeProvider == .codex {
                AgentControlsCodex(settings: settings, config: codexConfig)
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ id: CLIProviderID, _ name: String) -> some View {
        let isActive = store.activeProvider == id
        let isConnecting = viewModel.connecting == id
        MacRow(
            title: name,
            leading: { ProviderBrandIcon(assetName: agentBrandAssetName(id)) }
        ) {
            HStack(spacing: 10) {
                if isActive {
                    MacPill(text: "Connected", tone: .green, showsDot: true)
                }
                if isConnecting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MacSettingsTheme.text2)
                    }
                } else if isActive {
                    MacButton(title: "Disconnect", style: .default) { viewModel.disconnect() }
                } else {
                    MacButton(title: "Connect", style: .primary) { Task { await viewModel.connect(id) } }
                }
            }
        }
    }

    private func agentBrandAssetName(_ id: CLIProviderID) -> String {
        switch id {
        case .claude: return "claude-code"
        case .codex: return "codex"
        }
    }
}
