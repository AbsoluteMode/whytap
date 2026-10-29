import AppKit

enum ScreenshotTextLayout {
    static func attributes(_ annotation: ScreenshotAnnotation) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: max(14, annotation.width * 6), weight: .medium),
         .foregroundColor: annotation.color]
    }

    static func size(_ annotation: ScreenshotAnnotation) -> CGSize {
        let attributes = attributes(annotation)
        let font = attributes[.font] as! NSFont
        let rect = (annotation.text as NSString).boundingRect(
            with: CGSize(width: annotation.textWidth ?? 10_000, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return CGSize(width: ceil(rect.width), height: ceil(max(font.ascender - font.descender + font.leading, rect.height)))
    }

    static func frame(_ annotation: ScreenshotAnnotation) -> CGRect {
        CGRect(origin: annotation.points.first ?? .zero, size: size(annotation))
    }
}

/// Native editing keeps selection, input methods, clipboard commands and text undo local.
@MainActor
final class ScreenshotInlineTextView: NSTextView {
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoRedoDidChange), name: name, object: textUndoManager)
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func undoRedoDidChange() { didChangeText() }
    @objc(undo:) func undoText(_ sender: Any?) { textUndoManager.undo() }
    @objc(redo:) func redoText(_ sender: Any?) { textUndoManager.redo() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undoText(_:)) { return textUndoManager.canUndo }
        if item.action == #selector(redoText(_:)) { return textUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoText(_:)) { return textUndoManager.canUndo }
        if menuItem.action == #selector(redoText(_:)) { return textUndoManager.canRedo }
        return super.validateMenuItem(menuItem)
    }
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTab: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift), !hasMarkedText() {
            onFinish?(); return
        }
        if event.keyCode == 53, !hasMarkedText() { onCancel?(); return }
        if event.keyCode == 48, !hasMarkedText() { onTab?(event.modifierFlags.contains(.shift)); return }
        super.keyDown(with: event)
    }
}

/// A separate target leaves the text itself available for caret placement and selection.
@MainActor
final class ScreenshotTextMoveHandle: NSControl {
    var onDown: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onUp: ((NSEvent) -> Void)?
    var onKey: ((NSEvent) -> Void)?
    private(set) var hovered = false
    private(set) var pressed = false
    override var isEnabled: Bool { didSet { if !isEnabled { pressed = false }; needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("Move text")
        setAccessibilityHelp("Drag to move this label. Focus and use arrow keys to move; Return edits the text.")
        toolTip = "Drag to move text · Arrow keys when focused · Return to edit"
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { pressed = false; needsDisplay = true; return true }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: pressed ? .closedHand : .openHand) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; needsDisplay = true; onDown?(event)
        window?.makeFirstResponder(self); window?.invalidateCursorRects(for: self)
    }
    override func mouseDragged(with event: NSEvent) { if isEnabled && pressed { onDrag?(event) } }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; needsDisplay = true; onUp?(event); window?.invalidateCursorRects(for: self)
    }
    override func keyDown(with event: NSEvent) { if isEnabled { onKey?(event) } }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        return window?.makeFirstResponder(self) ?? false
    }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        let active = isEnabled && (hovered || pressed)
        (pressed && isEnabled ? NSColor(white: 0.65, alpha: 1) : active ? NSColor(white: 0.86, alpha: 1) : NSColor.white).setFill()
        path.fill()
        (focused ? NSColor.keyboardFocusIndicatorColor : NSColor.black).setStroke()
        path.lineWidth = focused ? 3 : 1; path.stroke()
        if let icon = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.black]))
            icon.withSymbolConfiguration(config)?.draw(in: bounds.insetBy(dx: 7, dy: 7), from: .zero,
                                                       operation: .sourceOver, fraction: isEnabled ? 1 : 0.35)
        }
    }
}
