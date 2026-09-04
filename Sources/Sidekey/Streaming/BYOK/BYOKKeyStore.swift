// Sources/Sidekey/Streaming/BYOK/BYOKKeyStore.swift
import Foundation

/// Per-provider API key storage in the Keychain, reusing `KeychainStore` with
/// a distinct account per provider under the app's keychain service.
///
/// `makeStore` is the test seam: production uses the login Keychain, tests
/// inject an in-memory `TokenStore` so the suite never touches (or prompts
/// for) the user's real credentials.
struct BYOKKeyStore {
    private let makeStore: (BYOKProvider) -> any TokenStore

    init() {
        self.init(makeStore: { provider in
            KeychainStore(service: BuildConfig.keychainService, account: BYOKKeyStore.account(for: provider))
        })
    }

    init(makeStore: @escaping (BYOKProvider) -> any TokenStore) {
        self.makeStore = makeStore
    }

    /// Keychain account name for `provider`'s key. Mirrored by
    /// `CredentialMigration.migratedAccounts`.
    static func account(for provider: BYOKProvider) -> String {
        "byok.\(provider.rawValue).api_key"
    }

    func save(key: String, for provider: BYOKProvider) throws {
        try makeStore(provider).save(key)
    }

    func read(for provider: BYOKProvider) throws -> String? {
        try makeStore(provider).read()
    }

    func delete(for provider: BYOKProvider) throws {
        try makeStore(provider).delete()
    }
}
