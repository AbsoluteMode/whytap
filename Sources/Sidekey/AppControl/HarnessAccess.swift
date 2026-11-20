import CryptoKit
import Darwin
import Foundation
import Security
import WhytapCaseKit

// WHY: .project-docs/decisions/2026-11-20-harness-access.md

/// The coding harness whose own process started the plugin's MCP server.
struct HarnessIdentity: Hashable, Codable, Sendable {
    let teamID: String
    let signingIdentifier: String
}

struct HarnessClient: Equatable, Sendable {
    let identity: HarnessIdentity
    let name: String
}

enum HarnessDecision: String, Codable, Sendable {
    case allow, deny
}

/// The user's remembered answer for one harness.
struct HarnessGrant: Codable, Equatable, Identifiable, Sendable {
    let identity: HarnessIdentity
    let name: String
    let decision: HarnessDecision
    let decidedAt: Date
    var id: HarnessIdentity { identity }
}

// MARK: Who is asking

protocol HarnessCallerResolving {
    func client(peerPID: pid_t) -> HarnessClient?
}

/// Only the helper's direct parent counts. A script running in the harness's
/// shell has a shell or an interpreter as the helper's parent, so it does not
/// inherit the harness's access; the harness starts its MCP servers itself.
struct HarnessCallerResolver: HarnessCallerResolving {
    let inspector: CaseProcessInspecting

    func client(peerPID: pid_t) -> HarnessClient? {
        guard peerPID > 1, let peer = inspector.info(pid: peerPID), peer.parentPID > 1,
              let parent = inspector.info(pid: peer.parentPID),
              // teamID is present only when an Apple certificate chain vouches for it.
              let team = parent.teamID, let identifier = parent.signingIdentifier,
              let known = CaseCallerResolver.knownAIApps.first(where: {
                  $0.teamID == team && $0.identifier == identifier
              })
        else { return nil }
        return HarnessClient(
            identity: HarnessIdentity(teamID: team, signingIdentifier: identifier), name: known.name)
    }
}

// MARK: Remembered answers

/// Answers live in a file whose contents are authenticated with a key only
/// Whytap's Keychain item holds: another process of the same user can delete
/// or corrupt the file (every harness is then asked again) but cannot write
/// itself an `allow`.
@MainActor
final class HarnessAccessStore: ObservableObject {
    private struct Envelope: Codable {
        let payload: Data
        let mac: Data
    }

    @Published private(set) var grants: [HarnessGrant] = []

    /// The running app's store, for Settings -> Agents. Nil outside a packaged app.
    static weak var active: HarnessAccessStore?

    private let fileURL: URL?
    private let key: () -> SymmetricKey?
    private var loaded = false

    /// `fileURL == nil` keeps answers for this launch only.
    init(fileURL: URL?, key: @escaping () -> SymmetricKey?) {
        self.fileURL = fileURL
        self.key = key
    }

    func decision(for identity: HarnessIdentity) -> HarnessDecision? {
        loadIfNeeded()
        return grants.first { $0.identity == identity }?.decision
    }

    func record(_ decision: HarnessDecision, for client: HarnessClient, at date: Date) {
        loadIfNeeded()
        grants.removeAll { $0.identity == client.identity }
        grants.append(HarnessGrant(identity: client.identity, name: client.name, decision: decision, decidedAt: date))
        save()
    }

    /// Forgets the answer: the harness is asked again on its next request.
    func forget(_ identity: HarnessIdentity) {
        loadIfNeeded()
        grants.removeAll { $0.identity == identity }
        save()
    }

