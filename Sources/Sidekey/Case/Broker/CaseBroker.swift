import Darwin
import Combine
import Foundation
import WhytapCaseKit

// MARK: Approval prompt seam (implemented by `CaseApprovalController`)

struct CaseApprovalRequest: Equatable {
    let appName: String
    let projectName: String
    let keyNames: [String]
    /// Shown to the person only; never logged.
    let command: String
    let timedMinutes: Int
    /// The registration and project a timed answer would cover; nil in previews.
    var appID: UUID?
    var projectID: UUID?
    /// Set when the prompt asks to let a coding harness use Whytap instead of
    /// asking about Case keys. It has no timed answer.
    var harness: HarnessClient?

    init(appName: String, projectName: String, keyNames: [String], command: String, timedMinutes: Int,
         appID: UUID? = nil, projectID: UUID? = nil) {
        self.appName = appName
        self.projectName = projectName
        self.keyNames = keyNames
        self.command = command
        self.timedMinutes = timedMinutes
        self.appID = appID
        self.projectID = projectID
    }
}

enum CaseApprovalOutcome: Equatable {
    case allow, allowTimed(minutes: Int), deny, timedOut
}

@MainActor
protocol CaseApprovalPresenting: AnyObject {
    func requestApproval(_ r: CaseApprovalRequest) async -> CaseApprovalOutcome
}

// MARK: Caller resolution seam

protocol CaseCallerResolving {
    func resolve(peerPID: pid_t, registrations: [CaseAppRegistration]) -> CaseCaller
    /// The terminal app a person runs the helper from, for the Touch ID text.
    func terminalAppName(peerPID: pid_t) -> String?
}

extension CaseCallerResolving {
    func terminalAppName(peerPID: pid_t) -> String? { nil }
}

/// Builds a `CaseCallerResolver` per request so registration changes apply
/// immediately.
struct CaseSystemCallerResolver: CaseCallerResolving {
    let inspector: CaseProcessInspecting
    var hostPID: pid_t = getpid()

    func resolve(peerPID: pid_t, registrations: [CaseAppRegistration]) -> CaseCaller {
        CaseCallerResolver(inspector: inspector, registrations: registrations, hostPID: hostPID)
            .resolve(peerPID: peerPID)
    }

    func terminalAppName(peerPID: pid_t) -> String? {
        CaseCallerResolver(inspector: inspector, registrations: [], hostPID: hostPID)
            .terminalAppName(peerPID: peerPID)
    }
}

// MARK: Broker

// WHY: docs/decisions/2026-10-19-case-secrets-broker.md
/// Answers one already-authenticated helper request: who is asking, what the
/// access policy says, and — only for an allowed `resolveRun` — the values of
/// exactly the requested project's keys. Never logs requests, names or values.
@MainActor
final class CaseBroker {
    static let commandSummaryLimit = 80
    static let unknownOrigin = "an unknown process"

    /// The Touch ID text for a person's `whytap case run`: which terminal app
    /// asks, for which command and project. Never contains a value. macOS
    /// shows it as "Whytap is trying to <reason>.", hence the lowercase verb.
    static func touchIDRunReason(projectName: String, command: String, origin: String?) -> String {
        let who = origin ?? unknownOrigin
        return "let \(who) run “\(commandSummary(command))” with keys from project \(projectName)"
    }

    /// The command on one line with whitespace collapsed, at most 80
    /// characters, shortened in the middle so its start and end stay visible.
    static func commandSummary(_ command: String) -> String {
        let line = command.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard line.count > commandSummaryLimit else { return line }
        let tail = (commandSummaryLimit - 1) / 2
        let head = commandSummaryLimit - 1 - tail
        return String(line.prefix(head)) + "…" + String(line.suffix(tail))
    }

    static let touchIDListReason = "let a terminal list Case keys"

    private let service: CaseVaultService
    private let resolver: CaseCallerResolving
    private let approvals: CaseApprovalPresenting
    private let authenticator: CaseAuthenticating
    private let now: () -> Date
    private let appControl: ((AppControlRequest) async -> AppControlResponse)?
    typealias HarnessAccess = (AppControlRequest, pid_t, (AppControlRequest) async -> AppControlResponse) async -> AppControlResponse
    private let harnessAccess: HarnessAccess?
    private(set) var grants = CaseTimedGrants()
    private var accessSubscription: AnyCancellable?

