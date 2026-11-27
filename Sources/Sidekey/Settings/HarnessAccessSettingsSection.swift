import AppKit
import SwiftUI

/// Settings -> Integrations -> Coding tools: Claude Code and Codex with one
/// switch each (`CodingToolsAccess`), then any other app the user answered
/// Whytap's access question for. A switch is the same answer, changed here:
/// off refuses the tool's next request at once, on allows it without another
/// prompt.
// WHY: .project-docs/decisions/2026-11-20-harness-access.md
@MainActor
struct HarnessAccessSettingsSection: View {
    @ObservedObject var tools: CodingToolsAccess

    static let title = "Coding tools"

    static func subtitle(_ decision: HarnessDecision, identity: HarnessIdentity? = nil) -> String {
        // An app on the live dictation list can do one thing, and its row says
        // exactly that. WHY: .project-docs/decisions/2026-11-24-drop-live-for-dictation-clients.md
        if let identity, let name = DropLiveFeed.allowedName(for: identity) {
            switch decision {
            case .allow: return "Shows your words in its own field while you dictate into \(name). Nothing you dictate into other apps, no meetings, settings or Case keys."
            case .deny: return "Does not get your dictation; Whytap's island shows it as usual."
            }
        }
        switch decision {
        case .allow: return "Reads your meetings, adds Vocab and Filler words and changes settings through the Whytap plugin."
        case .deny: return "Not allowed to use Whytap."
        }
    }

    /// Shown while the Keychain has not taken the latest answer.
    static let unsavedNotice = "Whytap couldn’t save this to the Keychain yet. A tool you turned off will not get access back without asking you. It will be saved when the Keychain is available."
    /// Shown when a No could not be written anywhere.
    static let unverifiedNotice = "Whytap couldn’t save this change. Access is off until Whytap quits and may come back after a restart. Turn it off again later."

    static func notice(unsaved: Bool, unverified: Bool) -> String? {
        if unverified { return unverifiedNotice }
        return unsaved ? unsavedNotice : nil
    }

    /// By name, so a changed answer does not move its row.
    static func rows(_ grants: [HarnessGrant]) -> [HarnessGrant] {
        grants.sorted { ($0.name, $0.identity.signingIdentifier) < ($1.name, $1.identity.signingIdentifier) }
    }

    /// Answers for apps other than the offered coding tools (a live
    /// dictation client), by name.
    static func otherRows(_ grants: [HarnessGrant]) -> [HarnessGrant] {
        let offered = Set(CodingToolsAccess.tools.compactMap { CodingToolsAccess.harnessClient($0)?.identity })
        return rows(grants).filter { !offered.contains($0.identity) }
    }

    var body: some View {
        let others = Self.otherRows(tools.store?.grants ?? [])
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: Self.title)
            MacCard {
                // Always shown: one switch connects the tool (its MCP entry
                // and access); a tool not on this Mac is grey.
                // WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
                ForEach(Array(CodingToolsAccess.tools.enumerated()), id: \.element) { index, tool in
                    if index > 0 { MacRowSeparator() }
                    MacRow(title: tool.displayName, subtitle: tools.subtitle(tool)) {
                        MacSwitch(isOn: Binding(
                            get: { tools.isConnected(tool) },
                            set: { on in Task { await tools.set(tool, on: on) } }),
                                  isEnabled: tools.canSwitch(tool),
                                  label: "Connect \(tool.displayName) to Whytap")
                    }
                }
                if let store = tools.store {
                    ForEach(others) { grant in
                        MacRowSeparator()
                        MacRow(title: grant.name, subtitle: Self.subtitle(grant.decision, identity: grant.identity)) {
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
            }
            if let store = tools.store,
               let notice = Self.notice(unsaved: store.hasUnsavedAnswers, unverified: store.revocationUnverified) {
                Text(notice)
                    .font(.system(size: 11)).foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .task { await tools.refresh() }
        // A tool installed meanwhile shows once Whytap is back in front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await tools.refresh() }
        }
    }
}
