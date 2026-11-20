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
    enum Page: Equatable { case overview, history }
    enum LoadState: Equatable { case loading, loaded, failed }

    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "list")

    @Published private(set) var sections: [MeetingListSectionItem] = []
    @Published private(set) var recentRows: [MeetingListRowItem] = []
    @Published private(set) var page: Page = .overview
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var focusRequest: UInt64 = 0
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
        loadState = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.source.loadList()
                if Task.isCancelled { return }
                self.apply(fetched)
                self.loadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                os_log(
                    "meeting list load failed",
                    log: Self.log, type: .error
                )
                // Keep the last readable list on a transient failure.
                self.loadState = .failed
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

    func showOverview() { page = .overview }
    func showHistory() { page = .history }
    func restoreFocus() { focusRequest &+= 1 }

    private func apply(_ fetched: [MeetingMetaWithLocalState]) {
        meetings = fetched.sorted {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.startedAt > $1.startedAt
        }
        let now = nowProvider()
        // WHY: docs/DESIGN.md — the overview is a bounded entry point; History
        // retains the complete list and the existing date groups.
        recentRows = meetings.prefix(5).map { meta in
            MeetingListRowItem(
                id: meta.id,
                title: (meta.title?.isEmpty == false) ? meta.title! : "Untitled",
                dateLabel: recentLabel(for: meta.startedAt, now: now),
                progressStatus: meta.progressStatus
            )
        }
        // Diagnostic: proves the refresh actually reached the @Published
        // mutation (vs. a cancelled/abandoned load Task). Pairs with the
        // store's "store list returned (count:)" line so a future
        // "notes didn't appear" report can be traced end-to-end.
        os_log(
            "meeting list applied (count: %{public}d)",
            log: Self.log, type: .info,
            fetched.count
        )
        let grouped = MeetingsDateGrouping.groupAndSort(meetings, now: now)
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

    private func recentLabel(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today · \(timeFormatter.string(from: date))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday · \(timeFormatter.string(from: date))"
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: date) == calendar.component(.year, from: now)
                ? "MMMd" : "yMMMd"
        )
        return formatter.string(from: date)
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


// MARK: - Overview and history

/// One shared source and selection for the overview and the full archive.
@MainActor
struct MeetingListView: View {
    @ObservedObject var model: MeetingListModel
    let onSelect: (UUID) -> Void
    var onDelete: ((UUID) -> Void)? = nil

    private enum Focus: Hashable { case navigation, meeting(UUID) }
    @FocusState private var focus: Focus?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.loadState == .failed {
                        loadFailure
                    }
                    if model.meetings.isEmpty {
                        emptyState
                    } else if model.page == .overview {
                        recentMeetings
                    } else {
                        history
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.focusRequest) { _, _ in
            if let id = model.selectedId,
               model.page == .history || model.recentRows.contains(where: { $0.id == id }) {
                focus = .meeting(id)
            } else {
                focus = .navigation
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.page == .history {
                Button {
                    model.showOverview()
                    focus = .navigation
                } label: {
                    Label("Meetings", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text)
                .focused($focus, equals: .navigation)
                .accessibilityIdentifier("meetings.history.back")
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.page == .overview ? "Meetings" : "History")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.page == .overview ? "Your latest meeting notes" : "All meeting notes")
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                }
                Spacer(minLength: 0)
                if model.page == .overview {
                    Button {
                        model.showHistory()
                        focus = .navigation
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(MacSettingsTheme.text)
                            .background(MacSettingsTheme.controlBg,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .focused($focus, equals: .navigation)
                    .accessibilityIdentifier("meetings.overview.history")
                }
            }
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recent meetings")
            rows(model.recentRows)
        }
    }

    private var history: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(model.sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(section.header)
                    rows(section.rows)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MacSettingsTheme.text)
            .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ items: [MeetingListRowItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { row in
                MeetingListRow(
                    item: row,
                    isSelected: row.id == model.selectedId,
                    onTap: { onSelect(row.id) }
                )
                .focused($focus, equals: .meeting(row.id))
                .contextMenu {
                    if let onDelete, row.progressStatus.canBeDeleted {
                        Button("Delete…", role: .destructive) { onDelete(row.id) }
                    }
                }
                if row.id != items.last?.id {
                    Rectangle()
                        .fill(MacSettingsTheme.sep)
                        .frame(height: 1)
                        .padding(.leading, 40)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(MacSettingsTheme.bgCard,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var loadFailure: some View {
        HStack(spacing: 12) {
            Label("Meetings couldn’t be loaded.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text)
            Spacer(minLength: 0)
            MacButton(title: "Retry") { model.refresh() }
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.loadState == .loading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading meetings…")
            } else if model.loadState == .loaded {
                Image(systemName: "note.text")
                    .font(.system(size: 24))
                    .accessibilityHidden(true)
                Text("No meetings yet")
                    .font(.system(size: 13, weight: .medium))
                Text("Your notes will appear here after your first recording.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(MacSettingsTheme.text2)
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct MeetingListRow: View {
    let item: MeetingListRowItem
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovering = false
    private var secondaryText: Color {
        isSelected || hovering ? MacSettingsTheme.text : MacSettingsTheme.text2
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 11) {
                Image(systemName: "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(secondaryText)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.progressStatus != .ready {
                        Text(item.progressStatus.displayLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(item.progressStatus == .failed && !isSelected && !hovering
                                ? MacSettingsTheme.red : secondaryText)
                    }
                }
                Spacer(minLength: 8)
                Text(item.dateLabel)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? MacSettingsTheme.selection : (hovering ? MacSettingsTheme.hover : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
        .accessibilityIdentifier("meetings.row.\(item.id.uuidString)")
    }
}
