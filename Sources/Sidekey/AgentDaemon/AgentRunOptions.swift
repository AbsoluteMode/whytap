import Foundation

/// Per-turn agent overrides chosen in Settings. A `nil` field means "send no
/// flag" (the CLI uses its own default) — in practice only `serviceTier` and
/// the bare `AgentRunOptions()` path: `AgentSettingsStore.options(for:)`
/// always resolves `effort`. Provider neutral: Claude ignores `serviceTier`.
struct AgentRunOptions: Equatable {
    var model: String?
    var effort: String?
    var serviceTier: String?

    init(model: String? = nil, effort: String? = nil, serviceTier: String? = nil) {
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
    }
}
