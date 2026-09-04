import Foundation

enum AgentConnectNotice: Equatable {
    case connected(CLIProviderID)
    case notInstalled(CLIProviderID)
    case notLoggedIn(CLIProviderID)
    case billing(CLIProviderID)
    case failed(CLIProviderID, String)
}

@MainActor
final class AgentModeViewModel: ObservableObject {
    @Published private(set) var connecting: CLIProviderID?
    let store: AgentProviderStore
    private let probe: (CLIProviderID) async -> ConnectOutcome
    private let notify: (AgentConnectNotice) -> Void

    init(store: AgentProviderStore,
         probe: @escaping (CLIProviderID) async -> ConnectOutcome,
         notify: @escaping (AgentConnectNotice) -> Void) {
        self.store = store
        self.probe = probe
        self.notify = notify
    }

    func connect(_ id: CLIProviderID) async {
        connecting = id
        defer { connecting = nil }
        switch await probe(id) {
        case .connected:        store.markConnected(id); notify(.connected(id))
        case .notInstalled:     notify(.notInstalled(id))
        case .notLoggedIn:      notify(.notLoggedIn(id))
        case .billing:          notify(.billing(id))
        case .failed(_, let m): notify(.failed(id, m))
        }
    }

    /// Deactivates the current agent (radio -> none). Lets the user toggle a
    /// provider off; switching to the other provider is just Connect on it.
    func disconnect() {
        store.disconnect()
    }
}
