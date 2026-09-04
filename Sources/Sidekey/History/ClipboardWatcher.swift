import AppKit
import Foundation
import os.log

/// Polls `NSPasteboard.general.changeCount` on a 500ms timer and saves
/// user-initiated copies into `SQLiteHistoryStore`'s `clipboard_entries`
/// table. The drop pipeline coordinates with this watcher via
/// `ClipboardSuppression` so the dictation it writes (and the snapshot
/// it later restores) are NOT recorded as clipboard history rows.
///
/// Pure-logic classification (`classify`) is exposed as a static for
/// unit-testing without hitting the real pasteboard. `handleChange`
/// performs the actual store insert and is also testable in isolation.
@MainActor
final class ClipboardWatcher {
    /// Kind variant produced by `classify`. The poller turns this into
    /// the matching SQLite insert; the variant carries the raw bytes /
    /// metadata so the watcher does not have to re-read the pasteboard.
    enum Kind: Equatable {
        case text(String)
        case image(Data, String)  // raw image bytes, file extension (e.g. "png")
        case fileURLs([URL])
    }

    /// Pure-data snapshot of an `NSPasteboard` event, ready for
    /// classification. The poller fills this in from the live
    /// `NSPasteboard.general`; tests fill it in directly.
    struct PasteboardSnapshotInput: Equatable {
        let text: String?
        let tiffData: Data?
        let pngData: Data?
        let fileURLs: [URL]
    }

    /// Per-history cap. Matches `historyCap` semantics elsewhere
    /// (`ChatStackStore.maxRows = 200` is intentionally higher because
    /// chats are smaller; clipboard images can be megabytes each).
    static let defaultMaxEntries: Int = 50

    /// Polling interval. 500ms is the same cadence as Maccy / Paste —
    /// fast enough that human-perceptible copies show up within one
    /// frame's worth of UI render, slow enough that idle power draw is
    /// negligible.
    static let pollIntervalSeconds: TimeInterval = 0.5

