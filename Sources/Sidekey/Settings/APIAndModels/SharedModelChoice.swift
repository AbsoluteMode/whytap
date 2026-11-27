import Foundation

/// The two shared rows at the top of Models: one speech model for every
/// speech feature, one LLM for every text feature. A shared row is not a
/// stored setting: it is read from the per-feature routes, and picking in it
/// writes those routes. Advanced keeps the per-feature menus.
// WHY: .project-docs/decisions/2026-11-22-shared-model-rows.md
enum SharedModelKind: String, CaseIterable, Identifiable, Sendable {
    case speech
    case llm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: return "Speech"
        case .llm: return "LLM"
        }
    }

    /// Every active feature belongs to exactly one kind (Subtitles have their
    /// own Audio translate slot and are no feature route).
    var features: [AIFeature] {
        switch self {
        case .speech: return [.dropFast, .dropSmart, .agentVoice, .voiceSearch, .meetings]
        case .llm: return [.dropSmartCleanup, .meetingNotes, .translation]
        }
    }

    /// The feature whose picker the shared row opens: what every model of
    /// this kind has to serve (live speech; text without tools).
    var pickerFeature: AIFeature {
        switch self {
        case .speech: return .dropFast
        case .llm: return .dropSmartCleanup
        }
    }

    static func kind(of feature: AIFeature) -> SharedModelKind? {
        allCases.first { $0.features.contains(feature) }
    }
}

/// What a shared choice would put on one feature.
struct SharedPlanItem: Equatable {
    let feature: AIFeature
    /// `nil`: the choice cannot serve this feature, see `skipReason`.
    let route: FeatureRoute?
    let skipReason: String?
}

/// A shared row as the Models card shows it.
struct SharedModelRow: Equatable, Identifiable {
    let kind: SharedModelKind
    /// The model most features follow; `nil` when nothing is set or the
    /// features disagree (`isMixed`).
    let choice: FeatureRoute?
    let choiceTitle: String?
    let isMixed: Bool
    /// Set to something other than what the shared choice gives them.
    let custom: [AIFeature]
    /// No route yet.
    let unset: [AIFeature]
    /// Features the shared choice cannot serve, with the reason.
    let uncovered: [SharedPlanItem]
    var isChecking = false
    /// Why the last shared pick did not apply everywhere.
    var notes: [String] = []

    var id: SharedModelKind { kind }

    /// "Anthropic · claude-sonnet-5-5 · 1 custom", "Mixed · 3 custom", "Choose a model".
    var label: String {
        var parts: [String] = []
        if isMixed {
            parts.append("Mixed")
        } else if let choice {
            parts.append("\(choiceTitle ?? choice.account.kind.displayName) · \(choice.model)")
        } else {
            return "Choose a model"
        }
        if !custom.isEmpty { parts.append("\(custom.count) custom") }
        if !unset.isEmpty { parts.append("\(unset.count) not set") }
        return parts.joined(separator: " · ")
    }

    /// The orange setup contour: no model, or features still without one.
    var needsSetup: Bool { (choice == nil && !isMixed) || !unset.isEmpty }
}

/// Pure planning over what each feature's picker offers, so whatever the
/// pickers allow (key status, catalog capabilities, a server's speech/LLM
/// split, a typed name) also decides what a shared choice reaches. It asks
/// one model at a time (`ModelStatusResolver.pickerReach`) and never builds
/// a picker list: Settings recomputes the rows on every preference change.
@MainActor
struct SharedModelPlanner {
    /// What `feature`'s picker does with `model` of `account` (memoized by the caller).
    let reach: (String, ProviderAccount, AIFeature) -> PickerReach
    let route: (AIFeature) -> FeatureRoute?

