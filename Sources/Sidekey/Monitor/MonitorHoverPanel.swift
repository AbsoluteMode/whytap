import SwiftUI

/// The hover hosts the same dashboard/server content and polling store as the
/// standalone Monitor. No window activation or collector implementation here.
@MainActor
struct MonitorHoverPanel: View {
    @StateObject private var store: MonitorStore
    @State private var selectedID: String?
    @State private var deleting = false
    let onBack: () -> Void
    private let deletionPrompts: MonitorDashboardDeletionPrompts

    init(store: MonitorStore? = nil,
         deletionPrompts: MonitorDashboardDeletionPrompts = .system,
         onBack: @escaping () -> Void) {
        self._store = StateObject(wrappedValue: store ?? MonitorStore())
        self.deletionPrompts = deletionPrompts
        self.onBack = onBack
    }

    /// Where the panel goes after a delete: an open board that is gone
    /// returns to the picker; any other selection stays.
    static func selection(afterDeleting deletedID: String, outcome: MonitorDashboardDeletion.Outcome,
                          selectedID: String?) -> String? {
        outcome.removesDashboard && selectedID == deletedID ? nil : selectedID
    }

    /// WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
    private func delete(_ dashboard: MonitorDashboard) {
        guard !deleting else { return }
        deleting = true
        Task { @MainActor in
            let outcome = await MonitorDashboardDeletion(store: store, prompts: deletionPrompts).delete(dashboard)
            selectedID = Self.selection(afterDeleting: dashboard.id, outcome: outcome, selectedID: selectedID)
            deleting = false
        }
    }

    private var selectedDashboard: MonitorDashboard? {
        store.dashboards.first { $0.id == selectedID }
    }

    private var title: String {
        if selectedID == "server-status" { return "Server status" }
        return selectedDashboard?.title ?? "Monitor"
    }

