import XCTest
@testable import Sidekey

final class BYOKKeyStoreTests: XCTestCase {
    /// `BYOKKeyStore` writes to the real login Keychain, which may hold a user's
    /// active saved key. Snapshot the providers we touch → run → restore, so the
    /// suite never clobbers real credentials.
    private func withSnapshot(_ providers: [BYOKProvider], _ body: () throws -> Void) rethrows {
        let store = BYOKKeyStore()
        let prior = providers.map { ($0, try? store.read(for: $0)) }
        defer {
            for (provider, value) in prior {
                if let value, !value.isEmpty { try? store.save(key: value, for: provider) }
                else { try? store.delete(for: provider) }
            }
        }
        try body()
    }

    func testRoundTripAndDelete() throws {
        try withSnapshot([.openAI]) {
            let store = BYOKKeyStore()
            try store.save(key: "sk-test-123", for: .openAI)
            XCTAssertEqual(try store.read(for: .openAI), "sk-test-123")
            try store.delete(for: .openAI)
            XCTAssertNil(try store.read(for: .openAI))
        }
    }

    func testProvidersAreIsolated() throws {
        try withSnapshot([.openAI, .selfHosted]) {
            let store = BYOKKeyStore()
            try store.save(key: "a", for: .openAI)
            try store.save(key: "b", for: .selfHosted)
            XCTAssertEqual(try store.read(for: .openAI), "a")
            XCTAssertEqual(try store.read(for: .selfHosted), "b")
            try store.delete(for: .openAI)
            try store.delete(for: .selfHosted)
        }
    }
}
