import AppKit
import Charts
import SwiftUI

@MainActor
final class MonitorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MonitorWindowController()
    private let store: MonitorStore

    init(store: MonitorStore? = nil) {
        let store = store ?? MonitorStore()
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Monitor"
        window.minSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        SidekeyWindowChrome.configureHoverOverlayPolicy(window)
        SidekeyWindowChrome.configure(window)
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(rootView: MonitorWindowView(store: store))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        store.start()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            SidekeyWindowChrome.centerOnMainScreen(window)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            SidekeyWindowChrome.centerOnMainScreen(window)
            SidekeyWindowChrome.centerOnMainScreenAfterNextLayout(window)
        }
    }

    func windowWillClose(_ notification: Notification) { store.stop() }
}

private struct MonitorWindowView: View {
    @ObservedObject var store: MonitorStore
    @State private var selectedID: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("DASHBOARDS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 12)
                if store.serverStatusListed {
                    dashboardButton(id: MonitorStore.serverStatusID, title: "Server status")
                }
                ForEach(store.dashboards) { dashboard in
                    dashboardButton(id: dashboard.id, title: dashboard.title)
                }
                Spacer()
                Button("Open dashboard folder") {
                    NSWorkspace.shared.open(store.dashboardsDirectory)
                }
                .buttonStyle(.link)
                .font(.caption)
                Text("Your agent can add dashboards here. Files stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 196)
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.3))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let error = store.dashboardError {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(16)
                }
                if selectedID == MonitorStore.serverStatusID, store.serverStatusListed {
                    MonitorServersView(store: store)
                } else if let dashboard = store.dashboards.first(where: { $0.id == selectedID }) {
                    MonitorCustomDashboardView(dashboard: dashboard)
                } else {
                    VStack(spacing: 12) {
                        let empty = MonitorHoverPanel.pickerIsEmpty(
                            serverStatusListed: store.serverStatusListed, dashboardCount: store.dashboards.count)
                        Text(empty ? MonitorHoverPanel.emptyTitle : "Choose a dashboard")
                            .font(.title2.weight(.semibold))
                        Text(empty ? MonitorHoverPanel.emptyText
                                   : "Pick one on the left or ask your agent to add another.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func dashboardButton(id: String, title: String) -> some View {
        Button { selectedID = id } label: {
            Text(title).font(.body.weight(selectedID == id ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(selectedID == id ? Color.accentColor.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct MonitorServersView: View {
    @ObservedObject var store: MonitorStore
    var allowsOpeningFolder = true
    var showsHeader = true
    var compactPresentation = false
    private var groups: [String] { Array(Set(store.readings.map { $0.server.group })).sorted() }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: compactPresentation ? 12 : 18) {
                    if showsHeader {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Server status").font(.title2.weight(.semibold))
                                Text("Read-only SSH metrics · refresh every \(Int(store.refreshSeconds))s while open")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Refresh") { store.requestRefresh() }
                        }
                    }
                    if let error = store.serverError {
                        Text(error).font(compactPresentation ? .caption : .body).foregroundStyle(.orange)
                    }
                    if store.readings.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No servers connected").font(.headline)
                            Text("Ask your agent to add servers.json to the Monitor folder using existing SSH aliases or credential references. Passwords do not belong in dashboard files.")
                                .font(compactPresentation ? .system(size: 12) : .body)
                                .foregroundStyle(.secondary)
                            if allowsOpeningFolder {
                                Button("Open Monitor folder") { NSWorkspace.shared.open(store.root) }
                            } else {
                                Text(store.root.appendingPathComponent("servers.json").path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(compactPresentation ? 12 : 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(groups, id: \.self) { group in
                        Text(group).font(.headline)
                        ForEach(store.readings.filter { $0.server.group == group }) { reading in
                            MonitorServerCard(reading: reading, now: context.date,
                                              staleAfter: max(45, store.refreshSeconds * 3),
                                              compactPresentation: compactPresentation)
                        }
                    }
                }
                .padding(compactPresentation ? 0 : 22)
            }
        }
    }
}

private struct MonitorServerCard: View {
    let reading: MonitorServerReading
    let now: Date
    let staleAfter: Double
    var compactPresentation = false
    private var status: String { reading.status(at: now, staleAfter: staleAfter) }

    var body: some View {
        VStack(alignment: .leading, spacing: compactPresentation ? 10 : 14) {
            HStack(alignment: compactPresentation ? .top : .center, spacing: compactPresentation ? 8 : nil) {
                Text(reading.server.name)
                    .font(compactPresentation ? .system(size: 12, weight: .semibold) : .headline)
                    .lineLimit(compactPresentation ? 2 : nil)
                    .layoutPriority(compactPresentation ? 1 : 0)
                Spacer()
                if reading.refreshing { ProgressView().controlSize(.small) }
                Text(status).font(.caption.weight(.semibold))
                    .foregroundStyle(status == "Live" ? .green : .orange)
                    .fixedSize(horizontal: compactPresentation, vertical: false)
            }
            if let metrics = reading.metrics {
                if compactPresentation {
                    VStack(spacing: 6) {
                        compactStat("CPU", String(format: "%.1f%%", metrics.cpuPercent))
                        compactStat("RAM", "\(gib(metrics.memoryUsedBytes)) / \(gib(metrics.memoryTotalBytes)) GiB")
                        compactStat("Load (1 min)", String(format: "%.2f", metrics.load1))
                    }
                } else {
                    HStack(spacing: 24) {
                        stat("CPU", String(format: "%.1f%%", metrics.cpuPercent))
                        stat("RAM", "\(gib(metrics.memoryUsedBytes)) / \(gib(metrics.memoryTotalBytes)) GiB")
                        stat("Load (1 min)", String(format: "%.2f", metrics.load1))
                    }
                }
                ProgressView(value: metrics.memoryUsedBytes / metrics.memoryTotalBytes)
                    .tint(.accentColor).accessibilityLabel("Memory usage")
                ForEach(metrics.gpus, id: \.index) { gpu in
                    if compactPresentation {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(gpu.name).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            compactStat("GPU \(gpu.index)", String(format: "%.0f%%", gpu.utilizationPercent))
                            compactStat("VRAM", String(format: "%.1f / %.1f GiB", gpu.memoryUsedMiB / 1024,
                                                       gpu.memoryTotalMiB / 1024))
                        }
                    } else {
                        HStack {
                            stat("GPU \(gpu.index) · \(gpu.name)", String(format: "%.0f%%", gpu.utilizationPercent))
                            Spacer()
                            stat("VRAM", String(format: "%.1f / %.1f GiB", gpu.memoryUsedMiB / 1024,
                                                 gpu.memoryTotalMiB / 1024))
                        }
                    }
                }
                if metrics.gpus.isEmpty {
                    Text(metrics.gpuState == "unavailable" ? "GPU telemetry unavailable" : "NVIDIA GPU telemetry is not installed or supported")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = reading.observedAt {
                    HStack(spacing: 4) {
                        Text(status == "Stale" ? "Last successful reading" : "Updated")
                        Text(date, style: .relative)
                        Text("ago")
                    }.font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(reading.refreshing ? "Connecting…" : "Metrics could not be fetched. Check SSH access, VPN and local collector tools.")
                    .font(compactPresentation ? .system(size: 12) : .callout).foregroundStyle(.secondary)
            }
            if reading.refreshFailed, reading.metrics != nil {
                Text("Refresh failed. Values above are from the last successful reading.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(compactPresentation ? 12 : 18)
        .frame(maxWidth: compactPresentation ? .infinity : nil, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced).weight(.semibold))
        }
    }

    private func compactStat(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gib(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1_073_741_824) }
}

struct MonitorCustomDashboardView: View {
    let dashboard: MonitorDashboard
    var showsTitle = true
    var compactPresentation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showsTitle { Text(dashboard.title).font(.title2.weight(.semibold)) }
                    if !dashboard.subtitle.isEmpty {
                        Text(dashboard.subtitle).font(compactPresentation ? .system(size: 12) : .body)
                            .foregroundStyle(.secondary)
                    }
                    Text(dashboard.freshness(at: context.date).rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(dashboard.freshness(at: context.date) == .live ? .green : .orange)
                    if let date = dashboard.updatedAt {
                        Text("Snapshot: \(date.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: compactPresentation ? [GridItem(.flexible(minimum: 0))]
                              : [GridItem(.adaptive(minimum: 230))], spacing: 12) {
                        ForEach(dashboard.widgets) { widget in
                            MonitorWidgetView(widget: widget, compactPresentation: compactPresentation)
                        }
                    }
                }
                .padding(compactPresentation ? 0 : 22)
            }
        }
    }
}

private struct MonitorWidgetView: View {
    let widget: MonitorWidget
    var compactPresentation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(widget.title).font(compactPresentation ? .system(size: 12, weight: .semibold) : .headline)
            switch widget.kind {
            case .metric:
                if compactPresentation {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(widget.value ?? "—").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                        if let unit = widget.unit {
                            Text(unit).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(widget.value ?? "—").font(.title.weight(.semibold)).monospacedDigit()
                        if let unit = widget.unit { Text(unit).foregroundStyle(.secondary) }
                    }
                }
            case .progress:
                if let value = widget.value { Text(value).font(.title3).monospacedDigit() }
                if let progress = widget.progress { ProgressView(value: progress) }
                else { Text("No reading").foregroundStyle(.secondary) }
            case .status:
                Text(widget.value ?? widget.status?.capitalized ?? "Unknown")
                    .foregroundStyle(statusColor)
            case .text:
                Text(widget.value ?? "").textSelection(.enabled)
            case .chart:
                if let points = widget.points, !points.isEmpty {
                    Chart(Array(points.enumerated()), id: \.offset) { item in
                        LineMark(x: .value("Label", item.element.label), y: .value("Value", item.element.value))
                    }.frame(height: 130)
                } else { Text("No readings").foregroundStyle(.secondary) }
            }
            if let detail = widget.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(compactPresentation ? 12 : 16)
        .frame(maxWidth: .infinity, minHeight: compactPresentation ? 0 : 110, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch widget.status?.lowercased() {
        case "healthy", "ok", "success", "completed": return .green
        case "warning", "stale": return .orange
        case "error", "failed", "critical": return .red
        default: return .secondary
        }
    }
}
