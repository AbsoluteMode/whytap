import AppKit
import Foundation

/// Shared pasteboard preserve / restore helpers. Used by `AutoPasteEngine`
/// (drop pipeline) and `SelectionFallback` (Cmd+C dance for selection
/// capture in apps that do not expose `kAXSelectedTextAttribute`).
///
/// Both subsystems follow the same recipe:
///
/// ```
///   let snap = Pasteboard.snapshot()
///   // mutate NSPasteboard.general …
///   Pasteboard.restore(snap)
/// ```
///
/// The snapshot copies every `NSPasteboardItem` and every readable
/// (type, bytes) pair, so non-string payloads (images, file URLs, RTF,
/// custom UTIs) survive the round trip. An empty snapshot causes
/// `restore` to just clear the pasteboard.
///
/// The parameterless `snapshot()` / `restore(_:)` always target
/// `NSPasteboard.general`; tests that need to exercise the snapshot /
/// restore round-trip in isolation can call `snapshot(of:)` /
/// `restore(_:into:)` against a unique private `NSPasteboard` so they
/// don't pollute the developer's real clipboard.
enum Pasteboard {
    /// Snapshot `NSPasteboard.general` into raw bytes per type so it can
    /// be rehydrated later via `restore(_:)`. Empty pasteboard returns an
    /// empty `PasteboardSnapshot.items`.
    static func snapshot() -> PasteboardSnapshot {
        snapshot(of: NSPasteboard.general)
    }

    /// Snapshot the given pasteboard. Used by tests that drive the
    /// snapshot / restore round-trip against an isolated named
    /// pasteboard so `NSPasteboard.general` is never mutated. Production
    /// callers use the parameterless `snapshot()`.
    static func snapshot(of pb: NSPasteboard) -> PasteboardSnapshot {
        var captured: [[String: Data]] = []
        guard let items = pb.pasteboardItems else {
            return PasteboardSnapshot(items: [])
        }
        for item in items {
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            if !entry.isEmpty {
                captured.append(entry)
            }
        }
        return PasteboardSnapshot(items: captured)
    }

    /// Rewrite `NSPasteboard.general` from a previously captured snapshot.
    /// Each entry becomes one `NSPasteboardItem` with every recorded
    /// (type, bytes) pair. Empty snapshots clear the pasteboard.
    static func restore(_ snapshot: PasteboardSnapshot) {
        restore(snapshot, into: NSPasteboard.general)
    }

    /// Restore a previously captured snapshot into the given pasteboard.
    /// Used by tests that drive the snapshot / restore round-trip
    /// against an isolated named pasteboard so `NSPasteboard.general` is
    /// never mutated. Production callers use the single-argument
    /// `restore(_:)`.
    static func restore(_ snapshot: PasteboardSnapshot, into pb: NSPasteboard) {
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(snapshot.items.count)
        for entry in snapshot.items {
            let item = NSPasteboardItem()
            for (rawType, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: rawType))
            }
            items.append(item)
        }
        pb.writeObjects(items)
    }
}
