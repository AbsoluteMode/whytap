import SwiftUI

/// Settings -> Features -> Monitor: what Monitor does, its shortcut, the
/// dashboards it lists now, and Copy prompt, which hands a coding agent the
/// snapshot contract and this Mac's paths to build a new one. Settings only
/// reads the dashboard files: it never polls servers.
// WHY: .project-docs/decisions/2026-11-24-hover-notify-monitor-screens.md
@MainActor
struct MonitorFeatureView: View {
    @ObservedObject var selection: SettingsWindowSelection
    @ObservedObject private var store: MonitorStore
    @StateObject private var shortcut: FeatureShortcutEditor
    private let environment: FeaturesEnvironment
    private let now: () -> Date

    init(selection: SettingsWindowSelection, environment: FeaturesEnvironment,
         now: @escaping () -> Date = Date.init) {
        self.selection = selection
        self.environment = environment
        self.store = environment.monitor
        self.now = now
        _shortcut = StateObject(wrappedValue: FeatureShortcutEditor(hotkey: .tool(.monitor),
                                                                    preferences: environment.hotkeys))
    }

    static let about = "Dashboards in the island: numbers from your servers or anything else you want to watch. "
        + "Your coding agent writes a collector that keeps a dashboard file up to date; "
        + "Whytap only shows it and never runs anything from it."

    static let promptText = "Copy the prompt, paste it into your coding agent and say what you want to watch. "
        + "It writes a collector that keeps a dashboard file up to date, and the dashboard appears in the list."

    private var isEmpty: Bool { store.dashboards.isEmpty && !store.serverStatusListed }

    var body: some View {
        let info = FeatureCatalog.info(for: .monitor)
        FeatureScreenScaffold {
            FeatureScreenHeader(info: info, about: Self.about) {
                selection.shownFeature = nil
            }
            FeatureVideoStrip(info: info)
            shortcutGroup
            if isEmpty {
                promptCard
                dashboards
            } else {
                dashboards
                promptCard
            }
            Text("To delete a dashboard, open Monitor in the island and click × on its row. "
                 + "Whytap never stops or deletes a collector: turn it off yourself if it should stop running.")
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            while !Task.isCancelled {
                store.reloadFiles()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
        .onDisappear { shortcut.cancel() }
    }

    private var shortcutGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Shortcut")
            MacCard {
                FeatureShortcutRow(editor: shortcut, detail: "Opens Monitor in the island with your dashboards.")
                MacRowSeparator()
                MacRow(title: "Monitor in the island", subtitle: "Pick a dashboard to see its numbers.") {
                    MacButton(title: "Open") { environment.openHoverPanel(.monitor) }
                        .fixedSize()
                        .accessibilityLabel("Open Monitor in the island")
                }
            }
        }
    }

    private var dashboards: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.dashboardError {
                MacBanner(tone: .warn, systemImage: "exclamationmark.triangle", text: error)
            }
            VStack(alignment: .leading, spacing: 0) {
                MacGroupTitle(title: "Dashboards", trailing: isEmpty ? nil : Self.countText(rows.count))
                // One row per dashboard (or that there is none): data, not
                // settings Lil Bro leads to.
                MacCard {
                    if isEmpty {
                        MacRow(title: "No dashboards yet",
                               subtitle: "Custom dashboards appear when a collector writes them. Server status "
                                   + "(CPU, RAM, load and GPU) appears once your servers are set up.") { EmptyView() }
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { MacRowSeparator() }
                            MacRow(title: row.title, subtitle: row.subtitle) {
                                Image(systemName: row.systemImage)
                                    .font(.system(size: 13))
                                    .foregroundStyle(MacSettingsTheme.text2)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                            } trailing: {
                                Text(row.state)
                                    .font(.system(size: 12))
                                    .foregroundStyle(MacSettingsTheme.text2)
                            }
                        }
                    }
                }
                .lilBroItems()
            }
        }
    }

    private var promptCard: some View {
        CodingAgentPromptCard(title: "Build a dashboard", text: Self.promptText,
                              prompt: CodingAgentPrompt.monitor(root: store.root),
                              copy: environment.copyText)
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let systemImage: String
        let state: String
    }

    /// Server status first when it is set up, then the custom dashboards in
    /// the order Monitor lists them, each with how fresh it is.
    var rows: [Row] {
        Self.rows(dashboards: store.dashboards, serverStatusListed: store.serverStatusListed,
                  serverError: store.serverError, now: now())
    }

    static func rows(dashboards: [MonitorDashboard], serverStatusListed: Bool, serverError: String?,
                     now: Date) -> [Row] {
        var rows: [Row] = []
        if serverStatusListed {
            rows.append(Row(id: MonitorStore.serverStatusID, title: "Server status",
                            subtitle: serverError ?? "CPU, RAM, load and GPU of your servers.",
                            systemImage: "server.rack", state: serverError == nil ? "Built in" : "Needs a fix"))
        }
        rows += dashboards.map { dashboard in
            Row(id: dashboard.id, title: dashboard.title,
                subtitle: dashboard.subtitle.isEmpty ? nil : dashboard.subtitle,
                systemImage: dashboard.systemImage, state: stateText(dashboard.freshness(at: now)))
        }
        return rows
    }

    static func stateText(_ freshness: MonitorFreshness) -> String {
        switch freshness {
        case .live: return "Up to date"
        case .stale: return "Not updated lately"
        case .unknown: return "No update time"
        }
    }

    static func countText(_ count: Int) -> String {
        count == 1 ? "1 dashboard" : "\(count) dashboards"
    }
}
