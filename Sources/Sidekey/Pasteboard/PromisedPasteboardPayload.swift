import AppKit
import Foundation

/// Counts how often a reader took the Drop paste payload from the
/// pasteboard. `AutoPasteEngine` compares the count before and after its
/// synthetic Cmd+V to learn when the target actually read the dictation.
///
/// Readers are not identified: macOS does not say which process asked.
/// The count only grows; the engine keeps its own baseline per paste.
// WHY: .project-docs/decisions/2026-11-27-drop-paste-restore-on-read.md
@MainActor
final class PasteboardReadMonitor {
    private(set) var readCount: Int = 0

    nonisolated init() {}

    func noteRead() {
        readCount += 1
    }
}

/// Publishes a Drop paste payload as promised pasteboard data. The data is
/// handed over only when a reader asks for it, which is the moment the
/// engine needs: Chromium/Electron read the pasteboard only when the page
/// handles the paste, possibly long after Cmd+V.
///
/// AppKit calls the provider on the main thread (or synchronously inside
/// this process for an in-process read) and serves later reads of the same
/// type from its cache, so each type is provided at most once. The item
/// keeps the provider alive until every promised type was provided or the
/// pasteboard was cleared.
final class PromisedPasteboardPayload: NSObject, NSPasteboardItemDataProvider {
    /// nspasteboard.org marker: the content is temporary and will be
    /// replaced shortly. Clipboard managers that honour it (and Whytap's
    /// own `ClipboardWatcher`) skip the item without reading its data, so
    /// they neither record the dictation nor trigger the read signal.
    static let transientMarker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let payload: [NSPasteboard.PasteboardType: Data]
    private let onRead: () -> Void

    /// Depth of Whytap's own snapshot reads on the main thread
    /// (`Pasteboard.snapshot`). Selection capture or a Shot copy that
    /// snapshots the clipboard is not the paste target: its read of a
    /// pending dictation must not end the wait for the target.
    private static var ownReadDepth = 0

    /// Runs `body` as one of Whytap's own reads. Main thread only; other
    /// threads run `body` unchanged.
    static func asOwnRead<T>(_ body: () -> T) -> T {
        guard Thread.isMainThread else { return body() }
        ownReadDepth += 1
        defer { ownReadDepth -= 1 }
        return body()
    }

    init(payload: [NSPasteboard.PasteboardType: Data], onRead: @escaping () -> Void) {
        self.payload = payload
        self.onRead = onRead
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let data = payload[type] else { return }
        item.setData(data, forType: type)
        if Thread.isMainThread, Self.ownReadDepth > 0 { return }
        onRead()
    }

    /// Clears `pasteboard` and writes one item that promises every payload
    /// type and carries the transient marker. Returns the change counts
    /// around the write, or nil when the pasteboard refused it.
    @MainActor
    static func write(
        _ payload: [NSPasteboard.PasteboardType: Data],
        to pasteboard: NSPasteboard,
        reads: PasteboardReadMonitor
    ) -> (before: Int, after: Int)? {
        guard !payload.isEmpty else { return nil }
        let provider = PromisedPasteboardPayload(payload: payload) { [weak reads] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { reads?.noteRead() }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { reads?.noteRead() }
                }
            }
        }
        let item = NSPasteboardItem()
        guard item.setData(Data(), forType: transientMarker),
              item.setDataProvider(provider, forTypes: Array(payload.keys))
        else { return nil }
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return nil }
        return (before, pasteboard.changeCount)
    }
}
