import AppKit
import Foundation

// WHY: .project-docs/decisions/2026-11-22-history-multi-paste.md
//
// History used to paste one row per opening: Enter pasted the hovered row and
// closed the panel, so attaching several copied files meant reopening History
// for each one. ⌘-click now marks rows in click order and Enter pastes all of
// them with as few Cmd+V presses as their kinds allow.

/// The rows marked with ⌘-click in the island's History, in click order.
/// Lives only while the History panel is on screen.
@MainActor
final class HistoryPasteSelection: ObservableObject {
    @Published private(set) var cards: [HistoryStripCard] = []

    var isEmpty: Bool { cards.isEmpty }
    var count: Int { cards.count }

    /// Adds the row at the end, or removes it when it is already marked.
    func toggle(_ card: HistoryStripCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards.remove(at: index)
        } else {
            cards.append(card)
        }
    }

    func clear() {
        if !cards.isEmpty { cards.removeAll() }
    }

    /// 1-based paste order of a marked row, `nil` when it is not marked.
    func position(of card: HistoryStripCard) -> Int? {
        cards.firstIndex(where: { $0.id == card.id }).map { $0 + 1 }
    }
}

/// One thing that can sit on the pasteboard next to others of its kind.
enum HistoryPasteAttachment: Equatable {
    case file(URL)
    case image(ClipboardImagePayload)
}

/// What one Cmd+V delivers.
enum HistoryPasteGroup: Equatable {
    /// Text rows, one per line.
    case text(String)
    /// Files and images, one pasteboard item each, the way Finder copies
    /// several files: chats, mail and forms attach all of them at once.
    case attachments([HistoryPasteAttachment])
}

enum HistoryPastePlan {
    static let textSeparator = "\n"

    /// Splits marked rows into pastes, keeping their order. Neighbouring
    /// texts share a paste and so do neighbouring files, so three files are
    /// one Cmd+V and text, file, text are three. Every image is a paste of
    /// its own: a pasteboard with several image items gives Chromium,
    /// Electron and most other apps only the first image.
    // WHY: .project-docs/decisions/2026-11-28-history-multi-paste-every-image.md
    static func groups(for cards: [HistoryStripCard]) -> [HistoryPasteGroup] {
        var groups: [HistoryPasteGroup] = []
        var texts: [String] = []
        var attachments: [HistoryPasteAttachment] = []

        func flushTexts() {
            guard !texts.isEmpty else { return }
            groups.append(.text(texts.joined(separator: textSeparator)))
            texts.removeAll()
        }
        func flushAttachments() {
            guard !attachments.isEmpty else { return }
            groups.append(.attachments(attachments))
            attachments.removeAll()
        }

        for card in cards {
            switch content(of: card) {
            case .text(let text):
                flushAttachments()
                texts.append(text)
            case .attachments(let items):
                flushTexts()
                for item in items {
                    switch item {
                    case .file:
                        attachments.append(item)
                    case .image:
                        flushAttachments()
                        groups.append(.attachments([item]))
                    }
                }
            }
        }
        flushTexts()
        flushAttachments()
        return groups
    }

    private static func content(of card: HistoryStripCard) -> HistoryPasteGroup {
        switch card {
        case .agent(let c):
            return .text(c.responseMarkdown)
        case .drop(let c):
            return .text(c.formattedText)
        case .clipboard(let c):
            switch c.payload {
            case .text(let s):
                return .text(s)
            case .image(let image):
                return .attachments([.image(image)])
            case .fileURLs(let urls):
                return .attachments(urls.map(HistoryPasteAttachment.file))
            }
        }
    }
}

