import XCTest
@testable import Sidekey

final class CredentialMigrationTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialMigrationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// In-memory keychain stub so tests don't touch the real Keychain.
    private final class InMemoryTokenStore: TokenStore {
        private var value: String?
        func save(_ token: String) throws { value = token }
        func read() throws -> String? { value }
        func delete() throws { value = nil }
    }

    /// A provider key that `CredentialMigration` actually migrates. The
    /// migration only walks `migratedAccounts`, so fixtures must use one of
    /// them for the file-to-keychain move to happen at all.
    private let account = OpenRouterLLMKeyStore.account

    func testMigratesFileTokenIntoKeychainAndDeletesFile() throws {
        let fileStore = FileTokenStore(service: "svc", account: account, rootDirectory: root)
        try fileStore.save("or-key-xyz")

        let keychain = InMemoryTokenStore()
        let migration = CredentialMigration(
            service: "svc",
            fileRootDirectory: root,
            keychainStoreFactory: { [account] in $0 == account ? keychain : InMemoryTokenStore() }
        )

        migration.run()

        XCTAssertEqual(try keychain.read(), "or-key-xyz")
        XCTAssertNil(try fileStore.read())
    }

    func testDoesNotOverwriteExistingKeychainValue() throws {
        let fileStore = FileTokenStore(service: "svc", account: account, rootDirectory: root)
        try fileStore.save("stale-file-token")

        let keychain = InMemoryTokenStore()
        try keychain.save("live-keychain-token")

        let migration = CredentialMigration(
            service: "svc",
            fileRootDirectory: root,
            keychainStoreFactory: { [account] in $0 == account ? keychain : InMemoryTokenStore() }
        )

        migration.run()

        XCTAssertEqual(try keychain.read(), "live-keychain-token")
        XCTAssertNil(try fileStore.read(), "the stray file is removed even when the keychain already holds a value")
    }

    func testSkipsMigrationWhenDestinationIsFileBacked() throws {
        let fileStore = FileTokenStore(service: "svc", account: account, rootDirectory: root)
        try fileStore.save("dev-file-token")

        let migration = CredentialMigration(
            service: "svc",
            fileRootDirectory: root,
            keychainStoreFactory: { _ in InMemoryTokenStore() },
            shouldRun: { false }
        )

        migration.run()

        XCTAssertEqual(try fileStore.read(), "dev-file-token")
    }

    func testIsIdempotentWhenNoFilesPresent() {
        let migration = CredentialMigration(
            service: "svc",
            fileRootDirectory: root,
            keychainStoreFactory: { _ in InMemoryTokenStore() }
        )
        XCTAssertNoThrow(migration.run())
    }

    func testDefaultDestinationStoreUsesConfiguredService() throws {
        let migration = CredentialMigration(
            service: "custom.service",
            fileRootDirectory: root,
            shouldRun: { false }
        )

        let store = try XCTUnwrap(
            migration.keychainStoreFactory(account) as? KeychainStore
        )
        XCTAssertEqual(store.service, "custom.service")
        XCTAssertEqual(store.account, account)
    }

    func testIsIdempotentAcrossRepeatedRuns() throws {
        let fileStore = FileTokenStore(service: "svc", account: account, rootDirectory: root)
        try fileStore.save("or-key-xyz")
        let keychain = InMemoryTokenStore()
        let migration = CredentialMigration(
            service: "svc",
            fileRootDirectory: root,
            keychainStoreFactory: { [account] in $0 == account ? keychain : InMemoryTokenStore() }
        )
        migration.run()
        XCTAssertEqual(try keychain.read(), "or-key-xyz")
        XCTAssertNoThrow(migration.run())  // second run: no file left, no error
        XCTAssertEqual(try keychain.read(), "or-key-xyz")  // value intact
    }

    func testMigratedAccountsCoverAllCredentialSources() {
        let accounts = Set(CredentialMigration.migratedAccounts)
        XCTAssertTrue(accounts.isSuperset(of: BYOKProvider.allCases.map { "byok.\($0.rawValue).api_key" }))
        XCTAssertTrue(accounts.contains(OpenRouterLLMKeyStore.account))
        XCTAssertTrue(accounts.contains(CustomLLMKeyStore.account))
        // The Whytap session tokens are gone with the cloud account; nothing
        // under `auth.*` is migrated any more.
        XCTAssertFalse(accounts.contains { $0.hasPrefix("auth.") })
    }
}