    /// The route a shared `choice` gives `feature`: the chosen model where the
    /// feature's picker offers it; for recorded speech (Meetings) the
    /// provider's recorded counterpart (ElevenLabs Scribe v3 for v3 Live,
    /// Soniox's async model); otherwise nothing, with the reason. A model the
    /// feature's picker rules out is never taken, typed or not (a server set
    /// to Language models gives its LLM to no speech feature). An LLM is
    /// never swapped for another model: a feature it cannot serve keeps its
    /// own route.
    func plan(_ choice: FeatureRoute, for feature: AIFeature) -> SharedPlanItem {
        let provider = choice.account.kind.displayName
        func taken(_ model: String) -> SharedPlanItem {
            SharedPlanItem(feature: feature, route: FeatureRoute(account: choice.account, model: model), skipReason: nil)
        }
        let direct = reach(choice.model, choice.account, feature)
        switch direct {
        case .noSection:
            return SharedPlanItem(feature: feature, route: nil, skipReason: "\(provider) can't serve \(feature.title)")
        case .offered:
            return taken(choice.model)
        case .ruledOut, .typed, .notListed:
            break
        }
        if feature.mode == .recorded, let counterpart = Self.recordedCounterpart(of: choice),
           counterpart != choice.model, reach(counterpart, choice.account, feature) == .offered {
            return taken(counterpart)
        }
        switch direct {
        case .ruledOut(let reason):
            return SharedPlanItem(feature: feature, route: nil, skipReason: reason)
        case .typed:
            return taken(choice.model)
        default:
            let what = feature.mode == .recorded ? "no recorded-audio model" : "doesn't offer \(choice.model) here"
            return SharedPlanItem(feature: feature, route: nil, skipReason: "\(provider) has \(what)")
        }
    }

    func plan(_ choice: FeatureRoute, kind: SharedModelKind) -> [SharedPlanItem] {
        kind.features.map { plan(choice, for: $0) }
    }

    /// The recorded-audio model that goes with a live speech pick.
    static func recordedCounterpart(of choice: FeatureRoute) -> String? {
        switch choice.account.kind {
        case .elevenLabs: return ModelRegistry.elevenLabsRecordedModel(for: choice.model)
        case .soniox, .deepgram, .onDevice:
            return ModelRegistry.recommended(for: .meetings, kind: choice.account.kind)
        case .openRouter, .openAI, .anthropic, .openAICompatible:
            return nil
        }
    }

    /// Whether `feature`'s saved route is what `choice` gives it. A pinned
    /// OpenRouter provider is a detail of the same model, not a custom choice.
    func follows(_ feature: AIFeature, _ choice: FeatureRoute) -> Bool {
        guard let current = route(feature), let planned = plan(choice, for: feature).route else { return false }
        return current.account == planned.account && current.model == planned.model
    }

    /// The shared row read from the saved routes. Candidates are the models of
    /// the features that take the picked model as it is (not Meetings, whose
    /// model is a counterpart); the one most features follow wins, the picker
    /// feature breaks a tie. When no candidate is followed by more than half
    /// of the features that have a model, the row is Mixed.
    func row(kind: SharedModelKind, title: (ProviderAccount) -> String) -> SharedModelRow {
        let features = kind.features
        let unset = features.filter { route($0) == nil }
        let routed = features.count - unset.count
        var candidates: [FeatureRoute] = []
        let leaders = [kind.pickerFeature] + features.filter { $0 != kind.pickerFeature && $0.mode != .recorded }
        for feature in leaders {
            guard let current = route(feature) else { continue }
            let base = FeatureRoute(account: current.account, model: current.model)
            if !candidates.contains(base) { candidates.append(base) }
        }
        var best: (choice: FeatureRoute, followers: Int)?
        for candidate in candidates {
            let followers = features.filter { follows($0, candidate) }.count
            if followers > (best?.followers ?? 0) { best = (candidate, followers) }
        }
        guard routed > 0 else {
            return SharedModelRow(kind: kind, choice: nil, choiceTitle: nil, isMixed: false,
                                  custom: [], unset: unset, uncovered: [])
        }
        guard let best, best.followers * 2 > routed else {
            let custom = features.filter { route($0) != nil }
            return SharedModelRow(kind: kind, choice: nil, choiceTitle: nil, isMixed: true,
                                  custom: custom, unset: unset, uncovered: [])
        }
        let plan = self.plan(best.choice, kind: kind)
        let custom = features.filter { route($0) != nil && !follows($0, best.choice) }
        let uncovered = plan.filter { $0.route == nil && route($0.feature) == nil }
        return SharedModelRow(kind: kind, choice: best.choice, choiceTitle: title(best.choice.account), isMixed: false,
                              custom: custom, unset: unset, uncovered: uncovered)
    }
}
