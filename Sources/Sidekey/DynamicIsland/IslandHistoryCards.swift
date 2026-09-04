import Foundation

/// Loads hover-History cards OFF the main thread.
///
/// The hover panel's SwiftUI `body` must never read the history store
/// synchronously: `SQLiteHistoryStore` serialises every read on a private
/// queue (`queue.sync`), so a `body`-time fetch blocks the main thread on
/// disk I/O. While a track plays the music equalizer re-renders the island
/// ~30×/s, which turned that single read into ~30 blocking SQLite reads per
/// second — the island-lag bug. This hop runs the fetch on a detached task
/// so the read happens off-main; the caller stores the result in `@State`
/// and the body only reads the cache.
///
/// WHY: docs/decisions/2026-06-24-island-history-off-main.md
enum IslandHistoryCards {
    /// Run `fetch` off the main thread and return its cards. `fetch` is the
    /// synchronous, queue-serialised store read (`HistoryStripFeed.cards`).
    static func load(
        mode: HistoryStripMode,
        using fetch: @escaping @Sendable (HistoryStripMode) -> [HistoryStripCard]
    ) async -> [HistoryStripCard] {
        await Task.detached(priority: .userInitiated) { fetch(mode) }.value
    }
}
