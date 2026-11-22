import Foundation

/// The badge on a feature's row in API & Models.
enum ModelRowStatus: Equatable {
    case ok
    case notSet
    case keyProblem
    case notVerified
    case removedByProvider
    case deprecatedAlias(of: String)
    case expiring(Date)
    case notSupported(reason: String)
}

/// How one model looks in a picker.
enum PickerOptionState: Equatable {
    case verified
    case new
    case notSupported(reason: String)
}

struct PickerOption: Equatable {
    let model: String
    let state: PickerOptionState
    let isSelected: Bool
    let hint: String?
    var dateLabel: String? = nil
    var catalogDate: Date? = nil
    /// OpenRouter's list price; display only, never part of search or routing.
    var priceLabel: String? = nil
}

/// One provider account's block in a feature's model picker.
struct PickerSection: Equatable {
    let account: ProviderAccount
    let title: String
    /// Models the feature cannot use are left out, except the selected one.
    let options: [PickerOption]
    /// The latest catalog refresh failed: the list is the cached one.
    let refreshFailed: Bool
    /// The provider refused the key or it can't be read: the section stays
    /// (a fixed key makes it work again) but its header says so.
    var keyProblem: String? = nil
    /// A custom server without a catalog still accepts its configured model
    /// name, even when the selected route is included in `options`.
    var acceptsModelName = false
}

/// What a feature's picker does with one model (`ModelStatusResolver.pickerReach`).
enum PickerReach: Equatable {
    /// The account has no section for this feature (no key, or it can't serve it).
    case noSection
    /// `verdict` rules the model out for this feature.
    case ruledOut(reason: String)
    /// Listed: registry, catalog or the feature's own route.
    case offered
    /// Not listed, but the server section takes a typed model name.
    case typed
    /// The section neither lists it nor takes a typed name.
    case notListed
}

/// One "Switch" action: several features sit on the same deprecated alias of
/// the same account and can move to its replacement together.
struct AliasGroupAction: Equatable {
    let account: ProviderAccount
    let from: String
    let to: String
    let features: [AIFeature]
}

extension OpenRouterLLMError {
    /// The provider turned the model itself down (bad request, not found,
    /// unprocessable), as opposed to a key, quota or outage problem. An input
    /// over the context window and OpenRouter's "no endpoints matching your
    /// data policy" (an account privacy setting) are not about the model.
    var isModelRefusal: Bool {
        guard case .unexpectedStatus(let status, let message) = self,
              [400, 404, 422].contains(status)
        else { return false }
        let text = (message ?? "").lowercased()
        let contextOverflow = text.contains("context_length")
            || (text.contains("context") && (text.contains("length") || text.contains("token")))
        return !contextOverflow && !text.contains("data policy")
    }
}

/// Derives what API & Models shows from the stores: the status of each
/// feature's row, the picker sections and the group "Switch" actions. Pure
/// reads of local state; it never touches the network.
// WHY: .project-docs/decisions/2026-10-19-api-and-models.md
@MainActor
struct ModelStatusResolver {
    static let refusedReason = "The provider refused this model"

    /// Picker order. OpenRouter lists hundreds of models, so it comes after
    /// the direct providers and the user's servers: first it buried the
    /// Anthropic and OpenAI sections far below the visible rows.
    // WHY: .project-docs/decisions/2026-11-22-direct-model-list-prices.md
    private static let directAccounts: [ProviderAccount] = [.soniox, .deepgram, .elevenLabs, .anthropic, .openAI, .thisMac]

    private let routing: AIRoutingStore
    private let keys: ProviderKeyStore
    private let catalogs: ModelCatalogStore
    private let checks: ModelCheckStore
    private let keyStatuses: KeyStatusStore
    private let onDevice: OnDeviceSpeechReadiness
    private let adapterVersion: (AIProviderKind, ModelUse) -> Int

