import AppKit
import ApplicationServices
import CoreGraphics

struct TextInserter {
    private let pasteHandler: @MainActor (String) -> Void
    private let replaceSelectionHandler: @MainActor (String) -> Bool

    init(
        paste: @escaping @MainActor (String) -> Void = SystemTextInsertion.paste,
        replaceSelection: @escaping @MainActor (String) -> Bool = SystemTextInsertion.replaceSelection
    ) {
        self.pasteHandler = paste
        self.replaceSelectionHandler = replaceSelection
    }

    @MainActor
    func paste(_ text: String) {
        pasteHandler(text)
    }

    @MainActor
    func replaceSelection(with text: String) -> Bool {
        replaceSelectionHandler(text)
    }

    @MainActor
    static func paste(_ text: String) {
        TextInserter().paste(text)
    }
}

/// Pastes or replaces text in whichever app currently has keyboard focus.
/// The paste path writes to the general pasteboard, then synthesizes Cmd+V so
/// the app's own paste handler runs.
private enum SystemTextInsertion {
    /// Virtual key code for "V" (kVK_ANSI_V from Carbon HIToolbox/Events.h).
    private static let vKeyCode: CGKeyCode = 0x09

    /// Slight delay before synthesizing the Cmd+V keystroke, giving the OS
    /// time to settle after our (non-activating) panel finishes drawing.
    private static let pasteDelay: TimeInterval = 0.05

    static func paste(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
            sendCmdV()
        }
    }

    static func replaceSelection(_ text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard
            focusedResult == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return false
        }

        let focusedElement = focusedValue as! AXUIElement
        return AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private static func sendCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
