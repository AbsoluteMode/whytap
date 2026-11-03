import Foundation
import WhytapCaseKit

/// The complete allowlist for agent access to the running app. All changes use
/// the stores/validation used by Settings. No arbitrary defaults, files or URLs.
// WHY: .project-docs/decisions/2026-10-21-app-control-plugin.md
@MainActor
final class AppControlController {
    private let routing: AIRoutingStore
    private var storedModels: APIAndModelsViewModel?
    private var models: APIAndModelsViewModel {
        if let storedModels { return storedModels }
        let created = APIAndModelsViewModel(routing: routing)
        storedModels = created
        return created
    }
    private let preferences: UserPreferencesCache
    private let languages: PrivacyPreferences
    private let idle: IslandIdlePreferences
    private let identity: AppBuildIdentity
    private let activity: () -> AppControlValue
    private let googleCalendarReview: () -> Bool
    private let screenCapture: AgentScreenCapture
    private let planner: @MainActor () -> PlannerStore
    private var mutating = false

    init(routing: AIRoutingStore? = nil, models: APIAndModelsViewModel? = nil,
         preferences: UserPreferencesCache? = nil, languages: PrivacyPreferences? = nil,
         idle: IslandIdlePreferences? = nil, identity: AppBuildIdentity = .current,
         activity: (() -> AppControlValue)? = nil, screenCapture: AgentScreenCapture? = nil,
         planner: (@MainActor () -> PlannerStore)? = nil,
         googleCalendarReview: @escaping () -> Bool = { GoogleCalendarReviewSession.current.isActive }) {
        self.screenCapture = screenCapture ?? AgentScreenCapture()
        self.planner = planner ?? { PlannerStore.shared }
        self.routing = routing ?? .shared
        // Reading status/settings must not read Keychain or initialize model
        // discovery. Model tools construct the view model only when needed.
        self.storedModels = models
        self.preferences = preferences ?? .shared
        self.languages = languages ?? .shared
        self.idle = idle ?? IslandIdlePreferences()
        self.identity = identity
        self.googleCalendarReview = googleCalendarReview
        self.activity = activity ?? {
            let state = AppState.shared
            return .object(["drop": .string(String(describing: state.phase)),
                            "agent": .string(String(describing: state.agentPhase)),
                            "meetingRecording": .bool(state.meetingRecordingActive),
                            "translationActive": .bool(state.translationActive),
                            "meetingAssistantActive": .bool(state.meetingAssistantActive)])
        }
    }