    /// Thumbnail size for clipboard images. Square, 64pt — matches the
    /// strip card preview area without forcing the watcher to re-render
    /// each time the strip opens.
    static let thumbnailSidePoints: CGFloat = 64

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "clipboard")

    private let store: SQLiteHistoryStore
    private let assetsDirectory: URL
    private let suppression: ClipboardSuppression
    private let clock: () -> Date
    private let maxEntries: Int

    /// Last `changeCount` observed by `handleChange`. Used both by the
    /// poller (to avoid re-running classification when the pasteboard
    /// hasn't changed) and by `handleChange` itself (idempotency
    /// against accidental double-calls).
    private var lastSeenChangeCount: Int = NSPasteboard.general.changeCount
    private var pollTimer: Timer?

    init(
        store: SQLiteHistoryStore,
        assetsDirectory: URL,
        suppression: ClipboardSuppression = .shared,
        clock: @escaping () -> Date = Date.init,
        maxEntries: Int = ClipboardWatcher.defaultMaxEntries
    ) {
        self.store = store
        self.assetsDirectory = assetsDirectory
        self.suppression = suppression
        self.clock = clock
        self.maxEntries = maxEntries
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        // Seed last change count so the watcher does not record whatever
        // happens to be in the pasteboard at startup time.
        lastSeenChangeCount = NSPasteboard.general.changeCount

        // Round 2 Bug 3: switched from `Timer(timeInterval:repeats:block:)`
        // + `RunLoop.main.add(_:forMode:.common)` to
        // `Timer.scheduledTimer(...)` so the scheduling step is explicit
        // and a debugger / `print` proves the fire path is wired. The
        // `block` form is still convenient because the closure runs on
        // the timer's runloop (main, in our case).
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            // Timer block runs on the main thread (RunLoop.main). Calling
            // straight into `poll()` keeps the latency to zero and dodges
            // a possible MainActor-isolation hop.
            self?.poll()
        }
        // Also re-add to `.common` so the watcher keeps polling while
        // menus / modal panels are open. `scheduledTimer` only registers
        // on `.default` by default — the `.common` add covers menu mode
        // too.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        os_log(
            "clipboard_watcher_started interval=%{public}.3f seed_change_count=%{public}d",
            log: Self.log,
            type: .info,
            Self.pollIntervalSeconds,
            lastSeenChangeCount
        )
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        os_log("clipboard_watcher_stopped", log: Self.log, type: .info)
    }

    // MARK: - Polling

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastSeenChangeCount else { return }
        os_log(
            "clipboard_watcher_delta last=%{public}d current=%{public}d",
            log: Self.log,
            type: .debug,
            lastSeenChangeCount,
            current
        )
        let snapshot = Self.readSnapshot(from: pb)
        handleChange(snapshot: snapshot, changeCount: current)
    }

    /// Reads the current pasteboard state into a classification input.
    /// Public-by-internal so a future hook can call it without the
    /// timer (e.g. on app foreground).
    nonisolated static func readSnapshot(from pb: NSPasteboard) -> PasteboardSnapshotInput {
        let text = pb.string(forType: .string)

        let png = pb.data(forType: .png)
        let tiff = pb.data(forType: .tiff)

        let urls: [URL]
        if let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            urls = items.filter { $0.isFileURL }
        } else {
            urls = []
        }

        return PasteboardSnapshotInput(
            text: text,
            tiffData: tiff,
            pngData: png,
            fileURLs: urls
        )
    }

    /// Classify the pasteboard snapshot into a concrete `Kind`, or `nil`
    /// when the event has no meaningful payload (empty / whitespace
    /// text, no recognisable bytes).
    ///
    /// Priority order: image > fileURLs > text. This mirrors the
    /// richness of the user's intent — Finder image copies produce
    /// image bytes AND a filename string; the image is the meaningful
    /// content there.
    nonisolated static func classify(_ snapshot: PasteboardSnapshotInput) -> Kind? {
        if let png = snapshot.pngData, !png.isEmpty {
            return .image(png, "png")
        }
        if let tiff = snapshot.tiffData, !tiff.isEmpty {
            return .image(tiff, "tiff")
        }
        if !snapshot.fileURLs.isEmpty {
            return .fileURLs(snapshot.fileURLs)
        }
        if let text = snapshot.text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .text(text)
            }
        }
        return nil
    }

    /// Handle a single pasteboard change. Tests call this directly;
    /// production code goes through `poll()`.
    func handleChange(snapshot: PasteboardSnapshotInput, changeCount: Int) {
        if suppression.isSuppressed {
            os_log("clipboard_watcher_suppressed change_count=%{public}d", log: Self.log, type: .debug, changeCount)
            // Update lastSeen even when suppressed so the next poll
            // doesn't immediately re-trigger this same change.
            lastSeenChangeCount = changeCount
            return
        }
        // Threshold-based suppression covers the race between the drop
        // pipeline's "flag cleared" point and the watcher's next poll
        // (500 ms cadence). A fast drop completes in <100 ms and bumps
        // changeCount twice (write + restore); the engine raises this
        // threshold to the post-restore changeCount before clearing the
        // flag so this branch swallows the residual bumps.
        if changeCount <= suppression.skipThroughChangeCount {
            os_log(
                "clipboard_watcher_suppressed_threshold change_count=%{public}d threshold=%{public}d",
                log: Self.log,
                type: .debug,
                changeCount,
                suppression.skipThroughChangeCount
            )
            lastSeenChangeCount = changeCount
            return
        }
        // Idempotent against accidental double-calls (e.g. poll firing
        // twice for one OS update, or a test re-issuing the same input).
        if changeCount == lastSeenChangeCount {
            return
        }
        lastSeenChangeCount = changeCount
        guard let kind = Self.classify(snapshot) else {
            os_log(
                "clipboard_watcher_classify_nil text_len=%{public}d png_bytes=%{public}d tiff_bytes=%{public}d urls=%{public}d",
                log: Self.log,
                type: .debug,
                snapshot.text?.count ?? 0,
                snapshot.pngData?.count ?? 0,
                snapshot.tiffData?.count ?? 0,
                snapshot.fileURLs.count
            )
            return
        }
        let kindLabel: String
        switch kind {
        case .text: kindLabel = "text"
        case .image: kindLabel = "image"
        case .fileURLs: kindLabel = "fileURLs"
        }
        os_log(
            "clipboard_watcher_classified kind=%{public}@",
            log: Self.log,
            type: .debug,
            kindLabel
        )

        let now = clock()
        do {
            switch kind {
            case .text(let s):
                let id = try store.insertClipboardTextEntry(createdAt: now, text: s)
                os_log(
                    "clipboard_watcher_insert kind=text id=%{public}lld chars=%{public}d",
                    log: Self.log,
                    type: .info,
                    id,
                    s.count
                )
            case .image(let bytes, let ext):
                let uuid = UUID()
                let thumb = Self.makeThumbnail(from: bytes) ?? bytes
                let id = try store.insertClipboardImageEntry(
                    createdAt: now,
                    uuid: uuid,
                    imageData: bytes,
                    imageExtension: ext,
                    thumbnailData: thumb,
                    assetsDirectory: assetsDirectory
                )
                os_log(
                    "clipboard_watcher_insert kind=image id=%{public}lld bytes=%{public}d ext=%{public}@",
                    log: Self.log,
                    type: .info,
                    id,
                    bytes.count,
                    ext
                )
            case .fileURLs(let urls):
                let id = try store.insertClipboardFileURLsEntry(createdAt: now, urls: urls)
                os_log(
                    "clipboard_watcher_insert kind=fileURLs id=%{public}lld count=%{public}d",
                    log: Self.log,
                    type: .info,
                    id,
                    urls.count
                )
            }
            try store.enforceClipboardCap(maxRows: maxEntries, assetsDirectory: assetsDirectory)
        } catch {
            // History persistence is best-effort. A failure here MUST NOT
            // break the user's clipboard flow — log and move on.
            os_log(
                "clipboard_watcher_insert_failed error=%{public}@",
                log: Self.log, type: .error,
                String(describing: type(of: error))
            )
        }
    }

    // MARK: - Thumbnails

    /// Renders a 64×64 PNG thumbnail from arbitrary image bytes. Returns
    /// the original bytes if NSImage can't decode them (the strip still
    /// renders the full image fallback in that case).
    nonisolated static func makeThumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }

        let side = thumbnailSidePoints
        let targetSize = NSSize(width: side, height: side)
        let thumb = NSImage(size: targetSize)

        thumb.lockFocus()
        defer { thumb.unlockFocus() }

        let sourceRect = NSRect(origin: .zero, size: image.size)
        let targetRect = NSRect(origin: .zero, size: targetSize)
        NSColor.clear.setFill()
        targetRect.fill()
        image.draw(
            in: targetRect,
            from: sourceRect,
            operation: .copy,
            fraction: 1.0
        )

        guard
            let tiff = thumb.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }
        return png
    }
}
