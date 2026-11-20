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

enum HarnessAccessSealState: Equatable {
    /// No seal, or one whose contents are not a seal.
    case missing
    /// It exists and cannot be read now: it may list Nos, so it is not replaced.
    case unreadable
    case seal(HarnessAccessSeal)
}

protocol HarnessAccessSealing {
    func load() -> HarnessAccessSealState
    /// True only when the seal is on disk as written.
    func save(_ seal: HarnessAccessSeal) -> Bool
    /// True only when no seal is left on disk.
    func remove() -> Bool
}

/// Written atomically and read back from disk before it is trusted:
/// preferences are flushed later and could not be verified.
struct HarnessAccessSealFile: HarnessAccessSealing {
    let url: URL

    func load() -> HarnessAccessSealState {
        do {
            let data = try Data(contentsOf: url)
            return (try? JSONDecoder().decode(HarnessAccessSeal.self, from: data)).map(HarnessAccessSealState.seal) ?? .missing
        } catch {
            // Missing only when its absence is confirmed. A folder that cannot
            // be looked into right now may still hold a seal that matches.
            return Self.isAbsent(error) && confirmsAbsence(of: url) ? .missing : .unreadable
        }
    }

    private static func isAbsent(_ error: Error) -> Bool {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            return cocoa.code == NSFileReadNoSuchFileError || cocoa.code == NSFileNoSuchFileError
        }
        return cocoa.domain == NSPOSIXErrorDomain && cocoa.code == Int(ENOENT)
    }

    /// The folder lists without the file, or the folder itself is confirmed
    /// absent by the first ancestor that can be listed.
    private func confirmsAbsence(of url: URL) -> Bool {
        var folder = url.deletingLastPathComponent()
        var missing = url.lastPathComponent
        while true {
            do {
                return !(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains(missing)
            } catch {
                guard Self.isAbsent(error), folder.path != "/" else { return false }
                missing = folder.lastPathComponent
                folder = folder.deletingLastPathComponent()
            }
        }
    }

    func save(_ seal: HarnessAccessSeal) -> Bool {
        guard let data = try? JSONEncoder().encode(seal) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        return load() == .seal(seal)
    }

    func remove() -> Bool {
        try? FileManager.default.removeItem(at: url)
        return load() == .missing
    }
}

/// The user's answers. Nothing stored is cached: every decision is worked out
/// from what the Keychain and the seal hold at that moment, plus the answers
/// given in this launch, so the two stores and memory cannot drift apart.
@MainActor
final class HarnessAccessStore: ObservableObject {
    private struct Document: Codable {
        var token: String
        var grants: [HarnessGrant]
    }

    /// The answers that apply now, for Settings.
    @Published private(set) var grants: [HarnessGrant] = []
    /// True while an answer of this launch is not in the Keychain yet.
    @Published private(set) var hasUnsavedAnswers = false
    /// True while a No of this launch is stored nowhere and the tool's
    /// earlier Yes would apply again after a relaunch.
    @Published private(set) var revocationUnverified = false

    /// The running app's store, for Settings -> Agents. Nil outside a packaged app.
    static weak var active: HarnessAccessStore?

    private let persistence: HarnessAccessPersisting?
    private let seal: HarnessAccessSealing?
    private let makeToken: () -> String
    /// Answers given in this launch. They apply here whatever is stored.
    private var session: [HarnessIdentity: HarnessGrant] = [:]
    private var revisions: [HarnessIdentity: Int] = [:]
    /// A session answer the Keychain has not taken.
    private var dirty = false

    /// Without `persistence` answers last for this launch only. Without
    /// `seal` a stored Yes needs no second half (tests of other behaviour).
    init(persistence: HarnessAccessPersisting?, seal: HarnessAccessSealing? = nil,
         makeToken: @escaping () -> String = { UUID().uuidString }) {
        self.persistence = persistence
        self.seal = seal
        self.makeToken = makeToken
    }

    func decision(for identity: HarnessIdentity) -> HarnessDecision? {
        // A refused write is retried on every read, and so is the seal while a
        // No is stored nowhere: either place may have become writable.
        if dirty, !commit(), revocationUnverified { journal(after: .deny) }
        return publish()[identity]?.decision
    }

    /// Changes with every answer recorded for this harness.
    func revision(for identity: HarnessIdentity) -> Int { revisions[identity] ?? 0 }

    /// For Settings: shows what applies now.
    func loadIfNeeded() { publish() }

    /// The answer applies at once; false when the Keychain did not take it.
    @discardableResult
    func record(_ decision: HarnessDecision, for client: HarnessClient, at date: Date) -> Bool {
        session[client.identity] = HarnessGrant(
            identity: client.identity, name: client.name, decision: decision, decidedAt: date)
        revisions[client.identity, default: 0] += 1
        dirty = persistence != nil
        let saved = commit()
        if !saved { journal(after: decision) }
        publish()
        return saved
    }

    // MARK: Storage

    private func stored() -> (document: Document?, readable: Bool) {
        guard let persistence else { return (nil, true) }
        switch persistence.load() {
        case .unavailable: return (nil, false)
        case .empty: return (nil, true)
        case .data(let data): return (try? JSONDecoder().decode(Document.self, from: data), true)
        }
    }