    init(
        routing: AIRoutingStore,
        keys: ProviderKeyStore,
        catalogs: ModelCatalogStore,
        checks: ModelCheckStore,
        keyStatuses: KeyStatusStore,
        onDevice: OnDeviceSpeechReadiness = .live,
        adapterVersion: @escaping (AIProviderKind, ModelUse) -> Int = ModelRegistry.adapterVersion
    ) {
        self.onDevice = onDevice
        self.routing = routing
        self.keys = keys
        self.catalogs = catalogs
        self.checks = checks
        self.keyStatuses = keyStatuses
        self.adapterVersion = adapterVersion
    }

    // MARK: - Row status

    func status(for feature: AIFeature) -> ModelRowStatus {
        guard let route = routing.route(for: feature) else { return .notSet }
        let account = route.account
        let credential = credential(of: account)
        if credential == .missing { return .notSet }
        if credential == .unreadable { return .keyProblem }
        if case .rejected = keyStatuses.record(for: account)?.status { return .keyProblem }

        guard let use = feature.modelUse(on: account.kind) else {
            return .notSupported(reason: "\(account.kind.displayName) can't serve \(feature.title)")
        }

        let snapshot = catalogs.snapshot(for: account)
        let entry = snapshot?.models.first { $0.id == route.model }
        // An empty list says nothing (ElevenLabs lists no speech models, a
        // server may have no /models), and a stale or partial one is never
        // grounds to call a model gone (Review Focus 4).
        if use != .decision, let snapshot, snapshot.isAuthoritative, !snapshot.models.isEmpty, entry == nil {
            return .removedByProvider
        }
        if let target = entry?.aliasOf { return .deprecatedAlias(of: target) }
        if let expiry = entry?.expiresAt { return .expiring(expiry) }
        if checks.refusedModel(for: feature) == route.model {
            return .notSupported(reason: Self.refusedReason)
        }
        if let reason = failedProbeReason(model: route.model, account: account, use: use) {
            return .notSupported(reason: reason)
        }
        return isVerified(model: route.model, account: account, feature: feature, use: use) ? .ok : .notVerified
    }

    // MARK: - Picker

    /// The accounts with a picker section, in picker order.
    func pickerAccounts() -> [ProviderAccount] {
        var accounts = Self.directAccounts.filter { credential(of: $0) != .missing }
        let servers = routing.state.servers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        accounts += servers.map { ProviderAccount.server($0.id) }
        if credential(of: .openRouter) != .missing { accounts.append(.openRouter) }
        return accounts
    }

    /// What `feature`'s picker does with one model of one account, answered
    /// without building the list: the shared Speech and LLM rows ask this for
    /// a handful of routes whenever Settings recomputes, and a full section
    /// of a large cached catalog (OpenRouter) costs seconds on the main actor.
    /// The same rules as `sections(for:)`: the account needs a section, the
    /// model must not be ruled out (`verdict`), and it is offered when the
    /// registry or the catalog lists it or it is the feature's route;
    /// otherwise a server section that takes a typed name accepts it.
    // WHY: .project-docs/decisions/2026-11-22-shared-model-rows.md
    func pickerReach(model: String, account: ProviderAccount, for feature: AIFeature,
                     accountsWithSection: [ProviderAccount]? = nil) -> PickerReach {
        guard (accountsWithSection ?? pickerAccounts()).contains(account),
              let use = feature.modelUse(on: account.kind) else { return .noSection }
        if case .notSupported(let reason) = verdict(model: model, account: account, for: feature) {
            return .ruledOut(reason: reason)
        }
        let selected = routing.route(for: feature)
        if selected?.account == account, selected?.model == model { return .offered }
        if ModelRegistry.models.contains(where: { $0.kind == account.kind && $0.id == model && $0.uses.contains(use) }) {
            return .offered
        }
        let snapshot = catalogs.snapshot(for: account)
        if let entry = snapshot?.models.first(where: { $0.id == model }), entry.aliasOf == nil,
           !ModelRegistry.offersOnlyBuiltInModels(account.kind), !Self.isStale(entry, fetchedAt: snapshot?.fetchedAt) {
            return .offered
        }
        guard account.kind == .openAICompatible else { return .notListed }
        // Same rule as the section's acceptsModelName: no list, or nothing of
        // this kind in it. A server's list is short.
        let models = snapshot?.models ?? []
        let listsThisKind = models.contains { entry in
            if case .notSupported = verdict(model: entry.id, account: account, for: feature) { return false }
            return true
        } || selected?.account == account
        return models.isEmpty || !listsThisKind ? .typed : .notListed
    }

