import Foundation

/// Which harness runs the Agent: the user's Claude Code or Codex.
///
/// Stored under `agent.harness.active`. The key earlier builds used,
/// `agent.activeProvider` (`"opencode"` for the native agent), is read only to
/// know that this Mac had a connected Agent before, and is never written or
/// removed: a rollback build then finds its native connection, route and key
/// exactly as they were. Nothing connects by itself; a harness becomes active
/// only after the user picks it and its sign-in check passes.
// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
@MainActor
final class AgentProviderStore: ObservableObject {
    /// The singleton instance shared between SettingsWindowController and
    /// AppDelegate so harness selection and turn dispatch see the same state.
    static let shared = AgentProviderStore()

    static let harnesses: [CLIProviderID] = [.claude, .codex]

    /// The harness every turn dispatches to. Written only by an explicit,
    /// probe-backed pick. WHY: docs/decisions/2026-08-02-onboarding-connect-is-probe-backed.md
    @Published private(set) var activeProvider: CLIProviderID?
    /// The Agent was connected before this Mac moved to harnesses (the native
    /// agent or an earlier Claude Code / Codex connection) and no harness is
    /// chosen yet: Settings and the island ask once to choose one.
    @Published private(set) var needsHarnessChoice: Bool

    private let defaults: UserDefaults
    nonisolated static let key = "agent.harness.active"
    /// Earlier builds' key; read-only here.
    static let legacyKey = "agent.activeProvider"
    private static let legacyNeedsSetupKey = "agent.opencode.needsSetup"
    /// Set at the first harness pick: the one-time ask never returns.
    private static let chosenKey = "agent.harness.chosen"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let active = Self.storedHarness(defaults)
        if active == nil, defaults.object(forKey: Self.key) != nil { defaults.removeObject(forKey: Self.key) }
        self.activeProvider = active
        let hadAgent = defaults.string(forKey: Self.legacyKey).flatMap(CLIProviderID.init) != nil
            || defaults.bool(forKey: Self.legacyNeedsSetupKey)
        self.needsHarnessChoice = active == nil && hadAgent && !defaults.bool(forKey: Self.chosenKey)
    }

    private static func storedHarness(_ defaults: UserDefaults) -> CLIProviderID? {
        defaults.string(forKey: key).flatMap(CLIProviderID.init).flatMap { harnesses.contains($0) ? $0 : nil }
    }

    func markConnected(_ id: CLIProviderID) {
        guard Self.harnesses.contains(id) else { return }
        activeProvider = id                            // radio: replaces any previous
        defaults.set(id.rawValue, forKey: Self.key)
        defaults.set(true, forKey: Self.chosenKey)
        needsHarnessChoice = false
    }

    /// No harness: the Agent cannot run until one is chosen again.
    func disconnect() {
        activeProvider = nil
        defaults.removeObject(forKey: Self.key)
    }

    /// A choice that arrived by settings sync or a restored backup.
    func reload() {
        let active = Self.storedHarness(defaults)
        if active != activeProvider { activeProvider = active }
        if active != nil { needsHarnessChoice = false }
    }
}
