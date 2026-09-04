import CryptoKit
import Security
import XCTest
@testable import Sidekey

final class CaseVaultKeyStoreTests: XCTestCase {
    func test_add_query_uses_flavored_service_account_and_no_sync() throws {
        let store = CaseVaultKeyStore(
            service: "com.rootwise.sidekey.tests",
            account: "case.vault_key.tests"
        )
        let query = try store.makeAddQueryForTesting(keyData: Data(repeating: 1, count: 32))

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.rootwise.sidekey.tests")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "case.vault_key.tests")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecValueData as String] as? Data, Data(repeating: 1, count: 32))
        XCTAssertNil(query[kSecAttrAccessControl as String])
        // Device-bound: key must not migrate to other machines via backup or
        // iCloud Keychain sync. AfterFirstUnlockThisDeviceOnly mirrors what the
        // auth-token store sets (KeychainStore.swift:196).
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func test_accessibility_migration_update_attributes_carry_device_only_policy() {
        // Existing installs created the key item before the accessibility
        // hardening, so it sits at the WhenUnlocked default and migrates with
        // backups onto other machines. The migration-on-read update must
        // re-assert the same device-only policy the add query sets.
        let store = CaseVaultKeyStore(
            service: "com.rootwise.sidekey.tests",
            account: "case.vault_key.tests"
        )
        let attributes = store.makeAccessibilityMigrationAttributesForTesting()

        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func test_read_query_requests_data_without_keychain_prompt() {
        let store = CaseVaultKeyStore(service: "com.rootwise.sidekey.tests", account: "case.vault_key.tests")
        let query = store.makeReadQueryForTesting()

        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(query[kSecUseOperationPrompt as String])
    }

    func test_default_service_uses_build_config_flavor() {
        XCTAssertEqual(CaseVaultKeyStore().service, BuildConfig.keychainService)
        XCTAssertEqual(CaseVaultKeyStore().account, "case.vault_key")
    }

    func test_read_or_create_key_throws_and_does_not_save_when_random_generation_fails() throws {
        var saveCallCount = 0
        let store = CaseVaultKeyStore(
            service: "com.rootwise.sidekey.tests",
            account: "case.vault_key.tests",
            randomBytes: { count in
                XCTAssertEqual(count, 32)
                return (errSecAllocate, Data(repeating: 0, count: count))
            },
            readKeyDataForTesting: { nil },
            saveKeyDataForTesting: { _ in
                saveCallCount += 1
            }
        )

        XCTAssertThrowsError(try store.readOrCreateKey()) { error in
            XCTAssertEqual(error as? CaseVaultKeyStoreError, .randomGenerationFailed(errSecAllocate))
        }
        XCTAssertEqual(saveCallCount, 0)
    }

    func test_read_or_create_key_requests_and_saves_exactly_32_random_bytes() throws {
        let generated = Data((0..<32).map(UInt8.init))
        var savedData: Data?
        let store = CaseVaultKeyStore(
            service: "com.rootwise.sidekey.tests",
            account: "case.vault_key.tests",
            randomBytes: { count in
                XCTAssertEqual(count, 32)
                return (errSecSuccess, generated)
            },
            readKeyDataForTesting: { nil },
            saveKeyDataForTesting: { data in
                savedData = data
            }
        )

        let key = try store.readOrCreateKey()

        XCTAssertEqual(savedData, generated)
        XCTAssertEqual(
            key.withUnsafeBytes { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count)
            },
            generated
        )
    }
}