    func handle(_ request: AppControlRequest) async -> AppControlResponse {
        let args = request.arguments
        let writes = ["set_model", "set_provider", "set_setting"].contains(request.operation)
        guard !Task.isCancelled else { return .failure("cancelled", "Request cancelled.") }
        if writes {
            guard !mutating else { return .failure("busy", "Another application-setting change is in progress.") }
            mutating = true
        }
        defer { if writes { mutating = false } }
        switch request.operation {
        case "capture_screen":
            return await screenCapture.handle(args)
        // To-do is the one user-content surface here: titles the user's own
        // processes can already read in the planner file. WHY:
        // .project-docs/decisions/2026-11-03-todo-helper.md
        case "todo_add", "todo_update", "todo_list":
            let store = planner()
            do {
                let todo = try TodoRequest(request.operation, args)
                guard todo.mutates else {
                    store.refreshFromDisk()
                    guard store.canWrite else { return .failure("planner_unreadable", store.errorMessage ?? "Couldn’t read the to-do list.") }
                    var nodes = store.archive.tasks.map(\.node)
                    return .success(try todo.apply(to: &nodes, now: Date())("app"))
                }
                var expected: [TodoNode] = []
                let reply = try store.editTasks { nodes in
                    let reply = try todo.apply(to: &nodes, now: Date())
                    expected = nodes
                    return reply
                }
                // Confirm from the saved state, not from the request.
                guard store.archive.tasks.map(\.node) == expected else {
                    return .failure("unconfirmed", "The saved to-do list does not contain the change.")
                }
                return .success(reply("app"))
            } catch let failure as PlannerTodoFile.Failure { return failure.response }
            catch { return .failure("save_failed", "Couldn’t save the to-do list.") }
        case "get_state":
            guard args.isEmpty else { return invalid() }
            let features = AIFeature.activeCases.map { feature in
                AppControlValue.object(["feature": .string(feature.rawValue), "title": .string(feature.title),
                                        "mode": .string(feature.mode.rawValue), "route": routeValue(feature)])
            }
            return .success(.object([
                "controlVersion": .int(1), "bundleIdentifier": .string(identity.bundleIdentifier),
                "version": .string(identity.version), "build": .string(identity.build),
                "sourceRevision": identity.sourceRevision.map(AppControlValue.string) ?? .null,
                "googleCalendarReviewActive": .bool(googleCalendarReview()),
                "activity": activity(), "features": .array(features)
            ]))
        case "get_settings":
            guard args.isEmpty else { return invalid() }
            return .success(.object([
                "values": .object(settings),
                "acceptedValues": .object([
                    "dropMode": .array([.string("fast"), .string("smart")]),
                    "autoHideIsland": .array([.bool(true), .bool(false)]),
                    "inputLanguage": .array([.null] + AppLanguage.all.map { .string($0.code) }),
                    "outputLanguage": .array([.null] + AppLanguage.all.map { .string($0.code) })
                ])
            ]))
        case "list_models":
            guard only(args, ["feature", "query", "account", "limit"]), let feature = feature(args),
                  args["query"] == nil || args["query"]?.string != nil,
                  args["account"] == nil || args["account"]?.string != nil,
                  args["limit"] == nil || args["limit"]?.int != nil else { return invalid() }
            let limit = args["limit"]?.int ?? 30
            guard (1...100).contains(limit), (args["query"]?.string?.count ?? 0) <= 256 else { return invalid() }
            let sections = models.sections(for: feature).filter {
                args["account"] == nil || $0.account.storageID == args["account"]?.string
            }
            let matches = ModelPickerSearch.results(in: sections, query: args["query"]?.string ?? "")
            let entries = matches.prefix(limit).map { result -> AppControlValue in
                let verified: Bool
                if case .verified = result.option.state { verified = true } else { verified = false }
                return .object(["account": .string(result.account.storageID), "model": .string(result.option.model),
                                "selected": .bool(result.option.isSelected), "supported": .bool(result.isEnabled),
                                "verified": .bool(verified), "catalogRefreshFailed": .bool(result.refreshFailed)])
            }
            return .success(.object(["models": .array(entries), "total": .int(matches.count),
                                     "source": .string("appCatalogCache")]))
        case "set_model":
            guard only(args, ["feature", "account", "model", "expected"]), let feature = feature(args),
                  let id = args["account"]?.string, let account = ProviderAccount(storageID: id),
                  let model = args["model"]?.string, validID(model), args["expected"] != nil else { return invalid() }
            guard args["expected"] == routeValue(feature) else { return conflict() }
            // Same account/key visibility and feature compatibility as the picker.
            guard models.accountIsAvailableForSelection(account),
                  models.sections(for: feature).contains(where: { $0.account == account }) else {
                return .failure("not_configured", "Add this provider in API & Models before assigning a model.")
            }
            let changed = await models.select(model: model, account: account, for: feature)
            guard !Task.isCancelled else { return .failure("cancelled", "Request cancelled; read state before retrying.") }
            guard changed else {
                if args["expected"] != routeValue(feature) { return conflict() }
                return .failure("model_not_selected", "The model check failed or another check is in progress. The previous route was kept. Check API & Models for details.")
            }
            // A changed model is already Auto; an unchanged model keeps its pin,
            // matching the model picker. Provider changes have a separate tool.
            return .success(.object(["feature": .string(feature.rawValue), "route": routeValue(feature)]))
        case "list_providers":
            guard only(args, ["feature"]), let feature = feature(args),
                  let original = routing.route(for: feature), original.account == .openRouter else { return invalid() }
            await models.loadProviders(for: feature)
            guard routing.route(for: feature) == original else { return conflict() }
            guard case .loaded(let endpoints, _) = models.providerLists[original.model] else {
                return .failure("unavailable", "Could not load this model's OpenRouter providers.")
            }
            return .success(.object(["route": routeValue(feature), "providers": .array(endpoints.map {
                .object(["provider": .string($0.tag), "title": .string($0.title)])
            })]))
        case "set_provider":
            guard only(args, ["feature", "provider", "expected"]), let feature = feature(args),
                  let provider = args["provider"], provider == .null || provider.string.map(validID) == true,
                  let current = routing.route(for: feature), current.account == .openRouter,
                  args["expected"] != nil else { return invalid() }
            guard args["expected"] == routeValue(feature) else { return conflict() }
            if let tag = provider.string {
                await models.loadProviders(for: feature)
                guard !Task.isCancelled else { return .failure("cancelled", "Request cancelled.") }
                guard args["expected"] == routeValue(feature) else { return conflict() }
                guard case .loaded(let endpoints, _) = models.providerLists[current.model],
                      endpoints.contains(where: { $0.tag == tag }) else {
                    return .failure("unknown_provider", "This endpoint is not listed for the current model.")
                }
            }
            models.selectProvider(provider.string, for: feature)
            return .success(.object(["feature": .string(feature.rawValue), "route": routeValue(feature)]))
        case "set_setting":
            guard only(args, ["key", "value", "expected"]), let key = args["key"]?.string,
                  let value = args["value"], let expected = args["expected"], let current = settings[key] else { return invalid() }
            guard expected == current else { return conflict() }
            switch (key, value) {
            case ("dropMode", .string(let mode)):
                guard let mode = TranscriptionMode(rawValue: mode) else { return invalid() }
                preferences.setMode(mode)
            case ("autoHideIsland", .bool(let enabled)): idle.isEnabled = enabled
            case ("inputLanguage", .null): languages.selectedLanguage = nil
            case ("outputLanguage", .null): languages.targetLanguage = nil
            case ("inputLanguage", .string(let code)), ("outputLanguage", .string(let code)):
                guard let language = AppLanguage.all.first(where: { $0.code == code }) else { return invalid() }
                if key == "inputLanguage" { languages.selectedLanguage = language }
                else {
                    guard preferences.currentMode == .smart else {
                        return .failure("requires_smart", "Output translation requires Drop Smart. Select Smart first.")
                    }
                    languages.targetLanguage = language
                }
            default: return invalid()
            }
            return .success(.object(["key": .string(key), "value": settings[key]!]))
        default: return .failure("unknown_operation", "Unknown application-control operation.")
        }
    }

