import AppKit
import SwiftUI

@MainActor
struct SettingsIntegrationsView: View {
    @ObservedObject var model: BackupViewModel = .shared
    /// Claude Code and Codex; tests pass fixed answers.
    let codingTools: CodingToolsAccess
    @State private var showToken = false
    @State private var token = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Integrations").font(.system(size: 20, weight: .semibold))
                MacCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            GitHubConnectionLabel(model: model)
                            Spacer()
                            if model.canUseGitHubBackup {
                                IntegrationAction(title: "Check connection", enabled: !model.isBusy) {
                                    Task { await model.checkGitHubConnection() }
                                }
                                IntegrationAction(title: "Disconnect",
                                          enabled: !model.isBusy && !model.hasPendingMaintenance && !model.needsRestart) {
                                    model.disconnectGitHub()
                                }
                            } else {
                                IntegrationAction(title: "Connect GitHub", primary: true, enabled: !model.isBusy) {
                                    Task {
                                        await model.connectExistingGitHub()
                                        if !model.canUseGitHubBackup { showToken = true }
                                    }
                                }
                            }
                        }
                        if model.canUseGitHubBackup {
                            Text(model.destinationName.replacingOccurrences(of: "GitHub · ", with: ""))
                                .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                        } else if showToken {
                            SecureField("GitHub access token", text: $token)
                                .textFieldStyle(.roundedBorder).onSubmit { connectToken() }
                            HStack {
                                IntegrationLink(title: "Create token", destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Whytap%20Backup")!)
                                    .font(.system(size: 12))
                                Spacer()
                                IntegrationAction(title: "Connect", primary: true,
                                          enabled: !model.isBusy && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                                    connectToken()
                                }
                            }
                        } else {
                            IntegrationAction(title: "Use access token", enabled: !model.isBusy) { showToken = true }
                        }
                        if let error = model.githubConnectionError {
                            Text(error).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(14)
                }
                // Calendars moved to Features → Calendar; Integrations keeps
                // GitHub and the coding tools that use Whytap (its MCP server).
                // WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
                // Coding tools (Claude Code, Codex) moved here from the
                // removed Agents tab: the plugin cannot grant itself access.
                // WHY: .project-docs/decisions/2026-11-20-other-feature-videos.md
                HarnessAccessSettingsSection(tools: codingTools)
            }
            .foregroundStyle(MacSettingsTheme.text)
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .focusable(false)
        .task { await model.checkGitHubConnection() }
        .onDisappear { token = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in token = "" }
    }

    private func connectToken() {
        guard !model.isBusy, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let value = token; token = ""
        Task { await model.connectGitHub(token: value) }
    }
}

@MainActor
struct GitHubConnectionLabel: View {
    @ObservedObject var model: BackupViewModel

    private var title: String {
        switch model.githubConnectionState {
        case .disconnected: return "GitHub · Not connected"
        case .checking: return "GitHub · Checking…"
        case .connected: return "GitHub · Connected"
        case .needsAttention: return "GitHub · Reconnect"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.githubConnectionState == .checking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.canUseGitHubBackup ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.canUseGitHubBackup ? MacSettingsTheme.green : MacSettingsTheme.text2)
            }
            Text(title).font(.system(size: 13, weight: .medium))
        }.accessibilityElement(children: .combine).accessibilityLabel(title)
    }
}
