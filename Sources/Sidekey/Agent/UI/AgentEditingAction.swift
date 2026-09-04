import AppKit
import Carbon.HIToolbox

/// Pure-logic classifier for the agent answer surface's editing key
/// equivalents. Maps a key-equivalent `NSEvent` to the responder-chain
/// selector that should handle it, or `nil` if the event is not one of
/// the editing shortcuts we forward.
///
/// Sidekey runs at `.accessory` activation policy (LSUIElement) so it has
/// no main menu. The Edit menu's Copy item normally owns Cmd+C and routes
/// it via `NSApplication.sendAction(_:to:from:)` to whichever responder
/// implements `copy(_:)`. Without that menu the same Cmd+C keystroke is
/// rejected unless a host replays the dispatch manually — which is what the
/// Dynamic Island answer panel's local key monitor does using this
/// classifier. Split out so the host stays a one-liner and the rule is
/// unit-testable without spinning up an `NSPanel`.
///
/// Recognised events:
/// - Cmd+C → `NSText.copy(_:)`
/// - Cmd+A → `NSResponder.selectAll(_:)`
///
/// Cmd+X / Cmd+V are intentionally absent — the answer surface is
/// read-only. Any modifier combo other than plain Cmd is rejected
/// so Cmd+Shift+C and friends stay available for other features.
///
/// Matching is done on the physical `event.keyCode` (Carbon
/// `kVK_ANSI_C` / `kVK_ANSI_A`) rather than on
/// `charactersIgnoringModifiers`, so the shortcut is
/// **layout-independent**: on a Cyrillic ЙЦУКЕН layout the same
/// physical "C" key emits "с" (U+0441 Cyrillic Es) and "A" emits
/// "ф" (U+0444 Cyrillic Ef). A string-compare on those characters
/// silently broke Cmd+C/Cmd+A for Russian-speaking users — keyCode
/// is the source-of-truth for "which physical key was pressed".
enum AgentEditingAction {
    static func action(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return nil }
        switch Int(event.keyCode) {
        case kVK_ANSI_C:
            return #selector(NSText.copy(_:))
        case kVK_ANSI_A:
            return #selector(NSResponder.selectAll(_:))
        default:
            return nil
        }
    }
}
