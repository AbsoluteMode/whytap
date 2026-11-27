import Foundation

/// What a synthetic request found out about a model. `inconclusive` means no
/// answer worth keeping (offline, a key problem, a 5xx): it is never stored.
enum ProbeOutcome: Codable, Equatable, Sendable {
    case passed
    case failed(reason: String)
    case inconclusive(reason: String)
}

/// One check is per account, model and use: the same model can behave
/// differently on another provider or for another kind of call.
struct ModelCheckKey: Hashable, Codable, Sendable {
    /// `ProviderAccount.storageID`.
    let account: String
    let model: String
    let use: ModelUse
}

/// The result of a probe, and which adapter code produced it: a newer adapter
/// (a fixed dialect) is reason to check again. Never a key or a response.
struct ModelCheckRecord: Codable, Equatable, Sendable {
    let adapterVersion: Int
    let outcome: ProbeOutcome
    let at: Date
}

/// Probe results and the model a provider refused for each feature, kept
/// across launches.
@MainActor
final class ModelCheckStore: ObservableObject {
    static let shared = ModelCheckStore()

    static let defaultsKey = "sidekey.aiRouting.modelChecks.v1"

    private struct Entry: Codable {
        let key: ModelCheckKey
        let record: ModelCheckRecord
    }

    private struct Refusal: Codable {
        let model: String
        let at: Date
    }

    private struct Persisted: Codable {
        var entries: [Entry] = []
        /// Keyed by `AIFeature.rawValue`.
        var refusals: [String: Refusal] = [:]
    }

    @Published private var state: Persisted

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           var decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            // Earlier builds' tool-use checks: nothing asks for them any more.
            // WHY: .project-docs/decisions/2026-11-27-remove-tool-probe.md
            decoded.entries.removeAll { $0.key.use == .retiredChatWithTools }
            self.state = decoded
        } else {
            self.state = Persisted()
        }
    }

    func record(for key: ModelCheckKey) -> ModelCheckRecord? {
        state.entries.first { $0.key == key }?.record
    }

    /// An `inconclusive` outcome is dropped: it says nothing about the model.
    func store(_ outcome: ProbeOutcome, for key: ModelCheckKey, adapterVersion: Int, at date: Date) {
        if case .inconclusive = outcome { return }
        var next = state
        next.entries.removeAll { $0.key == key }
        next.entries.append(Entry(key: key, record: ModelCheckRecord(adapterVersion: adapterVersion, outcome: outcome, at: date)))
        state = next
        save()
    }

    /// The model the provider turned down while the feature was running, so
    /// the next screen can say so. One per feature; the latest wins.
    func recordRefusal(feature: AIFeature, model: String, at date: Date) {
        var next = state
        next.refusals[feature.rawValue] = Refusal(model: model, at: date)
        state = next
        save()
    }

    /// The refused model worked again (a call, a passed check) or was picked
    /// again: the badge goes. A refusal of another model stays.
    func clearRefusal(feature: AIFeature, model: String) {
        guard state.refusals[feature.rawValue]?.model == model else { return }
        var next = state
        next.refusals[feature.rawValue] = nil
        state = next
        save()
    }

    func refusedModel(for feature: AIFeature) -> String? {
        state.refusals[feature.rawValue]?.model
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