enum HistoryPasteboardWriter {
    /// Puts every group on the pasteboard at once, for a click that copies
    /// several marked rows. One group is written exactly like `write`. Several
    /// (texts and files mixed) become one pasteboard with one item per group
    /// member in mark order: neighbouring texts as one string item a line
    /// each, then each file and image as its own item. Apps that take files
    /// attach them; a plain text read gets every text item joined by line
    /// breaks (AppKit's behaviour); some apps read only the first item.
    /// WHY: .project-docs/decisions/2026-11-22-history-multi-copy.md
    static func writeAll(_ groups: [HistoryPasteGroup], to pasteboard: NSPasteboard, assetsDirectory: URL) {
        guard !groups.isEmpty else { return }
        if groups.count == 1, let group = groups.first {
            write(group, to: pasteboard, assetsDirectory: assetsDirectory)
            return
        }
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = []
        for group in groups {
            switch group {
            case .text(let text):
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                objects.append(item)
            case .attachments(let items):
                objects += items.compactMap { pasteboardObject(for: $0, assetsDirectory: assetsDirectory) }
            }
        }
        if !objects.isEmpty {
            pasteboard.writeObjects(objects)
        }
    }

    /// Replaces the pasteboard with one paste's content. A single row is
    /// written exactly as History always wrote it.
    static func write(_ group: HistoryPasteGroup, to pasteboard: NSPasteboard, assetsDirectory: URL) {
        pasteboard.clearContents()
        switch group {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .attachments(let items):
            let objects = items.compactMap { pasteboardObject(for: $0, assetsDirectory: assetsDirectory) }
            if !objects.isEmpty {
                pasteboard.writeObjects(objects)
            }
        }
    }

    /// Writes one paste of a multi-paste series and reports what the series
    /// needs to wait for it. Text and a single image are promised data
    /// (`PromisedPasteboardPayload`): the target's read is counted in
    /// `reads`, so the next paste replaces the pasteboard only after the
    /// target took this one. Files are written as before (file URLs read by
    /// path); they give no read signal and the series waits a fixed gap.
    // WHY: .project-docs/decisions/2026-11-28-history-multi-paste-every-image.md
    @MainActor
    static func writeForPaste(
        _ group: HistoryPasteGroup,
        to pasteboard: NSPasteboard,
        assetsDirectory: URL,
        reads: PasteboardReadMonitor
    ) -> HistoryPasteWrite {
        let readsBefore = reads.readCount
        let ledger = PasteboardWriteLedger()
        switch group {
        case .text(let text):
            guard let written = PromisedPasteboardPayload.write(
                [.string: Data(text.utf8)], to: pasteboard, reads: reads, ledger: ledger
            ) else { return .failed(clearedChangeCount: ledger.takeFailedWrite()) }
            return .written(.init(changeCount: written.after, readsBefore: readsBefore))
        case .attachments(let items):
            if items.count == 1, case .image(let image) = items[0] {
                guard let payload = imagePayload(image, assetsDirectory: assetsDirectory) else { return .nothing }
                guard let written = PromisedPasteboardPayload.write(payload, to: pasteboard, reads: reads, ledger: ledger)
                else { return .failed(clearedChangeCount: ledger.takeFailedWrite()) }
                return .written(.init(changeCount: written.after, readsBefore: readsBefore))
            }
            let objects = items.compactMap { pasteboardObject(for: $0, assetsDirectory: assetsDirectory) }
            guard !objects.isEmpty else { return .nothing }
            let owned = pasteboard.clearContents()
            guard pasteboard.writeObjects(objects) else { return .failed(clearedChangeCount: owned) }
            return .written(.init(changeCount: owned, readsBefore: nil))
        }
    }

    /// PNG and TIFF of a History image: Chromium and Electron read PNG
    /// first, AppKit text views and most native apps read TIFF. nil when
    /// neither the sidecar nor the thumbnail decodes.
    static func imagePayload(
        _ image: ClipboardImagePayload,
        assetsDirectory: URL
    ) -> [NSPasteboard.PasteboardType: Data]? {
        let sidecar = try? Data(contentsOf: image.sidecarURL(in: assetsDirectory))
        for data in [sidecar, image.thumbnailData].compactMap({ $0 }) where !data.isEmpty {
            guard let decoded = NSImage(data: data), let tiff = decoded.tiffRepresentation else { continue }
            var payload: [NSPasteboard.PasteboardType: Data] = [.tiff: tiff]
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                payload[.png] = png
            }
            return payload
        }
        return nil
    }

    private static func pasteboardObject(
        for item: HistoryPasteAttachment,
        assetsDirectory: URL
    ) -> NSPasteboardWriting? {
        switch item {
        case .file(let url):
            return url as NSURL
        case .image(let img):
            let url = img.sidecarURL(in: assetsDirectory)
            if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
                return image
            }
            // Sidecar evicted: the thumbnail is still something pastable.
            return NSImage(data: img.thumbnailData)
        }
    }
}

