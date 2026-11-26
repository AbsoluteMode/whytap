import Combine
import Foundation

/// Settings -> Integrations -> Coding tools: Claude Code and Codex, one switch
/// each. On adds Whytap's MCP server to the tool (the same client setup as
/// Case -> Connect and the onboarding, `CaseClientSetup.connect`) and records
/// the person's Yes in `HarnessAccessStore`; off records No. The MCP entry is
/// left in place when the switch goes off: without a Yes the gate refuses the
/// tool, as for a No given in the island.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsAccess: ObservableObject {
    /// Offered in this order. Their harness identities are
    /// `CaseCallerResolver.knownAIApps`.
    static let tools: [CaseKnownClient] = [.claudeCode, .codex]

    enum Presence: Equatable {
        case checking
        case notInstalled
        case installed(configured: Bool)
    }

    /// What Settings asks of the Mac. Tests pass fixed answers; nothing here
    /// runs a client or writes its settings except `connect`.
    struct Probe {
        var presence: (CaseKnownClient) async -> Presence
        /// The problems the setup reported; empty when it went through.
        var connect: (CaseKnownClient) async -> [String]

        static func live(setup: CaseClientSetup = .live()) -> Probe {
            Probe(presence: { client in
                let found = await setup.presence(of: client)
                return found.installed ? .installed(configured: found.configured) : .notInstalled
            }, connect: { client in
                await setup.connect(client.identity).problems
            })
        }
    }

    /// The running app's list, created the first time Integrations is shown.
    static let shared = CodingToolsAccess(store: { HarnessAccessStore.active }, probe: .live())

    @Published private(set) var presence: [CaseKnownClient: Presence]
    @Published private(set) var busy: Set<CaseKnownClient> = []
    @Published private(set) var problems: [CaseKnownClient: String] = [:]
    private(set) var store: HarnessAccessStore?

    private let storeSource: () -> HarnessAccessStore?
    private let probe: Probe
    private var grantsWatch: AnyCancellable?
    private let now: () -> Date

    init(store: @escaping () -> HarnessAccessStore?, probe: Probe, now: @escaping () -> Date = Date.init) {
        storeSource = store
        self.probe = probe
        self.now = now
        presence = Dictionary(uniqueKeysWithValues: Self.tools.map { ($0, .checking) })
        attachStore()
    }

    /// The store the app made at launch; Settings may be built before it.
    private func attachStore() {
        guard store == nil, let found = storeSource() else { return }
        store = found
        found.loadIfNeeded()
        // A Yes or No given in the island shows here at once.
        grantsWatch = found.$grants.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    static func harnessClient(_ tool: CaseKnownClient) -> HarnessClient? {
        guard case let .developerID(teamID, signingIdentifier) = tool.identity else { return nil }
        return HarnessClient(identity: HarnessIdentity(teamID: teamID, signingIdentifier: signingIdentifier),
                             name: tool.displayName)
    }

    /// The person's answer that applies now, from the store's published list.
    func decision(_ tool: CaseKnownClient) -> HarnessDecision? {
        guard let identity = Self.harnessClient(tool)?.identity else { return nil }
        return store?.grants.first { $0.identity == identity }?.decision
    }

    /// Whytap's MCP server is in the tool and the tool may use Whytap.
    func isConnected(_ tool: CaseKnownClient) -> Bool {
        presence[tool] == .installed(configured: true) && decision(tool) == .allow
    }

    func canSwitch(_ tool: CaseKnownClient) -> Bool {
        guard store != nil, !busy.contains(tool) else { return false }
        if case .installed = presence[tool] { return true }
        return false
    }

    func refresh() async {
        attachStore()
        for tool in Self.tools where !busy.contains(tool) {
            let found = await probe.presence(tool)
            if !busy.contains(tool) { presence[tool] = found }
        }
    }

    /// On: write the MCP entry, then record Yes once the entry is there (a
    /// `whytap` entry the person wrote counts: Whytap leaves it as it is).
    /// Off: record No at once.
    func set(_ tool: CaseKnownClient, on: Bool) async {
        attachStore()
        guard let store, let client = Self.harnessClient(tool), !busy.contains(tool) else { return }
        problems[tool] = nil
        guard on else {
            store.record(.deny, for: client, at: now())
            return
        }
        // Not on this Mac (or not checked yet): nothing to connect.
        guard case .installed = presence[tool] else { return }
        busy.insert(tool)
        let reported = await probe.connect(tool)
        let found = await probe.presence(tool)
        presence[tool] = found
        busy.remove(tool)
        guard found == .installed(configured: true) else {
            problems[tool] = reported.isEmpty ? Self.notAddedProblem : reported.joined(separator: "\n")
            return
        }
        store.record(.allow, for: client, at: now())
    }

    static let notAddedProblem = "Whytap couldn’t add its MCP server. Try again."

    /// The line under the tool's name.
    func subtitle(_ tool: CaseKnownClient) -> String {
        let name = tool.displayName
        if busy.contains(tool) { return "Connecting…" }
        var line: String
        switch presence[tool] ?? .checking {
        case .checking:
            line = "Checking whether \(name) is on this Mac…"
        case .notInstalled:
            line = "Not installed on this Mac."
        case .installed:
            if store == nil {
                line = "Not connected. Connect it in the installed Whytap app."
            } else if isConnected(tool) {
                line = "Connected. Through Whytap’s MCP server it reads your meetings, adds Vocab and Filler words and changes settings."
            } else {
                line = "Not connected. Turn on to add Whytap’s MCP server to \(name) and let it use Whytap."
            }
        }
        if let problem = problems[tool] { line += "\n" + problem }
        return line
    }
}