    init(
        service: CaseVaultService,
        resolver: CaseCallerResolving,
        approvals: CaseApprovalPresenting,
        authenticator: CaseAuthenticating,
        now: @escaping () -> Date = Date.init,
        appControl: ((AppControlRequest) async -> AppControlResponse)? = nil,
        harnessAccess: HarnessAccess? = nil
    ) {
        self.harnessAccess = harnessAccess
        self.service = service
        self.resolver = resolver
        self.approvals = approvals
        self.authenticator = authenticator
        self.now = now
        self.appControl = appControl
        accessSubscription = service.$payload.dropFirst().sink { [weak self, weak service] incoming in
            // willSet: compare the old access configuration to the incoming one.
            // A narrowed scope or changed mode revokes existing temporary grants.
            for app in service?.payload?.apps ?? [] {
                if incoming?.apps.first(where: { $0.id == app.id }) != app {
                    self?.grants.remove(appID: app.id)
                }
            }
        }
    }

    func handle(_ request: CaseBrokerRequest, peerPID: pid_t) async -> CaseBrokerResponse {
        // The server has authenticated the bundled helper. App controls expose
        // only their own allowlist and neither load nor authorize the Case vault.
        // WHY: .project-docs/decisions/2026-10-21-app-control-plugin.md
        if case .appControl(let command) = request {
            guard let appControl else {
                return .appControl(.failure("unavailable", "Application controls are unavailable in this build."))
            }
            // Content and action tools first need the user's Yes for the harness
            // that started this helper. Its answers are not Case registrations.
            // WHY: .project-docs/decisions/2026-11-20-harness-access.md
            // It wraps the call, so an answer changed while content was being
            // read still stops the response.
            if let harnessAccess { return .appControl(await harnessAccess(command, peerPID, appControl)) }
            return .appControl(await appControl(command))
        }
        // The cached payload is reused; never re-read the vault per request.
        guard let payload = try? service.loadIfNeeded() else {
            return .denied(reason: .vaultUnavailable)
        }
        let caller = resolver.resolve(peerPID: peerPID, registrations: payload.apps)

        switch request {
        case .appControl:
            return .appControl(.failure("unavailable", "Application controls are unavailable."))
        case .listProjects:
            if let denial = await authorizeListing(caller) { return denial }
            if let denial = currentAuthorityDenial(for: caller, peerPID: peerPID) { return denial }
            guard let current = service.payload else { return .denied(reason: .vaultUnavailable) }
            let visible = Self.scopedPayload(current, caller: caller)
            return .projects(Self.projectInfos(visible.projects, in: visible))

        case .listKeys(let projectName):
            if let denial = await authorizeListing(caller) { return denial }
            if let denial = currentAuthorityDenial(for: caller, peerPID: peerPID) { return denial }
            guard let current = service.payload else { return .denied(reason: .vaultUnavailable) }
            let visible = Self.scopedPayload(current, caller: caller)
            var secrets = visible.secrets
            if let projectName {
                guard let project = Self.findProject(projectName, in: visible) else {
                    return .denied(reason: .unknownProject)
                }
                secrets = secrets.filter { $0.projectID == project.id }
            }
            let keys = secrets
                .map { CaseKeyInfo(name: $0.name, description: $0.description, project: Self.projectName($0.projectID, current)) }
                .sorted { ($0.project, $0.name) < ($1.project, $1.name) }
            return .keys(keys)

        case let .resolveRun(projectName, only, command, _):
            return await resolveRun(
                caller: caller, peerPID: peerPID, payload: payload, projectName: projectName, only: only,
                command: command)
        }
    }

    // MARK: Run

    private enum Target {
        case resolved(project: CaseProject, secretIDs: [UUID])
        case failure(CaseBrokerResponse)
    }

