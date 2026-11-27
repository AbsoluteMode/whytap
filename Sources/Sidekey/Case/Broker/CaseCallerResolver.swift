import Darwin
import Foundation

// WHY: docs/decisions/2026-10-19-case-secrets-broker.md
/// Decides who is asking the broker by walking the verified helper's parent
/// chain. The nearest registered or known AI ancestor wins; a chain with no
/// AI app is a person at a terminal.
struct CaseCallerResolver {
    static let maxHops = 32

    /// AI apps recognised by Developer ID even when not registered, so they
    /// are refused with a hint instead of being treated as a person.
    /// Verified on this Mac (codesign -dv). Cursor is matched by path only
    /// until its signing identity is verified on a machine that has it.
    static let knownAIApps: [(name: String, teamID: String, identifier: String)] = [
        ("Claude Code", "Q6L2SF6YDW", "com.anthropic.claude-code"),
        ("Codex", "2DC432GLL2", "codex"),
    ]

    private let inspector: CaseProcessInspecting
    private let registrations: [CaseAppRegistration]

    init(inspector: CaseProcessInspecting, registrations: [CaseAppRegistration]) {
        self.inspector = inspector
        self.registrations = registrations
    }

    /// `peerPID` is the already verified helper; it is never itself the
    /// calling app. Ancestors are looked up by pid (pid reuse here can only
    /// misattribute, the value path is still gated by the access policy).
    func resolve(peerPID: pid_t) -> CaseCaller {
        guard peerPID > 1, let peer = inspector.info(pid: peerPID) else { return .human }

        var visited: Set<pid_t> = [peerPID]
        var next = peer.parentPID
        for _ in 0..<Self.maxHops {
            guard next > 1, !visited.contains(next) else { return .human }
            visited.insert(next)
            guard let process = inspector.info(pid: next) else { return .human }
            if let caller = match(process) { return caller }
            next = process.parentPID
        }
        return .human
    }

    /// For the Touch ID text: the executable name of the nearest ancestor that
    /// is an app (Terminal, iTerm2, Ghostty…), or nil when the walk reaches
    /// pid 1, breaks or loops without one (ssh, a launchd job, cron).
    func terminalAppName(peerPID: pid_t) -> String? {
        guard peerPID > 1, let peer = inspector.info(pid: peerPID) else { return nil }
        var visited: Set<pid_t> = [peerPID]
        var next = peer.parentPID
        for _ in 0..<Self.maxHops {
            guard next > 1, !visited.contains(next), let process = inspector.info(pid: next) else { return nil }
            visited.insert(next)
            if process.executablePath.contains(".app/Contents/") {
                let name = URL(fileURLWithPath: process.executablePath).lastPathComponent
                return name.isEmpty ? nil : name
            }
            next = process.parentPID
        }
        return nil
    }

    // MARK: Matching

    private func match(_ process: CaseProcessInfo) -> CaseCaller? {
        if let reg = registrations.first(where: { Self.matches($0.identity, process) }) {
            return .registered(reg)
        }
        if let team = process.teamID, let id = process.signingIdentifier,
           let known = Self.knownAIApps.first(where: { $0.teamID == team && $0.identifier == id }) {
            return .knownUnregisteredAI(name: known.name)
        }
        return nil
    }

    private static func matches(_ identity: CaseAppIdentity, _ process: CaseProcessInfo) -> Bool {
        switch identity {
        case let .developerID(teamID, signingIdentifier):
            guard let team = process.teamID, let id = process.signingIdentifier else { return false }
            return team == teamID && id == signingIdentifier
        case let .executablePath(path):
            return pathMatches(registered: path, executable: process.executablePath)
        case .builtInOpenCode:
            return false // the earlier in-app agent; it no longer runs
        }
    }

    /// Exact executable, or anything inside a registered bundle/folder.
    /// The prefix must end at a path component boundary.
    static func pathMatches(registered: String, executable: String) -> Bool {
        var root = registered
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        guard root.hasPrefix("/"), root != "/", !executable.isEmpty else { return false }
        return executable == root || executable.hasPrefix(root + "/")
    }
}
