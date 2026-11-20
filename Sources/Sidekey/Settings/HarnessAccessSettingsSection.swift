import SwiftUI

/// Settings -> Agents: the coding tools the user answered Whytap's access
/// question for. The switch is the same answer, changed here: off refuses the
/// tool's next request at once, on allows it without another prompt.
// WHY: .project-docs/decisions/2026-11-20-harness-access.md
@MainActor
struct HarnessAccessSettingsSection: View {
    @ObservedObject var store: HarnessAccessStore

    static let title = "Coding tools"

    static func subtitle(_ decision: HarnessDecision) -> String {
        switch decision {
        case .allow: return "Reads your meetings and changes settings through the Whytap plugin."
        case .deny: return "Not allowed to use Whytap."
        }
    }

    /// Shown while the Keychain has not taken the latest answer.
    static let unsavedNotice = "Whytap couldn’t save this to the Keychain yet. Turning access off still holds after a restart. It will be saved when the Keychain is available."

    /// By name, so a changed answer does not move its row.
    static func rows(_ grants: [HarnessGrant]) -> [HarnessGrant] {
        grants.sorted { ($0.name, $0.identity.signingIdentifier) < ($1.name, $1.identity.signingIdentifier) }
    }

    var body: some View {
        let rows = Self.rows(store.grants)
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: Self.title)
                    MacCard {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, grant in
                            if index > 0 { MacRowSeparator() }
                            MacRow(title: grant.name, subtitle: Self.subtitle(grant.decision)) {
                                MacSwitch(isOn: Binding(
                                    get: { grant.decision == .allow },
                                    set: { allowed in
                                        store.record(allowed ? .allow : .deny,
                                                     for: HarnessClient(identity: grant.identity, name: grant.name),
                                                     at: Date())
                                    }), label: "Let \(grant.name) use Whytap")
                            }
                        }
                    }
                    if store.hasUnsavedAnswers {
                        Text(Self.unsavedNotice)
                            .font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                }
            }
        }
        .onAppear { store.loadIfNeeded() }
    }
}
