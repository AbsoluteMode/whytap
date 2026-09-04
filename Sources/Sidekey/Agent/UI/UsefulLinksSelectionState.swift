import Combine
import Foundation

/// Selection state for a single visible actions block (`useful.actions`,
/// generalised from the link-only `useful.links`). Drives the rolling-hint
/// chip (which sits to the left of the selected row) and dispatches the
/// ↑/↓/←/→ family to `UsefulLinksHotkeyController`.
///
/// Owned by the response panel content view for the lifetime of one visible
/// actions block — when the block appears, the panel calls `apply(items:)`;
/// when the panel closes or the block vanishes (next turn), the panel calls
/// `apply(items: [])` to clear selection and let the hotkey controller
/// unregister.
///
/// The type name is intentionally kept (`UsefulLinksSelectionState`) so the
/// wide call-site surface stays untouched; only the element type widened from
/// `UsefulLink` to `ActionItem`. `apply(links:)` / `links` / `selectedLink`
/// remain as a thin link-only bridge for callers that still speak links.
@MainActor
final class UsefulLinksSelectionState: ObservableObject {
    @Published private(set) var items: [ActionItem] = []
    /// 0-based row index into `items`. Defaults to 0 — the first item is the
    /// highest-priority entry per the SSE contract, so the chip starts at the
    /// top of the list each time a fresh block appears.
    @Published private(set) var currentIndex: Int = 0

    /// Click hooks the host (AgentController) installs so a chip click runs the
    /// SAME insert/open path as the hotkeys (the controller owns the focus
    /// snapshot + executor). `nil` until wired — a click is then a safe no-op
    /// for insert; chip open still falls back to NSWorkspace on `openTarget`.
    var onInsertItem: ((ActionItem) -> Void)?
    var onOpenItem: ((ActionItem) -> Void)?

    init(items: [ActionItem] = []) {
        self.apply(items: items)
    }

    /// Replaces the current item list and snaps the index back to 0. Used both
    /// on "block appeared" (with the new items) and on "block vanished" (with
    /// an empty array) — the empty case sweeps the chip off-screen and lets the
    /// hotkey controller unregister.
    func apply(items: [ActionItem]) {
        self.items = items
        self.currentIndex = 0
    }

    /// Advances selection by one row, stopping at the last item. No-op on empty
    /// state and on a single-item block. Spec calls this "stop, no wrap" — ↓
    /// past the bottom must not teleport the chip back to the top.
    func selectNext() {
        guard !items.isEmpty else { return }
        let next = currentIndex + 1
        if next >= items.count { return }
        currentIndex = next
    }

    /// Moves selection back one row, stopping at the first item. No-op on empty
    /// state. Repeated ↑ at the top stays anchored to row 0.
    func selectPrevious() {
        guard !items.isEmpty else { return }
        let previous = currentIndex - 1
        if previous < 0 { return }
        currentIndex = previous
    }

    /// The currently selected item, or `nil` when the block is empty. The chip
    /// view reads this as its "render / don't render" signal and the hotkey
    /// controller reads `items.count` to decide whether to register the up/down
    /// hotkeys at all.
    var selectedItem: ActionItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// Whether the currently selected item exposes the `open` action. `false`
    /// when empty or when the selected item is a `copy` (insert-only). The
    /// hotkey controller and rolling hint use this to drop the Open affordance
    /// for copy items.
    var selectedItemSupportsOpen: Bool {
        selectedItem?.availableActions.contains(.open) ?? false
    }

    // MARK: - Legacy link bridge

    /// Folds a legacy `UsefulLink` list into `.link` items. Kept for the
    /// link-only sync/render path until those callers move to `apply(items:)`.
    func apply(links: [UsefulLink]) {
        apply(items: links.map { .link(url: $0.url, description: $0.description, provider: $0.provider) })
    }

    /// The link subset of `items`, surfaced as `UsefulLink`s. Drops non-link
    /// items (paths / copy). Used by the link-only render path that hasn't yet
    /// migrated to rendering typed items.
    var links: [UsefulLink] {
        items.compactMap { item in
            guard case let .link(url, description, provider) = item else { return nil }
            return UsefulLink(url: url, description: description, provider: provider)
        }
    }

    /// The currently selected item as a `UsefulLink`, or `nil` when empty or
    /// when the selected item is not a link.
    var selectedLink: UsefulLink? {
        guard case let .link(url, description, provider)? = selectedItem else { return nil }
        return UsefulLink(url: url, description: description, provider: provider)
    }
}
