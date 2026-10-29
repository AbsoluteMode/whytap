import AppKit

@MainActor
private final class ScreenshotColorWell: NSColorWell {
    private var previousLevel: NSWindow.Level?
    override func activate(_ exclusive: Bool) {
        if previousLevel == nil { previousLevel = NSColorPanel.shared.level }
        NSColorPanel.shared.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        super.activate(exclusive)
    }
    override func deactivate() {
        super.deactivate()
        if let previousLevel { NSColorPanel.shared.level = previousLevel }
        previousLevel = nil
    }
}

/// A separate accessory surface; tool choices and finish actions stay on the main bar.
@MainActor
final class ScreenshotToolSettings: NSView {
    weak var canvas: ScreenshotCanvas?
    var onCommand: ((ScreenshotCommand) -> Void)?
    private let stack = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let mode = MacPopupButton()
    private let shape = MacPopupButton()
    private let width = MacPopupButton()
    private let color = ScreenshotColorWell()
    private var currentTool: ScreenshotTool?
    private let defaults: UserDefaults
    private var hoverFeedback: [ScreenshotSettingHover] = []
    var focusableControls: [NSControl] { [color as NSControl, width, shape, mode].filter { $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor } }

    init(canvas: ScreenshotCanvas, defaults: UserDefaults = .standard) {
        self.canvas = canvas; self.defaults = defaults
        super.init(frame: .zero)
        ScreenshotToolbarSurface.install(in: self)
        stack.orientation = .vertical; stack.spacing = 7; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let row = NSStackView(); row.spacing = 8; row.alignment = .centerY
        stack.addArrangedSubview(row)
        title.font = .systemFont(ofSize: 12, weight: .medium); title.textColor = .secondaryLabelColor
        row.addArrangedSubview(title)
        color.target = self; color.action = #selector(updateSettings(_:))
        color.setAccessibilityLabel("Annotation color"); color.toolTip = "Annotation color"
        color.widthAnchor.constraint(equalToConstant: 32).isActive = true
        color.heightAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(color)
        width.addItems(withTitles: ["2 pt", "3 pt", "5 pt", "8 pt"])
        width.target = self; width.action = #selector(updateSettings(_:)); width.setAccessibilityLabel("Line width")
        width.toolTip = "Line width"; row.addArrangedSubview(width)
        shape.addItems(withTitles: ["Rectangle", "Oval"])
        shape.target = self; shape.action = #selector(updateSettings(_:)); shape.setAccessibilityLabel("Shape")
        shape.toolTip = "Shape"; row.addArrangedSubview(shape)
        mode.addItems(withTitles: ScreenshotBlurMode.allCases.map(\.rawValue))
        mode.target = self; mode.action = #selector(updateSettings(_:)); mode.setAccessibilityLabel("What to blur")
        mode.toolTip = "What to blur"; row.addArrangedSubview(mode)
        row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10).isActive = true
        hoverFeedback = [color as NSControl, width, shape, mode].map(ScreenshotSettingHover.init)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    func closeAuxiliaryWindows() {
        if color.isActive { color.deactivate(); NSColorPanel.shared.orderOut(nil) }
    }
    func refresh() {
        guard let canvas else { return }
        let tool = canvas.tool
        if currentTool != tool {
            closeAuxiliaryWindows()
            currentTool = tool
            let saved = defaults.array(forKey: "sidekey.screenshot.color.\(tool.rawValue)") as? [Double]
            color.color = saved?.count == 4 ? NSColor(srgbRed: saved![0], green: saved![1], blue: saved![2], alpha: saved![3]) : .systemRed
            width.selectItem(at: min(3, max(0, defaults.object(forKey: "sidekey.screenshot.width.\(tool.rawValue)") as? Int ?? 1)))
            canvas.color = color.color; canvas.lineWidth = [2, 3, 5, 8][width.indexOfSelectedItem]
        }
        title.stringValue = tool == .ellipse || tool == .rectangle ? "Shape" : tool == .counter ? "Steps" : tool.rawValue.capitalized
        isHidden = tool == .select
        color.isHidden = [.select, .blur].contains(tool)
        width.isHidden = ![.arrow, .rectangle, .ellipse, .pen, .text].contains(tool)
        shape.isHidden = tool != .rectangle && tool != .ellipse
        shape.selectItem(at: tool == .ellipse ? 1 : 0)
        mode.isHidden = tool != .blur; mode.selectItem(withTitle: canvas.blurMode.rawValue)
        for control in [color as NSControl, width, shape, mode] { control.isEnabled = !canvas.busy }
        hoverFeedback.forEach { $0.refresh() }
        layoutSubtreeIfNeeded()
    }
    @objc private func updateSettings(_ sender: Any?) {
        guard let canvas else { return }
        canvas.color = color.color; canvas.lineWidth = [2, 3, 5, 8][max(0, width.indexOfSelectedItem)]
        if canvas.tool == .text { canvas.applyTextStyle() }
        canvas.blurMode = ScreenshotBlurMode.allCases[max(0, mode.indexOfSelectedItem)]
        if sender as? NSPopUpButton === shape {
            canvas.selectTool(shape.indexOfSelectedItem == 0 ? .rectangle : .ellipse)
        }
        if let rgb = color.color.usingColorSpace(.sRGB) {
            defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent], forKey: "sidekey.screenshot.color.\(canvas.tool.rawValue)")
        }
        defaults.set(width.indexOfSelectedItem, forKey: "sidekey.screenshot.width.\(canvas.tool.rawValue)")
    }
}

/// Adds whole-control hover feedback while retaining native popup/text/focus behavior.
@MainActor
private final class ScreenshotSettingHover: NSObject {
    private weak var control: NSControl?
    private var hovered = false
    init(_ control: NSControl) {
        self.control = control
        super.init()
        control.wantsLayer = true
        control.layer?.cornerRadius = 5
        control.addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    @objc func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    @objc func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    func refresh() {
        control?.layer?.borderWidth = 1
        control?.layer?.borderColor = hovered && control?.isEnabled == true ? NSColor.labelColor.withAlphaComponent(0.4).cgColor : NSColor.clear.cgColor
    }
}
