import Foundation

/// One step of the agent setup checklist.
enum AgentSetupStepStatus: Equatable {
    /// First check still in flight — the row shows a small spinner.
    case checking
    case satisfied
    case unsatisfied
}

/// The four checks the Settings → Agents setup guide tracks per provider.
struct AgentSetupSnapshot: Equatable {
    var homebrew: AgentSetupStepStatus = .checking
    var node: AgentSetupStepStatus = .checking
    var cli: AgentSetupStepStatus = .checking
    var signedIn: AgentSetupStepStatus = .checking

    var allSatisfied: Bool {
        [homebrew, node, cli, signedIn].allSatisfy { $0 == .satisfied }
    }

    var satisfiedCount: Int {
        [homebrew, node, cli, signedIn].filter { $0 == .satisfied }.count
    }
}

/// Injectable check implementations, one set per provider. Each closure may
/// spawn a process (login-shell `command -v`, locator, CLI probe), so they are
/// only ever invoked off the main actor by `AgentSetupChecklistViewModel`.
struct AgentSetupProbes {
    var brewInstalled: () -> Bool
    var nodeInstalled: () -> Bool
    var cliInstalled: () -> Bool
    var probe: () async -> ConnectOutcome

    static func claude() -> AgentSetupProbes {
        AgentSetupProbes(
            brewInstalled: { DevToolDetector().brewInstalled() },
            nodeInstalled: { DevToolDetector().nodeInstalled() },
            cliInstalled: { ClaudeBinaryLocator().locate() != nil },
            probe: { await ClaudeCodeProvider().probe() }
        )
    }

    static func codex() -> AgentSetupProbes {
        AgentSetupProbes(
            brewInstalled: { DevToolDetector().brewInstalled() },
            nodeInstalled: { DevToolDetector().nodeInstalled() },
            cliInstalled: { CodexBinaryLocator().locate() != nil },
            probe: { await CodexProvider().probe() }
        )
    }
}

/// Polls the four setup checks while the checklist is visible, so statuses go
/// green by themselves within a couple of seconds after the user installs
/// something in Terminal. Mirrors `RealOnboardingPermissionsSurface`'s
/// timer-poll shape, with one difference dictated by the heavier checks
/// (process spawns instead of TCC reads): cycles run async, off the main
/// actor, and are serialized — a tick that lands mid-cycle is skipped, so
/// spawns never pile up.
@MainActor
final class AgentSetupChecklistViewModel: ObservableObject {
    @Published private(set) var snapshot = AgentSetupSnapshot()

    /// Exposed so a Connect action can run the same probe this checklist
    /// polls with, without building a second set of closures.
    let probes: AgentSetupProbes
    private let pollInterval: TimeInterval
    private var pollTimer: Timer?
    /// Non-nil while a refresh cycle is in flight. The nil-guard in
    /// `refresh()` is what serializes cycles.
    private(set) var refreshTask: Task<Void, Never>?

    init(probes: AgentSetupProbes, pollInterval: TimeInterval = 2.0) {
        self.probes = probes
        self.pollInterval = pollInterval
    }

    var isPolling: Bool { pollTimer != nil }

    func start() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        guard refreshTask == nil else { return }
        let probes = self.probes
        refreshTask = Task { [weak self] in
            let snapshot = await Self.check(probes)
            // A cycle cancelled by stop() must not publish a stale result.
            guard !Task.isCancelled else { return }
            self?.snapshot = snapshot
            self?.refreshTask = nil
        }
    }

    /// Runs the four checks off the main actor (nonisolated async → global
    /// executor; each check may block on a spawned process). Sign-in only
    /// probes when the CLI is present: without a binary the probe could only
    /// say `.notInstalled`, which step 3 already covers.
    nonisolated static func check(_ probes: AgentSetupProbes) async -> AgentSetupSnapshot {
        var snapshot = AgentSetupSnapshot()
        snapshot.homebrew = probes.brewInstalled() ? .satisfied : .unsatisfied
        snapshot.node = probes.nodeInstalled() ? .satisfied : .unsatisfied
        let cliPresent = probes.cliInstalled()
        snapshot.cli = cliPresent ? .satisfied : .unsatisfied
        if cliPresent, case .connected = await probes.probe() {
            snapshot.signedIn = .satisfied
        } else {
            snapshot.signedIn = .unsatisfied
        }
        return snapshot
    }

    /// One-shot connect probe, run off the main actor for the same reason as
    /// `check` (it spawns a CLI process). This — not `allSatisfied` — is what
    /// a Connect action must trust: the Homebrew / Node rows guide a user who
    /// has nothing installed yet, but a Codex that came from the app bundle or
    /// an nvm-managed npm prefix connects fine without either of them.
    nonisolated static func probeOnce(_ probes: AgentSetupProbes) async -> ConnectOutcome {
        await probes.probe()
    }
}
