import Foundation

/// Per-turn agent overrides chosen in Settings. A `nil` field means "send no
/// flag" (the CLI uses its own default). Codex controls are validated against
/// its model registry; absent capabilities leave controls to Codex.
/// Provider neutral: Claude ignores `serviceTier`.
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
