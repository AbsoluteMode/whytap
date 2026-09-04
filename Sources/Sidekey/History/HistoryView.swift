import AppKit
import SwiftUI

/// Top-level history window content. Two tabs: agent turns and drop pastes.
/// Both lists sort by `created_at` DESC; tapping a row expands inline to show
/// the full body. No search/filter in MVP.
@MainActor
struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        TabView {
            AgentHistoryList(entries: viewModel.agentEntries)
                .tabItem { Text("Agent") }

            DropHistoryList(entries: viewModel.dropEntries)
                .tabItem { Text("Drop") }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { viewModel.refresh() }
    }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var agentEntries: [AgentHistoryEntry] = []
    @Published private(set) var dropEntries: [DropHistoryEntry] = []

    private let store: any HistoryStore
    private let pageSize: Int

    init(store: any HistoryStore, pageSize: Int = 200) {
        self.store = store
        self.pageSize = pageSize
    }

    func refresh() {
        agentEntries = (try? store.latestAgentEntries(limit: pageSize)) ?? []
        dropEntries = (try? store.latestDropEntries(limit: pageSize)) ?? []
    }
}

private let historyTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

private func formatTimestamp(_ date: Date) -> String {
    historyTimestampFormatter.string(from: date)
}

private struct AgentHistoryList: View {
    let entries: [AgentHistoryEntry]
    @State private var expandedID: Int64?

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(entries) { entry in
                    AgentHistoryRow(
                        entry: entry,
                        isExpanded: expandedID == entry.id,
                        onToggle: {
                            expandedID = expandedID == entry.id ? nil : entry.id
                        }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No agent history yet")
                .font(.headline)
            Text("Trigger an agent turn and it will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentHistoryRow: View {
    let entry: AgentHistoryEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(truncated(entry.queryText, max: 90))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundColor(.primary)
                        HStack(spacing: 6) {
                            Text(formatTimestamp(entry.createdAt))
                            Text("•")
                            Text(entry.queryMode.rawValue)
                            if !entry.toolNames.isEmpty {
                                Text("•")
                                Text(entry.toolNames.joined(separator: ", "))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    expandedBlock(title: "Query", body: entry.queryText, copyable: entry.queryText)
                    expandedBlock(title: "Response", body: entry.responseMarkdown, copyable: entry.responseMarkdown)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DropHistoryList: View {
    let entries: [DropHistoryEntry]
    @State private var expandedID: Int64?

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(entries) { entry in
                    DropHistoryRow(
                        entry: entry,
                        isExpanded: expandedID == entry.id,
                        onToggle: {
                            expandedID = expandedID == entry.id ? nil : entry.id
                        }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No drop history yet")
                .font(.headline)
            Text("Trigger a drop paste and it will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropHistoryRow: View {
    let entry: DropHistoryEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(truncated(entry.formattedText, max: 90))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundColor(.primary)
                        HStack(spacing: 6) {
                            Text(formatTimestamp(entry.createdAt))
                            if let app = entry.targetApp {
                                Text("•")
                                Text(app)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(alignment: .top, spacing: 12) {
                    expandedBlock(title: "Raw", body: entry.rawTranscript, copyable: entry.rawTranscript)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    expandedBlock(title: "Formatted", body: entry.formattedText, copyable: entry.formattedText)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private func expandedBlock(title: String, body: String, copyable: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            Button("Copy") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(copyable, forType: .string)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        Text(body.isEmpty ? "(empty)" : body)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(4)
    }
}

private func truncated(_ text: String, max: Int) -> String {
    let normalized = text.replacingOccurrences(of: "\n", with: " ")
    guard normalized.count > max else { return normalized }
    let end = normalized.index(normalized.startIndex, offsetBy: max)
    return normalized[..<end] + "…"
}
