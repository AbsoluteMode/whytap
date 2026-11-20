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

enum HarnessAccessStored: Equatable {
    /// The storage cannot be read now (Keychain locked): trust nothing, retry.
    case unavailable
    case empty
    case data(Data)
}

protocol HarnessAccessPersisting {
    func load() -> HarnessAccessStored
    func save(_ data: Data) -> Bool
}

/// Answers live in one Keychain item of this app. A file, even a signed one,
/// could be put back by another process after the user turned access off.
///
/// Checked on the signed app (2026-11-20): it has no entitlements, so the
/// item is in the user's file-based login keychain, like the Case vault key.
/// It stays on this Mac (that keychain is not synchronized) and is readable
/// without a prompt only by code the item's access list trusts, which is the
/// app that created it. `kSecAttrAccessible` applies only to the
/// data-protection keychain and is not set: it would claim a policy this
/// build does not have.
struct HarnessAccessKeychain: HarnessAccessPersisting {
    static let account = "harness_access.answers"
    let service: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account,
         kSecAttrSynchronizable as String: false]
    }

    func load() -> HarnessAccessStored {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(read as CFDictionary, &item) {
        case errSecSuccess: return (item as? Data).map(HarnessAccessStored.data) ?? .unavailable
        case errSecItemNotFound: return .empty
        default: return .unavailable
        }
    }

    func save(_ data: Data) -> Bool {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// The second half of every stored Yes. The Keychain item and the seal carry
/// the same random token, renewed with each successful save. A stored Yes
/// counts only while the two match, so when a No could not reach the
/// Keychain, replacing the seal's token is enough to cancel every stored Yes:
/// the old token is nowhere on disk afterwards. A missing or unreadable seal
/// matches nothing. The harness is then asked again; a stored No never needs
/// the seal.
struct HarnessAccessSeal: Codable, Equatable {
    var token: String
    /// Nos the Keychain has not taken yet. They only take access away.
    var revoked: [HarnessGrant]
}

protocol HarnessAccessSealing {
    /// nil when there is no seal or it cannot be read.
    func load() -> HarnessAccessSeal?
    /// True only when the seal is on disk as written.
    func save(_ seal: HarnessAccessSeal) -> Bool
}

/// Written atomically and read back from disk before it is trusted:
/// preferences are flushed later and could not be verified.
struct HarnessAccessSealFile: HarnessAccessSealing {
    let url: URL

    func load() -> HarnessAccessSeal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HarnessAccessSeal.self, from: data)
    }

    func save(_ seal: HarnessAccessSeal) -> Bool {
        guard let data = try? JSONEncoder().encode(seal) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        return load() == seal
    }
}

@MainActor
final class HarnessAccessStore: ObservableObject {
    private struct Document: Codable {
        var token: String
        var grants: [HarnessGrant]
    }

    @Published private(set) var grants: [HarnessGrant] = []
    /// True while an answer of this launch is not in the Keychain yet.
    @Published private(set) var hasUnsavedAnswers = false
    /// True when a No reached neither the Keychain nor the seal: it holds
    /// until Whytap quits and nothing guarantees it afterwards.
    @Published private(set) var revocationUnverified = false

    /// The running app's store, for Settings -> Agents. Nil outside a packaged app.
    static weak var active: HarnessAccessStore?

    private let persistence: HarnessAccessPersisting?
    private let seal: HarnessAccessSealing?
    private let makeToken: () -> String
    private var loaded = false
    /// Nos the Keychain has not taken yet.
    private var unsavedDenies: Set<HarnessIdentity> = []
    /// Of those, the ones the seal has not taken either.
    private var unverifiedDenies: Set<HarnessIdentity> = [] {
        didSet { revocationUnverified = !unverifiedDenies.isEmpty }
    }

    /// Without `persistence` answers last for this launch only. Without
    /// `seal` a stored Yes needs no second half (tests of other behaviour).
    init(persistence: HarnessAccessPersisting?, seal: HarnessAccessSealing? = nil,
         makeToken: @escaping () -> String = { UUID().uuidString }) {
        self.persistence = persistence
        self.seal = seal
        self.makeToken = makeToken
        loaded = persistence == nil
        // A No an earlier launch could not store applies before the Keychain
        // is read, and wins over what it holds.
        let pending = (seal?.load()?.revoked ?? []).filter { $0.decision == .deny }
        grants = pending
        unsavedDenies = Set(pending.map(\.identity))
        hasUnsavedAnswers = !pending.isEmpty
    }

    func decision(for identity: HarnessIdentity) -> HarnessDecision? {
        loadIfNeeded()
        // A refused write is retried on every read.
        if hasUnsavedAnswers { persist() }
        return grants.first { $0.identity == identity }?.decision
    }

    /// The answer applies at once; false when the Keychain did not take it.
    /// A refused No then cancels every stored Yes through the seal, so the
    /// old Yes cannot return after a relaunch.
    @discardableResult
    func record(_ decision: HarnessDecision, for client: HarnessClient, at date: Date) -> Bool {
        loadIfNeeded()
        let grant = HarnessGrant(identity: client.identity, name: client.name, decision: decision, decidedAt: date)
        grants.removeAll { $0.identity == client.identity }
        grants.append(grant)
        if persist() { return true }
        // A Yes for this tool reverses its own unsaved No, nobody else's.
        if decision == .deny { unsavedDenies.insert(client.identity) } else { unsavedDenies.remove(client.identity) }
        guard let seal else { return false }
        let revoked = grants.filter { $0.decision == .deny && unsavedDenies.contains($0.identity) }
        if decision == .deny || !unverifiedDenies.isEmpty {
            // A fresh token matches nothing the Keychain holds. A No that
            // reached neither place stays reported until it is saved or reversed.
            let sealed = seal.save(HarnessAccessSeal(token: makeToken(), revoked: revoked))
            unverifiedDenies = sealed ? [] : unsavedDenies
        } else if let current = seal.load(), current.revoked != revoked {
            // Only this tool's journaled No goes; the token stays, so other
            // stored answers keep their seal. This Yes itself is not stored:
            // after a relaunch the tool is asked again.
            _ = seal.save(HarnessAccessSeal(token: current.token, revoked: revoked))
        }
        return false
    }

