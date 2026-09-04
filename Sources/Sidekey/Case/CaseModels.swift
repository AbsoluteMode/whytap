import Foundation

struct CaseSecret: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var groupID: UUID?
    var copyCount: Int
    var lastCopiedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct CaseSecretValue: Identifiable, Codable, Equatable {
    var id: UUID { secretID }
    var secretID: UUID
    var value: String
}

struct CaseGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var keyIDs: [UUID]
    var copyCount: Int
    var lastCopiedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct CaseVaultPayload: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var secrets: [CaseSecret]
    var values: [CaseSecretValue]
    var groups: [CaseGroup]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        secrets: [CaseSecret] = [],
        values: [CaseSecretValue] = [],
        groups: [CaseGroup] = []
    ) {
        self.schemaVersion = schemaVersion
        self.secrets = secrets
        self.values = values
        self.groups = groups
    }

    func value(for secretID: UUID) -> String? {
        values.first { $0.secretID == secretID }?.value
    }
}
