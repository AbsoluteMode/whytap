import Foundation

/// The provider account and model one feature runs on.
struct FeatureRoute: Codable, Equatable, Sendable {
    var account: ProviderAccount
    var model: String
    /// OpenRouter only: the endpoint tag (`"deepinfra/fp4"`) the model is
    /// pinned to, with no fallback to other providers. `nil` is Auto, where
    /// OpenRouter picks. Belongs to `model`: a new model starts on Auto.
    var provider: String? = nil
}

/// Everything `AIRoutingStore` persists, as one JSON value.
struct AIRoutingState: Codable, Equatable {
    /// Keyed by `AIFeature.rawValue`. A feature without an entry is Not set.
    var routes: [String: FeatureRoute]
    /// What each feature was set to by the one-time migration. Later changes
    /// leave it alone, so Settings can still say what a Not set feature used
    /// to run on.
    var migratedRoutes: [String: FeatureRoute]
    var servers: [ServerEndpoint]
    /// 0 — legacy migration pending; 1 — legacy routes carried over;
    /// 2 — subtitle translation detached from text Translation;
    /// 3 — default Smart decision route added once; 4 — that route retired.
    var migrationVersion: Int
}

/// Which provider account and model each AI feature runs on, plus the user's
/// own servers. The runtime reads a feature's route on every call, so a change
/// applies to the next dictation, meeting or agent turn.
///
/// Routes change only through a user action or the one-time migration. The
/// store never moves a feature to another provider by itself: a removed key or
/// server leaves its features Not set.
// WHY: .project-docs/decisions/2026-10-19-api-and-models.md
@MainActor
final class AIRoutingStore: ObservableObject {
    /// Shared by the Settings window and the runtime, so both see one state.
    static let shared = AIRoutingStore()

    static let defaultsKey = "sidekey.aiRouting.v1"
    /// A copy of a stored value this build did not read in full, written just
    /// before the first change replaces it.
    static let backupKey = "sidekey.aiRouting.v1.unreadable"

    private static let emptyState = AIRoutingState(
        routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 0
    )

    @Published private(set) var state: AIRoutingState

    private let defaults: UserDefaults
    /// The stored value as loaded, when part or all of it could not be read.
    private var pendingBackup: Any?
    /// An independent choice this build cannot decode is not an absent route.
    private var hasUnreadSubtitleRoute: Bool

