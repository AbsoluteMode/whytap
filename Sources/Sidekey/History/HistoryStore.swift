import Foundation

enum HistoryQueryMode: String, Codable, Equatable, CaseIterable {
    case text
    case voice
}

struct AgentHistoryEntry: Equatable, Identifiable {
    let id: Int64
    let createdAt: Date
    let queryText: String
    let queryMode: HistoryQueryMode
    let responseMarkdown: String
    let toolNames: [String]
}

struct DropHistoryEntry: Equatable, Identifiable {
    let id: Int64
    let createdAt: Date
    let rawTranscript: String
    let formattedText: String
    let targetApp: String?
}

/// Local-only history persistence. Both agent turns and drop pastes are
/// written here. Network is never touched — `Constraint: history is local`.
protocol HistoryStore: AnyObject {
    @discardableResult
    func insertAgentEntry(
        createdAt: Date,
        queryText: String,
        queryMode: HistoryQueryMode,
        responseMarkdown: String,
        toolNames: [String]
    ) throws -> Int64

    @discardableResult
    func insertDropEntry(
        createdAt: Date,
        rawTranscript: String,
        formattedText: String,
        targetApp: String?
    ) throws -> Int64

    func latestAgentEntries(limit: Int) throws -> [AgentHistoryEntry]
    func latestDropEntries(limit: Int) throws -> [DropHistoryEntry]
}

/// Default location used by the app at runtime. Tests pass an in-memory
/// path (":memory:") or a temporary file instead.
enum HistoryStoreLocation {
    static var defaultURL: URL {
        let fm = FileManager.default
        // `~/Library/Application Support/com.rootwise.sidekey/history.sqlite`
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.rootwise.sidekey", isDirectory: true)
            .appendingPathComponent("history.sqlite", isDirectory: false)
    }

    /// `~/Library/Application Support/com.rootwise.sidekey/history-assets/`
    /// — sidecar directory for clipboard image entries. Created lazily
    /// by `ClipboardWatcher.handleChange` on the first image insert.
    static var defaultAssetsDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.rootwise.sidekey", isDirectory: true)
            .appendingPathComponent("history-assets", isDirectory: true)
    }

    /// Creates the parent directory if missing and returns the path SQLite
    /// should open. Called by `SQLiteHistoryStore.shared()`.
    static func prepareDefaultPath() throws -> String {
        let url = defaultURL
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return url.path
    }

    /// Pre-creates the assets directory so `ClipboardWatcher` can start
    /// writing sidecar files immediately. Idempotent.
    @discardableResult
    static func prepareAssetsDirectory() throws -> URL {
        let url = defaultAssetsDirectory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
