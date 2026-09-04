import Foundation
@testable import Sidekey

/// Dictionary-backed `TokenStore` for tests that must never touch the login
/// Keychain. One instance = one (service, account) slot; share a `Box` across
/// instances to model several accounts in one store.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    final class Box: @unchecked Sendable {
        var values: [String: String] = [:]
        private let lock = NSLock()
        func with<T>(_ body: (inout [String: String]) throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body(&values)
        }
    }

    private let box: Box
    private let account: String

    init(account: String = "default", box: Box = Box()) {
        self.account = account
        self.box = box
    }

    func save(_ token: String) throws {
        box.with { $0[account] = token }
    }

    func read() throws -> String? {
        box.with { $0[account] }
    }

    func delete() throws {
        box.with { $0[account] = nil }
    }
}

extension BYOKKeyStore {
    /// A `BYOKKeyStore` whose per-provider slots live in `box` (fresh by
    /// default) instead of the login Keychain.
    static func inMemory(box: InMemoryTokenStore.Box = InMemoryTokenStore.Box()) -> BYOKKeyStore {
        BYOKKeyStore(makeStore: { provider in
            InMemoryTokenStore(account: BYOKKeyStore.account(for: provider), box: box)
        })
    }
}
