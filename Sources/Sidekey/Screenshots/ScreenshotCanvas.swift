import AppKit
import Carbon.HIToolbox

enum ScreenshotCommand: Hashable { case cancel, copy, copyText, download, share }

@MainActor
final class ScreenshotCanvas: NSView, NSTextViewDelegate {
    let source: CGImage
    let documentSize: CGSize
    var selection: CGRect = .zero
    var annotations: [ScreenshotAnnotation] = []
    var tool: ScreenshotTool = .select
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var blurMode = ScreenshotBlurMode.textAndNumbers
    var busy = false { didSet { if busy { finishTextEditing() }; updateTextHandle(); needsDisplay = true; onChange?() } }
    var busyMessage = "Processing on this Mac…"
    var message = ""
    var onChange: (() -> Void)?
    var onSelection: (() -> Void)?
    var onBlur: ((CGRect, ScreenshotBlurMode) -> Void)?
    var onCommand: ((ScreenshotCommand) -> Void)?
    let arrowBindings: @MainActor () -> ScreenshotArrowBindings

    private struct Snapshot { let selection: CGRect; let annotations: [ScreenshotAnnotation] }
    private var undoStates: [Snapshot] = [], redoStates: [Snapshot] = []
    private var start: CGPoint = .zero
    private var beforeDrag: Snapshot?
    private var drawing: ScreenshotAnnotation?
    private var movingAnnotation: UUID?
    private var selectedAnnotation: UUID?
    private var movingSelection = false
    private var creatingSelection = false
    private var resizeCorner: CGPoint?
    private var tracking: NSTrackingArea?
    private(set) var textEditor: ScreenshotInlineTextView?
    private(set) var textHandle: ScreenshotTextMoveHandle?
    private var editingText: UUID?
    private var beforeTextEditing: Snapshot?
    private var textTop: CGFloat = 0
    private var hoveredText: UUID?
    private var handleAnnotation: UUID?
    private var textSelectionAnchor: Int?
    var canUndo: Bool { !busy && !undoStates.isEmpty }
    var canRedo: Bool { !busy && !redoStates.isEmpty }