/// What a key press does while History is on screen.
enum HistoryKeyAction: Equatable {
    case paste([HistoryStripCard])
    case clearSelection
    /// Not History's key: hand it on.
    case pass
}

enum HistoryKeyDecision {
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let escapeKeyCode: UInt16 = 53

    /// Enter pastes the marked rows when there are any, otherwise the
    /// hovered row. Without a paste target (`canPaste` false) Enter leaves
    /// marked rows alone, so they stay for a click to copy. Escape first
    /// drops the marks; with nothing marked it keeps its usual meaning.
    static func action(
        keyCode: UInt16,
        hovered: HistoryStripCard?,
        selection: [HistoryStripCard],
        canPaste: Bool = true
    ) -> HistoryKeyAction {
        switch keyCode {
        case returnKeyCode, keypadEnterKeyCode:
            if !selection.isEmpty { return canPaste ? .paste(selection) : .pass }
            if let hovered { return .paste([hovered]) }
            return .pass
        case escapeKeyCode:
            return selection.isEmpty ? .pass : .clearSelection
        default:
            return .pass
        }
    }
}

/// What the series knows about one paste it put on the pasteboard.
struct HistoryPasteReceipt: Equatable {
    /// The pasteboard generation this write owns.
    let changeCount: Int
    /// The read count before the write; nil when the content gives no read
    /// signal (files) and the series waits a fixed gap instead.
    let readsBefore: Int?
}

/// The result of writing one paste of the series.
enum HistoryPasteWrite: Equatable {
    /// The group had nothing pastable (an evicted image without a
    /// thumbnail); the pasteboard was not touched.
    case nothing
    case written(HistoryPasteReceipt)
    /// The pasteboard refused the write. `clearedChangeCount` is the
    /// generation of the write's own clear when it got that far (the
    /// pasteboard is then empty and the series' to give back), `nil` when
    /// the pasteboard was not touched.
    case failed(clearedChangeCount: Int?)
}

/// How a wait for the target to read one paste ended (for logs and tests).
enum HistoryPasteWaitOutcome: Equatable {
    /// The target read it; quiet for `afterReadMs` since the last read.
    case read
    /// No read came within `fallbackMs`.
    case timeout
    /// Files: no read signal, the fixed gap passed.
    case gap
    /// Other content replaced the paste on the pasteboard.
    case replaced
}

/// Waits until the target has read one paste before the series replaces
/// the pasteboard (the next paste or the user's own clipboard).
// WHY: .project-docs/decisions/2026-11-28-history-multi-paste-every-image.md
@MainActor
struct HistoryPasteReadWaiter {
    struct Timing: Equatable {
        /// How often the wait checks for reads and replacements.
        var pollMs: UInt64 = 10
        /// Quiet time after the last read: a reader that takes several
        /// types (PNG, then TIFF) reads them in a burst.
        var afterReadMs: UInt64 = 150
        /// Continue anyway when the target never reads the paste.
        var fallbackMs: UInt64 = 2_000
        /// Files give no read signal: the former fixed gap.
        var unsignalledGapMs: UInt64 = 400

        static let standard = Timing()
    }

    let readCount: () -> Int
    let changeCount: () -> Int
    let nowMs: () -> UInt64
    let sleepMs: (UInt64) async -> Void
    var timing: Timing = .standard

