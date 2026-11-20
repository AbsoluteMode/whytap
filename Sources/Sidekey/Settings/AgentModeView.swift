import AppKit
import SwiftUI

@MainActor
struct AgentModeView: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var settings: AgentSettingsStore
    @ObservedObject var store: AgentProviderStore
    private let agentEnabledProvider: () -> Bool
    private let onAgentToggle: (Bool) -> Void
    private let openAPIAndModels: (AIFeature) -> Void
    @State private var agentEnabled: Bool
    @State private var message: String?

    init(viewModel: AgentModeViewModel, settings: AgentSettingsStore, store: AgentProviderStore,
         agentEnabled: @escaping () -> Bool, onAgentToggle: @escaping (Bool) -> Void,
         openAPIAndModels: @escaping (AIFeature) -> Void) {
        self.viewModel = viewModel
        self.settings = settings
        self.store = store
        self.agentEnabledProvider = agentEnabled
        self.onAgentToggle = onAgentToggle
        self.openAPIAndModels = openAPIAndModels
        _agentEnabled = State(initialValue: agentEnabled())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Whytap Agent is built in and starts directly with your selected model. Requests and relevant context go to that provider; memory and recent conversation stay on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Agent")
                    MacCard {
                        MacRow(title: "Use Agent shortcuts", subtitle: "Ask by text or voice. Shortcuts in Hotkeys.") {
                            MacSwitch(isOn: Binding(get: { agentEnabled }, set: {
                                agentEnabled = $0; onAgentToggle($0)
                            }), label: "Use Agent shortcuts")
                        }
                        MacRowSeparator()
                        MacRow(title: "Model", subtitle: settings.selectedOpenCodeModelLabel ?? "Choose a model in API & Models") {
                            MacButton(title: "Choose model", style: .default) { openAPIAndModels(.agent) }
                        }
                        MacRowSeparator()
                        MacRow(title: "Workspace", subtitle: "~/Library/Application Support/whytap/agent\nAGENTS.md holds memory. Conversation context resets after 15 minutes.") {
                            MacButton(title: "Open folder", style: .default) {
                                do { NSWorkspace.shared.open(try AgentDaemonWorkingDirectory.ensure()) }
                                catch { message = "Couldn’t open the agent workspace." }
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    if store.activeProvider == .native {
                        MacPill(text: "Connected", tone: .green, showsDot: true)
                        Spacer()
                        MacButton(title: "Disconnect", style: .default) { viewModel.disconnect() }
                    } else {
                        if viewModel.connecting == .native { ProgressView().controlSize(.small) }
                        Spacer()
                        MacButton(title: "Connect", style: .primary) {
                            Task {
                                guard settings.selectedOpenCodeModel != nil else { message = "Choose an Agent model in API & Models."; return }
                                message = nil
                                await viewModel.connect(.native)
                            }
                        }.disabled(viewModel.connecting != nil)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(MacSettingsTheme.text2) }
                MacCard {
                    MacRow(title: "Allow file edits and commands",
                           subtitle: "Uses your Mac user’s permissions. Off: edits and shell commands are blocked. Applies to the next request.") {
                        MacSwitch(isOn: $settings.openCodeAllowActions, label: "Allow file edits and commands")
                    }
                }
                if let harnessAccess = HarnessAccessStore.active {
                    HarnessAccessSettingsSection(store: harnessAccess)
                }

            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { agentEnabled = agentEnabledProvider() }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)) { _ in
            agentEnabled = agentEnabledProvider()
        }
    }

}