    /// Reads the stored answers once the storage is readable. Until then
    /// nothing stored is trusted and nothing stored is overwritten.
    func loadIfNeeded() {
        guard !loaded, let persistence else { return }
        switch persistence.load() {
        case .unavailable:
            return
        case .empty:
            loaded = true
        case .data(let data):
            loaded = true
            let document = try? JSONDecoder().decode(Document.self, from: data)
            // Fail closed: a Yes without its matching seal is not an answer.
            let sealed = seal == nil || (document != nil && seal?.load()?.token == document?.token)
            let stored = (document?.grants ?? []).filter { $0.decision == .deny || sealed }
            // Answers of this launch and journaled Nos win over the storage.
            let fresh = Set(grants.map(\.identity))
            grants = stored.filter { !fresh.contains($0.identity) } + grants
            // Rewrite both halves so what is stored is what applies.
            if !sealed { hasUnsavedAnswers = true }
        }
        if hasUnsavedAnswers { persist() }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let persistence else { return true }
        let token = makeToken()
        guard loaded, let data = try? JSONEncoder().encode(Document(token: token, grants: grants)),
              persistence.save(data) else {
            hasUnsavedAnswers = true
            return false
        }
        // The Keychain has every answer now, journaled Nos included. If the
        // seal cannot be written, the stored Yes is asked for again later.
        hasUnsavedAnswers = false
        unsavedDenies = []
        unverifiedDenies = []
        _ = seal?.save(HarnessAccessSeal(token: token, revoked: []))
        return true
    }
}

// MARK: Asking the user

/// Bound by the gate around a gated request, so a tool that acts on the
/// user's screen can ask once more at the last moment, with no suspension
/// between the check and the action.
enum HarnessConsent {
    @TaskLocal static var stillAllowed: (@MainActor @Sendable () -> Bool)?
}

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
    private var prompting: Set<HarnessIdentity> = []
    private var waiters: [HarnessIdentity: [UUID: CheckedContinuation<HarnessAccessOutcome?, Never>]] = [:]
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

    /// Answers a request: refused here, or performed and then released only
    /// if the harness is still allowed and still there.
    func handle(_ request: AppControlRequest, peerPID: pid_t,
                perform: (AppControlRequest) async -> AppControlResponse) async -> AppControlResponse {
        if let refusal = await intercept(request, peerPID: peerPID) { return refusal }
        guard Self.gatedOperations.contains(request.operation) else { return await perform(request) }
        let response = await HarnessConsent.$stillAllowed.withValue({ [weak self] in
            guard let self, let client = self.resolver.client(peerPID: peerPID) else { return false }
            return self.store.decision(for: client.identity) == .allow
        }) { await perform(request) }
        // Access turned off, or the client gone, while the content was read.
        guard !Task.isCancelled else { return Self.cancelled }
        guard let client = resolver.client(peerPID: peerPID) else { return Self.unsupported }
        guard store.decision(for: client.identity) == .allow else { return Self.denied(client) }
        return response
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
                if !prompting.contains(client.identity), askedUnprompted.insert(client.identity).inserted {
                    startPrompt(client)
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
            // nil: this client went away while the prompt was up; it gets nothing.
            guard let outcome = await answer(for: client), !Task.isCancelled else { return Self.cancelled }
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

    /// Waits for the harness's prompt. A request that is cancelled stops
    /// waiting at once; the prompt stays for the user and for other requests.
    private func answer(for client: HarnessClient) async -> HarnessAccessOutcome? {
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                waiters[client.identity, default: [:]][waiter] = continuation
                startPrompt(client)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters[client.identity]?.removeValue(forKey: waiter)?.resume(returning: nil)
            }
        }
    }

    /// One prompt per harness however many requests wait for it. It does not
    /// belong to the request that started it, so a session that ends does not
    /// take the question away from the user.
    private func startPrompt(_ client: HarnessClient) {
        guard prompting.insert(client.identity).inserted else { return }
        Task { @MainActor [weak self] in
            let outcome = await self?.presenter?.requestAccess(for: client) ?? .timedOut
            guard let self else { return }
            self.prompting.remove(client.identity)
            switch outcome {
            case .allow: self.store.record(.allow, for: client, at: self.now())
            case .deny: self.store.record(.deny, for: client, at: self.now())
            case .timedOut: break
            }
            for continuation in (self.waiters.removeValue(forKey: client.identity) ?? [:]).values {
                continuation.resume(returning: outcome)
            }
        }
    }

    private static func status(_ client: HarnessClient, _ access: String) -> AppControlResponse {
        .success(.object(["client": .string(client.name), "access": .string(access)]))
    }

    private static func denied(_ client: HarnessClient) -> AppControlResponse {
        .failure("access_denied",
            "The user has not allowed \(client.name) to use Whytap. They can change it in Whytap Settings → Agents. Do not retry.")
    }

    private static let cancelled = AppControlResponse.failure("cancelled", "Request cancelled.")

    private static let unsupported = AppControlResponse.failure("unsupported_client",
        "These Whytap tools work only from the Whytap MCP server that Claude Code or Codex started itself. A script or a shell command cannot use them.")
}