    init(image: CGImage, size: CGSize, arrowBindings: (@MainActor () -> ScreenshotArrowBindings)? = nil) {
        source = image; documentSize = size
        self.arrowBindings = arrowBindings ?? { HotkeyPreferences.shared.screenshotArrowBindings }
        super.init(frame: CGRect(origin: .zero, size: size))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screenshot selection and annotations")
        setAccessibilityHelp("Drag to select an area. Enter copies that area and closes the editor. Tools and export actions are in the floating toolbar.")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : tool == .select && !selection.isEmpty ? .arrow : .crosshair)
        if !busy, tool == .text || tool == .select {
            for annotation in annotations where annotation.tool == .text {
                let rect = ScreenshotTextLayout.frame(annotation).intersection(selection)
                if !rect.isEmpty && !rect.isNull { addCursorRect(rect, cursor: .iBeam) }
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredText = busy ? nil : annotations.last(where: { $0.tool == .text && hit($0, point: point) && selection.contains(point) })?.id
        if let textHandle, !textHandle.isHidden, textHandle.frame.insetBy(dx: -5, dy: -5).contains(point) {
            hoveredText = handleAnnotation
        }
        updateTextHandle(); needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hoveredText = nil; updateTextHandle(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(source, in: bounds)
        context.saveGState()
        if !selection.isEmpty { context.clip(to: selection) }
        for annotation in annotations where annotation.id != editingText { ScreenshotRenderer.draw(annotation, in: context, bounds: bounds) }
        if let drawing, drawing.tool != .blur { ScreenshotRenderer.draw(drawing, in: context, bounds: bounds) }
        context.restoreGState()
        if !busy, let id = editingText ?? hoveredText ?? selectedAnnotation,
           let annotation = annotations.first(where: { $0.id == id && $0.tool == .text }) {
            let frame = (textEditor?.frame ?? ScreenshotTextLayout.frame(annotation)).insetBy(dx: -2, dy: -2)
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: frame); outline.lineWidth = 3; outline.stroke()
            (editingText == id ? NSColor.controlAccentColor : NSColor.black).setStroke()
            outline.lineWidth = 1; outline.stroke()
        }
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill(); shade.fill()
        if !selection.isEmpty {
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
            if tool == .select {
                for corner in corners {
                    let handle = CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6)
                    NSColor.white.setFill(); NSBezierPath(rect: handle).fill()
                    NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: handle).stroke()
                }
            }
            if let drawing, drawing.tool == .blur {
                let path = NSBezierPath(rect: drawing.rect)
                path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
            }
        }
        let text = busy ? busyMessage : message
        (text as NSString).draw(at: CGPoint(x: 20, y: bounds.height - 38), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65)
        ])
    }

    private var corners: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)]
    }
    private func bounded(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }
    private func snapshot() -> Snapshot { Snapshot(selection: selection, annotations: annotations) }
    private func checkpoint(_ snapshot: Snapshot) {
        undoStates.append(snapshot); if undoStates.count > 40 { undoStates.removeFirst() }; redoStates.removeAll()
    }
    func commit(_ annotation: ScreenshotAnnotation) {
        checkpoint(snapshot()); annotations.append(annotation); selectedAnnotation = annotation.id
        updateTextHandle(); needsDisplay = true; onChange?()
    }
    func undo() {
        finishTextEditing()
        guard !busy, let state = undoStates.popLast() else { return }
        redoStates.append(snapshot()); restore(state)
    }
    func redo() {
        finishTextEditing()
        guard !busy, let state = redoStates.popLast() else { return }
        undoStates.append(snapshot()); restore(state)
    }
    private func restore(_ state: Snapshot) {
        selection = state.selection; annotations = state.annotations; selectedAnnotation = nil
        hoveredText = nil; updateTextHandle()
        if selection.isEmpty { tool = .select }
        needsDisplay = true; onSelection?(); onChange?()
    }
    func selectTool(_ value: ScreenshotTool) {
        guard !busy else { return }
        finishTextEditing()
        tool = value; selectedAnnotation = nil
        hoveredText = nil; updateTextHandle()
        message = ""
        window?.invalidateCursorRects(for: self); needsDisplay = true; onChange?()
    }

    override func mouseDown(with event: NSEvent) {
        guard !busy else { return }
        if selection.isEmpty { tool = .select }
        let point = bounded(convert(event.locationInWindow, from: nil), to: bounds)
        if selection.contains(point), tool == .text || tool == .select,
           let annotation = annotations.last(where: { $0.tool == .text && hit($0, point: point) }) {
            beginTextEditing(annotation: annotation)
            if let editor = textEditor {
                let index = editor.characterIndexForInsertion(at: editor.convert(event.locationInWindow, from: nil))
                editor.setSelectedRange(NSRange(location: index, length: 0)); textSelectionAnchor = index
            }
            return
        }
        finishTextEditing()
        window?.makeFirstResponder(self)
        start = point
        beforeDrag = snapshot(); movingSelection = false; creatingSelection = false; movingAnnotation = nil; resizeCorner = nil
        if selection.isEmpty || tool == .select {
            if let corner = corners.first(where: { hypot($0.x - start.x, $0.y - start.y) <= 10 }), !selection.isEmpty {
                resizeCorner = CGPoint(x: corner.x == selection.minX ? selection.maxX : selection.minX,
                                       y: corner.y == selection.minY ? selection.maxY : selection.minY)
            } else if let annotation = annotations.last(where: { hit($0, point: start) }), selection.contains(start) {
                selectedAnnotation = annotation.id
                if annotation.tool != .blur { movingAnnotation = annotation.id }
                else { message = "Blur selected · Delete to remove, or ⌘Z to undo" }
            } else if selection.contains(start) { movingSelection = true; selectedAnnotation = nil }
            else { selection = CGRect(origin: start, size: .zero); creatingSelection = true; selectedAnnotation = nil }
        } else if selection.contains(start) {
            if tool == .text {
                beforeDrag = nil
                beginTextEditing(at: start)
            } else if tool == .counter {
                let number = annotations.filter { $0.tool == .counter }.count + 1
                commit(ScreenshotAnnotation(tool: .counter, points: [start], color: color, text: String(number))); beforeDrag = nil
            } else {
                drawing = ScreenshotAnnotation(tool: tool, points: [start, start], color: color, width: lineWidth)
            }
        }
        updateTextHandle(); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let anchor = textSelectionAnchor, let editor = textEditor {
            let index = editor.characterIndexForInsertion(at: editor.convert(event.locationInWindow, from: nil))
            editor.setSelectedRange(NSRange(location: min(anchor, index), length: abs(index - anchor)))
            return
        }
        guard !busy, beforeDrag != nil else { return }
        let oldSelection = selection
        let oldDrawing = drawing?.rect
        let point = bounded(convert(event.locationInWindow, from: nil), to: bounds)
        if var annotation = drawing {
            let inside = bounded(point, to: selection)
            if annotation.tool == .pen { annotation.points.append(inside) }
            else { annotation.points = [start, inside] }
            drawing = annotation
        } else if let id = movingAnnotation, let original = beforeDrag?.annotations.first(where: { $0.id == id }),
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            var dx = point.x - start.x, dy = point.y - start.y
            if original.tool == .text {
                let frame = ScreenshotTextLayout.frame(original)
                dx = min(max(dx, selection.minX - frame.minX), max(0, selection.maxX - frame.maxX))
                dy = min(max(dy, selection.minY - frame.minY), max(0, selection.maxY - frame.maxY))
            }
            annotations[index].points = original.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        } else if let fixed = resizeCorner { selection = ScreenshotGeometry.rect(from: fixed, to: point) }
        else if movingSelection, let original = beforeDrag?.selection {
            let origin = CGPoint(x: min(max(0, original.minX + point.x - start.x), bounds.width - original.width),
                                 y: min(max(0, original.minY + point.y - start.y), bounds.height - original.height))
            selection = CGRect(origin: origin, size: original.size)
        } else if creatingSelection {
            // An immovable Blur is selection-only. Only an explicit crop gesture may replace the crop.
            selection = ScreenshotGeometry.rect(from: start, to: point)
        }
        updateTextHandle()
        if let drawing, let oldDrawing, ![.text, .counter].contains(drawing.tool) {
            let padding = max(20, drawing.width * 5)
            setNeedsDisplay(oldDrawing.union(drawing.rect).insetBy(dx: -padding, dy: -padding))
        } else if oldSelection != selection {
            setNeedsDisplay(oldSelection.union(selection).insetBy(dx: -12, dy: -12))
        } else { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        if textSelectionAnchor != nil { mouseDragged(with: event); textSelectionAnchor = nil; return }
        guard !busy, let before = beforeDrag else { return }
        mouseDragged(with: event)
        beforeDrag = nil
        if let annotation = drawing {
            drawing = nil
            if annotation.rect.width >= 2 || annotation.rect.height >= 2 {
                if annotation.tool == .blur { onBlur?(annotation.rect, blurMode) }
                else { commit(annotation) }
            }
        } else if let id = movingAnnotation {
            if before.annotations.first(where: { $0.id == id })?.points != annotations.first(where: { $0.id == id })?.points { checkpoint(before) }
        } else if before.selection != selection { checkpoint(before) }
        if selection.width < 2 || selection.height < 2 { selection = .zero }
        movingAnnotation = nil; movingSelection = false; creatingSelection = false; resizeCorner = nil
        updateTextHandle(); needsDisplay = true; onSelection?(); onChange?()
    }

    private func hit(_ annotation: ScreenshotAnnotation, point: CGPoint) -> Bool {
        if annotation.tool == .text, let anchor = annotation.points.first {
            return CGRect(origin: anchor, size: ScreenshotTextLayout.size(annotation)).insetBy(dx: -4, dy: -4).contains(point)
        }
        return annotation.rect.insetBy(dx: -10, dy: -10).contains(point)
    }

    private func beginTextEditing(at point: CGPoint) {
        let annotation = ScreenshotAnnotation(tool: .text, points: [point], color: color, width: lineWidth)
        beginTextEditing(annotation: annotation, isNew: true)
    }

    private func beginTextEditing(annotation: ScreenshotAnnotation, isNew: Bool = false) {
        finishTextEditing()
        beforeTextEditing = snapshot()
        var annotation = annotation
        if isNew {
            let height = ScreenshotTextLayout.size(annotation).height
            let point = annotation.points[0]
            annotation.points = [CGPoint(x: min(point.x, selection.maxX - min(24, selection.width)),
                                         y: max(selection.minY, point.y - height))]
            annotations.append(annotation)
        }
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        if annotation.textWidth == nil {
            annotation.textWidth = max(1, selection.maxX - annotation.points[0].x,
                                       isNew ? 0 : ScreenshotTextLayout.size(annotation).width)
        }
        annotations[index] = annotation
        editingText = annotation.id; selectedAnnotation = annotation.id; hoveredText = nil
        textTop = ScreenshotTextLayout.frame(annotation).maxY
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: annotation.textWidth!, height: 100_000))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let editor = ScreenshotInlineTextView(frame: .zero, textContainer: container)
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false; editor.textContainerInset = .zero
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: annotation.textWidth!, height: 100_000)
        editor.string = annotation.text
        editor.setAccessibilityLabel("Screenshot annotation text")
        editor.setAccessibilityHelp("Type directly on the screenshot. Shift-Return adds a line. Return copies and exits. Escape cancels this edit.")
        editor.onFinish = { [weak self] in self?.finishTextEditing(); self?.onCommand?(.copy) }
        editor.onCancel = { [weak self] in self?.finishTextEditing(cancel: true) }
        editor.onTab = { [weak self] backwards in
            self?.finishTextEditing()
            (self?.window as? ScreenshotCapturePanel)?.onAdvanceFocus?(backwards)
        }
        textEditor = editor; addSubview(editor)
        editor.delegate = self
        updateTextEditorStyle()
        window?.makeKey(); window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        updateTextHandle(); needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, notification.object as? NSTextView === editor,
              let index = annotations.firstIndex(where: { $0.id == editingText }) else { return }
        annotations[index].text = editor.string
        layoutTextEditor(); updateTextHandle(); needsDisplay = true
    }

    func updateTextEditorStyle() {
        guard let editor = textEditor, let index = annotations.firstIndex(where: { $0.id == editingText }) else { return }
        // Existing labels retain their own style until a text setting is explicitly changed.
        let annotation = annotations[index]
        let attributes = ScreenshotTextLayout.attributes(annotation)
        editor.typingAttributes = attributes
        editor.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertionPointColor = annotation.color
        layoutTextEditor(); updateTextHandle(); needsDisplay = true
    }

    func applyTextStyle() {
        guard let index = annotations.firstIndex(where: { $0.id == editingText }) else { return }
        annotations[index].color = color; annotations[index].width = lineWidth
        updateTextEditorStyle()
    }

    private func layoutTextEditor() {
        guard let editor = textEditor, let index = annotations.firstIndex(where: { $0.id == editingText }) else { return }
        let size = ScreenshotTextLayout.size(annotations[index])
        let origin = CGPoint(x: annotations[index].points[0].x, y: max(selection.minY, textTop - size.height))
        annotations[index].points = [origin]
        editor.frame = CGRect(origin: origin, size: CGSize(width: min(annotations[index].textWidth!, max(24, size.width + 3)), height: size.height))
    }

    /// Export and tool commands must include the live native editor before taking their snapshot.
    func finishTextEditing(cancel: Bool = false) {
        guard let id = editingText, let before = beforeTextEditing else { return }
        let editor = textEditor
        if !cancel, let index = annotations.firstIndex(where: { $0.id == id }), let editor {
            annotations[index].text = editor.string
            layoutTextEditor()
        }
        textEditor = nil; editingText = nil; beforeTextEditing = nil; textSelectionAnchor = nil
        editor?.delegate = nil
        if window?.firstResponder === editor { window?.makeFirstResponder(self) }
        editor?.removeFromSuperview()
        if cancel { annotations = before.annotations; selectedAnnotation = nil }
        else {
            annotations.removeAll { $0.id == id && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let old = before.annotations.first { $0.id == id }, new = annotations.first { $0.id == id }
            if old?.text != new?.text || old?.points != new?.points || old?.width != new?.width || old?.color != new?.color || old?.textWidth != new?.textWidth {
                checkpoint(before)
            }
            selectedAnnotation = new?.id
        }
        updateTextHandle(); window?.invalidateCursorRects(for: self); needsDisplay = true; onChange?()
    }

    private func updateTextHandle() {
        let id = editingText ?? hoveredText ?? selectedAnnotation
        guard !busy, let annotation = annotations.first(where: { $0.id == id && $0.tool == .text }),
              !selection.isEmpty else {
            if let textHandle, window?.firstResponder === textHandle { window?.makeFirstResponder(self) }
            textHandle?.isEnabled = false; textHandle?.isHidden = true; handleAnnotation = nil; return
        }
        let handle: ScreenshotTextMoveHandle
        if let textHandle { handle = textHandle }
        else {
            handle = ScreenshotTextMoveHandle(frame: .zero); textHandle = handle; addSubview(handle)
            handle.onDown = { [weak self] event in
                guard let self, let id = self.handleAnnotation else { return }
                self.finishTextEditing()
                self.selectedAnnotation = id; self.movingAnnotation = id
                self.start = self.convert(event.locationInWindow, from: nil); self.beforeDrag = self.snapshot()
            }
            handle.onDrag = { [weak self] in self?.mouseDragged(with: $0) }
            handle.onUp = { [weak self] in self?.mouseUp(with: $0) }
            handle.onKey = { [weak self] in self?.handleTextMoveKey($0) }
        }
        handleAnnotation = annotation.id
        let rect = textEditor?.frame ?? ScreenshotTextLayout.frame(annotation)
        var origin = CGPoint(x: rect.minX - 30, y: rect.maxY - 28)
        if origin.x < bounds.minX {
            if rect.maxX + 32 <= bounds.maxX { origin.x = rect.maxX + 4 }
            else if rect.maxY + 32 <= bounds.maxY { origin = CGPoint(x: rect.minX, y: rect.maxY + 4) }
            else { origin = CGPoint(x: rect.minX, y: rect.minY - 32) }
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - 28))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - 28))
        handle.frame = CGRect(origin: origin, size: CGSize(width: 28, height: 28))
        handle.isHidden = false; handle.isEnabled = !busy
        // Keep the handle above the text editor when an existing label is reopened.
        if subviews.last !== handle { addSubview(handle, positioned: .above, relativeTo: textEditor) }
    }

    private func handleTextMoveKey(_ event: NSEvent) {
        guard !busy, let index = annotations.firstIndex(where: { $0.id == handleAnnotation }) else { return }
        if [36, 76].contains(event.keyCode) { beginTextEditing(annotation: annotations[index]); return }
        if event.keyCode == 53 { window?.makeFirstResponder(self); cancelOperation(nil); return }
        if event.keyCode == 48 { (window as? ScreenshotCapturePanel)?.onAdvanceFocus?(event.modifierFlags.contains(.shift)); return }
        if [51, 117].contains(event.keyCode) { keyDown(with: event); return }
        guard [123, 124, 125, 126].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return }
        let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let rect = ScreenshotTextLayout.frame(annotations[index])
        let dx = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
        let dy = event.keyCode == 125 ? -amount : event.keyCode == 126 ? amount : 0
        let point = CGPoint(x: min(max(rect.minX + dx, selection.minX), max(selection.minX, selection.maxX - rect.width)),
                            y: min(max(rect.minY + dy, selection.minY), max(selection.minY, selection.maxY - rect.height)))
        guard point != annotations[index].points[0] else { return }
        checkpoint(snapshot()); annotations[index].points = [point]
        updateTextHandle(); needsDisplay = true; onChange?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if [36, 76].contains(event.keyCode), let handle = window?.firstResponder as? ScreenshotTextMoveHandle {
            handle.keyDown(with: event); return true
        }
        if [36, 76].contains(event.keyCode), !(window?.firstResponder is NSTextView) {
            keyDown(with: event); return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !(window?.firstResponder is NSTextView), modifiers == .command || modifiers == [.command, .shift] else { return super.performKeyEquivalent(with: event) }
        // The physical Z key also produces я in Russian. Command dispatch can
        // reach a nonactivating panel without a main-menu key-equivalent pass.
        // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
        if event.keyCode == UInt16(kVK_ANSI_Z) {
            modifiers.contains(.shift) ? redo() : undo(); return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": onCommand?(.copy); return true
        case "s": if !busy { onCommand?(.download) }; return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if textEditor != nil { finishTextEditing(cancel: true) }
        else if movingAnnotation != nil, let beforeDrag {
            self.beforeDrag = nil; movingAnnotation = nil; restore(beforeDrag)
        }
        else if drawing != nil { drawing = nil; beforeDrag = nil; needsDisplay = true }
        else { onCommand?(.cancel) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            (window as? ScreenshotCapturePanel)?.onAdvanceFocus?(event.modifierFlags.contains(.shift))
            return
        }
        if event.keyCode == 53 { cancelOperation(nil); return }
        if [36, 76].contains(event.keyCode) {
            guard !selection.isEmpty else { return }
            onCommand?(.copy)
            return
        }
        if let arrow = ScreenshotArrow(keyCode: event.keyCode),
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            let action = arrowBindings()[arrow]
            if action != .moveCrop {
                // Holding an export key must not execute the same command repeatedly.
                if !event.isARepeat { perform(action) }
                return
            }
        }
        guard !busy else { return }
        if [51, 117].contains(event.keyCode), let id = selectedAnnotation {
            checkpoint(snapshot()); annotations.removeAll { $0.id == id }; selectedAnnotation = nil
            hoveredText = nil; updateTextHandle(); needsDisplay = true; onChange?(); return
        }
        if [123, 124, 125, 126].contains(event.keyCode), !selection.isEmpty {
            checkpoint(snapshot())
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
            let dy: CGFloat = event.keyCode == 125 ? -amount : event.keyCode == 126 ? amount : 0
            if event.modifierFlags.contains(.option) {
                selection.size.width = min(bounds.maxX - selection.minX, max(2, selection.width + dx))
                selection.size.height = min(bounds.maxY - selection.minY, max(2, selection.height + dy))
            } else {
                selection.origin.x = min(max(0, selection.minX + dx), bounds.width - selection.width)
                selection.origin.y = min(max(0, selection.minY + dy), bounds.height - selection.height)
            }
            needsDisplay = true; onSelection?(); return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), let entry = ScreenshotEditorKeys.tools.first(where: { $0.key == key }) { selectTool(entry.tool) }
        // The window forwards editor keys here. Bubbling an unknown key back
        // to that window re-enters this method until the stack overflows.
        // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    }

    private func perform(_ action: ScreenshotEditorAction) {
        if action == .cancel { cancelOperation(nil); return }
        guard !busy else { return }
        guard beforeDrag == nil else { return }
        if let tool = action.tool { selectTool(tool); return }
        switch action {
        case .undo: undo()
        case .redo: redo()
        case .copy: if !selection.isEmpty { onCommand?(.copy) }
        case .copyText: if !selection.isEmpty { onCommand?(.copyText) }
        case .download: if !selection.isEmpty { onCommand?(.download) }
        case .share: if !selection.isEmpty { onCommand?(.share) }
        case .cancel: cancelOperation(nil)
        case .deleteAnnotation:
            guard let id = selectedAnnotation else { return }
            checkpoint(snapshot()); annotations.removeAll { $0.id == id }; selectedAnnotation = nil
            hoveredText = nil; updateTextHandle(); needsDisplay = true; onChange?()
        default: break
        }
    }
}
