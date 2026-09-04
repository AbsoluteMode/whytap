import SwiftUI
import os.log

// MARK: - Row / section view models

/// A single meeting row as the SwiftUI list renders it. Decoupled from
/// `MeetingMetaWithLocalState` so the view layer stays trivial and testable.
struct MeetingListRowItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// Right-aligned secondary label: time for recent buckets, date for older.
    let dateLabel: String
    let progressStatus: MeetingProgressStatus
}

/// A date-bucketed section: an uppercase header + its meeting rows.
struct MeetingListSectionItem: Identifiable, Equatable {
    let id: String
    let header: String
    let rows: [MeetingListRowItem]
}

// MARK: - Model

/// Loads meetings from the injected source, buckets them via
/// `MeetingsDateGrouping`, and publishes the result for `MeetingListView`.
/// Replaces the old `NSTableView` data plumbing — same source protocol,
/// native SwiftUI rendering.
@MainActor
final class MeetingListModel: ObservableObject {

    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "list")

    @Published private(set) var sections: [MeetingListSectionItem] = []
    @Published var selectedId: UUID?

    /// Flat newest-first list, exposed for callers that need the raw metas
    /// (e.g. resolving a title by id). Mirrors the old controller's `meetings`.
    private(set) var meetings: [MeetingMetaWithLocalState] = []

    private let source: MeetingsSidebarSource
    private let nowProvider: () -> Date
    private var loadTask: Task<Void, Error>?

    /// Time-of-day for Today / Yesterday rows (the header already names the day).
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "Jun 3" for older buckets, where time-only would drop the day.
    private let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    init(
        source: MeetingsSidebarSource,
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.source = source
        self.nowProvider = nowProvider
    }

    var newestMeetingId: UUID? {
        meetings.max { $0.startedAt < $1.startedAt }?.id
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.source.loadList()
                if Task.isCancelled { return }
                self.apply(fetched)
            } catch {
                os_log(
                    "meeting list load failed: %{public}@",
                    log: Self.log, type: .error,
                    String(describing: error)
                )
                self.apply([])
            }
        }
    }

    /// Test seam — await the in-flight load without sleeping.
    func awaitLoad() async throws {
        if let task = loadTask { _ = try await task.value }
    }

    func select(_ id: UUID?) {
        selectedId = id
    }

    private func apply(_ fetched: [MeetingMetaWithLocalState]) {
        meetings = fetched
        // Diagnostic: proves the refresh actually reached the @Published
        // mutation (vs. a cancelled/abandoned load Task). Pairs with the
        // store's "store list returned (count:)" line so a future
        // "notes didn't appear" report can be traced end-to-end.
        os_log(
            "meeting list applied (count: %{public}d)",
            log: Self.log, type: .info,
            fetched.count
        )
        let grouped = MeetingsDateGrouping.groupAndSort(fetched, now: nowProvider())
        sections = grouped.map { section in
            let header = MeetingsDateGrouping.headerLabel(for: section.bucket)
            let rows = section.meetings.map { meta -> MeetingListRowItem in
                let title = (meta.title?.isEmpty == false) ? meta.title! : "Untitled"
                return MeetingListRowItem(
                    id: meta.id,
                    title: title,
                    dateLabel: label(for: meta.startedAt, bucket: section.bucket),
                    progressStatus: meta.progressStatus
                )
            }
            return MeetingListSectionItem(id: header, header: header, rows: rows)
        }
    }

    private func label(for date: Date, bucket: MeetingsDateBucket) -> String {
        switch bucket {
        case .today, .yesterday:
            return timeFormatter.string(from: date)
        case .thisWeek, .month:
            return dayMonthFormatter.string(from: date)
        }
    }
}

// MARK: - View

/// Native meeting list for the Notes surface. Grouped by date, with a calm
/// macOS-Settings look: uppercase section headers, rounded hover/selection
/// fills, title + secondary date. Replaces the old `NSTableView` sidebar.
@MainActor
struct MeetingListView: View {
    @ObservedObject var model: MeetingListModel
    let onSelect: (UUID) -> Void

    var body: some View {
        Group {
            if model.sections.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            MeetingListRow(
                                item: row,
                                isSelected: row.id == model.selectedId,
                                onTap: { onSelect(row.id) }
                            )
                        }
                    } header: {
                        sectionHeader(section.header)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MacSettingsTheme.text2)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(MacSettingsTheme.text2)
            Text("No meetings yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingListRow: View {
    let item: MeetingListRowItem
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isSelected ? Color.white : MacSettingsTheme.text2)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : MacSettingsTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.progressStatus != .ready {
                    Text(item.progressStatus.displayLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? Color.white.opacity(0.78)
                                : (item.progressStatus == .failed ? Color.red : MacSettingsTheme.text2)
                        )
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(item.dateLabel)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : MacSettingsTheme.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: item.progressStatus == .ready ? 36 : 44)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? MacSettingsTheme.selection : (hovering ? MacSettingsTheme.hover : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}
