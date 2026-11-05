import AppKit
import SwiftUI

/// Search never reads or mutates the user's pinned tools: its source is the full catalog.
enum IslandHoverToolSearch {
    static let fieldHeight: CGFloat = 30
    static let fieldVerticalInset: CGFloat = 6
    static let searchBandHeight = fieldHeight + fieldVerticalInset * 2

    static func isFiltering(_ query: String) -> Bool { !tokens(query).isEmpty }

    static func results(for query: String) -> [HoverTool] {
        let terms = tokens(query)
        guard !terms.isEmpty else { return [] }
        let phrase = terms.joined(separator: " ")
        return HoverTool.allCases.enumerated().compactMap { index, tool -> (HoverTool, Int, Int)? in
            let info = HoverToolRegistry.info(for: tool)
            let title = normalized(info.title)
            let aliases = normalized(aliases(for: tool))
            let searchable = title + " " + aliases + " " + normalized(info.description)
            guard terms.allSatisfy({ searchable.contains($0) }) else { return nil }
            let rank: Int
            if title == phrase { rank = 0 }
            else if title.hasPrefix(phrase) { rank = 1 }
            else if terms.allSatisfy({ title.contains($0) }) { rank = 2 }
            else if terms.allSatisfy({ aliases.contains($0) }) { rank = 3 }
            else { rank = 4 }
            return (tool, rank, index)
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .map(\.0)
    }

    static func nextSelection(current: Int, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((min(max(0, current), count - 1) + direction) % count + count) % count
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func tokens(_ text: String) -> [String] {
        normalized(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func aliases(for tool: HoverTool) -> String {
        switch tool {
        case .dropMode: return "fast smart dictation transcription режим диктовка"
        case .clipboard: return "clipboard copy paste history буфер история"
        case .vocab: return "vocabulary dictionary словарь"
        case .caseVault: return "secrets keys api tokens credentials snippets vault фразы кейс"
        case .filler: return "phrases snippets филлер"
        case .inputLang: return "input language source язык ввода"
        case .outputLang: return "output language translation translate target язык вывода перевод"
        case .hotkeys: return "keyboard shortcuts горячие клавиши"
        case .notes: return "meetings meeting notes встречи заметки"
        case .meetingRecord: return "meeting recording record запись встречи"
        case .notifs: return "notify notification notifications alerts уведомления оповещения"
        case .monitor: return "dashboard server status монитор серверы"
        case .tasks: return "todo to-do tasks checklist task list задачи список дел туду"
        case .calendar: return "calendar schedule events agenda google outlook apple teams zoom календарь расписание события встречи"
        case .brightness: return "screen brightness sun hdr xdr vivid extra boost яркость экран солнце"
        case .translate: return "translator translation text llm перевод переводчик текст"
        case .subtitles: return "translator live captions system audio video перевод субтитры системный звук"
        case .screenshot: return "screenshot capture area crop blur text numbers redact annotation screen скриншот снимок область размытие текст числа блюр"
        case .quit: return "exit выход"
        case .settings: return "preferences настройки"
        }
    }
}

enum IslandHoverSearchCommand {
    case previous, next, activate, cancel
}

/// An explicit click acquires keyboard focus; merely opening Hover leaves the user's app focused.
@MainActor
struct IslandHoverSearchField: NSViewRepresentable {
    @Binding var text: String
    let onFocusChange: (Bool) -> Void
    let onCommand: (IslandHoverSearchCommand) -> Void

    func makeNSView(context: Context) -> IslandHoverSearchNativeField {
        let field = IslandHoverSearchNativeField(frame: .zero)
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = "Search all tools"
        field.setAccessibilityLabel("Search all tools")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .none
        // Preserve native bezel geometry (text/search/cancel insets). The 26+
        // cell omits only the opaque paint, leaving the SwiftUI glass visible.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            field.drawsBackground = false
            field.backgroundColor = .clear
        }
        #endif
        field.font = NSFont.systemFont(ofSize: 12)
        field.textColor = NSColor.white.withAlphaComponent(0.92)
        field.onFocusChange = onFocusChange
        return field
    }

    func updateNSView(_ field: IslandHoverSearchNativeField, context: Context) {
        context.coordinator.parent = self
        field.onFocusChange = onFocusChange
        if field.stringValue != text { field.stringValue = text }
        // Focus originates in mouseDown. Don't reacquire it on every state update:
        // that would steal it back from a clicked result or the next inline tool.
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: IslandHoverSearchNativeField,
        context: Context
    ) -> CGSize? {
        // The outer SwiftUI frame is 30 pt, but AppKit's intrinsic search
        // field is only 24 pt. Its native button rect then extends beyond
        // the NSView, where a remounted transition layer can clip the icon.
        // Give the NSView the full field height on every layout pass;
        // AppKit still owns the text/search/cancel layout inside that frame.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let width = proposal.width, width.isFinite {
            return CGSize(width: max(0, width), height: IslandHoverToolSearch.fieldHeight)
        }
        #endif
        return nil
    }

    static func dismantleNSView(_ field: IslandHoverSearchNativeField, coordinator: Coordinator) {
        field.removeWindowObserver()
        field.delegate = nil
        field.onFocusChange = { _ in }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: IslandHoverSearchField
        init(parent: IslandHoverSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        // Moving from the field editor to an in-panel Button must not resign
        // the key window between its mouse-down and mouse-up. Activation or the
        // actual window.didResignKey observer releases text-entry focus.
        func controlTextDidEndEditing(_ notification: Notification) {}

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: IslandHoverSearchCommand
            switch selector {
            case #selector(NSResponder.moveUp(_:)): command = .previous
            case #selector(NSResponder.moveDown(_:)): command = .next
            case #selector(NSResponder.insertNewline(_:)): command = .activate
            case #selector(NSResponder.cancelOperation(_:)): command = .cancel
            default: return false
            }
            parent.onCommand(command)
            return true
        }
    }
}

@MainActor
final class IslandHoverSearchNativeField: NSSearchField {
    override class var cellClass: AnyClass? {
        get {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return IslandHoverSearchGlassCell.self }
            #endif
            return super.cellClass
        }
        set { super.cellClass = newValue }
    }

    var onFocusChange: (Bool) -> Void = { _ in }
    private var resignKeyObserver: NSObjectProtocol?
    private var searchGlyph: IslandHoverSearchGlyphView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateSearchGlyph()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateSearchGlyph()
    }

