import AppKit
import SwiftUI

/// Settings → Features → Agent → Sources: what the Agent may search when you
/// ask. Each row: name, where it came from, status with a readable reason, an
/// on/off switch, and Details (values, tools and their classes, remove).
// WHY: .project-docs/decisions/2026-11-26-agent-sources.md
@MainActor
struct AgentSourcesSection: View {
    @ObservedObject var controller: SourcesController
    @State private var adding = false
    @State private var details: SourceSheetID?

    struct SourceSheetID: Identifiable { let id: String }

    static let footnote = "The Agent searches sources only when you ask, with read-only tools. What it finds goes to your Agent model’s provider. After reading a source, the same request can only search that source again: no file edits, commands, web pages, other sources or Whytap changes."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Sources")
            MacCard {
                if controller.sources.isEmpty {
                    MacRow(title: "Add a source to search it",
                           subtitle: "GitHub, Jira, a folder, or MCP servers you already use in Claude Code, Cursor, Codex or VS Code.") {
                        MacButton(title: "Add source…", style: .primary) { adding = true }.fixedSize()
                    }
                } else {
                    ForEach(Array(controller.sources.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { MacRowSeparator() }
                        SourceRow(record: record, status: controller.statuses[record.id] ?? .off,
                                  toggle: { on in Task { await controller.setEnabled(on, id: record.id) } },
                                  open: { details = SourceSheetID(id: record.id) })
                    }
                    MacRowSeparator()
                    HStack {
                        Spacer()
                        MacButton(title: "Add source…") { adding = true }.fixedSize()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            Text(Self.footnote)
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.top, 7)
            if let error = controller.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.red)
                    .padding(.horizontal, 6).padding(.top, 4)
            }
        }
        .task { controller.loadIfNeeded() }
        .sheet(isPresented: $adding) {
            AddSourceSheet(controller: controller) { adding = false }
        }
        .sheet(item: $details) { item in
            SourceDetailSheet(controller: controller, id: item.id) { details = nil }
        }
    }
}

@MainActor
struct SourceRow: View {
    let record: SourceRecord
    let status: SourceStatus
    let toggle: (Bool) -> Void
    let open: () -> Void

    static func symbol(_ kind: SourceKind) -> String {
        switch kind {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .jira: return "checklist"
        case .folder: return "folder"
        case .imported, .custom: return "server.rack"
        }
    }

    static func tone(_ status: SourceStatus) -> MacPill.Tone {
        switch status {
        case .ready: return .green
        case .warning, .needsValue: return .orange
        case .failed: return .red
        case .connecting: return .blue
        case .off: return .neutral
        }
    }

