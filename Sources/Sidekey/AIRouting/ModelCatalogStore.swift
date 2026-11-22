import CryptoKit
import Foundation

/// What the app last learned about one account's model catalog. Model metadata
/// only: no keys, no URLs, no response bodies.
struct CatalogSnapshot: Codable, Equatable {
    static let currentMetadataVersion = 6
    var models: [CatalogModel]
    /// Last successful load.
    var fetchedAt: Date?
    /// The latest refresh failed (offline, 5xx, anything else): the models are
    /// the previous ones and nothing may be called "removed" on their strength.
    var lastRefreshFailed: Bool
    /// The key may not list models: only the built-in registry applies.
    var limited: Bool
    /// Older caches remain readable offline, but refresh once for dates,
    /// capabilities and OpenRouter prices (version 4), OpenAI's speech
    /// models (version 5) and their narrowing to two (version 6).
    var metadataVersion: Int?
    /// For a user's server: a digest of the base URL the list came from (not
    /// the URL), so a list is never shown for another address. `nil` for
    /// providers and caches written before.
    // WHY: .project-docs/decisions/2026-11-22-server-window.md
    var source: String?

    init(models: [CatalogModel] = [], fetchedAt: Date? = nil, lastRefreshFailed: Bool = false, limited: Bool = false) {
        self.models = models
        self.fetchedAt = fetchedAt
        self.lastRefreshFailed = lastRefreshFailed
        self.limited = limited
        self.metadataVersion = Self.currentMetadataVersion
    }

    /// The list can be trusted to say a model is gone.
    var isAuthoritative: Bool { fetchedAt != nil && !lastRefreshFailed && !limited }
}

/// Per-account catalog cache with a time-to-live, kept in
/// `~/Library/Caches/<bundle id>/model-catalog-v1.json`.
@MainActor
final class ModelCatalogStore: ObservableObject {
    static let shared = ModelCatalogStore()

    nonisolated static var defaultFileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches
            .appendingPathComponent(BuildConfig.bundleID, isDirectory: true)
            .appendingPathComponent("model-catalog-v1.json")
    }

    /// Keyed by `ProviderAccount.storageID`.
    @Published private(set) var snapshots: [String: CatalogSnapshot]

    private let fileURL: URL
    private let fetcher: any ModelCatalogFetching
    private let now: () -> Date
    private let ttl: TimeInterval
    private var inFlight: Set<String> = []
    /// Bumped by `forget`: a refresh that was in flight then does not write
    /// back what it fetched for the forgotten configuration.
    private var generations: [String: Int] = [:]

    init(
        fileURL: URL = ModelCatalogStore.defaultFileURL,
        fetcher: any ModelCatalogFetching = ModelCatalogFetcher(),
        now: @escaping () -> Date = Date.init,
        ttl: TimeInterval = 86_400
    ) {
        self.fileURL = fileURL
        self.fetcher = fetcher
        self.now = now
        self.ttl = ttl
        self.snapshots = Self.load(from: fileURL)
    }

    func snapshot(for account: ProviderAccount) -> CatalogSnapshot? {
        snapshots[account.storageID]
    }

    /// The server's list, only if it came from the server's current address.
    func snapshot(for account: ProviderAccount, server: ServerEndpoint) -> CatalogSnapshot? {
        guard let snapshot = snapshots[account.storageID], snapshot.source == Self.source(of: server) else { return nil }
        return snapshot
    }

    nonisolated static func source(of server: ServerEndpoint) -> String {
        SHA256.hash(data: Data(server.baseURL.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads the catalog unless the cached one is younger than the TTL and its
    /// last refresh worked.
    func refreshIfStale(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async {
        let needsCurrentMetadata = [ProviderAccount.openAI, .anthropic, .openRouter].contains(account)
        if let snapshot = snapshots[account.storageID],
           (!needsCurrentMetadata || snapshot.metadataVersion == CatalogSnapshot.currentMetadataVersion),
           let fetchedAt = snapshot.fetchedAt,
           !snapshot.lastRefreshFailed,
           now().timeIntervalSince(fetchedAt) < ttl {
            return
        }
        await refresh(account, apiKey: apiKey, server: server)
    }

    func refresh(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async {
        let id = account.storageID
        guard inFlight.insert(id).inserted else { return }
        defer { inFlight.remove(id) }

        let generation = generations[id, default: 0]
        let source = server.map(Self.source(of:))
        var snapshot = snapshots[id] ?? CatalogSnapshot()
        if snapshot.source != source {
            // Another address's list says nothing about this one.
            snapshot = CatalogSnapshot()
            snapshot.source = source
        }
        do {
            snapshot.models = try await fetcher.fetch(account: account, apiKey: apiKey, server: server)
            snapshot.fetchedAt = now()
            snapshot.lastRefreshFailed = false
            snapshot.limited = false
            snapshot.metadataVersion = CatalogSnapshot.currentMetadataVersion
        } catch let error as CatalogFetchError {
            switch Self.outcome(of: error, account: account) {
            case .emptyCatalog:
                // A valid server that has no /models: an empty, successful catalog.
                snapshot.models = []
                snapshot.fetchedAt = now()
                snapshot.lastRefreshFailed = false
                snapshot.limited = false
            case .limited:
                snapshot.limited = true
                snapshot.lastRefreshFailed = false
            case .failed:
                snapshot.lastRefreshFailed = true
            }
        } catch {
            snapshot.lastRefreshFailed = true
        }
        guard generations[id, default: 0] == generation else { return }
        snapshots[id] = snapshot
        persist()
    }

    func forget(_ account: ProviderAccount) {
        generations[account.storageID, default: 0] += 1
        guard snapshots.removeValue(forKey: account.storageID) != nil else { return }
        persist()
    }

    // MARK: - Outcome

    private enum Outcome { case emptyCatalog, limited, failed }

    private static func outcome(of error: CatalogFetchError, account: ProviderAccount) -> Outcome {
        guard case .http(let status, let code) = error else { return .failed }
        switch account {
        case .server where status == 404:
            return .emptyCatalog
        case .soniox where status == 403:
            return .limited
        case .deepgram where (status == 401 || status == 403) && code == "INSUFFICIENT_PERMISSIONS":
            return .limited
        default:
            return .failed
        }
    }

    // MARK: - File

    private static func load(from url: URL) -> [String: CatalogSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CatalogSnapshot].self, from: data)
        else { return [:] }
        var normalized = decoded
        // v2 classified every text-shaped Jev catalog entry as chat and did
        // not know OpenAI Decisions. Correct those known capabilities even
        // offline, before the first picker opens; the version also forces a
        // normal free catalog refresh instead of waiting for its daily TTL.
        for (id, snapshot) in decoded where snapshot.metadataVersion != CatalogSnapshot.currentMetadataVersion {
            var snapshot = snapshot
            snapshot.models = snapshot.models.map { model in
                var model = model
                if id == ProviderAccount.openRouter.storageID,
                   model.id.hasPrefix("typesafe/jev-"), model.id != "typesafe/jev-router" {
                    model.uses = [.decision]
                } else if id == ProviderAccount.openAI.storageID, model.id == ModelRegistry.openAIDecisionModel {
                    model.uses = (model.uses ?? [.chat, .chatWithTools]).union([.decision])
                }
                return model
            }
            normalized[id] = snapshot
        }
        return normalized
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshots).write(to: fileURL, options: .atomic)
        } catch {
            // A cache that cannot be written is only a cache that is not kept.
        }
    }
}
