import Combine
import Foundation

/// What Settings last learned about one harness on this Mac.
enum HarnessStatus: Equatable {
    case unknown
    case checking
    case ready
    case notInstalled
    case signedOut
    case billing
    case failed(String)
}

/// Keys & models → Models → Harness: which of the user's own coding tools runs
/// the Agent, and its model, reasoning and Fast mode. A pick becomes active only
/// after its sign-in check passes; nothing is chosen by itself.
// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
@MainActor
final class HarnessSettingsModel: ObservableObject {
    let store: AgentProviderStore
    let settings: AgentSettingsStore
    @Published private(set) var statuses: [CLIProviderID: HarnessStatus] = [:]
    /// The harness the last pick or check was about, so its problem is shown
    /// even when it did not become active.
    @Published private(set) var attempted: CLIProviderID?

    private let probe: (CLIProviderID) async -> ConnectOutcome
    private let refreshClaude: (AgentSettingsStore) async -> Void
    private let refreshCodex: (AgentSettingsStore) async -> Void
    private var forwarding: [AnyCancellable] = []

    init(store: AgentProviderStore = .shared,
         settings: AgentSettingsStore = .shared,
         probe: @escaping (CLIProviderID) async -> ConnectOutcome = HarnessSettingsModel.liveProbe,
         refreshClaude: @escaping (AgentSettingsStore) async -> Void = { await $0.refreshClaudeCatalog(force: true) },
         refreshCodex: @escaping (AgentSettingsStore) async -> Void = { await $0.refreshCodexCatalog(force: true) }) {
        self.store = store
        self.settings = settings
        self.probe = probe
        self.refreshClaude = refreshClaude
        self.refreshCodex = refreshCodex
        // The row's words follow the stores the pickers write.
        forwarding = [store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
                      settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }]
    }

    static func liveProbe(_ id: CLIProviderID) async -> ConnectOutcome {
        switch id {
        case .claude: return await ClaudeCodeProvider().probe()
        case .codex: return await CodexProvider().probe()
        }
    }

    static func name(_ id: CLIProviderID) -> String {
        switch id {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var active: CLIProviderID? { store.activeProvider }
    func status(_ id: CLIProviderID) -> HarnessStatus { statuses[id] ?? .unknown }
    var isChecking: Bool { statuses.values.contains(.checking) }

    /// The user picked a harness in the menu: check its sign-in, then make it
    /// the Agent's harness. A failed check leaves the previous one in place.
    func choose(_ id: CLIProviderID) async {
        attempted = id
        guard await check(id) else { return }
        store.markConnected(id)
        await refreshCatalog(id)
    }

    /// "Check again", and the first time the row opens: the active harness
    /// (or the last pick that failed) and its model list.
    func refresh() async {
        guard let id = attempted ?? active else { return }
        let ok = await check(id)
        // A pick that failed before (not installed, signed out) becomes the
        // Agent's harness once it passes: the user chose it.
        if ok, attempted == id, active != id { store.markConnected(id) }
        if ok { await refreshCatalog(id) }
    }

    @discardableResult
    private func check(_ id: CLIProviderID) async -> Bool {
        statuses[id] = .checking
        let outcome = await probe(id)
        let status: HarnessStatus
        switch outcome {
        case .connected: status = .ready
        case .notInstalled: status = .notInstalled
        case .notLoggedIn: status = .signedOut
        case .billing: status = .billing
        case .failed(_, let message): status = .failed(message)
        }
        statuses[id] = status
        return status == .ready
    }

    private func refreshCatalog(_ id: CLIProviderID) async {
        switch id {
        case .claude: await refreshClaude(settings)
        case .codex: await refreshCodex(settings)
        }
    }

    // MARK: Words

    /// Closed row: harness · model · reasoning, or what is missing.
    var summaryParts: [String] {
        guard let id = active else { return ["Not set up"] }
        var parts = [Self.name(id)]
        switch id {
        case .claude:
            parts.append(settings.selectedClaudeOption?.displayName
                         ?? settings.claudeRunModel ?? "Default model")
            if let effort = settings.claudeRunEffort { parts.append(Self.effortLabel(effort)) }
        case .codex:
            parts.append(settings.selectedCodexOption?.label ?? settings.selectedCodexModel ?? "Default model")
            if let effort = settings.options(for: .codex).effort { parts.append(Self.effortLabel(effort)) }
            if fastModeOn { parts.append("Fast") }
        }
        return parts
    }

    static func effortLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "xhigh": return "Very high"
        default: return level.capitalized
        }
    }

    /// The line under the controls: the state of the harness the user is
    /// dealing with, in words.
    var statusLine: (text: String, isProblem: Bool)? {
        guard let id = attempted ?? active else {
            return ("Choose Claude Code or Codex. The Agent runs on the one you already use, with your sign-in.",
                    store.needsHarnessChoice)
        }
        let name = Self.name(id)
        switch status(id) {
        case .unknown: return nil
        case .checking: return ("Checking \(name)…", false)
        case .ready:
            if id == .claude, let error = settings.claudeCatalogError { return (error, true) }
            if id == .codex, let error = settings.codexCatalogError { return (error, true) }
            if id == .claude, let version = settings.claudeVersion { return ("Ready · \(name) \(version)", false) }
            return ("Ready · \(name)", false)
        case .notInstalled:
            return ("\(name) isn’t on this Mac. Install it, sign in, then check again.", true)
        case .signedOut:
            return (id == .claude ? "Claude Code is signed out. Run claude in Terminal and sign in, then check again."
                                  : "Codex is signed out. Run codex login in Terminal, then check again.", true)
        case .billing:
            return ("Your \(name) plan can’t run requests right now.", true)
        case .failed(let message):
            return (message, true)
        }
    }

    /// The setup contour: the Agent is on (or was before) and has no harness.
    func needsSetup(agentEnabled: Bool) -> Bool {
        active == nil && (agentEnabled || store.needsHarnessChoice)
    }

    // MARK: Codex Fast mode

    /// The selected Codex model's Fast tier, if it has one.
    var fastTier: CodexModelOption.ServiceTier? {
        settings.selectedCodexOption?.tiers.first { ["priority", "fast"].contains($0.id.lowercased()) }
    }

    var fastModeOn: Bool {
        guard let tier = fastTier else { return false }
        return settings.options(for: .codex).serviceTier == tier.id
    }

    func setFastMode(_ on: Bool) {
        guard let tier = fastTier else { return }
        settings.codexServiceTier = on ? tier.id : "default"
    }
}
