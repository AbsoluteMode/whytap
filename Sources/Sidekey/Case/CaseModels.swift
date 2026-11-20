import Foundation

/// A named bucket of keys. Every secret belongs to exactly one project;
/// keys that had no group in schema 1 live in the fixed built-in General.
struct CaseProject: Identifiable, Codable, Equatable {
    static let generalID = UUID(uuidString: "00000000-0000-0000-0000-00000000CA5E")!
    static let generalName = "General"
    static let maxNameCharacters = 48

    var id: UUID
    var name: String
    var description: String
    var createdAt: Date
    var updatedAt: Date

    static func general(now: Date) -> CaseProject {
        CaseProject(id: generalID, name: generalName, description: "", createdAt: now, updatedAt: now)
    }

    /// `base`, or `base (2)`, `base (3)`… shortened to fit `maxNameCharacters`,
    /// whichever is not in `taken` (lowercased names).
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        var candidate = String(base.prefix(maxNameCharacters))
        var n = 2
        while taken.contains(candidate.lowercased()) {
            let suffix = " (\(n))"
            candidate = String(base.prefix(maxNameCharacters - suffix.count)) + suffix
            n += 1
        }
        return candidate
    }
}

struct CaseSecret: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var projectID: UUID
    var description: String
    var copyCount: Int
    var lastCopiedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

extension CaseSecret {
    private enum CodingKeys: String, CodingKey {
        case id, name, projectID, description, copyCount, lastCopiedAt, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        copyCount = try c.decode(Int.self, forKey: .copyCount)
        lastCopiedAt = try c.decodeIfPresent(Date.self, forKey: .lastCopiedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

struct CaseSecretValue: Identifiable, Codable, Equatable {
    var id: UUID { secretID }
    var secretID: UUID
    var value: String
}

enum CaseAccessMode: String, Codable, Equatable {
    case approve
    case bypass
}

enum CaseAppIdentity: Codable, Equatable, Hashable {
    case developerID(teamID: String, signingIdentifier: String)
    case executablePath(String)
    /// Retired built-in agent identity; kept decodable so existing schema-3
    /// vaults, backups and rollbacks load without error or data loss.
    // WHY: .project-docs/decisions/2026-11-20-case-remove-whytap-agent.md
    case builtInOpenCode
}

struct CaseAppRegistration: Identifiable, Codable, Equatable {
    var id: UUID
    var displayName: String
    var identity: CaseAppIdentity
    var defaultMode: CaseAccessMode
    var projectModes: [UUID: CaseAccessMode]
    var createdAt: Date
    /// nil = all current and future projects; an empty set grants no projects.
    /// Missing in schema 2, whose registrations retain their previous access.
    var allowedProjectIDs: Set<UUID>? = nil

    func allows(projectID: UUID) -> Bool {
        allowedProjectIDs?.contains(projectID) ?? true
    }
}

struct CaseVaultPayload: Codable, Equatable {
    // Older binaries must refuse scoped registrations rather than ignore them.
    // WHY: docs/decisions/2026-10-20-case-connect-and-scope.md
    static let currentSchemaVersion = 3
    static let defaultTimedApprovalMinutes = 15

    var schemaVersion: Int
    var projects: [CaseProject]
    var secrets: [CaseSecret]
    var values: [CaseSecretValue]
    var apps: [CaseAppRegistration]
    var timedApprovalMinutes: Int

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projects: [CaseProject] = [CaseProject.general(now: Date(timeIntervalSinceReferenceDate: 0))],
        secrets: [CaseSecret] = [],
        values: [CaseSecretValue] = [],
        apps: [CaseAppRegistration] = [],
        timedApprovalMinutes: Int = Self.defaultTimedApprovalMinutes
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.secrets = secrets
        self.values = values
        self.apps = apps
        self.timedApprovalMinutes = timedApprovalMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, secrets, values, apps, timedApprovalMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        projects = try c.decode([CaseProject].self, forKey: .projects)
        secrets = try c.decode([CaseSecret].self, forKey: .secrets)
        values = try c.decode([CaseSecretValue].self, forKey: .values)
        apps = try c.decodeIfPresent([CaseAppRegistration].self, forKey: .apps) ?? []
        timedApprovalMinutes = try c.decodeIfPresent(Int.self, forKey: .timedApprovalMinutes)
            ?? Self.defaultTimedApprovalMinutes
    }

    func value(for secretID: UUID) -> String? {
        values.first { $0.secretID == secretID }?.value
    }

    func project(_ id: UUID) -> CaseProject? {
        projects.first { $0.id == id }
    }
}