    func wait(for receipt: HistoryPasteReceipt) async -> HistoryPasteWaitOutcome {
        guard let baseline = receipt.readsBefore else {
            await sleepMs(timing.unsignalledGapMs)
            return .gap
        }
        let start = nowMs()
        var seen = baseline
        var lastReadAt: UInt64?
        while true {
            let now = nowMs()
            if changeCount() != receipt.changeCount { return .replaced }
            let reads = readCount()
            if reads != seen {
                seen = reads
                lastReadAt = now
            }
            if let lastReadAt {
                if now - lastReadAt >= timing.afterReadMs { return .read }
            } else if now - start >= timing.fallbackMs {
                return .timeout
            }
            await sleepMs(timing.pollMs)
        }
    }
}

/// Runs the pastes of marked rows one after another into the target that
/// was remembered when Enter was pressed, then gives the user's clipboard
/// back. Collaborators are injected so the order, waits, target checks and
/// the restore are testable without a pasteboard or synthetic events.
@MainActor
struct HistoryMultiPaster {
    /// The series' target is still the one Enter was pressed for: running,
    /// not replaced by a later capture and, after the first paste, still
    /// focused (the argument is `true` for the first paste). Checked before
    /// the pasteboard is replaced.
    let targetIsCurrent: (_ isFirst: Bool) -> Bool
    let write: (HistoryPasteGroup) -> HistoryPasteWrite
    /// Posts Cmd+V only into the series' target
    /// (`pasteAlreadyOnPasteboard(into:restoringFocus:expectedChangeCount:)`);
    /// only the first paste may bring the target back to the front. No V-down
    /// is sent once the pasteboard no longer holds `expectedChangeCount`, the
    /// series' own write.
    let paste: (_ isFirst: Bool, _ expectedChangeCount: Int) async -> Bool
    /// Returns once the target has read the paste (`HistoryPasteReadWaiter`).
    /// Runs after every posted paste, the last one too: the next write or the
    /// restore must not replace content the target has not read yet.
    let awaitConsumed: (HistoryPasteReceipt) async -> Void
    let changeCount: () -> Int
    /// Puts the user's clipboard from before the series back.
    let restore: () -> Void
    /// Keeps exactly one generation the series itself wrote (a paste, a
    /// cleared refused write, the restore) out of clipboard history, right
    /// after that write and before anything can run in between. Never
    /// called for a generation someone else produced: the user's own copy
    /// during the series is recorded as usual.
    /// WHY: .project-docs/decisions/2026-11-28-clipboard-suppression-per-owner.md
    var suppressOwn: (Int) -> Void = { _ in }

    /// Returns how many pastes were posted. Stops at the first paste whose
    /// target is gone, that the engine could not post or whose content was
    /// replaced by someone else, so nothing lands in another app or out of
    /// order. Afterwards the user's clipboard comes back only while the
    /// pasteboard still holds the series' own last generation: a copy made
    /// meanwhile (by the user or another app) is never overwritten.
    @discardableResult
    func run(_ groups: [HistoryPasteGroup]) async -> Int {
        var posted = 0
        // The series' own generation still expected on the pasteboard, if any.
        var owned: Int?
        series: for group in groups {
            guard targetIsCurrent(posted == 0) else { break }
            if let owned, changeCount() != owned { return posted }
            switch write(group) {
            case .nothing:
                continue
            case .failed(let cleared):
                // A refused write that cleared the pasteboard leaves an empty
                // generation of our own; one that never touched it leaves the
                // previous generation (ours or the user's) in place.
                if let cleared {
                    suppressOwn(cleared)
                    owned = cleared
                }
                break series
            case .written(let receipt):
                suppressOwn(receipt.changeCount)
                owned = receipt.changeCount
                guard await paste(posted == 0, receipt.changeCount) else { break series }
                posted += 1
                await awaitConsumed(receipt)
            }
        }
        guard let owned, changeCount() == owned else { return posted }
        restore()
        suppressOwn(changeCount())
        return posted
    }
}
