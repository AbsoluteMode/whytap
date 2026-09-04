import CryptoKit
import Foundation
import os.log
import Security

enum CaseVaultKeyStoreError: Error, Equatable {
    case unhandled(OSStatus)
    case unexpectedData
    case accessControlUnavailable
    case randomGenerationFailed(OSStatus)
}

struct CaseVaultKeyStore {
    typealias RandomBytes = (Int) -> (OSStatus, Data)

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "case-vault-key")

    let service: String
    let account: String
    private let randomBytes: RandomBytes
    private let readKeyDataOverride: (() throws -> Data?)?
    private let saveKeyDataOverride: ((Data) throws -> Void)?

    init(
        service: String = BuildConfig.keychainService,
        account: String = "case.vault_key",
        randomBytes: @escaping RandomBytes = CaseVaultKeyStore.secRandomBytes,
        readKeyDataForTesting: (() throws -> Data?)? = nil,
        saveKeyDataForTesting: ((Data) throws -> Void)? = nil
    ) {
        self.service = service
        self.account = account
        self.randomBytes = randomBytes
        self.readKeyDataOverride = readKeyDataForTesting
        self.saveKeyDataOverride = saveKeyDataForTesting
    }

    func readOrCreateKey() throws -> SymmetricKey {
        if let existing = try readKeyData() {
            return SymmetricKey(data: existing)
        }
        let data = try randomKeyData()
        try saveKeyData(data)
        return SymmetricKey(data: data)
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw CaseVaultKeyStoreError.unhandled(status)
        }
    }

    func makeAddQueryForTesting(keyData: Data) throws -> [String: Any] {
        try makeAddQuery(keyData: keyData)
    }

    func makeReadQueryForTesting() -> [String: Any] {
        makeReadQuery()
    }

    func makeAccessibilityMigrationAttributesForTesting() -> [String: Any] {
        makeAccessibilityMigrationAttributes()
    }

    private func readKeyData() throws -> Data? {
        if let readKeyDataOverride {
            return try readKeyDataOverride()
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(makeReadQuery() as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw CaseVaultKeyStoreError.unexpectedData
            }
            migrateAccessibilityToDeviceOnly()
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CaseVaultKeyStoreError.unhandled(status)
        }
    }

    /// Items created before the accessibility hardening sit at the
    /// kSecAttrAccessibleWhenUnlocked default and migrate with backups onto
    /// other machines — new installs get the device-only policy via the add
    /// query, but readOrCreateKey returns early for existing keys, so without
    /// this they would keep the old policy forever. Re-assert the policy on
    /// every successful read: the update is cheap and idempotent, which is
    /// simpler than tracking a migrated flag. Deliberately NOT delete+add —
    /// a crash between the two would destroy the vault master key. Fail-open:
    /// a failed migration must never block vault access, so the status is
    /// logged (no key material) and the read result is returned regardless.
    private func migrateAccessibilityToDeviceOnly() {
        let status = SecItemUpdate(
            baseQuery() as CFDictionary,
            makeAccessibilityMigrationAttributes() as CFDictionary
        )
        if status != errSecSuccess {
            os_log(
                "case_vault_key_accessibility_migration_failed status=%{public}d",
                log: Self.log,
                type: .error,
                status
            )
        }
    }

    private func saveKeyData(_ data: Data) throws {
        if let saveKeyDataOverride {
            try saveKeyDataOverride(data)
            return
        }

        let addQuery = try makeAddQuery(keyData: data)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CaseVaultKeyStoreError.unhandled(updateStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw CaseVaultKeyStoreError.unhandled(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func makeReadQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private func makeAddQuery(keyData: Data) throws -> [String: Any] {
        var query = baseQuery()
        query[kSecValueData as String] = keyData
        query.merge(makeAccessibilityMigrationAttributes()) { _, new in new }
        return query
    }

    /// Device-bound: the vault master key must not migrate to other machines
    /// via iCloud Keychain sync or device backups. Mirrors the auth-token
    /// store's policy (KeychainStore.swift:196) — consistent accessibility
    /// across all sensitive Keychain items the app writes. Shared by the add
    /// query (new installs) and the migration update (existing installs).
    private func makeAccessibilityMigrationAttributes() -> [String: Any] {
        [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }

    private func randomKeyData() throws -> Data {
        let (status, data) = randomBytes(32)
        guard status == errSecSuccess else {
            throw CaseVaultKeyStoreError.randomGenerationFailed(status)
        }
        guard data.count == 32 else {
            throw CaseVaultKeyStoreError.unexpectedData
        }
        return data
    }

    private static func secRandomBytes(count: Int) -> (OSStatus, Data) {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return (status, Data(bytes))
    }

}
