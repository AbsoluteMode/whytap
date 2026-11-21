import Foundation

/// The coding agents on this Mac that the last onboarding page offers to
/// connect to Whytap. Connect runs the same client setup as Case -> Connect
/// (`CaseClientSetup.connect`: the `whytap` command and the agent's MCP entry
/// pointing at the bundled helper). It registers nothing in Case: key access
/// still needs Case -> Connect, and meetings still ask once in the island.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
final class OnboardingCodingTools: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    /// Offered in this order when present.
    static let offered: [CaseKnownClient] = [.claudeCode, .codex]

    @Published private(set) var installed: [CaseKnownClient] = []
    @Published private(set) var state: State = .idle

    private let detect: () async -> [CaseKnownClient]
    private let connectClient: (CaseKnownClient) async -> CaseClientSetupReport
    private var detected = false

    init(detect: @escaping () async -> [CaseKnownClient],
         connect: @escaping (CaseKnownClient) async -> CaseClientSetupReport) {
        self.detect = detect
        connectClient = connect
    }

    convenience init() {
        let setup = CaseClientSetup.live()
        self.init(detect: { await setup.installed(among: OnboardingCodingTools.offered) },
                  connect: { await setup.connect($0.identity) })
    }

    /// "Claude Code and Codex", "Claude Code" or "Codex".
    var names: String {
        installed.map(\.displayName).joined(separator: " and ")
    }

    func refreshIfNeeded() async {
        guard !detected else { return }
        detected = true
        let found = await detect()
        installed = Self.offered.filter(found.contains)
    }

    /// Shows a fixed list, for offscreen review images.
    func show(_ clients: [CaseKnownClient], state: State = .idle) {
        detected = true
        installed = clients
        self.state = state
    }

    func connect() {
        guard state != .connecting, !installed.isEmpty else { return }
        state = .connecting
        let clients = installed
        Task { @MainActor in
            var problems: [String] = []
            for client in clients {
                problems += await connectClient(client).problems
            }
            state = problems.isEmpty ? .connected : .failed(problems.joined(separator: "\n"))
        }
    }
}