    private func resolveRun(
        caller: CaseCaller,
        peerPID: pid_t,
        payload: CaseVaultPayload,
        projectName: String?,
        only: [String]?,
        command: String
    ) async -> CaseBrokerResponse {
        // An unregistered AI app learns nothing, not even whether a name exists.
        if case .knownUnregisteredAI = caller { return .denied(reason: .unknownAIApp) }

        let target: (project: CaseProject, secretIDs: [UUID])
        switch Self.target(projectName: projectName, only: only, in: Self.scopedPayload(payload, caller: caller)) {
        case .resolved(let project, let ids):
            target = (project, ids)
        case .failure(let response):
            // The ambiguity answer names projects and their descriptions; a
            // person at a terminal proves presence first, like for listing.
            if case .ambiguous = response, case .human = caller {
                guard await authenticate(reason: Self.touchIDListReason) else {
                    return .denied(reason: .touchIDFailed)
                }
                if let denial = currentAuthorityDenial(for: caller, peerPID: peerPID) { return denial }
            }
            return response
        }

        var timedGrant: (appID: UUID, minutes: Int)?
        switch CaseAccessPolicy.decideRun(caller: caller, projectID: target.project.id, grants: grants, now: now()) {
        case .allow:
            break
        case .deny(let reason):
            return .denied(reason: reason)
        case .askTouchID:
            let reason = Self.touchIDRunReason(
                projectName: target.project.name, command: command,
                origin: resolver.terminalAppName(peerPID: peerPID))
            guard await authenticate(reason: reason) else {
                return .denied(reason: .touchIDFailed)
            }
        case .askApproval:
            guard case .registered(let app) = caller else { return .denied(reason: .notRegistered) }
            let minutes = payload.timedApprovalMinutes
            let request = CaseApprovalRequest(
                appName: app.displayName,
                projectName: target.project.name,
                keyNames: target.secretIDs.compactMap { id in payload.secrets.first { $0.id == id }?.name },
                command: command,
                timedMinutes: minutes,
                appID: app.id,
                projectID: target.project.id)
            let outcome = await approvals.requestApproval(request)
            // The client hung up while the prompt was up: nothing is granted to it.
            if Task.isCancelled { return .denied(reason: .userDeclined) }
            switch outcome {
            case .allow:
                break
            case .allowTimed(let selectedMinutes):
                guard CaseViewModel.timedApprovalRange.contains(selectedMinutes) else {
                    return .denied(reason: .userDeclined)
                }
                timedGrant = (app.id, selectedMinutes)
            case .deny:
                return .denied(reason: .userDeclined)
            case .timedOut:
                return .denied(reason: .timedOut)
            }
        }

        // A client that went away during Touch ID or the prompt gets nothing.
        if Task.isCancelled { return .denied(reason: .userDeclined) }
        // Approval is for this principal, not a registration snapshot. No await
        // may separate this check, the grant and value release on the main actor.
        // WHY: docs/decisions/2026-10-19-case-secrets-broker.md
        if let denial = currentAuthorityDenial(for: caller, peerPID: peerPID, projectID: target.project.id) { return denial }
        // The vault may have changed while the prompt was up: read values now,
        // and only for the secrets that were approved.
        guard let current = service.payload else { return .denied(reason: .vaultUnavailable) }
        guard current.project(target.project.id) != nil else { return .denied(reason: .unknownProject) }
        var environment: [String: String] = [:]
        for id in target.secretIDs {
            guard let secret = current.secrets.first(where: { $0.id == id }),
                  secret.projectID == target.project.id
            else { return .denied(reason: .unknownKey) }
            guard let value = current.value(for: id) else { return .denied(reason: .vaultUnavailable) }
            environment[secret.name] = value
        }
        if let timedGrant {
            grants.grant(
                appID: timedGrant.appID, projectID: target.project.id,
                until: now().addingTimeInterval(TimeInterval(timedGrant.minutes) * 60))
        }
        return .runEnvironment(environment)
    }