    /// Reads the file once a key is available. Without the key (Keychain not
    /// readable yet) nothing is trusted and the read is retried later.
    func loadIfNeeded() {
        guard !loaded, let key = key() else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload, using: key),
              let stored = try? JSONDecoder().decode([HarnessGrant].self, from: envelope.payload)
        else { return }
        // Answers given before the Keychain became readable win over the file.
        let fresh = Set(grants.map(\.identity))
        grants = stored.filter { !fresh.contains($0.identity) } + grants
    }

    private func save() {
        guard loaded, let fileURL, let key = key(),
              let payload = try? JSONEncoder().encode(grants) else { return }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        guard let data = try? JSONEncoder().encode(Envelope(payload: payload, mac: mac)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// The signing key of the answers file: device-bound, never synchronized.
enum HarnessAccessKeychain {
    static let account = "harness_access.signing_key"

    static func key(service: String) -> SymmetricKey? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        var read = base
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // Any other failure (locked, dark wake) must not replace an existing key.
        guard status == errSecItemNotFound else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        var add = base
        add[kSecValueData as String] = Data(bytes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return SymmetricKey(data: Data(bytes))
    }
}

// MARK: Asking the user

enum HarnessAccessOutcome: Equatable, Sendable {
    case allow, deny, timedOut
}

@MainActor
protocol HarnessAccessPresenting: AnyObject {
    func requestAccess(for client: HarnessClient) async -> HarnessAccessOutcome
}

/// Stands between the authenticated helper and the application controls that
/// read the user's content or act for them. Settings and To-do keep their
/// earlier boundary. Case secrets are never reachable from here.
@MainActor
final class HarnessAccessGate {
    static let requestOperation = "request_access"
    /// Every operation that needs the user's Yes for the calling harness.
    static let gatedOperations: Set<String> = [
        "meetings_search", "meeting_get", "meeting_transcript", "meeting_open",
    ]

    private let resolver: HarnessCallerResolving
    private let store: HarnessAccessStore
    private weak var presenter: HarnessAccessPresenting?
    private let now: () -> Date
    private var pending: [HarnessIdentity: Task<HarnessAccessOutcome, Never>] = [:]
    /// A prompt the user left unanswered is not shown again just because the
    /// harness started another session; a real request still asks.
    private var askedUnprompted: Set<HarnessIdentity> = []

    init(resolver: HarnessCallerResolving, store: HarnessAccessStore,
         presenter: HarnessAccessPresenting?, now: @escaping () -> Date = Date.init) {
        self.resolver = resolver
        self.store = store
        self.presenter = presenter
        self.now = now
    }

    /// `nil` lets the request through to the application controls.
    func intercept(_ request: AppControlRequest, peerPID: pid_t) async -> AppControlResponse? {
        if request.operation == Self.requestOperation {
            guard request.arguments.isEmpty else {
                return .failure("invalid_arguments", "request_access takes no arguments.")
            }
            guard let client = resolver.client(peerPID: peerPID) else { return Self.unsupported }
            switch store.decision(for: client.identity) {
            case .allow: return Self.status(client, "allowed")
            case .deny: return Self.status(client, "denied")
            case nil:
                if pending[client.identity] == nil, askedUnprompted.insert(client.identity).inserted {
                    _ = ask(client)
                }
                return Self.status(client, "pending")
            }
        }
        guard Self.gatedOperations.contains(request.operation) else { return nil }
        guard let client = resolver.client(peerPID: peerPID) else { return Self.unsupported }
        switch store.decision(for: client.identity) {
        case .allow:
            return nil
        case .deny:
            return Self.denied(client)
        case nil:
            let outcome = await ask(client).value
            // The client went away while the prompt was up: it gets nothing.
            guard !Task.isCancelled else { return .failure("cancelled", "Request cancelled.") }
            switch outcome {
            case .allow: break
            case .deny: return Self.denied(client)
            case .timedOut:
                return .failure("approval_timed_out",
                    "Whytap asked the user to allow \(client.name) and got no answer. Ask them to answer the prompt in Whytap, then retry.")
            }
        }
        // The answer is for this harness as it is now, not for a snapshot.
        guard resolver.client(peerPID: peerPID) == client, store.decision(for: client.identity) == .allow else {
            return Self.denied(client)
        }
        return nil
    }

    /// One prompt per harness however many requests wait for it. It does not
    /// belong to the request that started it, so a session that ends does not
    /// take the question away from the user.
    private func ask(_ client: HarnessClient) -> Task<HarnessAccessOutcome, Never> {
        if let running = pending[client.identity] { return running }
        let task = Task { @MainActor [weak self] () -> HarnessAccessOutcome in
            guard let self, let presenter = self.presenter else { return .timedOut }
            let outcome = await presenter.requestAccess(for: client)
            self.pending[client.identity] = nil
            switch outcome {
            case .allow: self.store.record(.allow, for: client, at: self.now())
            case .deny: self.store.record(.deny, for: client, at: self.now())
            case .timedOut: break
            }
            return outcome
        }
        pending[client.identity] = task
        return task
    }

    private static func status(_ client: HarnessClient, _ access: String) -> AppControlResponse {
        .success(.object(["client": .string(client.name), "access": .string(access)]))
    }

    private static func denied(_ client: HarnessClient) -> AppControlResponse {
        .failure("access_denied",
            "The user has not allowed \(client.name) to use Whytap. They can change it in Whytap Settings → Agents. Do not retry.")
    }

    private static let unsupported = AppControlResponse.failure("unsupported_client",
        "These Whytap tools work only from the Whytap MCP server that Claude Code or Codex started itself. A script or a shell command cannot use them.")
}