    /// `only`: build just that account's section.
    func sections(for feature: AIFeature, only: ProviderAccount? = nil) -> [PickerSection] {
        let selected = routing.route(for: feature)
        let openRouterModels = Dictionary(
            (catalogs.snapshot(for: .openRouter)?.models ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var accounts = pickerAccounts()
        if let only { accounts = accounts.filter { $0 == only } }
        return accounts.compactMap { account in
            guard let use = feature.modelUse(on: account.kind) else { return nil }
            let snapshot = catalogs.snapshot(for: account)
            let isSelected: (String) -> Bool = { selected?.account == account && selected?.model == $0 }

            var seen = Set<String>()
            var ids: [String] = []
            func add(_ id: String) { if seen.insert(id).inserted { ids.append(id) } }
            for model in ModelRegistry.models where model.kind == account.kind && model.uses.contains(use) {
                add(model.id)
            }
            for model in (snapshot?.models ?? []).sorted(by: { $0.id < $1.id })
            where (model.aliasOf == nil && !ModelRegistry.offersOnlyBuiltInModels(account.kind)
                && !Self.isStale(model, fetchedAt: snapshot?.fetchedAt)) || isSelected(model.id) {
                add(model.id)
            }
            if let selected, selected.account == account { add(selected.model) }

            var options: [PickerOption] = []
            for id in ids {
                let state = verdict(model: id, account: account, for: feature)
                if case .notSupported = state, !isSelected(id) { continue }
                let entry = snapshot?.models.first { $0.id == id }
                let date: Date?
                switch account {
                case .deepgram: date = entry?.updatedAt
                case .server: date = Self.serverModelDate(entry?.catalogDate, fetchedAt: snapshot?.fetchedAt)
                default: date = entry?.catalogDate ?? ModelRegistry.documentedReleaseDate(for: id, kind: account.kind)
                }
                let dateLabel = Self.catalogDateLabel(date, account: account)
                // Price and "always reasons" come from OpenRouter's catalog:
                // the row itself there, its counterpart for a direct route.
                let listing = account == .openRouter ? entry
                    : Self.openRouterCounterpart(of: id, account: account, in: openRouterModels)
                options.append(PickerOption(
                    model: id, state: state, isSelected: isSelected(id),
                    hint: hint(model: id, account: account, feature: feature, use: use, listing: listing),
                    dateLabel: dateLabel,
                    catalogDate: dateLabel == nil ? nil : date,
                    priceLabel: Self.catalogPriceLabel(listing?.tokenPrice)
                ))
            }
            return PickerSection(
                account: account,
                title: title(of: account),
                options: options,
                refreshFailed: snapshot?.lastRefreshFailed ?? false,
                keyProblem: keyProblem(of: account),
                // A server without a list, or whose list has nothing of this
                // kind, takes a typed model name (it may serve more than it lists).
                // WHY: .project-docs/decisions/2026-11-22-server-model-kinds.md
                acceptsModelName: account.kind == .openAICompatible
                    && ((snapshot?.models.isEmpty ?? true) || options.isEmpty)
            )
        }
    }

    /// A model whose provider dates its versions (Deepgram) and that has not
    /// been updated for this long before the catalog was fetched is left out
    /// of pickers; it stays in the catalog, so a route on it keeps working.
    static let staleAfter: TimeInterval = 365 * 86_400

    static func catalogDateLabel(_ date: Date?, account: ProviderAccount) -> String? {
        guard let date, date.timeIntervalSince1970 > 0, date < .distantFuture else { return nil }
        let title: String
        switch account {
        case .anthropic, .soniox, .elevenLabs: title = "Released"
        case .deepgram: title = "Updated"
        case .openAI: title = "Created"
        case .openRouter: title = "Added to OpenRouter"
        case .server: title = "Added"
        case .thisMac: return nil
        }
        return "\(title) \(catalogDateFormatter.string(from: date))"
    }

    /// A user's server may send `created` in /v1/models: Ollama the time the
    /// model was pulled or changed there, while vLLM and llama.cpp stamp every
    /// model with the time of the request. A date within an hour of the fetch
    /// is that stamp, not the model's, and is not shown.
    static func serverModelDate(_ date: Date?, fetchedAt: Date?) -> Date? {
        guard let date, let fetchedAt, date < fetchedAt.addingTimeInterval(-3_600) else { return nil }
        return date
    }

    /// OpenRouter's list price: `$1.25 in / $10 out per 1M tokens`, or `Free`
    /// when the catalog states zero for both. An unknown price has no label.
    // WHY: .project-docs/decisions/2026-11-17-openrouter-model-prices.md
    static func catalogPriceLabel(_ price: CatalogTokenPrice?) -> String? {
        guard let price,
              let input = priceAmount(price.inputPerMillion),
              let output = priceAmount(price.outputPerMillion)
        else { return nil }
        if price.inputPerMillion == 0, price.outputPerMillion == 0 { return "Free" }
        return "$\(input) in / $\(output) out per 1M tokens"
    }

    /// The same model in OpenRouter's catalog, for a direct Anthropic or
    /// OpenAI row: their own model lists carry no price and do not say whether
    /// a model always reasons. OpenAI IDs match exactly (`gpt-5.4` is
    /// `openai/gpt-5.4`; a dated snapshot only when OpenRouter lists that
    /// snapshot). Anthropic IDs also match without the date suffix and with
    /// dots between version digits (`claude-opus-4-5-20251101` is
    /// `anthropic/claude-opus-4.5`). No match, no OpenRouter catalog or any
    /// other provider: nil, so the row shows no price rather than a guess.
    // WHY: .project-docs/decisions/2026-11-22-direct-model-list-prices.md
    static func openRouterCounterpart(
        of model: String, account: ProviderAccount, in openRouterModels: [String: CatalogModel]
    ) -> CatalogModel? {
        guard !openRouterModels.isEmpty else { return nil }
        return openRouterCounterpartIDs(of: model, account: account).lazy
            .compactMap { openRouterModels[$0] }.first
    }

    static func openRouterCounterpartIDs(of model: String, account: ProviderAccount) -> [String] {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !model.contains("/") else { return [] }
        switch account {
        case .openAI:
            return ["openai/\(model)"]
        case .anthropic:
            var base = model
            if let range = base.range(of: #"-\d{8}$"#, options: .regularExpression) {
                base.removeSubrange(range)
            }
            let dotted = base.replacingOccurrences(
                of: #"(?<=\d)-(?=\d)"#, with: ".", options: .regularExpression)
            var ids: [String] = []
            for candidate in [model, dotted] where !ids.contains("anthropic/\(candidate)") {
                ids.append("anthropic/\(candidate)")
            }
            return ids
        case .soniox, .deepgram, .elevenLabs, .openRouter, .thisMac, .server:
            return []
        }
    }

    /// Two decimals from $1 up; three significant digits below, so a small
    /// price is never rounded to zero.
    private static func priceAmount(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        if value == 0 { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        if value >= 1 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
        } else {
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 3
        }
        return formatter.string(from: NSNumber(value: value))
    }

    private static let catalogDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // Catalog dates describe a UTC calendar day, even west of Greenwich.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func isStale(_ model: CatalogModel, fetchedAt: Date?) -> Bool {
        guard let updated = model.updatedAt, let fetchedAt else { return false }
        return fetchedAt.timeIntervalSince(updated) > staleAfter
    }

    func missingProviderHint(for feature: AIFeature) -> String? {
        guard sections(for: feature).isEmpty else { return nil }
        let kinds = AIProviderKind.allCases.filter { feature.modelUse(on: $0) != nil }
        let names = kinds.filter { $0 != .onDevice }.map(Self.phrase(for:))
        // The keyless way to start, where this Mac can run the model.
        let download = kinds.contains(.onDevice) && OnDeviceSpeechModelStore.isSupportedHost
            ? ", or download the On this Mac model" : ""
        guard let last = names.last else { return nil }
        if names.count == 1 { return "Add a key for \(last)\(download)" }
        return "Add a key for \(names.dropLast().joined(separator: ", ")) or \(last)\(download)"
    }

    /// `ignoringStoredFailure` — what the model would be without a failed
    /// probe on record: a pick re-probes such a model instead of refusing it.
    func verdict(
        model: String, account: ProviderAccount, for feature: AIFeature, ignoringStoredFailure: Bool = false
    ) -> PickerOptionState {
        let kind = account.kind
        guard let use = feature.modelUse(on: kind) else {
            return .notSupported(reason: "\(kind.displayName) can't serve \(feature.title)")
        }
        if let reason = ModelRegistry.knownUnsupportedReason(model, kind: kind, use: use) {
            return .notSupported(reason: reason)
        }
        if let entry = judgedEntry(model: model, account: account, for: feature),
           let reason = contradiction(entry, feature: feature, use: use) {
            return .notSupported(reason: reason)
        }
        if !ignoringStoredFailure, let reason = failedProbeReason(model: model, account: account, use: use) {
            return .notSupported(reason: reason)
        }
        return isVerified(model: model, account: account, feature: feature, use: use) ? .verified : .new
    }

    /// The current adapter's probe of this model failed on this Mac.
    func hasStoredProbeFailure(model: String, account: ProviderAccount, for feature: AIFeature) -> Bool {
        guard let use = feature.modelUse(on: account.kind) else { return false }
        return failedProbeReason(model: model, account: account, use: use) != nil
    }

    // MARK: - Switch actions

    func aliasGroups() -> [AliasGroupAction] {
        struct Key: Hashable { let account: ProviderAccount; let from: String; let to: String }
        var order: [Key] = []
        var members: [Key: [AIFeature]] = [:]
        for feature in AIFeature.activeCases {
            guard let route = routing.route(for: feature),
                  case .deprecatedAlias(let target) = status(for: feature)
            else { continue }
            let key = Key(account: route.account, from: route.model, to: target)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(feature)
        }
        return order.compactMap { key in
            guard let features = members[key], features.count >= 2 else { return nil }
            return AliasGroupAction(account: key.account, from: key.from, to: key.to, features: features)
        }
    }

    // MARK: - Pieces

    private enum Credential { case present, missing, unreadable }

    /// A built-in provider needs its key; a server may run without one. An
    /// unreadable Keychain item is a key problem, never "no key".
    private func credential(of account: ProviderAccount) -> Credential {
        // On this Mac has no key: its downloaded model is the credential.
        if account == .thisMac { return onDevice.isReady() ? .present : .missing }
        guard let keychainAccount = account.keychainAccount(in: routing) else { return .missing }
        switch keys.lookup(account: keychainAccount) {
        case .key: return .present
        case .unreadable: return .unreadable
        case .absent:
            if case .server = account { return .present }
            return .missing
        }
    }

    private func keyProblem(of account: ProviderAccount) -> String? {
        if credential(of: account) == .unreadable { return "Couldn't read the key" }
        if case .rejected = keyStatuses.record(for: account)?.status { return "Key not accepted" }
        return nil
    }

    private func title(of account: ProviderAccount) -> String {
        if case .server(let id) = account, let server = routing.server(id) { return server.name }
        return account.kind.displayName
    }

    private func checkKey(model: String, account: ProviderAccount, use: ModelUse) -> ModelCheckKey {
        ModelCheckKey(account: account.storageID, model: model, use: use)
    }

    /// A failed probe counts only for the adapter that ran it.
    private func failedProbeReason(model: String, account: ProviderAccount, use: ModelUse) -> String? {
        guard let record = checks.record(for: checkKey(model: model, account: account, use: use)),
              record.adapterVersion == adapterVersion(account.kind, use),
              case .failed(let reason) = record.outcome
        else { return nil }
        return reason
    }

    /// In the registry; or probed and passed by the current adapter; or what
    /// the migration set up while every adapter was still at version 1.
    private func isVerified(model: String, account: ProviderAccount, feature: AIFeature, use: ModelUse) -> Bool {
        let version = adapterVersion(account.kind, use)
        if ModelRegistry.isVerified(model, kind: account.kind, use: use) { return true }
        if let record = checks.record(for: checkKey(model: model, account: account, use: use)),
           record.adapterVersion == version, record.outcome == .passed {
            return true
        }
        if let migrated = routing.migratedRoute(for: feature),
           migrated.account == account, migrated.model == model, version == 1 {
            return true
        }
        return false
    }

    /// The catalog's entry as `verdict` judges it. A server's models serve
    /// what the server's choice says (by default their names). The model a
    /// feature already runs on is not judged by that guess: a route that
    /// worked before the choice existed, or before the user changed it, keeps
    /// working and stays offered; only the user moves it.
    // WHY: .project-docs/decisions/2026-11-22-server-model-kinds.md
    private func judgedEntry(model: String, account: ProviderAccount, for feature: AIFeature) -> CatalogModel? {
        guard var entry = catalogs.snapshot(for: account)?.models.first(where: { $0.id == model }) else { return nil }
        guard case .server(let id) = account else { return entry }
        let current = routing.route(for: feature)
        if current?.account == account, current?.model == model {
            entry.uses = nil
        } else {
            entry.uses = (routing.server(id)?.modelKinds ?? .automatic).uses(of: model)
        }
        return entry
    }

    /// Why the catalog's own description rules a model out for this use.
    private func contradiction(_ entry: CatalogModel, feature: AIFeature, use: ModelUse) -> String? {
        switch use {
        case .realtimeSTT:
            if let uses = entry.uses, !uses.contains(.realtimeSTT) {
                return uses.contains(.asyncSTT) ? "recorded only" : "not a speech model"
            }
        case .asyncSTT:
            if let uses = entry.uses, !uses.contains(.asyncSTT) {
                return uses.contains(.realtimeSTT) ? "real-time only" : "not a speech model"
            }
        case .decision:
            if let uses = entry.uses, !uses.contains(.decision) { return "not a decision model" }
        case .chat:
            if let uses = entry.uses, !uses.contains(.chat) { return "not a text model" }
        case .chatWithTools:
            if entry.supportsTools == false { return "no tool support" }
            if let uses = entry.uses, !uses.contains(.chatWithTools) { return "no tool support" }
        case .speechTranslation:
            if entry.uses?.contains(.speechTranslation) != true { return "not a speech translation model" }
        }
        let minimum: Int?
        switch feature {
        case .agent: minimum = ModelRegistry.agentMinContext
        case .meetingNotes: minimum = ModelRegistry.meetingNotesMinContext
        case .dropFast, .dropSmart, .dropSmartCleanup, .dropSmartDecision, .meetings, .agentVoice, .voiceSearch, .translation, .subtitlesTranslation, .subtitlesAudio, .retiredMeetingAudio, .retiredMeetingText: minimum = nil
        }
        if let minimum, let context = entry.contextLength, context < minimum {
            return "context under 64K tokens"
        }
        return nil
    }

    /// `listing` is the model's OpenRouter catalog entry (its counterpart for
    /// a direct Anthropic or OpenAI row).
    private func hint(
        model: String, account: ProviderAccount, feature: AIFeature, use: ModelUse, listing: CatalogModel?
    ) -> String? {
        switch feature {
        case .dropSmartCleanup:
            return listing?.reasoning?.mandatory == true ? "always reasons, slower" : nil
        case .dropSmartDecision:
            return nil // Historical feature only; never shown as a configurable row.
        case .meetings:
            let registered = ModelRegistry.models.first {
                $0.kind == account.kind && $0.id == model && $0.uses.contains(use)
            }
            if registered?.diarization == true { return "with speakers" }
            // WHY: .project-docs/decisions/2026-11-21-on-device-everywhere.md
            return account == .thisMac ? "without speakers" : nil
        case .dropFast, .dropSmart, .meetingNotes, .agent, .retiredMeetingText, .agentVoice, .voiceSearch, .translation, .subtitlesTranslation, .subtitlesAudio, .retiredMeetingAudio:
            return nil
        }
    }

    private static func phrase(for kind: AIProviderKind) -> String {
        switch kind {
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic, .onDevice: return kind.displayName
        case .openAICompatible: return "an OpenAI-compatible server"
        }
    }
}