    private static func target(projectName: String?, only: [String]?, in payload: CaseVaultPayload) -> Target {
        if let projectName {
            guard let project = findProject(projectName, in: payload) else {
                return .failure(.denied(reason: .unknownProject))
            }
            let inProject = payload.secrets.filter { $0.projectID == project.id }
            // Two keys with one name in a project (an old merge) are never
            // resolved by picking one: the run is refused.
            guard let only else {
                let names = inProject.map(\.name)
                guard Set(names).count == names.count else { return .failure(.denied(reason: .unknownKey)) }
                return .resolved(project: project, secretIDs: inProject.map(\.id))
            }
            var ids: [UUID] = []
            for name in unique(only) {
                let hits = inProject.filter { $0.name == name }
                guard hits.count == 1 else { return .failure(.denied(reason: .unknownKey)) }
                ids.append(hits[0].id)
            }
            return .resolved(project: project, secretIDs: ids)
        }

        // Without -p a project is never guessed: only named keys are looked up,
        // across all projects, and General is not mixed in.
        guard let only, !only.isEmpty else { return .failure(.denied(reason: .unknownProject)) }
        var ids: [UUID] = []
        var projectID: UUID?
        for name in unique(only) {
            let hits = payload.secrets.filter { $0.name == name }
            if hits.isEmpty { return .failure(.denied(reason: .unknownKey)) }
            if hits.count > 1 {
                let projects = payload.projects.filter { project in hits.contains { $0.projectID == project.id } }
                // Duplicates inside one project are refused, not offered as a choice.
                guard projects.count == hits.count else { return .failure(.denied(reason: .unknownKey)) }
                return .failure(.ambiguous(key: name, projects: projectInfos(projects, in: payload)))
            }
            let hit = hits[0]
            // Keys from different projects in one run would need one decision
            // per project; ask for -p instead.
            if let projectID, projectID != hit.projectID { return .failure(.denied(reason: .unknownProject)) }
            projectID = hit.projectID
            ids.append(hit.id)
        }
        guard let projectID, let project = payload.project(projectID) else {
            return .failure(.denied(reason: .unknownProject))
        }
        return .resolved(project: project, secretIDs: ids)
    }

    // MARK: Helpers

    /// Re-resolve after suspension, preserving the authenticated principal.
    /// A removed custom-path registration must not fall back to a human run;
    /// re-registering the same app also requires a new request and approval.
    private func currentAuthorityDenial(for caller: CaseCaller, peerPID: pid_t, projectID: UUID? = nil) -> CaseBrokerResponse? {
        guard let current = service.payload else { return .denied(reason: .vaultUnavailable) }
        let resolved = resolver.resolve(peerPID: peerPID, registrations: current.apps)
        switch (caller, resolved) {
        case (.human, .human):
            return nil
        case let (.registered(original), .registered(fresh)):
            guard original.id == fresh.id, original.identity == fresh.identity,
                  let app = current.apps.first(where: { $0.id == original.id && $0.identity == original.identity })
            else { return .denied(reason: .notRegistered) }
            if let projectID, !app.allows(projectID: projectID) { return .denied(reason: .unknownProject) }
            return nil
        default:
            return .denied(reason: .notRegistered)
        }
    }

    private func authorizeListing(_ caller: CaseCaller) async -> CaseBrokerResponse? {
        switch CaseAccessPolicy.decideList(caller: caller) {
        case .allow, .askApproval:
            return nil
        case .deny(let reason):
            return .denied(reason: reason)
        case .askTouchID:
            return await authenticate(reason: Self.touchIDListReason) ? nil : .denied(reason: .touchIDFailed)
        }
    }

    /// Filter before resolving names, so ambiguity replies cannot reveal projects
    /// outside this registration's current scope. Human runs keep Touch ID.
    private static func scopedPayload(_ payload: CaseVaultPayload, caller: CaseCaller) -> CaseVaultPayload {
        guard case .registered(let original) = caller,
              let app = payload.apps.first(where: { $0.id == original.id }),
              let allowed = app.allowedProjectIDs else { return payload }
        var visible = payload
        visible.projects = payload.projects.filter { allowed.contains($0.id) }
        visible.secrets = payload.secrets.filter { allowed.contains($0.projectID) }
        return visible
    }

    private func authenticate(reason: String) async -> Bool {
        do {
            try await authenticator.authenticate(reason: reason)
            return true
        } catch {
            return false
        }
    }

    /// A single exact match first; otherwise a single case-insensitive match.
    /// Several projects with the name are refused, never picked.
    static func findProject(_ name: String, in payload: CaseVaultPayload) -> CaseProject? {
        let exact = payload.projects.filter { $0.name == name }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        let folded = payload.projects.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return folded.count == 1 ? folded[0] : nil
    }

    private static func projectInfos(_ projects: [CaseProject], in payload: CaseVaultPayload) -> [CaseProjectInfo] {
        projects.map { project in
            CaseProjectInfo(
                name: project.name, description: project.description,
                keyCount: payload.secrets.filter { $0.projectID == project.id }.count)
        }
    }

    private static func projectName(_ id: UUID, _ payload: CaseVaultPayload) -> String {
        payload.project(id)?.name ?? ""
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
