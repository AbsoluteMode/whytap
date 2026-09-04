import XCTest
@testable import Sidekey

/// Round-trip tests against the real macOS Keychain. Each test scopes itself to
/// a unique service+account so parallel runs and prior failures don't bleed
/// state between cases.
final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!
    private var service: String!
    private var account: String!

    override func setUp() {
        super.setUp()
        // Unique service per test — survives crashes via tearDown's delete().
        service = "com.rootwise.sidekey.tests.\(UUID().uuidString)"
        account = "byok.test.api_key"
        store = KeychainStore(service: service, account: account)
    }

    override func tearDown() {
        try? store.delete()
        store = nil
        service = nil
        account = nil
        super.tearDown()
    }

    func testReadAbsentReturnsNil() throws {
        let token = try store.read()
        XCTAssertNil(token)
    }

    func testSaveAndRead() throws {
        try store.save("jwt-token-1")
        let token = try store.read()
        XCTAssertEqual(token, "jwt-token-1")
    }

    func testOverwriteExisting() throws {
        try store.save("first")
        try store.save("second")
        let token = try store.read()
        XCTAssertEqual(token, "second")
    }

    func testDelete() throws {
        try store.save("to-be-deleted")
        try store.delete()
        let token = try store.read()
        XCTAssertNil(token)
    }

    func testDeleteAbsentDoesNotThrow() throws {
        // Idempotent delete — calling on empty store should not throw.
        XCTAssertNoThrow(try store.delete())
    }

    func testSavePreservesUnicode() throws {
        let unicode = "токен-with-юникод-✓"
        try store.save(unicode)
        let token = try store.read()
        XCTAssertEqual(token, unicode)
    }

    // MARK: - flavor

    /// Beta and Prod builds must store credentials under different
    /// `kSecAttrService` strings so installations of both flavors can
    /// coexist on the same machine without overwriting each other's
    /// tokens. The `service` value comes from `BuildConfig`, switched by
    /// the `-DBETA` compile flag.
    func testFlavorKeychainServiceIsolation() {
        #if BETA
        XCTAssertEqual(BuildConfig.keychainService, "com.rootwise.sidekey.beta")
        #else
        XCTAssertEqual(BuildConfig.keychainService, "com.rootwise.sidekey")
        #endif

        // A store built without an explicit service must inherit the flavor
        // service, not a hardcoded literal — otherwise both flavors would
        // collide in the user's keychain.
        let defaultStore = KeychainStore(account: account)
        XCTAssertEqual(defaultStore.service, BuildConfig.keychainService)
    }

    /// Every build except the dev run (DEBUG + SIDEKEY_FILE_TOKEN_STORE) must
    /// keep secrets in the Keychain, never in a plaintext file. The test
    /// environment (DEBUG without the flag) must resolve to `.keychain` — the
    /// same path release uses.
    func testNonDevBuildUsesKeychainBackend() {
        XCTAssertEqual(KeychainStore(account: account).activeBackend, .keychain)
    }

}

final class FileTokenStoreTests: XCTestCase {
    private var rootDirectory: URL!

    override func setUp() {
        super.setUp()
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTokenStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        rootDirectory = nil
        super.tearDown()
    }

    func testSaveReadOverwriteAndDeleteRoundTrip() throws {
        let store = FileTokenStore(
            service: "com.rootwise.sidekey.tests",
            account: "auth.access_token",
            rootDirectory: rootDirectory
        )

        XCTAssertNil(try store.read())

        try store.save("first-token")
        XCTAssertEqual(try store.read(), "first-token")

        try store.save("second-token")
        XCTAssertEqual(try store.read(), "second-token")

        try store.delete()
        XCTAssertNil(try store.read())
    }

    func testTokenFileAndDirectoryUsePrivatePermissions() throws {
        let store = FileTokenStore(
            service: "com.rootwise.sidekey.tests",
            account: "auth.access_token",
            rootDirectory: rootDirectory
        )

        try store.save("secret-token")

        let directoryPermissions = try posixPermissions(at: rootDirectory)
        let tokenPermissions = try posixPermissions(at: store.fileURL)

        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(tokenPermissions, 0o600)
    }

    func testTokenFileNameDoesNotExposeServiceOrAccount() throws {
        let service = "com.rootwise.sidekey.tests"
        let account = "auth.access_token"
        let store = FileTokenStore(
            service: service,
            account: account,
            rootDirectory: rootDirectory
        )

        try store.save("secret-token")

        XCTAssertFalse(store.fileURL.lastPathComponent.contains(service))
        XCTAssertFalse(store.fileURL.lastPathComponent.contains(account))
        XCTAssertTrue(store.fileURL.lastPathComponent.hasSuffix(".token"))
    }

    func testDifferentServiceAccountsDoNotCollide() throws {
        let first = FileTokenStore(
            service: "com.rootwise.sidekey",
            account: "auth.access_token",
            rootDirectory: rootDirectory
        )
        let second = FileTokenStore(
            service: "com.rootwise.sidekey.beta",
            account: "auth.access_token",
            rootDirectory: rootDirectory
        )

        try first.save("prod-token")
        try second.save("beta-token")

        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(try first.read(), "prod-token")
        XCTAssertEqual(try second.read(), "beta-token")
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue
    }
}