    /// What applies: a stored No always, a stored Yes only with its matching
    /// seal, Nos listed in the seal, and over all of them this launch's answers.
    private func effective(_ document: Document?, _ state: HarnessAccessSealState) -> [HarnessIdentity: HarnessGrant] {
        var result: [HarnessIdentity: HarnessGrant] = [:]
        if let document {
            var sealed = seal == nil
            if case .seal(let current) = state { sealed = current.token == document.token }
            for grant in document.grants where grant.decision == .deny || sealed { result[grant.identity] = grant }
        }
        if case .seal(let current) = state {
            for grant in current.revoked where grant.decision == .deny { result[grant.identity] = grant }
        }
        for (identity, grant) in session { result[identity] = grant }
        return result
    }

    @discardableResult
    private func publish() -> [HarnessIdentity: HarnessGrant] {
        let state = seal?.load() ?? .missing
        let (document, readable) = stored()
        let map = effective(document, state)
        let list = map.values.sorted { ($0.name, $0.identity.signingIdentifier) < ($1.name, $1.identity.signingIdentifier) }
        if list != grants { grants = list }
        if hasUnsavedAnswers != dirty { hasUnsavedAnswers = dirty }
        let unverified = dirty && session.values.contains {
            $0.decision == .deny && wouldReturn($0.identity, document: document, readable: readable, state: state)
        }
        if revocationUnverified != unverified { revocationUnverified = unverified }
        return map
    }

    /// Whether a relaunch right now would let this harness in without asking.
    private func wouldReturn(_ identity: HarnessIdentity, document: Document?, readable: Bool,
                             state: HarnessAccessSealState) -> Bool {
        guard seal != nil else { return true }
        switch state {
        case .missing:
            return false
        case .unreadable:
            return true
        case .seal(let current):
            if current.revoked.contains(where: { $0.identity == identity && $0.decision == .deny }) { return false }
            guard readable else { return true }
            return document?.token == current.token
                && document?.grants.contains { $0.identity == identity && $0.decision == .allow } == true
        }
    }

    /// Writes what applies now to the Keychain and renews both tokens.
    @discardableResult
    private func commit() -> Bool {
        guard let persistence else {
            dirty = false
            return true
        }
        let state = seal?.load() ?? .missing
        let (document, readable) = stored()
        // Locked Keychain: nothing stored is overwritten. An unreadable seal
        // may list Nos that cannot be merged now: it is not replaced either.
        guard readable, state != .unreadable else { return false }
        let token = makeToken()
        let merged = effective(document, state).values.sorted { $0.decidedAt < $1.decidedAt }
        guard let data = try? JSONEncoder().encode(Document(token: token, grants: merged)),
              persistence.save(data) else { return false }
        dirty = false
        // If the seal cannot be written, the stored Yes is asked for again later.
        _ = seal?.save(HarnessAccessSeal(token: token, revoked: []))
        return true
    }

    /// The Keychain refused: keep this launch's Nos where the next launch
    /// reads them, and make sure a refused No cannot leave an old Yes valid.
    private func journal(after decision: HarnessDecision) {
        guard let seal else { return }
        let state = seal.load()
        // An unreadable seal may list Nos. A Yes is no reason to replace it;
        // a No is: it must cancel the stored Yeses, and tools whose No is
        // lost that way are asked again, not let in.
        if state == .unreadable, decision == .allow { return }
        var current: HarnessAccessSeal?
        if case .seal(let existing) = state { current = existing }
        var revoked = (current?.revoked ?? []).filter { $0.decision == .deny && session[$0.identity] == nil }
        revoked += session.values.filter { $0.decision == .deny }.sorted { $0.decidedAt < $1.decidedAt }
        switch decision {
        case .deny:
            // A fresh token matches nothing the Keychain holds. If the seal
            // cannot be written, removing it cancels every stored Yes too.
            if !seal.save(HarnessAccessSeal(token: makeToken(), revoked: revoked)) { _ = seal.remove() }
        case .allow:
            // Only this tool's journaled No goes; the token stays, so other
            // stored answers keep their seal. This Yes itself is not stored:
            // after a relaunch the tool is asked again.
            _ = seal.save(HarnessAccessSeal(token: current?.token ?? makeToken(), revoked: revoked))
        }
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
        let asked = store.revision(for: client.identity)
        Task { @MainActor [weak self] in
            var outcome = await self?.presenter?.requestAccess(for: client) ?? .timedOut
            guard let self else { return }
            self.prompting.remove(client.identity)
            if self.store.revision(for: client.identity) != asked {
                // The user answered in Settings while the card was up: that
                // later answer stands and the card's is dropped.
                switch self.store.decision(for: client.identity) {
                case .allow: outcome = .allow
                case .deny: outcome = .deny
                case nil: outcome = .timedOut
                }
            } else {
                switch outcome {
                case .allow: self.store.record(.allow, for: client, at: self.now())
                case .deny: self.store.record(.deny, for: client, at: self.now())
                case .timedOut: break
                }
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
