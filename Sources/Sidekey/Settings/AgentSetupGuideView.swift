import AppKit
import SwiftUI

/// One step of the setup guide: what to check, how to explain it, and what the
/// user can do when it is not satisfied yet.
struct AgentSetupGuideStep {
    let id: String
    /// Which snapshot field this step reflects.
    let status: KeyPath<AgentSetupSnapshot, AgentSetupStepStatus>
    let title: String
    let detail: String
    /// Copyable install/sign-in command shown while the step is unsatisfied.
    let command: String?
    let link: (label: String, url: URL)?
    let opensTerminal: Bool

    init(
        id: String,
        status: KeyPath<AgentSetupSnapshot, AgentSetupStepStatus>,
        title: String,
        detail: String,
        command: String? = nil,
        link: (label: String, url: URL)? = nil,
        opensTerminal: Bool = false
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.command = command
        self.link = link
        self.opensTerminal = opensTerminal
    }
}

/// Per-provider copy for the four-step setup guide. The first two steps
/// (Homebrew, Node.js) are shared; the CLI and sign-in steps differ. Install
/// links reuse the providers' `installURL` constants — no second hardcode.
struct AgentSetupGuideContent {
    let providerName: String
    let steps: [AgentSetupGuideStep]

    static let claude = make(
        providerName: "Claude Code",
        cliDetail: "The Claude Code CLI — Whytap drives it as your agent.",
        cliCommand: "npm install -g @anthropic-ai/claude-code",
        installURL: ClaudeCodeProvider().installURL,
        signInDetail: "Open Terminal, run claude, and log in with your Anthropic account.",
        signInCommand: "claude"
    )

    static let codex = make(
        providerName: "Codex",
        cliDetail: "The Codex CLI — Whytap drives it as your agent.",
        cliCommand: "npm install -g @openai/codex",
        installURL: CodexProvider().installURL,
        signInDetail: "Open Terminal, run codex login, and sign in with your ChatGPT account.",
        signInCommand: "codex login"
    )

    private static func make(
        providerName: String,
        cliDetail: String,
        cliCommand: String,
        installURL: URL,
        signInDetail: String,
        signInCommand: String
    ) -> AgentSetupGuideContent {
        AgentSetupGuideContent(providerName: providerName, steps: [
            AgentSetupGuideStep(
                id: "homebrew",
                status: \.homebrew,
                title: "Homebrew installed",
                detail: "The macOS package manager — used to install Node.js below.",
                command: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                link: ("Open brew.sh", URL(string: "https://brew.sh")!)
            ),
            AgentSetupGuideStep(
                id: "node",
                status: \.node,
                title: "Node.js installed",
                detail: "The JavaScript runtime the CLI installer runs on.",
                command: "brew install node",
                link: ("Open nodejs.org", URL(string: "https://nodejs.org")!)
            ),
            AgentSetupGuideStep(
                id: "cli",
                status: \.cli,
                title: "\(providerName) installed",
                detail: cliDetail,
                command: cliCommand,
                link: ("Install guide", installURL)
            ),
            AgentSetupGuideStep(
                id: "signin",
                status: \.signedIn,
                title: "Signed in",
                detail: signInDetail,
                command: signInCommand,
                opensTerminal: true
            ),
        ])
    }
}

/// Four-step setup checklist shown inside a provider's card while that
/// provider is not connected. Statuses poll live (see
/// `AgentSetupChecklistViewModel`), so finishing a step in Terminal turns it
/// green here within a couple of seconds. The guide never connects by itself —
/// Connect stays the user's explicit action, and the probe behind it remains
/// the source of truth (a non-standard install can connect with steps unmet).
@MainActor
struct AgentSetupGuideView: View {
    let content: AgentSetupGuideContent
    @ObservedObject var checklist: AgentSetupChecklistViewModel
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                ForEach(content.steps, id: \.id) { step in
                    stepRow(step)
                }
            }
        }
        .padding(.bottom, expanded ? 6 : 0)
        .onAppear { checklist.start() }
        .onDisappear { checklist.stop() }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Set up \(content.providerName)")
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text)
                Spacer(minLength: 8)
                if checklist.snapshot.allSatisfied {
                    MacPill(text: "Ready — press Connect", tone: .green, showsDot: true)
                } else {
                    Text("\(checklist.snapshot.satisfiedCount) of \(content.steps.count) done")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Setup guide for \(content.providerName)")
    }

    private func stepRow(_ step: AgentSetupGuideStep) -> some View {
        let status = checklist.snapshot[keyPath: step.status]
        return HStack(alignment: .top, spacing: 11) {
            statusIcon(status)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text)
                Text(step.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if status != .satisfied {
                    actions(for: step)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusIcon(_ status: AgentSetupStepStatus) -> some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .satisfied:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.green)
        case .unsatisfied:
            Image(systemName: "circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(MacSettingsTheme.text3)
        }
    }

    @ViewBuilder
    private func actions(for step: AgentSetupGuideStep) -> some View {
        HStack(spacing: 8) {
            if let command = step.command {
                CopyableCommandView(command: command)
            }
            if let link = step.link {
                MacButton(title: link.label, style: .ghost) {
                    NSWorkspace.shared.open(link.url)
                }
            }
            if step.opensTerminal {
                MacButton(title: "Open Terminal", style: .ghost) {
                    Self.openTerminal()
                }
            }
        }
    }

    /// Brings Terminal.app forward so the user can run the sign-in command
    /// themselves. Never executes any command on their behalf.
    static func openTerminal() {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Monospaced command capsule; clicking copies the command to the clipboard
/// and shows a brief "Copied" confirmation.
@MainActor
private struct CopyableCommandView: View {
    let command: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 340, alignment: .leading)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied ? MacSettingsTheme.green : MacSettingsTheme.text3)
                if copied {
                    Text("Copied")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.green)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                MacSettingsTheme.fieldBg,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(MacSettingsTheme.sep, lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.15), value: copied)
        }
        .buttonStyle(.plain)
        .help("Copy command")
        .accessibilityLabel("Copy command: \(command)")
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
