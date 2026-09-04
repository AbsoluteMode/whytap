import AppKit
import Combine
import Foundation
import SwiftUI

/// Live agent-setup surface for the onboarding Try-Agent step. Wraps the
/// production `AgentSetupChecklistViewModel` (one per provider) and the
/// `AgentProviderStore`, mirroring the active provider's checklist into
/// the four onboarding statuses. Connect actions reuse the same paths as
/// Settings → Agents (copy command, open Terminal, open install guide) —
/// including the connection itself, which is decided by the provider probe.
///
/// Lives in the Sidekey target only — the preview uses
/// `MockAgentSetupSurface`.
@MainActor
final class RealOnboardingAgentSetupSurface: ObservableObject, OnboardingAgentSetupSurface {
    @Published var provider: OnboardingAgentProvider {
        didSet {
            guard provider != oldValue else { return }
            // Remember the pick immediately, before any probe succeeds: the
            // pane must reopen on the provider the user chose, not on the
            // Claude default.
            store.selectPreferred(Self.cliID(provider))
            syncConnected()
            rebind()
        }
    }
    @Published private(set) var homebrew: OnboardingAgentStepStatus = .checking
    @Published private(set) var node: OnboardingAgentStepStatus = .checking
    @Published private(set) var cli: OnboardingAgentStepStatus = .checking
    @Published private(set) var signedIn: OnboardingAgentStepStatus = .checking
    @Published private(set) var isConnected = false

    private let store: AgentProviderStore
    private let claudeChecklist: AgentSetupChecklistViewModel
    private let codexChecklist: AgentSetupChecklistViewModel
    private var snapshotCancellable: AnyCancellable?
    private var activeProviderCancellable: AnyCancellable?
    private var started = false

    /// The store and probes are injectable so the connect contract can be
    /// tested without a real CLI on the machine; production uses the shared
    /// store and the live probes.
    init(
        store: AgentProviderStore = .shared,
        claudeProbes: AgentSetupProbes = .claude(),
        codexProbes: AgentSetupProbes = .codex()
    ) {
        self.store = store
        self.claudeChecklist = AgentSetupChecklistViewModel(probes: claudeProbes)
        self.codexChecklist = AgentSetupChecklistViewModel(probes: codexProbes)
        // The connected agent wins; failing that, the user's last pick. Only a
        // user who has never chosen lands on the Claude default.
        let restored = store.activeProvider ?? store.preferredProvider
        provider = (restored == .codex) ? .codex : .claude
        rebind()
        syncConnected()
        // Settings → Agents can connect or disconnect while onboarding is
        // open; keep the pane's connected state honest either way.
        activeProviderCancellable = store.$activeProvider
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncConnected() }
    }

    private var active: AgentSetupChecklistViewModel {
        provider == .claude ? claudeChecklist : codexChecklist
    }

    func start() {
        started = true
        active.start()
        apply(active.snapshot)
    }

    func stop() {
        started = false
        claudeChecklist.stop()
        codexChecklist.stop()
    }

    /// Probe the selected provider and, on success, make it the active agent.
    /// This is the ONLY path in onboarding that writes the active provider —
    /// an explicit user action, backed by the same probe Settings → Agents
    /// uses, and deliberately not gated on the Homebrew / Node rows (a Codex
    /// from `/Applications/Codex.app` or an nvm npm prefix needs neither).
    /// WHY: docs/decisions/2026-08-02-onboarding-connect-is-probe-backed.md
    func confirmConnection() async -> OnboardingAgentConnectResult {
        let requested = Self.cliID(provider)
        let outcome = await AgentSetupChecklistViewModel.probeOnce(active.probes)
        // The chooser may have moved while the probe was spawning a process;
        // a stale result must never connect a provider the user left behind.
        guard Self.cliID(provider) == requested else { return .failed }
        switch outcome {
        case .connected:
            store.markConnected(requested)
            syncConnected()
            return .connected
        case .notInstalled:
            return .notInstalled
        case .notLoggedIn:
            return .notSignedIn
        case .billing, .failed:
            return .failed
        }
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openTerminal() {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// The real answer surface: streams the live agent response straight from
    /// the island's `AskResponseStore` (see `OnboardingAgentLiveAnswer`).
    func answerContent() -> AnyView {
        AnyView(OnboardingAgentLiveAnswer())
    }

    // MARK: - Binding

    static func cliID(_ provider: OnboardingAgentProvider) -> CLIProviderID {
        provider == .claude ? .claude : .codex
    }

    private func syncConnected() {
        isConnected = store.activeProvider == Self.cliID(provider)
    }

    private func rebind() {
        // Only the active provider's checklist polls; the other is paused.
        let inactive = provider == .claude ? codexChecklist : claudeChecklist
        inactive.stop()
        snapshotCancellable = active.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.apply(snapshot) }
        if started {
            active.start()
        }
    }

    /// Mirrors the active checklist into the four onboarding rows. It does NOT
    /// connect anything: an all-green checklist used to call `markConnected`
    /// here, which silently claimed Claude — the pane's default provider — for
    /// any user who merely opened the Agent tab with Claude Code installed,
    /// and that stuck pick then outranked every later attempt to pick Codex.
    private func apply(_ snapshot: AgentSetupSnapshot) {
        homebrew = Self.map(snapshot.homebrew)
        node = Self.map(snapshot.node)
        cli = Self.map(snapshot.cli)
        signedIn = Self.map(snapshot.signedIn)
    }

    private static func map(_ status: AgentSetupStepStatus) -> OnboardingAgentStepStatus {
        switch status {
        case .checking: return .checking
        case .satisfied: return .satisfied
        case .unsatisfied: return .unsatisfied
        }
    }
}
