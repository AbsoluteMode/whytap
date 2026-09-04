import Foundation

@MainActor
final class AgentProviderStore: ObservableObject {
    /// The singleton instance shared between SettingsWindowController and
    /// AppDelegate so provider selection and turn dispatch see the same state.
    static let shared = AgentProviderStore()

    /// The agent every turn dispatches to. Written only by an explicit,
    /// probe-backed Connect — never by a setup checklist going green on its
    /// own. WHY: docs/decisions/2026-08-02-onboarding-connect-is-probe-backed.md
    @Published private(set) var activeProvider: CLIProviderID?
    /// The provider the user last picked in a chooser, even when Connect has
    /// not succeeded yet (CLI still installing, sign-in pending). A UI-restore
    /// hint only: reopening the onboarding pane lands on the user's pick
    /// instead of snapping back to the Claude default. Turn dispatch never
    /// reads this — `activeProvider` is the only thing that runs a CLI.
    @Published private(set) var preferredProvider: CLIProviderID?
    private let defaults: UserDefaults
    private static let key = "agent.activeProvider"
    private static let preferredKey = "agent.preferredProvider"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.activeProvider = defaults.string(forKey: Self.key).flatMap(CLIProviderID.init)
        self.preferredProvider = defaults.string(forKey: Self.preferredKey).flatMap(CLIProviderID.init)
    }

    func markConnected(_ id: CLIProviderID) {
        activeProvider = id                            // radio: replaces any previous
        defaults.set(id.rawValue, forKey: Self.key)
        selectPreferred(id)
    }

    /// Remember a chooser pick without connecting. Keeps the onboarding pane
    /// on the provider the user selected across re-entry, so a half-finished
    /// setup (CLI installed, sign-in still pending) is not silently reverted.
    func selectPreferred(_ id: CLIProviderID) {
        preferredProvider = id
        defaults.set(id.rawValue, forKey: Self.preferredKey)
    }

    func disconnect() {
        activeProvider = nil
        defaults.removeObject(forKey: Self.key)
        // The pick survives a disconnect: the user turned the agent off, they
        // did not change their mind about which CLI is theirs.
    }
}
