import Foundation
import CryptoKit
import Security

/// Errors that can be thrown by `KeychainStore`.
enum KeychainError: Error, CustomStringConvertible {
    /// Wraps an unexpected `OSStatus` from a Security framework call.
    case unhandledError(OSStatus)
    /// The stored item was present but not decodable as UTF-8 string data.
    case unexpectedData

    var description: String {
        switch self {
        case .unhandledError(let status):
            return "Keychain error: OSStatus \(status)"
        case .unexpectedData:
            return "Keychain error: stored item is not valid UTF-8"
        }
    }
}

/// Abstraction over a credential store. Production code uses `KeychainStore`;
/// tests can substitute a stub that throws on demand to exercise error paths.
protocol TokenStore {
    func save(_ token: String) throws
    func read() throws -> String?
    func delete() throws
}

/// File-backed credential storage used exclusively in dev builds
/// (DEBUG + SIDEKEY_FILE_TOKEN_STORE, set by `scripts/dev-run.sh`).
///
/// This avoids macOS "wants to access your keychain" prompts and
/// entitlement issues when running unsigned dev builds. Release, beta,
/// and plain DEBUG test builds use the real login keychain instead.
struct FileTokenStore: TokenStore {
    let service: String
    let account: String
    let rootDirectory: URL

    init(
        service: String,
        account: String,
        rootDirectory: URL = Self.defaultRootDirectory()
    ) {
        self.service = service
        self.account = account
        self.rootDirectory = rootDirectory
    }

    var fileURL: URL {
        rootDirectory.appendingPathComponent(Self.fileName(service: service, account: account))
    }

    func save(_ token: String) throws {
        try ensurePrivateDirectory()
        try token.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }

    func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func ensurePrivateDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: rootDirectory.path
        )
    }

    static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base
            .appendingPathComponent("Whytap", isDirectory: true)
            .appendingPathComponent("Auth", isDirectory: true)
    }

    private static func fileName(service: String, account: String) -> String {
        let raw = "\(service)\u{0}\(account)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).token"
    }
}

/// Thin wrapper over secret persistence for a single `(service, account)`
/// pair — provider API keys (BYOK, OpenRouter, custom LLM) and the Case
/// vault key. The type name is kept for API stability across the app.
///
/// Release, beta, and plain DEBUG test builds use the real `SecItem*`
/// login keychain path. Local dev app bundles pass `SIDEKEY_FILE_TOKEN_STORE`
/// (set by `scripts/dev-run.sh`) so dev runs use a no-prompt file-backed
/// path without disturbing the developer's own keychain entries.
///
/// Beta and prod flavors use different `kSecAttrService` values
/// (`com.rootwise.sidekey` vs `com.rootwise.sidekey.beta`) so their
/// secrets stay separate in the user's keychain.
struct KeychainStore: TokenStore {
    let service: String
    let account: String

    init(
        service: String = BuildConfig.keychainService,
        account: String
    ) {
        self.service = service
        self.account = account
    }

    // Diagnostic/test seam only — lets tests assert which storage path the
    // current build flags select. Production code never branches on this;
    // the real dispatch happens via the `#if` guards in save/read/delete.
    enum StorageBackend: Equatable {
        case keychain
        case file
    }

    /// Which storage is active for the current build flags. The file store
    /// lives ONLY in dev runs (DEBUG + SIDEKEY_FILE_TOKEN_STORE); release,
    /// beta and plain tests always use the login keychain.
    var activeBackend: StorageBackend {
        #if DEBUG && SIDEKEY_FILE_TOKEN_STORE
        return .file
        #else
        return .keychain
        #endif
    }

    #if DEBUG && SIDEKEY_FILE_TOKEN_STORE
    private var fileStore: FileTokenStore {
        FileTokenStore(service: service, account: account)
    }
    #else
    /// Common attributes every SecItem query needs. Returns a fresh
    /// dictionary on each call so callers can mutate it.
    private func baseQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif

    /// Persists `token` under `(service, account)`. Overwrites any
    /// existing value.
    func save(_ token: String) throws {
        #if DEBUG && SIDEKEY_FILE_TOKEN_STORE
        try fileStore.save(token)
        #else
        let data = Data(token.utf8)

        // Try update first; if the item doesn't exist, fall back to add.
        let query = baseQuery()
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandledError(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        // `AfterFirstUnlockThisDeviceOnly`: the secret survives reboots but
        // stays bound to this Mac (no iCloud sync, which would leak through
        // Keychain sync to other devices the user is signed into).
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledError(addStatus)
        }
        #endif
    }

    /// Reads the stored token. Returns `nil` if no item is present.
    func read() throws -> String? {
        #if DEBUG && SIDEKEY_FILE_TOKEN_STORE
        return try fileStore.read()
        #else
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedData
            }
            guard let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledError(status)
        }
        #endif
    }

    /// Removes the stored token. Idempotent — does not throw if no
    /// item exists.
    func delete() throws {
        #if DEBUG && SIDEKEY_FILE_TOKEN_STORE
        try fileStore.delete()
        #else
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledError(status)
        }
        #endif
    }
}
