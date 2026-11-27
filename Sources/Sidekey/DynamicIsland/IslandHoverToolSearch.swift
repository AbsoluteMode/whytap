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
            let aliases = normalized(aliases(for: tool) + (tool == .screenshot ? " " + copyTextAliases : ""))
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

    /// Copy text is a command inside Shot's editor, not a tool of its own: it is
    /// found through Shot, and a query that only the OCR words explain labels
    /// the Shot result as Copy text so the user knows where to click.
    // WHY: .project-docs/decisions/2026-11-22-shot-hover-hints.md
    static let copyTextAliases = "copy text from screen ocr recognize recognition extract скопировать скопируй копировать текст текста с экрана распознать распознай распознавание"

    static func resultLabel(for tool: HoverTool, query: String) -> (title: String, description: String) {
        let info = HoverToolRegistry.info(for: tool)
        guard tool == .screenshot, isCopyTextQuery(query) else { return (info.title, info.description) }
        return ("\(info.title) — Copy text", "Select an area, then click Copy text (OCR)")
    }

    static func isCopyTextQuery(_ query: String) -> Bool {
        let terms = tokens(query)
        guard !terms.isEmpty else { return false }
        let info = HoverToolRegistry.info(for: .screenshot)
        let shot = normalized(info.title + " " + aliases(for: .screenshot) + " " + info.description)
        let copyText = normalized(copyTextAliases)
        return terms.allSatisfy { shot.contains($0) || copyText.contains($0) }
            && terms.contains { !shot.contains($0) && copyText.contains($0) }
    }

    /// The one tool both the row highlight and the footer show.
    static func selectedTool(in matches: [HoverTool], at index: Int) -> HoverTool? {
        matches.indices.contains(index) ? matches[index] : nil
    }

    /// Row fill opacity: a press is stronger than the selection; "Soon" rows stay flat.
    static func rowHighlight(isSelected: Bool, isPressed: Bool, isComingSoon: Bool) -> Double {
        guard !isComingSoon else { return 0 }
        return isPressed ? 0.24 : (isSelected ? 0.13 : 0)
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
        case .help: return "help ask question support faq docs contact how to помощь вопрос поддержка спросить"
        case .quit: return "exit выход"
        case .settings: return "preferences настройки"
        }
    }
}

/// The search results. Every row is identified by its tool, never by its
/// position: a position id inside the tool-keyed ForEach froze the visible
/// rows of the LazyVStack at their first render, so the highlight and even
/// the titles stayed on the first query while the footer moved on.
// WHY: .project-docs/decisions/2026-11-25-hover-search-row-identity.md
@MainActor
struct IslandHoverSearchResultsList: View {
    let query: String
    let matches: [HoverTool]
    let selectedIndex: Int
    @ObservedObject var bridge: IslandHoverHitBridge
    let hitContext: String
    let unreadNotifications: Int
    let onActivate: (HoverTool) -> Void
    /// (tool, index, pointer inside)
    let onHover: (HoverTool, Int, Bool) -> Void

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if matches.isEmpty {
                    VStack(spacing: 5) {
                        Text("No tools found")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Try “language” or “monitor”.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element) { index, tool in
                            row(tool, index: index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
                }
            }
            // Minimal scroll (no anchor): a row already in view, such as the
            // one under the pointer, never moves.
            .onChange(of: selectedIndex) { _, index in
                if let tool = IslandHoverToolSearch.selectedTool(in: matches, at: index) { scroll.scrollTo(tool) }
            }
            .onChange(of: query) { _, _ in
                if let first = matches.first { scroll.scrollTo(first, anchor: .top) }
            }
        }
    }

    private func row(_ tool: HoverTool, index: Int) -> some View {
        let info = HoverToolRegistry.info(for: tool)
        let label = IslandHoverToolSearch.resultLabel(for: tool, query: query)
        let isSelected = index == selectedIndex
        let isPressed = bridge.pressedID == IslandHoverHitTargetID(surface: .result, tool: tool)
        let showsUnread = tool == .notifs && unreadNotifications > 0
        return Button { onActivate(tool) } label: {
            HStack(spacing: 10) {
                Image(systemName: info.sfSymbol)
                    .font(.system(size: 15))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(label.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let soon = tool.comingSoonBadge {
                    IslandSoonBadge(text: soon)
                }
                if showsUnread {
                    Circle().fill(.red).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(IslandHoverToolSearch.rowHighlight(
                        isSelected: isSelected, isPressed: isPressed, isComingSoon: tool.isComingSoon)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .islandHoverHitTarget(
            bridge: bridge,
            id: IslandHoverHitTargetID(surface: .result, tool: tool),
            context: hitContext,
            action: { onActivate(tool) }
        )
        .disabled(tool.isComingSoon)
        .accessibilityLabel(label.title)
        .accessibilityHint(label.description)
        .accessibilityValue(tool.comingSoonBadge
            ?? (showsUnread ? "\(unreadNotifications) new notifications" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .opacity(tool.isComingSoon ? 0.6 : 1)
        .id(tool)
        .onHover { inside in onHover(tool, index, inside) }
    }

    static let rowHeight: CGFloat = 42
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
