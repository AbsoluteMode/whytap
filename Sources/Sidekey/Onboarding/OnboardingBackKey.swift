import AppKit

/// ← and ⌘[ go back a page, like the footer's Back, unless the keyboard is in
/// a text field (the language search, a key field, the try field), where the
/// arrow moves the caret. Physical keys, so ⌘[ works in every input layout.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
enum OnboardingBackKey {
    static let leftArrowKeyCode: UInt16 = 123
    static let leftBracketKeyCode: UInt16 = 33

    static func isBack(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, editingText: Bool) -> Bool {
        guard !editingText else { return false }
        let pressed = modifiers.intersection([.command, .option, .control, .shift])
        switch keyCode {
        case leftArrowKeyCode: return pressed.isEmpty
        case leftBracketKeyCode: return pressed == .command
        default: return false
        }
    }

    /// The window's keyboard is in a text field or text view.
    static func isEditingText(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField
    }
}
