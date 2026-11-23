import Foundation

extension ProviderAccount {
    /// Separate from the retired OpenAI speech credential; adding an LLM
    /// provider never silently revives a previous audio route or key.
    static let openAIKeychainAccount = "byok.openai.llm_api_key"
    /// The Anthropic key's Keychain account. New with Anthropic, so it was
    /// never written to a `.token` file and needs no credential migration.
    static let anthropicKeychainAccount = "byok.anthropic.api_key"

    /// The Keychain account this provider account's API key is stored under, or
    /// `nil` for a server that has been removed. The built-in providers keep
    /// the names the old Models tab wrote, so no stored key has to move; a
    /// server names its own (`ServerEndpoint.keyAccount`).
    @MainActor
    func keychainAccount(in routing: AIRoutingStore) -> String? {
        switch self {
        case .soniox: return BYOKKeyStore.account(for: .soniox)
        case .deepgram: return BYOKKeyStore.account(for: .deepgram)
        case .elevenLabs: return BYOKKeyStore.account(for: .elevenLabs)
        case .openRouter: return OpenRouterLLMKeyStore.account
        case .openAI: return Self.openAIKeychainAccount
        case .anthropic: return Self.anthropicKeychainAccount
        // No key exists for it; readiness is the model's files.
        case .thisMac: return nil
        case .server(let id): return routing.server(id)?.keyAccount
        }
    }
}

/// API keys by Keychain account name. Each provider account (and each server)
/// has its own account, so one provider's key can never be handed to another.
///
/// `makeStore` is the test seam: production uses the login Keychain, tests
/// inject an in-memory `TokenStore`.
struct ProviderKeyStore {
    /// What the Keychain holds for one account.
    enum KeyLookup: Equatable {
        /// A usable key, without surrounding whitespace.
        case key(String)
        /// No key: nothing is stored, or only whitespace.
        case absent
        /// The Keychain could not be read (locked, access denied, a damaged
        /// item), so a key may well exist. Not the same as `absent`: a server
        /// that needs its key must not be connected to without it.
        case unreadable
    }

    private let makeStore: (String) -> any TokenStore

    init(makeStore: @escaping (String) -> any TokenStore = { KeychainStore(service: BuildConfig.keychainService, account: $0) }) {
        self.makeStore = makeStore
    }

    /// Looks the account's key up and keeps "there is none" (`absent`) apart
    /// from "the Keychain would not say" (`unreadable`). A `TokenStore` reports
    /// an item that is not there as `nil`, and every other failure by throwing.
    func lookup(account: String) -> KeyLookup {
        let stored: String?
        do {
            stored = try makeStore(account).read()
        } catch {
            return .unreadable
        }
        let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? .absent : .key(key)
    }

    /// Whether a key is stored, without reading it or prompting.
    func hasKey(account: String) -> Bool {
        makeStore(account).exists()
    }

    /// The key from `lookup`, or `nil` for either of the other answers. For
    /// callers that cannot act differently on an unreadable Keychain; the route
    /// resolver tells the two apart with `lookup`.
    func read(account: String) -> String? {
        guard case .key(let key) = lookup(account: account) else { return nil }
        return key
    }

    /// Stores the key without surrounding whitespace, replacing any earlier one.
    func save(_ key: String, account: String) throws {
        try makeStore(account).save(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removing a key that is not there is not an error.
    func delete(account: String) throws {
        try makeStore(account).delete()
    }
}