    override func layout() {
        super.layout()
        updateSearchGlyph()
    }

    private func updateSearchGlyph() {
        guard let cell = cell as? IslandHoverSearchGlassCell else { return }
        // Draw the loupe independently of NSSearchFieldCell's interior pass
        // and image clipping when SwiftUI removes and remounts the field.
        // Keep the original button cell for native hit testing/actions/insets.
        cell.searchButtonCell?.isTransparent = true
        let glyph: IslandHoverSearchGlyphView
        if let searchGlyph {
            glyph = searchGlyph
        } else {
            glyph = IslandHoverSearchGlyphView(frame: .zero)
            glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            glyph.imageScaling = .scaleProportionallyUpOrDown
            glyph.contentTintColor = NSColor.white.withAlphaComponent(0.62)
            glyph.setAccessibilityElement(false)
            addSubview(glyph)
            searchGlyph = glyph
        }
        let nativeButtonRect = cell.searchButtonRect(forBounds: bounds)
        let side = max(0, min(14, nativeButtonRect.width, nativeButtonRect.height))
        glyph.frame = NSRect(
            x: nativeButtonRect.midX - side / 2,
            y: nativeButtonRect.midY - side / 2,
            width: side, height: side
        )
        glyph.isHidden = side == 0
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The host panel deliberately cannot become key until this request.
        onFocusChange(true)
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObserver()
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFocusChange(false) }
        }
    }

    func removeWindowObserver() {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
    }

    deinit {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }
}

/// Decoration only: a click on the loupe still reaches NSSearchField and its
/// original search button, and VoiceOver exposes only the labelled search field.
@MainActor
final class IslandHoverSearchGlyphView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Keep NSSearchFieldCell's native layout and button tracking, but let the
/// surrounding glass lens draw the surface instead of the dark AppKit bezel.
@MainActor
final class IslandHoverSearchGlassCell: NSSearchFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        return editor
    }
}
