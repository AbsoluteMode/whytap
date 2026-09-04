import Foundation

/// One-shot migration of provider keys from legacy plaintext `.token` files
/// (an old release path, CAN-001) into the login keychain. Idempotent: a
/// repeat run with no files left is a no-op.
struct CredentialMigration {
    let service: String
    let fileRootDirectory: URL
    let keychainStoreFactory: (String) -> any TokenStore
    let shouldRun: () -> Bool

    init(
        service: String = BuildConfig.keychainService,
        fileRootDirectory: URL = FileTokenStore.defaultRootDirectory(),
        keychainStoreFactory: ((String) -> any TokenStore)? = nil,
        shouldRun: (() -> Bool)? = nil
    ) {
        self.service = service
        self.fileRootDirectory = fileRootDirectory
        if let keychainStoreFactory {
            self.keychainStoreFactory = keychainStoreFactory
        } else {
            self.keychainStoreFactory = { account in
                KeychainStore(service: service, account: account)
            }
        }
        self.shouldRun = shouldRun ?? {
            KeychainStore(service: service, account: OpenRouterLLMKeyStore.account).activeBackend == .keychain
        }
    }

    /// Every `(service, account)` pair that was ever written through
    /// `KeychainStore` and therefore may have landed in a plaintext file.
    static var migratedAccounts: [String] {
        var accounts = BYOKProvider.allCases.map { "byok.\($0.rawValue).api_key" }
        accounts.append(OpenRouterLLMKeyStore.account)
        accounts.append(CustomLLMKeyStore.account)
        return accounts
    }

    func run() {
        guard shouldRun() else { return }
        for account in Self.migratedAccounts {
            migrate(account: account)
        }
        cleanupEmptyDirectory()
    }

    private func migrate(account: String) {
        let fileStore = FileTokenStore(
            service: service,
            account: account,
            rootDirectory: fileRootDirectory
        )
        guard let fileToken = try? fileStore.read(), !fileToken.isEmpty else { return }

        let keychain = keychainStoreFactory(account)
        // Never overwrite a live keychain value; the stray file goes anyway.
        if let existing = try? keychain.read(), !existing.isEmpty {
            try? fileStore.delete()
            return
        }

        do {
            try keychain.save(fileToken)
            try fileStore.delete()
        } catch {
            // Leave the file in place and retry on the next launch.
        }
    }

    private func cleanupEmptyDirectory() {
        let visible = try? FileManager.default.contentsOfDirectory(
            at: fileRootDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        if let visible, visible.isEmpty {
            try? FileManager.default.removeItem(at: fileRootDirectory)
        }
    }
}
