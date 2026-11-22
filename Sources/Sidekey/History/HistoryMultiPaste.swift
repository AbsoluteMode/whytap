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
    /// rows of one kind share a paste, so three files are one Cmd+V and
    /// text, file, text are three.
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
                attachments.append(contentsOf: items)
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

/// Runs the pastes of marked rows one after another into the target that
/// was remembered when Enter was pressed. Collaborators are injected so the
/// order, gaps and target checks are testable without a pasteboard or
/// synthetic events.
@MainActor
struct HistoryMultiPaster {
    /// Time the target gets to read one paste before the pasteboard is
    /// replaced for the next. Drop restores the clipboard 120 ms after its
    /// Cmd+V; attachments can be read more slowly, so mixed pastes wait longer.
    static let gapBetweenPastesNs: UInt64 = 400_000_000

    /// The series' target is still the one Enter was pressed for: running,
    /// not replaced by a later capture and, after the first paste, still
    /// focused (the argument is `true` for the first paste). Checked before
    /// the pasteboard is replaced, so a stopped series leaves the last pasted
    /// content in place.
    let targetIsCurrent: (_ isFirst: Bool) -> Bool
    let write: (HistoryPasteGroup) -> Void
    /// Posts Cmd+V only into the series' target
    /// (`pasteAlreadyOnPasteboard(into:restoringFocus:)`); only the first
    /// paste may bring the target back to the front.
    let paste: (_ isFirst: Bool) async -> Bool
    let sleep: (UInt64) async -> Void

    /// Returns how many pastes were posted. Stops at the first paste whose
    /// target is gone or that the engine could not post, so nothing lands in
    /// another app or out of order.
    @discardableResult
    func run(_ groups: [HistoryPasteGroup]) async -> Int {
        var posted = 0
        for (index, group) in groups.enumerated() {
            if index > 0 { await sleep(Self.gapBetweenPastesNs) }
            guard targetIsCurrent(index == 0) else { break }
            write(group)
            guard await paste(index == 0) else { break }
            posted += 1
        }
        return posted
    }
}