    /// Production uses `UserDefaults.standard`. Tests pass an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = Self.load(from: defaults)
        self.state = loaded.state
        self.pendingBackup = loaded.unreadValue
        self.hasUnreadSubtitleRoute = loaded.hasUnreadSubtitleRoute
    }

    var isMigrated: Bool { state.migrationVersion >= 1 }

    /// Settings sync wrote another Mac's routing document: read it again so
    /// the next request and Settings use it. Nothing is written here.
    // WHY: .project-docs/decisions/2026-11-20-settings-sync.md
    func reloadFromDefaults() {
        let loaded = Self.load(from: defaults)
        pendingBackup = loaded.unreadValue
        hasUnreadSubtitleRoute = loaded.hasUnreadSubtitleRoute
        if loaded.state != state { state = loaded.state }
        // Settings sync can bring a Meetings route from an older Mac that still
        // names a streaming Scribe model: the row, Check now and the recording
        // all use the recorded model.
        // WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
        moveMeetingsToRecordedModelIfNeeded()
        adoptExplicitServerModelsIfNeeded()
    }

    // MARK: - Routes

    func route(for feature: AIFeature) -> FeatureRoute? {
        guard feature.isActive else { return nil }
        // A partial v1 document cannot be rewritten at launch. Expose the
        // same one-time split in memory so configured subtitles keep working
        // before the first real edit commits it (and retains the raw backup).
        return stateWithSubtitleSeparation.routes[feature.rawValue]
    }

    /// The route the migration chose for `feature`, if any. Not affected by
    /// later changes.
    func migratedRoute(for feature: AIFeature) -> FeatureRoute? {
        feature.isActive ? state.migratedRoutes[feature.rawValue] : nil
    }

    /// `nil` un-sets the feature.
    func setRoute(_ route: FeatureRoute?, for feature: AIFeature) {
        guard feature.isActive else { return }
        var updated = stateWithSubtitleSeparation
        guard state.routes[feature.rawValue] != route || updated.routes[feature.rawValue] != route else { return }
        updated.routes[feature.rawValue] = route
        commit(updated)
    }

    /// Pins an OpenRouter route to one provider endpoint, or back to Auto
    /// (`nil`). Other accounts have no provider choice and are left alone.
    func setProvider(_ provider: String?, for feature: AIFeature) {
        guard var route = route(for: feature), route.account == .openRouter else { return }
        route.provider = provider
        setRoute(route, for: feature)
    }

    /// Un-sets every feature that runs on `account`, for example after its key
    /// was removed. Returns them in registry order so the UI can say which
    /// features were left without a model. The migration snapshot stays.
    @discardableResult
    func clearRoutes(using account: ProviderAccount) -> [AIFeature] {
        var updated = stateWithSubtitleSeparation
        let cleared = AIFeature.activeCases.filter { updated.routes[$0.rawValue]?.account == account }
        guard !cleared.isEmpty else { return [] }
        for feature in cleared {
            updated.routes[feature.rawValue] = nil
        }
        commit(updated)
        return cleared
    }

    // MARK: - Servers

    func server(_ id: UUID) -> ServerEndpoint? {
        state.servers.first { $0.id == id }
    }

    /// Adds a server under a fresh ID. Its key, if the user sets one, belongs
    /// in the Keychain account named by the returned `keyAccount`.
    @discardableResult
    func addServer(name: String, baseURL: String) -> ServerEndpoint {
        let id = UUID()
        let server = ServerEndpoint(
            id: id, name: name, baseURL: baseURL,
            keyAccount: "byok.server.\(id.uuidString.lowercased()).api_key",
            models: []
        )
        var updated = stateWithSubtitleSeparation
        updated.servers.append(server)
        commit(updated)
        return server
    }

    /// Changes a server's address and the name older builds show; routes,
    /// key and models stay.
    func updateServer(_ id: UUID, name: String, baseURL: String) {
        var updated = stateWithSubtitleSeparation
        guard let index = updated.servers.firstIndex(where: { $0.id == id }) else { return }
        updated.servers[index].name = name
        updated.servers[index].baseURL = baseURL
        commit(updated)
    }

    /// Replaces the server's model list (the first of a repeated name and
    /// kind is kept). Features of a kind that ran on a model taken off the
    /// list become Not set; a route on a model that was never listed stays.
    /// Returns the features that became Not set.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    @discardableResult
    func setModels(_ models: [ServerModel], forServer id: UUID) -> [AIFeature] {
        var updated = stateWithSubtitleSeparation
        guard let index = updated.servers.firstIndex(where: { $0.id == id }) else { return [] }
        let old = updated.servers[index].models ?? []
        var kept: [ServerModel] = []
        for model in models where !kept.contains(where: { $0.name == model.name && $0.kind == model.kind }) {
            kept.append(model)
        }
        updated.servers[index].models = kept
        let cleared = AIFeature.activeCases.filter { feature in
            guard let route = updated.routes[feature.rawValue], route.account == .server(id),
                  let kind = ServerModel.Kind(feature) else { return false }
            let wasListed = old.contains { $0.name == route.model && $0.kind == kind }
            let isListed = kept.contains { $0.name == route.model && $0.kind == kind }
            return wasListed && !isListed
        }
        for feature in cleared { updated.routes[feature.rawValue] = nil }
        commit(updated)
        return cleared
    }

    /// Adds a model to the server's list. `false` when the server is gone or
    /// already has this name as this kind; the same name may be added once
    /// per kind (a model that both chats and transcribes).
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    @discardableResult
    func addModel(_ model: ServerModel, toServer id: UUID) -> Bool {
        var updated = stateWithSubtitleSeparation
        guard let index = updated.servers.firstIndex(where: { $0.id == id }),
              !updated.servers[index].hasModel(model.name, kind: model.kind) else { return false }
        updated.servers[index].models = (updated.servers[index].models ?? []) + [model]
        commit(updated)
        return true
    }

    /// Removes one model of one kind and un-sets the features of that kind
    /// that ran on it, in registry order. None moves to another model.
    @discardableResult
    func removeModel(named name: String, kind: ServerModel.Kind, fromServer id: UUID) -> [AIFeature] {
        var updated = stateWithSubtitleSeparation
        guard let index = updated.servers.firstIndex(where: { $0.id == id }) else { return [] }
        updated.servers[index].models = (updated.servers[index].models ?? []).filter { $0.name != name || $0.kind != kind }
        let cleared = AIFeature.activeCases.filter { feature in
            guard let route = updated.routes[feature.rawValue] else { return false }
            return route.account == .server(id) && route.model == name && ServerModel.Kind(feature) == kind
        }
        for feature in cleared { updated.routes[feature.rawValue] = nil }
        commit(updated)
        return cleared
    }

    /// A server written before models were added explicitly gets, once, one
    /// entry per model its features run on, with that feature's kind, marked
    /// checked (it was in use). Its other `/v1/models` entries are no longer
    /// offered until the user adds them. Runs at launch and after settings
    /// sync, so a server restored from an older backup or synced from an older
    /// Mac is converted too; a server that already has a list is left alone.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    func adoptExplicitServerModelsIfNeeded() {
        guard pendingBackup == nil else { return }
        var updated = stateWithSubtitleSeparation
        for index in updated.servers.indices where updated.servers[index].models == nil {
            let account = ProviderAccount.server(updated.servers[index].id)
            var models: [ServerModel] = []
            for feature in AIFeature.activeCases {
                guard let route = updated.routes[feature.rawValue], route.account == account,
                      let kind = ServerModel.Kind(feature),
                      !models.contains(where: { $0.name == route.model && $0.kind == kind }) else { continue }
                models.append(ServerModel(name: route.model, kind: kind, checked: true))
            }
            updated.servers[index].models = models
        }
        commit(updated)
    }

    /// Removes the server and un-sets every feature that ran on it. Those
    /// features become Not set; none moves to another provider.
    func removeServer(_ id: UUID) {
        var updated = stateWithSubtitleSeparation
        guard updated.servers.contains(where: { $0.id == id })
                || updated.routes.values.contains(where: { $0.account == .server(id) }) else { return }
        updated.servers.removeAll { $0.id == id }
        updated.routes = updated.routes.filter { $0.value.account != .server(id) }
        commit(updated)
    }

    // MARK: - Migration

    /// Records the one-time migration of the old Models-tab settings: the routes
    /// it chose (also kept as the "selected before migration" snapshot), the
    /// servers it carried over, and the version marker.
    func completeMigration(routes: [AIFeature: FeatureRoute], servers: [ServerEndpoint]) {
        let byFeature = Dictionary(uniqueKeysWithValues: routes.map { ($0.key.rawValue, $0.value) })
        commit(AIRoutingState(
            routes: byFeature, migratedRoutes: byFeature, servers: servers, migrationVersion: 1
        ))
    }

    /// Preserve the route already used by configured subtitles once, then
    /// keep it independent. An unset/deleted subtitle LLM never borrows the
    /// text translator's route on later launches.
    // WHY: .project-docs/decisions/2026-10-20-translation-tools.md
    func separateSubtitleTranslationIfNeeded() {
        guard pendingBackup == nil else { return }
        commit(stateWithSubtitleSeparation)
    }

    /// The pending v1 split is also the read-only effective route until it
    /// can be persisted. An explicit edit commits the split before applying
    /// the change, so later clears/removals cannot be undone on relaunch.
    private var stateWithSubtitleSeparation: AIRoutingState {
        guard state.migrationVersion == 1 else { return state }
        var updated = state
        if !hasUnreadSubtitleRoute,
           updated.routes[AIFeature.subtitlesTranslation.rawValue] == nil,
           updated.routes[AIFeature.subtitlesAudio.rawValue] != nil,
           let previous = updated.routes[AIFeature.translation.rawValue] {
            updated.routes[AIFeature.subtitlesTranslation.rawValue] = previous
        }
        updated.migrationVersion = 2
        return updated
    }

    /// Retire the independent Decision route, including after an old backup
    /// restore. Other routes, provider pins, keys and unknown data stay intact.
    // WHY: .project-docs/decisions/2026-10-22-smart-editor-pass.md
    func retireSmartDecisionIfNeeded() {
        guard pendingBackup == nil else { return }
        var updated = stateWithSubtitleSeparation
        updated.routes[AIFeature.dropSmartDecision.rawValue] = nil
        updated.migratedRoutes[AIFeature.dropSmartDecision.rawValue] = nil
        updated.migrationVersion = max(4, updated.migrationVersion)
        commit(updated)
    }

    /// Also retire routes restored from older backups. Keep provider keys,
    /// unrelated routes and historical usage identifiers intact.
    // WHY: docs/decisions/2026-11-05-retire-live-assistant.md
    func retireMeetingRoutesIfNeeded() {
        guard pendingBackup == nil else { return }
        var updated = stateWithSubtitleSeparation
        for feature in [AIFeature.retiredMeetingText, .retiredMeetingAudio] {
            updated.routes[feature.rawValue] = nil
            updated.migratedRoutes[feature.rawValue] = nil
        }
        commit(updated)
    }

    /// Move every ElevenLabs route still naming Scribe v2 Realtime to Scribe
    /// v3 Live: the same account and key, the provider's newer model. Runs at
    /// each launch, so a route restored from an older backup moves too. The
    /// migration snapshot keeps what was chosen before.
    // WHY: .project-docs/decisions/2026-11-20-elevenlabs-scribe-v3.md
    func upgradeElevenLabsScribeIfNeeded() {
        guard pendingBackup == nil else { return }
        var updated = stateWithSubtitleSeparation
        for (feature, route) in updated.routes
        where route.account == .elevenLabs && route.model == ModelRegistry.elevenLabsRetiredRealtimeModel {
            updated.routes[feature]?.model = ModelRegistry.elevenLabsRealtimeModel
        }
        commit(updated)
    }

    /// Meetings on ElevenLabs go to its speech-to-text endpoint, which
    /// refuses the streaming model: a saved Meetings route naming a Scribe
    /// real-time model moves to Scribe v3 on the same account and key, on the
    /// owner's decision. Not version-gated, so a route restored from an older
    /// backup or synced from an older Mac moves too. Nothing else changes;
    /// Deepgram's nova-3 serves both kinds.
    // WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
    func moveMeetingsToRecordedModelIfNeeded() {
        guard pendingBackup == nil else { return }
        let key = AIFeature.meetings.rawValue
        guard let route = stateWithSubtitleSeparation.routes[key], route.account == .elevenLabs else { return }
        let recorded = ModelRegistry.elevenLabsRecordedModel(for: route.model)
        guard recorded != route.model else { return }
        var updated = stateWithSubtitleSeparation
        updated.routes[key]?.model = recorded
        commit(updated)
    }

    /// Soniox v6 replaced v5 on the owner's decision, three weeks before
    /// Soniox itself routes v5 requests to v6: a saved Soniox route moves to
    /// the same kind of v6 model on the same account. Not version-gated, so a
    /// route restored from an older backup moves too. Nothing else changes.
    // WHY: .project-docs/decisions/2026-11-20-speech-model-lists.md
    func upgradeSonioxModelsIfNeeded() {
        guard pendingBackup == nil else { return }
        let replacements = [
            ModelRegistry.sonioxRetiredRealtimeModel: ModelRegistry.sonioxRealtimeModel,
            ModelRegistry.sonioxRetiredRecordedModel: ModelRegistry.sonioxRecordedModel,
        ]
        var updated = stateWithSubtitleSeparation
        for (feature, route) in updated.routes where route.account == .soniox {
            if let newer = replacements[route.model] { updated.routes[feature]?.model = newer }
        }
        commit(updated)
    }

    // MARK: - Persistence

    /// Reads entry by entry: a route or server this build does not know (an
    /// account a newer build added) is skipped and the rest is kept. A stored
    /// value that cannot be read at all still counts as migrated, with every
    /// feature Not set: running the migration again would overwrite the user's
    /// choices from the frozen old settings. Loading never writes; the first
    /// real change saves a copy of such a value under `backupKey`.
    // WHY: .project-docs/decisions/2026-10-19-api-and-models.md
    private static func load(from defaults: UserDefaults) -> (state: AIRoutingState, unreadValue: Any?, hasUnreadSubtitleRoute: Bool) {
        guard let stored = defaults.object(forKey: defaultsKey) else { return (emptyState, nil, false) }
        guard let data = stored as? Data,
              let read = try? JSONDecoder().decode(LenientRoutingState.self, from: data)
        else {
            return (AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 1), stored, false)
        }
        return (read.state, read.isComplete ? nil : data, read.hasUnreadSubtitleRoute)
    }

    /// Applies a change in one step (one `objectWillChange`) and saves the
    /// whole state. A change that alters nothing neither publishes nor writes.
    private func commit(_ updated: AIRoutingState) {
        guard updated != state else { return }
        if let backup = pendingBackup {
            defaults.set(backup, forKey: Self.backupKey)
            pendingBackup = nil
        }
        state = updated
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            defaults.set(try encoder.encode(updated), forKey: Self.defaultsKey)
        } catch {
            assertionFailure("AIRoutingState cannot be encoded: \(error)")
        }
    }
}

