import XCTest
@testable import Sidekey

/// Round trips through the real Keychain, under a service of this test's own.
/// The suite used to snapshot and restore the app's own service: a second test
/// process (a parallel run, another session's suite) touching the same item
/// raced it, and a crash between save and restore left the user's real key
/// replaced or deleted. A unique service keeps the real Keychain round trip
/// and the per-provider account names without touching the app's items.
final class BYOKKeyStoreTests: XCTestCase {
    private var store: BYOKKeyStore!

    override func setUp() {
        super.setUp()
        let service = "com.rootwise.sidekey.tests.\(UUID().uuidString)"
        store = BYOKKeyStore(makeStore: { provider in
            KeychainStore(service: service, account: BYOKKeyStore.account(for: provider))
        })
    }

    override func tearDown() {
        for provider in [BYOKProvider.openAI, .selfHosted] { try? store.delete(for: provider) }
        store = nil
        super.tearDown()
    }

    func testRoundTripAndDelete() throws {
        try store.save(key: "sk-test-123", for: .openAI)
        XCTAssertEqual(try store.read(for: .openAI), "sk-test-123")
        try store.delete(for: .openAI)
        XCTAssertNil(try store.read(for: .openAI))
    }

    func testProvidersAreIsolated() throws {
        try store.save(key: "a", for: .openAI)
        try store.save(key: "b", for: .selfHosted)
        XCTAssertEqual(try store.read(for: .openAI), "a")
        XCTAssertEqual(try store.read(for: .selfHosted), "b")
        try store.delete(for: .openAI)
        XCTAssertNil(try store.read(for: .openAI))
        XCTAssertEqual(try store.read(for: .selfHosted), "b", "deleting one provider keeps the other")
    }
}