    var body: some View {
        VStack(spacing: 10) {
            // Equal side slots center the title without overlapping navigation.
            HStack(spacing: 8) {
                IslandHoverBackButton(destination: "monitor:\(selectedID ?? "picker")",
                    accessibilityLabel: selectedID == nil ? "Back to tools" : "Back to dashboards") {
                    if selectedID == nil { onBack() }
                    else { selectedID = nil }
                }
                .frame(width: 88, alignment: .leading)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                Group {
                    if selectedID != nil {
                        Button { store.requestRefresh() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Refresh dashboard")
                    } else {
                        Color.clear.frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 88, alignment: .trailing)
            }
            .frame(height: 26)

            Rectangle().fill(IslandInk.color.opacity(0.12)).frame(height: 1)

            if let error = store.dashboardError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                if selectedID == nil {
                    dashboardPicker
                } else if selectedID == "server-status" {
                    MonitorServersView(store: store, allowsOpeningFolder: false, showsHeader: false,
                                       compactPresentation: true)
                } else if let dashboard = selectedDashboard {
                    MonitorCustomDashboardView(dashboard: dashboard, showsTitle: false,
                                               compactPresentation: true)
                } else {
                    Text("This dashboard is no longer available. Choose another dashboard.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { store.start() }
        .onDisappear { store.stop() }
    }

    /// The scroller sits in the panel's right margin, beside the cards
    /// instead of over their edge.
    static let scrollerGutter: CGFloat = 10

    private var dashboardPicker: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 8) {
                dashboardRow(id: "server-status", title: "Server status",
                             image: "server.rack", subtitle: "CPU, memory and GPU readings", onDelete: nil)
                ForEach(store.dashboards) { dashboard in
                    dashboardRow(id: dashboard.id, title: dashboard.title,
                                 image: dashboard.systemImage, subtitle: dashboard.subtitle,
                                 onDelete: { delete(dashboard) })
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, Self.scrollerGutter)
        }
        .padding(.trailing, -Self.scrollerGutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A whole row opens its board; custom boards carry a separate × that
    /// asks before deleting. No context menu: the island has no right-click
    /// interactions. WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
    private func dashboardRow(id: String, title: String, image: String, subtitle: String,
                              onDelete: (() -> Void)?) -> some View {
        MonitorDashboardRowButton(title: title, action: { selectedID = id }) {
            HStack(spacing: 8) {
                Image(systemName: image)
                    .font(.system(size: 18))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            // Room for the × so long titles never run under it.
            .padding(.trailing, onDelete == nil ? 0 : MonitorDashboardDeleteButton.size)
        }
        .overlay(alignment: .trailing) {
            if let onDelete {
                MonitorDashboardDeleteButton(title: title, action: onDelete)
                    .disabled(deleting)
                    .padding(.trailing, 6)
            }
        }
    }
}

/// How the picker's controls look in each state. Pure, so tests pin every
/// state: hover, press and focus only show while the control is enabled, so
/// a × disabled under the pointer looks like a disabled ×, not a hovered one.
struct MonitorPickerControlAppearance: Equatable {
    var fill: Double
    var focusRing: Double
    var symbol: Double

    static func deleteCross(hovered: Bool, pressed: Bool, focused: Bool, enabled: Bool) -> Self {
        guard enabled else { return Self(fill: 0, focusRing: 0, symbol: 0.25) }
        return Self(fill: pressed ? 0.2 : hovered ? 0.12 : 0,
                    focusRing: focused ? 0.85 : 0,
                    symbol: pressed || hovered ? 0.95 : 0.5)
    }

    static func row(hovered: Bool, pressed: Bool, focused: Bool, enabled: Bool) -> Self {
        guard enabled else { return Self(fill: 0.03, focusRing: 0, symbol: 0.42) }
        return Self(fill: pressed ? 0.14 : hovered ? 0.09 : 0.05,
                    focusRing: focused ? 0.85 : 0,
                    symbol: 1)
    }
}

/// A dashboard row: the whole card opens the board and shows hover, press and
/// keyboard focus itself, since it has no chevron.
struct MonitorDashboardRowButton<Label: View>: View {
    let title: String
    /// Starts as if the pointer were over it; offscreen render tests only.
    var initiallyHovered = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(MonitorDashboardRowStyle(focused: focused, initiallyHovered: initiallyHovered))
            .focused($focused)
            .accessibilityLabel(title)
    }
}

private struct MonitorDashboardRowStyle: ButtonStyle {
    let focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.islandHoverNativePressed) private var nativePressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Bool

    init(focused: Bool, initiallyHovered: Bool) {
        self.focused = focused
        self._hovered = State(initialValue: initiallyHovered)
    }

    func makeBody(configuration: Configuration) -> some View {
        let look = MonitorPickerControlAppearance.row(hovered: hovered,
            pressed: configuration.isPressed || nativePressed, focused: focused, enabled: enabled)
        let shape = RoundedRectangle(cornerRadius: 12)
        return configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(look.symbol)
            .background(IslandInk.color.opacity(look.fill), in: shape)
            .overlay(shape.strokeBorder(IslandInk.color.opacity(0.14), lineWidth: 0.7))
            .overlay(shape.strokeBorder(IslandInk.color.opacity(look.focusRing), lineWidth: 1.5)
                .allowsHitTesting(false))
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: look)
    }
}

/// The × on a custom dashboard row.
struct MonitorDashboardDeleteButton: View {
    static let size: CGFloat = 24

    let title: String
    /// Starts as if the pointer were over it; offscreen render tests only.
    var initiallyHovered = false
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: Self.size, height: Self.size)
        }
        .buttonStyle(MonitorDashboardDeleteStyle(focused: focused, initiallyHovered: initiallyHovered))
        .focused($focused)
        .help("Delete dashboard")
        .accessibilityLabel("Delete \(title)")
    }
}

private struct MonitorDashboardDeleteStyle: ButtonStyle {
    let focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.islandHoverNativePressed) private var nativePressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Bool

    init(focused: Bool, initiallyHovered: Bool) {
        self.focused = focused
        self._hovered = State(initialValue: initiallyHovered)
    }

    func makeBody(configuration: Configuration) -> some View {
        let look = MonitorPickerControlAppearance.deleteCross(hovered: hovered,
            pressed: configuration.isPressed || nativePressed, focused: focused, enabled: enabled)
        return configuration.label
            .foregroundStyle(IslandInk.color.opacity(look.symbol))
            .background(Circle().fill(IslandInk.color.opacity(look.fill)))
            .overlay(Circle().strokeBorder(IslandInk.color.opacity(look.focusRing), lineWidth: 1.5)
                .allowsHitTesting(false))
            .contentShape(Circle())
            // The pointer is still tracked while disabled; the look ignores it.
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: look)
    }
}
