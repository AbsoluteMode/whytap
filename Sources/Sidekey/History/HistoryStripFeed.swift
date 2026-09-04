import Foundation

/// One logical history entry to render as a card inside the bottom
/// strip. Polymorphic — the strip view dispatches on the case to pick
/// the right card layout (text body, image thumbnail, file URL chips).
enum HistoryStripCard: Identifiable, Equatable, Sendable {
    case agent(AgentCard)
    case drop(DropCard)
    case clipboard(ClipboardCard)

    var id: String {
        switch self {
        case .agent(let c): return "agent-\(c.id)"
        case .drop(let c): return "drop-\(c.id)"
        case .clipboard(let c): return "clipboard-\(c.id)"
        }
    }

    var createdAt: Date {
        switch self {
        case .agent(let c): return c.createdAt
        case .drop(let c): return c.createdAt
        case .clipboard(let c): return c.createdAt
        }
    }

    struct AgentCard: Equatable, Sendable {
        let id: Int64
        let createdAt: Date
        let title: String?
        let responseMarkdown: String
        let links: [URL]
    }

    struct DropCard: Equatable, Sendable {
        let id: Int64
        let createdAt: Date
        let formattedText: String
        let targetApp: String?
    }

    struct ClipboardCard: Equatable, Sendable {
        let id: Int64
        let createdAt: Date
        let payload: ClipboardHistoryEntryPayload
    }
}

/// Read-only adapter over `SQLiteHistoryStore` that produces per-mode
/// card lists for the strip. UI calls `cards(for:)` whenever the strip
/// opens or the mode switches.
///
/// `nonisolated` because every call goes through the store's own
/// dispatch queue — there is no main-thread mutation here, only reads.
///
/// ROO-208 iter 2: the per-mode cap is fixed at `Self.uiFeedCap` = 10.
/// The deck-with-peek carousel inside `HistoryStripView` cannot render
/// more than a handful of cards usefully, and capping here keeps the
/// store query small while keeping older rows on disk. Tests can
/// override the cap via the designated initializer.
final class HistoryStripFeed: Sendable {
    /// Default UI-feed cap. The SQLite store still retains older rows
    /// (capped only by the watcher's retention policy) — this is a
    /// pure UI slice so the deck stays interactive.
    static let uiFeedCap: Int = 10

    private let store: SQLiteHistoryStore
    private let maxAgentEntries: Int
    private let maxDropEntries: Int
    private let maxClipboardEntries: Int

    init(
        store: SQLiteHistoryStore,
        maxAgentEntries: Int = HistoryStripFeed.uiFeedCap,
        maxDropEntries: Int = HistoryStripFeed.uiFeedCap,
        maxClipboardEntries: Int = HistoryStripFeed.uiFeedCap
    ) {
        self.store = store
        self.maxAgentEntries = maxAgentEntries
        self.maxDropEntries = maxDropEntries
        self.maxClipboardEntries = maxClipboardEntries
    }

    /// Returns the cards for the given mode, newest-first. The strip
    /// renders them as a deck-with-peek carousel where the front card
    /// is the newest entry and older cards stack behind with progressive
    /// offset, opacity, and scale.
    func cards(for mode: HistoryStripMode) -> [HistoryStripCard] {
        switch mode {
        case .agent:
            return agentCards()
        case .drop:
            return dropCards()
        case .clipboard:
            return clipboardCards()
        }
    }

    private func agentCards() -> [HistoryStripCard] {
        // Pull a slightly larger window from the store than the UI cap
        // because some rows are filtered out below (`.pending` /
        // `.streaming`). Without the headroom, a session full of
        // pending turns could leave us short of `maxAgentEntries`
        // completed cards even though older completed rows exist.
        let queryLimit = max(maxAgentEntries, maxAgentEntries * 2)
        let rows = (try? store.latestChatRows(limit: queryLimit)) ?? []
        return rows
            // Show only completed turns. Pending / streaming turns would
            // render as half-baked cards; error turns can still be useful
            // because the response_markdown is the user-facing error
            // message — surface them so the user can copy/retry.
            .filter { $0.status == .done || $0.status == .error }
            .prefix(maxAgentEntries)
            .map { row in
                HistoryStripCard.agent(.init(
                    id: row.id,
                    createdAt: row.createdAt,
                    title: row.title,
                    responseMarkdown: row.responseMarkdown,
                    links: AgentResponseLinks.extract(from: row.responseMarkdown)
                ))
            }
    }

    private func dropCards() -> [HistoryStripCard] {
        let rows = (try? store.latestDropEntries(limit: maxDropEntries)) ?? []
        return rows.map { row in
            HistoryStripCard.drop(.init(
                id: row.id,
                createdAt: row.createdAt,
                formattedText: row.formattedText,
                targetApp: row.targetApp
            ))
        }
    }

    private func clipboardCards() -> [HistoryStripCard] {
        let rows = (try? store.latestClipboardEntries(limit: maxClipboardEntries)) ?? []
        return rows.map { row in
            HistoryStripCard.clipboard(.init(
                id: row.id,
                createdAt: row.createdAt,
                payload: row.payload
            ))
        }
    }
}
