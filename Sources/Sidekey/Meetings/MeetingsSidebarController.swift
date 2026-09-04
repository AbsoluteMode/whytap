import AppKit
import Foundation
import SwiftUI
import os.log

/// Abstract source for the meetings list. The production wiring uses an
/// adapter around `MeetingsStore.list()`; the sidebar tests inject an
/// in-memory stub so the list contract can be exercised without spinning
/// up SQLite + the Application Support tree.
@MainActor
protocol MeetingsSidebarSource: AnyObject {
    /// Returns rows ordered newest-first. Errors propagate to the
    /// controller, which logs and renders an empty list — the menu bar
    /// path keeps working either way.
    func loadList() async throws -> [MeetingMetaWithLocalState]
}

/// Sink for selection events emitted by the list. `MeetingsContentController`
/// conforms to this so a row click pushes a `loadMeeting(id:)` into the viewer.
@MainActor
protocol MeetingsSidebarDelegate: AnyObject {
    func sidebarDidSelectMeeting(id: UUID)
}

/// Adapter that lets the production `MeetingsStore` actor satisfy the
/// `MeetingsSidebarSource` protocol without forcing the actor itself to
/// adopt a MainActor-isolated protocol. The actor's `list()` already
/// returns the same shape — this wrapper just forwards.
@MainActor
final class MeetingsStoreSidebarSource: MeetingsSidebarSource {
    private let store: MeetingsStore

    init(store: MeetingsStore) {
        self.store = store
    }

    func loadList() async throws -> [MeetingMetaWithLocalState] {
        try await store.list()
    }
}

/// `NSViewController` that owns the meetings list. The list itself is now a
/// native SwiftUI `MeetingListView` (grouped by date, calm macOS-Settings
/// styling) hosted in an `NSHostingView`; this controller keeps the same
/// public surface the old `NSTableView` version had — `refresh()`,
/// `selectMeeting(id:)`, `awaitLoad()`, `meetings`, `delegate` — so
/// `MeetingsContentController` (Settings + standalone) is unchanged.
@MainActor
final class MeetingsSidebarController: NSViewController {

    private let model: MeetingListModel
    weak var delegate: MeetingsSidebarDelegate?

    /// Flat newest-first list, exposed for callers that resolve a title by id.
    var meetings: [MeetingMetaWithLocalState] { model.meetings }

    /// Latest meeting id (newest-first). Kept for callers that want the most
    /// recent note without reaching into the grouped sections.
    var newestMeetingId: UUID? { model.newestMeetingId }

    /// Grouped sections the SwiftUI list renders. Exposed for tests so the
    /// bucketing contract can be asserted without touching view internals.
    var sections: [MeetingListSectionItem] { model.sections }

    init(
        source: MeetingsSidebarSource,
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.model = MeetingListModel(source: source, nowProvider: nowProvider)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MeetingsSidebarController only supports programmatic init.")
    }

    // MARK: - View lifecycle

    override func loadView() {
        let host = NSHostingView(
            rootView: MeetingListView(model: model) { [weak self] id in
                self?.handleUserSelection(id: id)
            }
        )
        host.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    // MARK: - Public API

    /// Kicks off a fresh fetch from the source. Safe to call from the
    /// menu-bar refresh path and on `newMeetingAvailable`.
    func refresh() {
        model.refresh()
    }

    /// Test seam — awaits the current load task without sleeping.
    func awaitLoad() async throws {
        try await model.awaitLoad()
    }

    /// Programmatic selection (highlight only) — does NOT notify the delegate,
    /// so callers that select and then load a meeting themselves don't get a
    /// double load. No-op rendering if the id is not in the current list.
    func selectMeeting(id: UUID) {
        model.select(id)
    }

    /// A row was tapped by the user — highlight it and notify the delegate.
    func handleUserSelection(id: UUID) {
        model.select(id)
        delegate?.sidebarDidSelectMeeting(id: id)
    }
}