/// `AIRoutingState` read leniently: each route and server on its own, unknown
/// keys ignored, absent fields empty. A state without a version marker was
/// still written by this store after the migration, so it counts as migrated.
private struct LenientRoutingState: Decodable {
    let state: AIRoutingState
    /// Nothing was skipped.
    let isComplete: Bool
    let hasUnreadSubtitleRoute: Bool

    private enum CodingKeys: String, CodingKey {
        case routes, migratedRoutes, servers, migrationVersion
    }

    /// One value that may not decode; `nil` then, instead of failing the whole.
    private struct Entry<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let routes = (try? container.decodeIfPresent([String: Entry<FeatureRoute>].self, forKey: .routes)) ?? nil
        let migrated = (try? container.decodeIfPresent([String: Entry<FeatureRoute>].self, forKey: .migratedRoutes)) ?? nil
        let servers = (try? container.decodeIfPresent([Entry<ServerEndpoint>].self, forKey: .servers)) ?? nil
        let version = (try? container.decodeIfPresent(Int.self, forKey: .migrationVersion)) ?? nil
        if let subtitle = routes?[AIFeature.subtitlesTranslation.rawValue] {
            hasUnreadSubtitleRoute = subtitle.value == nil
        } else {
            hasUnreadSubtitleRoute = false
        }

        state = AIRoutingState(
            routes: (routes ?? [:]).compactMapValues(\.value),
            migratedRoutes: (migrated ?? [:]).compactMapValues(\.value),
            servers: (servers ?? []).compactMap(\.value),
            migrationVersion: version ?? 1
        )
        let skippedEntry = (routes ?? [:]).values.contains { $0.value == nil }
            || (migrated ?? [:]).values.contains { $0.value == nil }
            || (servers ?? []).contains { $0.value == nil }
        isComplete = routes != nil && migrated != nil && servers != nil && version != nil && !skippedEntry
    }
}
