import AppKit
import Combine
import SwiftUI

/// Assignment controls live with the screenshot tools. They never execute an
/// export on click: the physical arrows run actions; clicking changes a binding.
@MainActor
final class ScreenshotArrowCluster: NSView {
    // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md — grouped shortcut revision.
    static let size = CGSize(width: 261, height: 30)
    private static let order: [ScreenshotArrow] = [.up, .left, .right, .down]
    private let preferences: HotkeyPreferences
    private var observation: AnyCancellable?
    private var hints: [ScreenshotArrow: NSView] = [:]
    private(set) var buttons: [ScreenshotArrow: ScreenshotToolbarButton] = [:]
    var isEnabled = true {
        didSet {
            for (direction, button) in buttons {
                button.isEnabled = isEnabled
                hints[direction]?.alphaValue = isEnabled ? 1 : 0.45
                button.menu?.items.filter { !$0.isSeparatorItem }.forEach { $0.isEnabled = isEnabled }
            }
        }
    }
    var focusableControls: [NSControl] { [.up, .left, .right, .down].compactMap { buttons[$0] }.filter(\.isEnabled) }

    init(preferences: HotkeyPreferences) {
        self.preferences = preferences
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        setAccessibilityElement(false)
        for direction in Self.order {
            let button = ScreenshotToolbarButton(title: "", target: self, action: #selector(showAssignments(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(direction.rawValue)
            button.assignmentArrow = direction
            button.isBordered = false; button.imagePosition = .imageOnly; button.focusRingType = .exterior
            button.onDropAction = { [weak self] action in
                guard let self, self.isEnabled else { return false }
                self.preferences.screenshotArrowBindings[direction] = action
                return true
            }
            let hint = ScreenshotArrowKeycapHostingView(rootView:
                HotkeyHintView(contents: [.text(direction.glyph)], style: .keycaps).accessibilityHidden(true))
            hint.identifier = NSUserInterfaceItemIdentifier("screenshot.arrow-keycap.\(direction.rawValue)")
            button.addSubview(hint)
            addSubview(button); hints[direction] = hint; buttons[direction] = button
        }
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
        observation = preferences.$screenshotArrowBindings.sink { [weak self] in self?.refresh($0) }
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { Self.size }
    override func layout() {
        super.layout()
        for (index, direction) in Self.order.enumerated() {
            buttons[direction]?.frame = CGRect(x: index * 68, y: 0, width: 57, height: 30)
            hints[direction]?.frame = CGRect(x: 31, y: 4, width: 22, height: 22)
        }
    }

    private func refresh(_ bindings: ScreenshotArrowBindings) {
        for (direction, button) in buttons {
            let action = bindings[direction]
            button.dragAction = action
            button.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            button.setAccessibilityLabel("\(direction.glyph) \(action.title) — change assignment")
            button.setAccessibilityValue(action.title)
            button.toolTip = "\(direction.glyph): \(action.title). Drag a toolbar tool here to replace this action, drag this assignment to another shortcut, or click to choose. Changes save immediately."
            button.setAccessibilityHelp(button.toolTip)
            let menu = NSMenu(title: "\(direction.glyph) arrow")
            menu.autoenablesItems = false
            for candidate in ScreenshotEditorAction.allCases {
                let item = NSMenuItem(title: candidate.title, action: #selector(assign(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = [direction.rawValue, candidate.rawValue]
                item.image = NSImage(systemSymbolName: candidate.symbol, accessibilityDescription: nil)
                item.state = candidate == action ? .on : .off
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let reset = NSMenuItem(title: "Reset this arrow", action: #selector(assign(_:)), keyEquivalent: "")
            reset.target = self; reset.representedObject = [direction.rawValue, ScreenshotArrowBindings.defaults[direction].rawValue]
            reset.isEnabled = isEnabled
            menu.addItem(reset); button.menu = menu; button.needsDisplay = true
        }
    }
    @objc private func showAssignments(_ sender: NSButton) {
        guard isEnabled, let menu = sender.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY), in: sender)
    }
    @objc private func assign(_ sender: NSMenuItem) {
        guard isEnabled, let parts = sender.representedObject as? [String], parts.count == 2,
              let direction = ScreenshotArrow(rawValue: parts[0]), let action = ScreenshotEditorAction(rawValue: parts[1]) else { return }
        preferences.screenshotArrowBindings[direction] = action
    }
}

/// The hint belongs to its assignment button's single click and focus target.
@MainActor
private final class ScreenshotArrowKeycapHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
