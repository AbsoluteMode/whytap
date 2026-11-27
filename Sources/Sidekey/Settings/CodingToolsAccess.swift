import Combine
import Foundation

/// Settings -> Integrations -> Coding tools: Claude Code and Codex, one switch
/// each. On adds Whytap's MCP server to the tool (the same client setup as
/// Case -> Connect and the onboarding, `CaseClientSetup.connect`) and records
/// the person's Yes in `HarnessAccessStore`; off records No. The MCP entry is
/// left in place when the switch goes off: without a Yes the gate refuses the
/// tool, as for a No given in the island. The switch shows the answer the gate
/// applies, so a Yes can always be taken back, even for a tool Whytap no
/// longer finds or whose entry is gone.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsAccess: ObservableObject {
    /// Offered in this order. Their harness identities are
    /// `CaseCallerResolver.knownAIApps`.
    static let tools: [CaseKnownClient] = [.claudeCode, .codex]

    enum Presence: Equatable {
        case checking
        case notInstalled
        /// On this Mac; `configured`: its `whytap` entry is exactly Whytap's.
        case installed(configured: Bool)
        /// On this Mac with a `whytap` entry Whytap did not write (or cannot
        /// read). Whytap does not judge whether it works and leaves it alone.
        case customEntry
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
                guard found.installed else { return .notInstalled }
                switch found.entry {
                case .none: return .installed(configured: false)
                case .ours: return .installed(configured: true)
                case .custom: return .customEntry
                }
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
    private var storeWatch: AnyCancellable?
    /// Each presence read gets a number when it starts; a read that started
    /// before the last one applied (a refresh overtaken by Connect) is dropped.
    private var reads = 0
    private var applied: [CaseKnownClient: Int] = [:]
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
        // A Yes or No given in the island shows here at once, and so does a
        // save that went through later (the warning under the list).
        storeWatch = found.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Reads the tool's presence and keeps it unless a newer read was applied.
    private func readPresence(_ tool: CaseKnownClient) async {
        reads += 1
        let number = reads
        let found = await probe.presence(tool)
        guard number > applied[tool, default: 0] else { return }
        applied[tool] = number
        presence[tool] = found
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

    /// The switch: the tool may use Whytap (the gate's answer now). The line
    /// under it says whether Whytap's MCP server is in the tool too.
    func isConnected(_ tool: CaseKnownClient) -> Bool { decision(tool) == .allow }

    /// On needs the tool on this Mac; Off is always there for a Yes.
    func canSwitch(_ tool: CaseKnownClient) -> Bool {
        guard store != nil, !busy.contains(tool) else { return false }
        if isConnected(tool) { return true }
        if case .installed = presence[tool] { return true }
        return false
    }

    func refresh() async {
        attachStore()
        // The answer that applies now: a Yes whose seal is gone no longer shows.
        store?.loadIfNeeded()
        for tool in Self.tools where !busy.contains(tool) {
            await readPresence(tool)
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
        // An answer given meanwhile (a No in the island) is newer than this On.
        let answered = store.revision(for: client.identity)
        busy.insert(tool)
        let reported = await probe.connect(tool)
        await readPresence(tool)
        busy.remove(tool)
        // Setup refused (no helper in this app): no new Yes, whatever is there.
        guard !reported.contains(CaseClientSetup.helperMissingMessage),
              presence[tool] == .installed(configured: true) else {
            problems[tool] = reported.isEmpty ? Self.notAddedProblem : reported.joined(separator: "\n")
            return
        }
        guard store.revision(for: client.identity) == answered else { return }
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
        case .customEntry:
            line = isConnected(tool)
                ? "Allowed to use Whytap. \(name) has its own whytap MCP entry, which Whytap leaves as it is. Turn off to take the access back."
                : "\(name) has its own whytap MCP entry, which Whytap leaves as it is. Remove it in \(name) to connect here, or answer Yes when \(name) asks for access."
        case .notInstalled:
            line = isConnected(tool)
                ? "Not found on this Mac, but still allowed to use Whytap. Turn off to take that back."
                : "Not installed on this Mac."
        case .installed(let configured):
            if store == nil {
                line = "Not connected. Connect it in the installed Whytap app."
            } else if isConnected(tool) && configured {
                line = "Connected. Through Whytap’s MCP server it reads your meetings, adds Vocab and Filler words and changes settings."
            } else if isConnected(tool) {
                line = "Allowed to use Whytap, but \(name) has no working whytap MCP server. Turn off and on again to add it."
            } else {
                line = "Not connected. Turn on to add Whytap’s MCP server to \(name) and let it use Whytap."
            }
        }
        if let problem = problems[tool] { line += "\n" + problem }
        return line
    }
}