    var body: some View {
        MacRow(title: record.name, subtitle: subtitle) {
            Image(systemName: Self.symbol(record.kind))
                .font(.system(size: 14))
                .foregroundStyle(MacSettingsTheme.text2)
                .frame(width: 22)
                .accessibilityHidden(true)
        } trailing: {
            HStack(spacing: 10) {
                if case .connecting = status { ProgressView().controlSize(.small) }
                MacButton(title: needsAttention ? "Fix…" : "Details…", style: needsAttention ? .tinted : .default, action: open)
                    .fixedSize()
                    .accessibilityLabel("\(record.name) details")
                MacSwitch(isOn: Binding(get: { record.enabled }, set: toggle), size: .compact,
                          label: "Search \(record.name) when I ask")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.name), \(status.text)")
    }

    private var needsAttention: Bool {
        switch status {
        case .failed, .needsValue, .warning: return true
        default: return false
        }
    }

    private var subtitle: String {
        let origin = record.importedFrom.map { "From \($0) · " } ?? ""
        return origin + status.text
    }
}

/// One source: its values (secrets stay in Keychain; only presence is shown),
/// its tools with their classes, and removal.
@MainActor
struct SourceDetailSheet: View {
    @ObservedObject var controller: SourcesController
    let id: String
    let close: () -> Void
    @State private var values: [String: String] = [:]
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let record = controller.record(id) {
                header(record)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !record.secretNames.isEmpty { valuesCard(record) }
                        toolsCard(record)
                    }
                }
                .frame(minHeight: 260, maxHeight: 460)
                footer(record)
            } else {
                Text("This source was removed.").foregroundStyle(MacSettingsTheme.text2)
                HStack { Spacer(); MacButton(title: "Done", style: .primary, action: close) }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(MacSettingsTheme.bgContent)
    }

    private func header(_ record: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(MacSettingsTheme.text)
            Text(record.summary)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(MacSettingsTheme.text2)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if let status = controller.statuses[id] {
                MacPill(text: status.text, tone: SourceRow.tone(status), showsDot: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func valuesCard(_ record: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Values", trailing: "Kept in Keychain")
            MacCard {
                ForEach(Array(record.secretNames.enumerated()), id: \.element) { index, name in
                    if index > 0 { MacRowSeparator() }
                    let stored = controller.hasSecret(name, id: id)
                    MacRow(title: SourcesController.displayName(name), subtitle: stored ? "Saved" : "Missing") {
                        HStack(spacing: 8) {
                            MacField(placeholder: stored ? "Replace…" : "Paste the value",
                                     text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), isSecure: true)
                                .frame(width: 200)
                                .accessibilityLabel("Value for \(SourcesController.displayName(name))")
                            MacButton(title: "Save", isEnabled: !(values[name] ?? "").isEmpty) {
                                let value = values[name] ?? ""
                                values[name] = nil
                                Task { await controller.setSecret(value, name: name, id: id) }
                            }.fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func toolsCard(_ record: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Tools", trailing: "\(record.readTools.count) of \(record.tools.count) usable by the Agent")
            if record.pendingReviewCount > 0 {
                let count = record.pendingReviewCount
                MacBanner(tone: .warn, systemImage: "exclamationmark.triangle",
                          title: "\(count) tool\(count == 1 ? "" : "s") waiting for you",
                          text: record.kind.trustedOnConnect || record.tools.contains(where: { record.decisions[$0.name]?.needsReview == false && record.decisions[$0.name]?.toolClass == .read })
                              ? "The server changed how these tools are described. They stay unavailable until you approve them."
                              : "Whytap can’t check what this server’s tools really do. Look at the classes below; the Agent uses its Read tools only after you approve.")
                    .padding(.bottom, 8)
                HStack {
                    Spacer()
                    MacButton(title: "Approve tools", style: .tinted) { Task { await controller.approveChanges(id: id) } }.fixedSize()
                }
                .padding(.bottom, 8)
            }
            MacCard {
                if record.tools.isEmpty {
                    MacRow(title: "No tools yet", subtitle: "Press Check again once the source connects.") { EmptyView() }
                }
                ForEach(Array(record.tools.enumerated()), id: \.element.name) { index, tool in
                    if index > 0 { MacRowSeparator() }
                    let decision = record.decisions[tool.name]
                    MacRow(title: tool.title ?? tool.name,
                           subtitle: (decision?.needsReview == true ? "Waiting for approval · " : "")
                               + String(tool.description.replacingOccurrences(of: "\n", with: " ").prefix(140))) {
                        MacPopup(items: [SourceToolClass.read, .outward, .destructive].map { .init(value: $0, label: $0.label) },
                                 selection: Binding(get: { decision?.toolClass ?? .outward },
                                                    set: { controller.setClass($0, tool: tool.name, id: id) }),
                                 minWidth: 130, maxWidth: 150)
                            .accessibilityLabel("Class of \(tool.name)")
                    }
                }
            }
            Text("Only Read tools are offered to the Agent. Tools that change or delete things are never called in this version.")
                .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text3)
                .padding(.horizontal, 6).padding(.top, 7)
        }
    }

    private func footer(_ record: SourceRecord) -> some View {
        HStack {
            MacButton(title: "Remove…", style: .danger) { confirmRemove = true }.fixedSize()
                .confirmationDialog("Remove \(record.name)?", isPresented: $confirmRemove) {
                    Button("Remove", role: .destructive) {
                        Task { await controller.remove(id) }
                        close()
                    }
                } message: {
                    Text("Its saved values are deleted from Keychain. Nothing changes in \(record.importedFrom ?? "the service").")
                }
            Spacer()
            MacButton(title: "Check again") { Task { await controller.check(id) } }.fixedSize()
            MacButton(title: "Done", style: .primary, action: close).fixedSize()
                .keyboardShortcut(.defaultAction)
        }
    }
}
