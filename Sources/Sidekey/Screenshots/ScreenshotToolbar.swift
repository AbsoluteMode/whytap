import AppKit

@MainActor
final class ScreenshotToolbar: NSView {
    weak var canvas: ScreenshotCanvas?
    var onCommand: ((ScreenshotCommand) -> Void)?
    var onLayout: (() -> Void)?
    let toolSettings: ScreenshotToolSettings
    let arrowCluster: ScreenshotArrowCluster
    private let rows = NSStackView()
    private var controls: [NSView] = []
    private var tools: [ScreenshotTool: NSButton] = [:]
    private var commands: [ScreenshotCommand: NSButton] = [:]
    private var undoButton: ScreenshotToolbarButton!
    private var redoButton: ScreenshotToolbarButton!
    private var availableWidth: CGFloat = 0
    private var layoutTool: ScreenshotTool?
    var focusableControls: [NSControl] {
        controls.flatMap { view -> [NSControl] in
            if view === arrowCluster { return arrowCluster.focusableControls }
            return (view as? NSControl).map { [$0] } ?? []
        }.filter { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
    }

    init(canvas: ScreenshotCanvas, defaults: UserDefaults = .standard, arrowPreferences: HotkeyPreferences? = nil) {
        self.canvas = canvas
        toolSettings = ScreenshotToolSettings(canvas: canvas, defaults: defaults)
        arrowCluster = ScreenshotArrowCluster(preferences: arrowPreferences ?? .shared)
        super.init(frame: .zero)
        ScreenshotToolbarSurface.install(in: self)
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 6, left: 7, bottom: 6, right: 7)
        rows.translatesAutoresizingMaskIntoConstraints = false; addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor), rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor), rows.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        controls += [arrowCluster, separator()]
        for (tool, symbol, title, help) in [
            (ScreenshotTool.arrow, "arrow.up.right", "", "Arrow · A — point to a detail"),
            (.rectangle, "rectangle", "", "Shape · R / O — draw a rectangle or oval"),
            (.pen, "pencil", "", "Pen · P — draw freehand"),
            (.text, "textformat", "", "Text · T — click anywhere in the selection and type; drag a label’s handle to move it"),
            (.blur, "", "Blur", "Blur · B — blur text and numbers or an entire area"),
            (.counter, "number.circle", "", "Numbered steps · N — place consecutive step numbers")
        ] {
            let button = makeButton(symbol: symbol, title: title, help: help, action: #selector(chooseTool(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.dragAction = ScreenshotEditorAction(rawValue: tool.rawValue)
            button.toolTip = help + ". Click again to stop drawing and adjust the selection or annotations. Drag onto an arrow to assign."
            button.setButtonType(.toggle); controls.append(button); tools[tool] = button
        }
        controls.append(separator())
        for (command, symbol, help) in [
            (ScreenshotCommand.copyText, "doc.text.viewfinder", "Copy text — recognize text and numbers on this Mac, copy and exit"),
            (.share, "square.and.arrow.up", "Share — send the edited screenshot using macOS")
        ] {
            let button = makeButton(symbol: symbol, help: help, action: #selector(command(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("command.\(command)")
            button.dragAction = command == .copyText ? .copyText : .share
            controls.append(button); commands[command] = button
        }
        controls.append(separator())
        undoButton = makeButton(symbol: "arrow.uturn.backward", help: "Undo · ⌘Z — undo the last screenshot edit", action: #selector(undo(_:)))
        redoButton = makeButton(symbol: "arrow.uturn.forward", help: "Redo · ⇧⌘Z — restore the last undone edit", action: #selector(redo(_:)))
        undoButton.dragAction = .undo; redoButton.dragAction = .redo
        controls += [undoButton, redoButton, separator()]
        let download = makeButton(symbol: "arrow.down.to.line", help: "Download to Downloads · ⌘S — save PNG and keep editing", action: #selector(command(_:)))
        download.dragAction = .download
        commands[.download] = download; controls.append(download)
        let copy = ScreenshotToolbarButton(title: "Copy & exit", target: self, action: #selector(command(_:)))
        copy.bezelStyle = .rounded; copy.bezelColor = .controlAccentColor; copy.focusRingType = .exterior
        copy.isPrimaryAction = true; copy.font = .systemFont(ofSize: 13, weight: .semibold)
        copy.showsReturnKeycap = true
        copy.dragAction = .copy
        copy.setAccessibilityLabel("Copy screenshot and exit"); copy.toolTip = "Copy screenshot and close editor · Enter / Return / ⌘C"
        copy.setAccessibilityHelp(copy.toolTip)
        commands[.copy] = copy; controls.append(copy)
        let cancel = makeButton(symbol: "xmark", help: "Cancel capture · Esc — close without copying", action: #selector(command(_:)))
        cancel.dragAction = .cancel
        commands[.cancel] = cancel; controls.append(cancel)
        toolSettings.onCommand = { [weak self] command in self?.onCommand?(command) }
        configure(availableWidth: 1200)
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    /// Wrap controls without hiding commands or shrinking their hit areas.
    func configure(availableWidth: CGFloat) {
        let width = max(240, availableWidth - 16)
        guard self.availableWidth != width else { return }
        self.availableWidth = width
        for control in controls { control.removeFromSuperview() }
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        var row = makeRow(), used: CGFloat = 0
        for control in controls {
            let controlWidth = ceil(control.fittingSize.width) + 1
            let separator = control is NSBox
            if used > 0 && used + 3 + controlWidth > width - 14 {
                if let last = row.arrangedSubviews.last, last is NSBox {
                    row.removeArrangedSubview(last); last.removeFromSuperview()
                }
                row = makeRow(); used = 0
            }
            if separator && used == 0 { continue }
            row.addArrangedSubview(control)
            used += (used == 0 ? 0 : 3) + controlWidth
        }
    }
    private func makeRow() -> NSStackView {
        let row = NSStackView(); row.spacing = 3; row.alignment = .centerY
        rows.addArrangedSubview(row)
        row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -7).isActive = true
        return row
    }
    func closeAuxiliaryWindows() { toolSettings.closeAuxiliaryWindows() }
    func refresh() {
        guard let canvas else { return }
        arrowCluster.isEnabled = !canvas.busy
        for (kind, button) in tools {
            if kind == .rectangle {
                (button as? ScreenshotToolbarButton)?.dragAction = canvas.tool == .ellipse ? .ellipse : .rectangle
            }
            button.state = canvas.tool == kind || (kind == .rectangle && canvas.tool == .ellipse) ? .on : .off
            button.isEnabled = !canvas.busy
            button.contentTintColor = button.isEnabled ? .labelColor : .disabledControlTextColor
            button.wantsLayer = true; button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = button.state == .on ? NSColor.controlAccentColor.withAlphaComponent(button.isEnabled ? 0.16 : 0.06).cgColor : NSColor.clear.cgColor
        }
        undoButton.isEnabled = canvas.canUndo; redoButton.isEnabled = canvas.canRedo
        for (command, button) in commands {
            button.isEnabled = command == .cancel || (!canvas.busy && !canvas.selection.isEmpty)
        }
        toolSettings.refresh()
        if layoutTool != canvas.tool {
            layoutTool = canvas.tool; onLayout?()
        }
    }
    private func makeButton(symbol: String, title: String = "", help: String, action: Selector) -> ScreenshotToolbarButton {
        let button = ScreenshotToolbarButton(title: title, target: self, action: action)
        button.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = symbol.isEmpty ? .noImage : title.isEmpty ? .imageOnly : .imageLeading
        button.bezelStyle = .inline; button.isBordered = false; button.focusRingType = .exterior
        button.toolTip = help; button.setAccessibilityLabel(help.components(separatedBy: " — ")[0])
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: title.isEmpty ? 30 : 60).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    private func separator() -> NSView {
        let view = NSBox(); view.boxType = .separator
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }
    @objc private func chooseTool(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let tool = ScreenshotTool(rawValue: value) else { return }
        guard let canvas else { return }
        let isCurrent = canvas.tool == tool || (tool == .rectangle && canvas.tool == .ellipse)
        canvas.selectTool(isCurrent ? .select : tool)
        canvas.window?.makeKey(); canvas.window?.makeFirstResponder(canvas)
    }
    @objc private func undo(_ sender: Any?) { canvas?.undo() }
    @objc private func redo(_ sender: Any?) { canvas?.redo() }
    @objc private func command(_ sender: NSButton) {
        guard let command = commands.first(where: { $0.value === sender })?.key else { return }
        onCommand?(command)
    }
}

@MainActor
enum ScreenshotToolbarSurface {
    static func install(in view: NSView) {
        let material = NSVisualEffectView()
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 13
        material.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(material)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: view.leadingAnchor), material.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            material.topAnchor.constraint(equalTo: view.topAnchor), material.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