    private var settings: [String: AppControlValue] {
        ["dropMode": .string(preferences.currentMode.rawValue), "autoHideIsland": .bool(idle.isEnabled),
         "inputLanguage": languages.selectedLanguage.map { .string($0.code) } ?? .null,
         "outputLanguage": languages.targetLanguage.map { .string($0.code) } ?? .null]
    }

    private func routeValue(_ feature: AIFeature) -> AppControlValue {
        guard let route = routing.route(for: feature) else { return .null }
        return .object(["account": .string(route.account.storageID), "model": .string(route.model),
                        "provider": route.provider.map(AppControlValue.string) ?? .null])
    }
    private func feature(_ args: [String: AppControlValue]) -> AIFeature? {
        guard let feature = args["feature"]?.string.flatMap(AIFeature.init(rawValue:)), feature.isActive else { return nil }
        return feature
    }
    private func only(_ args: [String: AppControlValue], _ keys: Set<String>) -> Bool { Set(args.keys).isSubset(of: keys) }
    private func validID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256 && !text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
    }
    private func invalid() -> AppControlResponse { .failure("invalid_arguments", "Use the documented feature, setting and argument types; unknown fields are rejected.") }
    private func conflict() -> AppControlResponse { .failure("conflict", "The current value changed. Read state/settings again before deciding whether to retry.") }
}
