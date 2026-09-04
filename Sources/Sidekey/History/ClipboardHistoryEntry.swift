import Foundation

/// Identifies the kind of clipboard content captured by `ClipboardWatcher`.
/// Stored in `clipboard_entries.kind` as a raw string so a future schema
/// migration can add new kinds without rewriting existing rows.
enum ClipboardEntryKind: String, Codable, Equatable {
    case text
    case image
    case fileURLs = "file_urls"
}

/// Image attachment carried by a `.image` `ClipboardHistoryEntry`. The
/// full image lives in a sidecar file under `<app support>/history/assets/`;
/// `thumbnailData` is the 64×64 PNG kept inside the SQLite row for fast
/// strip-card rendering without re-reading the sidecar.
struct ClipboardImagePayload: Equatable, Sendable {
    let uuid: UUID
    /// File extension WITHOUT the leading dot (`"png"`, `"jpg"`, `"heic"`).
    let fileExtension: String
    /// Bytes of the 64×64 thumbnail PNG, in JSON-encoded base64 inside SQLite.
    let thumbnailData: Data

    /// Resolved sidecar URL for the full-size image given an assets root.
    /// Pure path math; the file may or may not actually exist (eviction
    /// deletes it).
    func sidecarURL(in assetsDirectory: URL) -> URL {
        assetsDirectory.appendingPathComponent("\(uuid.uuidString).\(fileExtension)")
    }
}

/// Payload variants persisted in a `ClipboardHistoryEntry`. Mirrors the
/// three kinds the watcher classifies. File URLs are stored as absolute
/// paths to keep the schema lossless even when the user empties their
/// volume — the strip surface can decide what to render if the path is
/// gone.
enum ClipboardHistoryEntryPayload: Equatable, Sendable {
    case text(String)
    case image(ClipboardImagePayload)
    case fileURLs([URL])
}

/// One row in `clipboard_entries`. Sorted newest-first by
/// `SQLiteHistoryStore.latestClipboardEntries`.
struct ClipboardHistoryEntry: Equatable, Identifiable {
    let id: Int64
    let createdAt: Date
    let payload: ClipboardHistoryEntryPayload
}
