import AppKit
import SwiftUI

/// Native button tracking/focus/pressed states, with an explicit whole-button hover.
@MainActor
final class ScreenshotToolbarButton: NSButton, NSDraggingSource {
    static let actionPasteboardType = NSPasteboard.PasteboardType("com.rootwise.sidekey.screenshot-action")
    var dragAction: ScreenshotEditorAction?
    var assignmentArrow: ScreenshotArrow?
    var onDropAction: ((ScreenshotEditorAction) -> Bool)? {
        didSet { registerForDraggedTypes(onDropAction == nil ? [] : [Self.actionPasteboardType]) }
    }
    private var dropHovered = false
    var isPrimaryAction = false
    var showsReturnKeycap = false {
        didSet {
            returnHint?.removeFromSuperview(); returnHint = nil
            if showsReturnKeycap {
                let hint = ScreenshotKeycapHostingView(rootView:
                    HotkeyHintView(contents: [.symbol("return", accessibilityLabel: "Return key")], style: .keycaps)
                        .accessibilityHidden(true))
                hint.identifier = NSUserInterfaceItemIdentifier("screenshot.return-keycap")
                hint.alphaValue = isEnabled ? 1 : 0.45
                addSubview(hint); returnHint = hint
            }
            invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true
        }
    }
    private var returnHint: NSView?
    private var keycapSize: CGSize { returnHint?.fittingSize ?? CGSize(width: 22, height: 22) }
    private var labelSize: CGSize { (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]) }
    override var intrinsicContentSize: NSSize {
        guard showsReturnKeycap else { return super.intrinsicContentSize }
        return NSSize(width: ceil(labelSize.width) + 8 + keycapSize.width + 20, height: max(30, keycapSize.height + 8))
    }
    override func layout() {
        super.layout()
        guard let returnHint else { return }
        let size = keycapSize, groupWidth = labelSize.width + 8 + size.width
        returnHint.frame = CGRect(x: bounds.midX + groupWidth / 2 - size.width,
                                  y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    override var acceptsFirstResponder: Bool { isEnabled }

    // Track the native down/drag/up sequence so a drag never also clicks the
    // source tool or opens an assignment menu on release.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let dragAction, let window else { super.mouseDown(with: event); return }
        trackMousePress(event, in: window, dragAction: dragAction, nextEvent: {
            window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture,
                             inMode: .eventTracking, dequeue: true)
        }, canContinue: { [weak self, weak window] in
            guard let self, let window else { return false }
            return self.isEnabled && self.window === window && window.isVisible
        })
    }

    /// The event source and liveness check are injectable for unshown native
    /// regressions; production uses only this window's normal tracking queue.
    func trackMousePress(_ event: NSEvent, in window: NSWindow, dragAction: ScreenshotEditorAction,
                         nextEvent: () -> NSEvent?, canContinue: () -> Bool) {
        window.makeFirstResponder(self)
        highlight(true)
        defer { highlight(false) }
        while let next = nextEvent() {
            guard canContinue() else { return }
            if next.type == .keyDown {
                // A keyboard command cancels the pending mouse click before
                // dispatch. Escape can never leave a delayed Copy/Download.
                highlight(false)
                if next.keyCode == 53 { window.cancelOperation(self) }
                else { window.sendEvent(next) }
                return
            }
            let point = convert(next.locationInWindow, from: nil)
            let inside = bounds.contains(point)
            if next.type == .leftMouseUp {
                if inside, let action { NSApp.sendAction(action, to: target, from: self) }
                return
            }
            highlight(inside)
            if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) >= 4 {
                let item = NSPasteboardItem()
                item.setString(dragAction.dragPayload, forType: Self.actionPasteboardType)
                let drag = NSDraggingItem(pasteboardWriter: item)
                drag.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: dragAction.symbol, accessibilityDescription: dragAction.title))
                highlight(false)
                beginDraggingSession(with: [drag], event: next, source: self)
                return
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    @discardableResult
    func acceptAssignment(from pasteboard: NSPasteboard) -> Bool {
        guard isEnabled, let raw = pasteboard.string(forType: Self.actionPasteboardType),
              let action = ScreenshotEditorAction(dragPayload: raw) else { return false }
        return onDropAction?(action) == true
    }
    private func dragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let raw = sender.draggingPasteboard.string(forType: Self.actionPasteboardType)
        dropHovered = isEnabled && onDropAction != nil && bounds.contains(point)
            && raw.flatMap(ScreenshotEditorAction.init(dragPayload:)) != nil
        needsDisplay = true
        return dropHovered ? .copy : []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHovered = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dragOperation(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard dragOperation(sender) == .copy else { return false }
        defer { dropHovered = false; needsDisplay = true }
        return acceptAssignment(from: sender.draggingPasteboard)
    }


    override var isEnabled: Bool {
        didSet {
            if !title.isEmpty {
                attributedTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: isEnabled ? NSColor.labelColor : .disabledControlTextColor,
                    .font: font ?? NSFont.systemFont(ofSize: 13)
                ])
            }
            returnHint?.alphaValue = isEnabled ? 1 : 0.45
            needsDisplay = true
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if assignmentArrow != nil {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            let active = isEnabled && (hovered || isHighlighted || dropHovered)
            (active ? NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.28 : 0.16) : NSColor.labelColor.withAlphaComponent(isEnabled ? 0.035 : 0.015)).setFill()
            path.fill()
            // Keep the grouping boundary above 3:1 after the render's ICC profile is converted to sRGB.
            let idleBorder = NSColor.secondaryLabelColor.blended(withFraction: 0.15, of: .labelColor) ?? .labelColor
            (isEnabled ? (active ? NSColor.controlAccentColor : idleBorder) : .disabledControlTextColor).setStroke()
            path.lineWidth = dropHovered && isEnabled ? 1.8 : 1
            path.stroke()
            let foreground = isEnabled ? NSColor.labelColor : .disabledControlTextColor
            if let symbol = image?.withSymbolConfiguration(.init(paletteColors: [foreground])) {
                let center = CGPoint(x: 15, y: bounds.midY)
                let scale = min(16 / symbol.size.width, 16 / symbol.size.height)
                let rect = CGRect(x: center.x - symbol.size.width * scale / 2, y: center.y - symbol.size.height * scale / 2,
                                  width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return
        }
        var primaryForeground = NSColor.labelColor
        if isPrimaryAction {
            var background = isEnabled ? NSColor.controlAccentColor : .quaternaryLabelColor
            if isEnabled && (hovered || isHighlighted) {
                background = background.blended(withFraction: isHighlighted ? 0.16 : 0.08, of: .labelColor) ?? background
            }
            background.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
            if let rgb = background.usingColorSpace(.sRGB) {
                let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                    $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
                }
                let luminance = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
                primaryForeground = 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05 ? .white : .black
            }
        } else if isBordered { super.draw(dirtyRect) }
        if !isPrimaryAction && isEnabled && (hovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        guard isPrimaryAction || !isBordered, let cell = cell as? NSButtonCell else { return }
        // Inline cells dim unselected content even when enabled. Draw semantic
        // foregrounds at full opacity so the expanded toolbar stays readable.
        let foreground = isEnabled ? (isPrimaryAction ? primaryForeground : NSColor.labelColor) : .disabledControlTextColor
        if let image {
            let symbol = image.withSymbolConfiguration(.init(paletteColors: [foreground])) ?? image
            let available = imagePosition == .imageOnly ? bounds.insetBy(dx: 6, dy: 6) : cell.imageRect(forBounds: bounds)
            let scale = min(available.width / symbol.size.width, available.height / symbol.size.height)
            let rect = CGRect(x: available.midX - symbol.size.width * scale / 2,
                              y: available.midY - symbol.size.height * scale / 2,
                              width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver,
                        fraction: 1, respectFlipped: true, hints: nil)
        }
        if showsReturnKeycap {
            let size = labelSize, groupWidth = size.width + 8 + keycapSize.width
            (title as NSString).draw(at: CGPoint(x: bounds.midX - groupWidth / 2, y: bounds.midY - size.height / 2),
                                    withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground])
        } else if !title.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (title as NSString).draw(in: cell.titleRect(forBounds: bounds), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground,
                .paragraphStyle: paragraph
            ])
        }
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}


/// The keycap is a hint within the button's single hit/focus area.
@MainActor
private final class ScreenshotKeycapHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
